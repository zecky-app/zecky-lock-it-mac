//
//  SealItFlow.swift
//  Zecky Lock it (Mac) — Seal it / Keystone air-gapped signing
//
//  The wallet side of the air-gapped flow, on ZcashLightClientKit 3.0.0:
//
//    Pair:  scan ur:zcash-accounts  -> importAccount(ufvk:..., keySource: "sealit")
//    Send:  proposeTransfer -> createPCZTFromProposal
//             -> redactPCZTForSigner  (shown as ur:zcash-pczt)
//             -> addProofsToPCZT      (on the ORIGINAL, unredacted PCZT, in parallel)
//           scan signed ur:zcash-pczt
//             -> createTransactionFromPCZT(pcztWithProofs:pcztWithSigs:)  (finalize + send)
//
//  Spending keys never touch this Mac. Seal it refuses anything with Sapling in
//  it, so Sapling-only recipients are refused up front.
//

import Foundation
import ZcashLightClientKit

@MainActor
/// Watch-only wallets: added from someone's (or your shop's) viewing key and
/// imported as view-only, so the engine itself refuses to spend from them.
enum WatchOnly {
    nonisolated static let keySource = "watch"
    /// Orchard's start (NU5): the earliest a unified viewing key can have
    /// shielded funds, for "I don't know since when".
    nonisolated static let orchardStart = 1_687_104

    nonisolated static func isWatch(_ account: Account) -> Bool { account.keySource == keySource }

    /// The engine's refusal of a key that belongs to a wallet already here
    /// (in another form of the same key).
    nonisolated static func isCollision(_ text: String) -> Bool {
        text.range(of: #"collision|already exists|already been imported|duplicate"#,
                   options: [.regularExpression, .caseInsensitive]) != nil
    }

    /// Receive for a watch-only wallet: a key without an Orchard part (an
    /// older wallet) has no shielded address Lock it can show.
    nonisolated static func addressProblem(_ text: String) -> String {
        if text.range(of: "orchard", options: .caseInsensitive) != nil || text.range(of: "receiver", options: .caseInsensitive) != nil {
            return "This viewing key has no Orchard part, so Lock it cannot show a shielded address for it. Payments to the wallet's own addresses still show here."
        }
        return "No address could be shown for this wallet. Payments to its addresses still show here."
    }

    /// The Business row in Settings.
    nonisolated static func summary(count: Int) -> String {
        switch count {
        case 0: return "Watch only · viewing key · CSV"
        case 1: return "1 watch-only wallet"
        default: return "\(count) watch-only wallets"
        }
    }

    enum Failure: LocalizedError, Equatable {
        case notAViewingKey, testnet, alreadyHere, noName
        var errorDescription: String? {
            switch self {
            case .notAViewingKey: return "That is not a Zcash viewing key. It starts with uview1…; in Lock it: Settings › Viewing key."
            case .testnet: return "That is a testnet viewing key. Lock it works on mainnet (uview1…)."
            case .alreadyHere: return "That wallet is already in Lock it."
            case .noName: return "Give the wallet a name, for example Shop."
            }
        }
    }

    /// A pasted or scanned key, checked: a mainnet unified full viewing key.
    nonisolated static func cleaned(_ raw: String) throws -> String {
        let key = raw.trimmingCharacters(in: .whitespacesAndNewlines.union(.controlCharacters))
        if key.lowercased().hasPrefix("uviewtest") { throw Failure.testnet }
        guard key.hasPrefix("uview1"), (try? UnifiedFullViewingKey(encoding: key, network: .mainnet)) != nil else {
            throw Failure.notAViewingKey
        }
        return key
    }

    /// The name on the key ring: trimmed, at most 40 characters, not empty.
    nonisolated static func name(_ raw: String) -> String? {
        let name = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        return name.isEmpty ? nil : String(name.prefix(40))
    }
}

final class SealItFlow: ObservableObject {
    enum Step {
        case idle
        case preparing(String)
        case showUnsigned(SealItUREncoder)
        case scanSigned
        case broadcasting
        case sent(txId: String)
        case failed(String)
    }

    /// Marks the imported account.
    nonisolated static let keySource = "sealit"
    nonisolated static let keySources: Set<String> = ["sealit"]

    nonisolated static func isSealIt(_ account: Account) -> Bool {
        guard let source = account.keySource else { return false }
        return keySources.contains(source)
    }

    @Published private(set) var step: Step = .idle

    private let synchronizer: SDKSynchronizer
    private let network: NetworkType
    private var provingTask: Task<Pczt, Error>?

    init(synchronizer: SDKSynchronizer, network: NetworkType) {
        self.synchronizer = synchronizer
        self.network = network
    }

    // MARK: Pairing

    /// Seal it accounts in this wallet.
    func sealItAccounts() async -> [Account] {
        let all = (try? await synchronizer.listAccounts()) ?? []
        return all.filter { Self.isSealIt($0) }
    }

    /// Imports the first account from a scanned `ur:zcash-accounts` message.
    /// `choice`: the owner's answer to "new or already used?" (PairingStart),
    /// so a new wallet is ready in seconds and a used one shows its history.
    @discardableResult
    func importAccount(fromAccountsUR message: Data, start choice: PairingStart) async throws -> AccountUUID {
        let export = try SealItPayload.parseAccounts(message)
        let account = export.accounts[0]

        // Don't import the same signer account twice.
        for existing in await sealItAccounts() {
            if let fingerprint = export.seedFingerprint {
                if existing.seedFingerprint == fingerprint && existing.hdAccountIndex?.index == account.index { return existing.id }
            } else if existing.ufvk?.stringEncoded == account.ufvk {
                return existing.id
            }
        }

        // Where to start is the owner's answer to "new or already used?";
        // which device it is shows only now, after the scan.
        let tip = (try? await synchronizer.latestHeight()).map { Int($0) } ?? Birthday.estimatedTip()
        let start: BlockHeight? = BlockHeight(PairingStart.height(choice, cupcake: export.fromCupcake, tip: tip))
        let id = try await synchronizer.importAccount(
            ufvk: account.ufvk,
            seedFingerprint: export.seedFingerprint,
            zip32AccountIndex: export.seedFingerprint == nil ? nil : Zip32AccountIndex(account.index),
            purpose: .spending,          // as Zashi does for Keystone: enables PCZT spending
            name: Self.walletName(account.name, cupcake: export.fromCupcake),
            keySource: Self.keySource,
            birthday: start
        )
        if let start { WalletStarts.set(id, Int(start)) }
        return id
    }

    /// The name of a newly paired wallet says where it signs: "Keystone ·
    /// Account 0", "Cupcake · My wallet". A wallet with a seed fingerprint
    /// comes from Keystone (Seal it uses the same QR but is not live).
    nonisolated static func walletName(_ given: String?, cupcake: Bool) -> String {
        let device = cupcake ? "Cupcake" : "Keystone"
        let name = (given ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        if name.isEmpty || name.caseInsensitiveCompare(device) == .orderedSame { return device }
        if name.lowercased().hasPrefix(device.lowercased()) { return String(name.prefix(40)) }
        return String("\(device) · \(name)".prefix(40))
    }

    /// Removes a sealed wallet from Lock it. Its keys stay on the phone, so it
    /// can be paired again at any time.
    func removeAccount(_ id: AccountUUID) async throws {
        reset()
        try await synchronizer.deleteAccount(id)
    }

    /// A safe birthday for a brand-new signer seed: a little below the chain tip.

    // MARK: Sending

    /// Starts sealing a payment priced on the Send screen (the same checks
    /// and receipt as the lock; Sapling-only addresses are refused there).
    /// The payment being signed goes to Cupcake, which uses its own PCZT layout.
    private var signerIsCupcake = false

    func startSend(from account: AccountUUID, proposal: Proposal) async {
        reset()
        do {
            step = .preparing("Building the payment…")
            try NetworkUpgrade.checkReleases(networkHeight: (try? await synchronizer.latestHeight()) ?? 0)
            let pczt = try await synchronizer.createPCZTFromProposal(accountUUID: account, proposal: proposal)

            // A wallet paired from Cupcake has no seed fingerprint.
            let cupcake = (try? await synchronizer.listAccounts())?.first { $0.id == account }.map { $0.seedFingerprint == nil } ?? false
            signerIsCupcake = cupcake
            if cupcake {
                // Cupcake signs and then makes the proofs itself (as Zkool
                // does), so it gets the whole PCZT, witnesses included, in
                // its shielded-assets layout (same content, empty asset fields).
                step = .showUnsigned(.pczt(try CupcakePczt.toCupcake(pczt), forCupcake: true))
                return
            }

            // Proofs are made here on the Mac, on the full PCZT, while the phone signs.
            let sync = synchronizer
            provingTask = Task { try await sync.addProofsToPCZT(pczt: pczt) }

            let redacted = try await synchronizer.redactPCZTForSigner(pczt: pczt)
            step = .showUnsigned(.pczt(redacted, forCupcake: false))
        } catch {
            fail(error)
        }
    }

    /// The phone has approved; show the camera for the signed code.
    func readyToScanSigned() {
        step = .scanSigned
    }

    /// Called with the complete `ur:zcash-pczt` message scanned from the signer.
    func receivedSigned(message: Data) async {
        do {
            let scanned = try SealItPayload.parsePczt(message)
            let signed: Data
            let proven: Data
            if signerIsCupcake {
                // Cupcake's reply carries its own proofs and signatures; the
                // engine checks both before anything is sent.
                signed = try CupcakePczt.fromCupcake(scanned)
                proven = signed
            } else {
                signed = scanned
                guard let provingTask else { throw FlowError.noPendingTransaction }
                step = .preparing("Finishing the proofs…")
                proven = try await provingTask.value
            }

            try NetworkUpgrade.checkReleases(networkHeight: (try? await synchronizer.latestHeight()) ?? 0)
            step = .broadcasting
            // Made first, handed over second, as on the Send screen: over
            // Tor to public servers, or to the server Lock it reads from.
            let created = try await synchronizer.broadcaster.createTransactionFromPCZT(
                pcztWithProofs: proven,
                pcztWithSigs: signed
            )
            let overTor = TorSending.isOn
            let reports = await synchronizer.broadcaster.submit(
                transactions: created, to: Server.broadcastEndpoints(overTor: overTor), timing: TorSending.timing(overTor: overTor))
            var lastTxId: Data?
            for report in reports {
                // Not delivered yet: stored; the engine resends it the same
                // way until it is mined or expires.
                lastTxId = report.txId
                if case .rejected(let code, let message) = report.outcome {
                    throw FlowError.submit("\(message) (\(code))")
                }
                if case .accepted = report.outcome { Undelivered.remove(report.txId) } else { Undelivered.insert(report.txId) }
            }
            self.provingTask = nil
            step = .sent(txId: lastTxId.map(Self.displayTxId) ?? "")
        } catch {
            fail(error)
        }
    }

    func reset() {
        provingTask?.cancel()
        provingTask = nil
        signerIsCupcake = false
        step = .idle
    }

    private func fail(_ error: Error) {
        provingTask?.cancel()
        provingTask = nil
        step = .failed((error as? LocalizedError)?.errorDescription ?? String(describing: error))
    }

    /// Zcash shows txids byte-reversed, like Bitcoin.
    private static func displayTxId(_ data: Data) -> String {
        data.reversed().map { String(format: "%02x", $0) }.joined()
    }

    enum FlowError: LocalizedError {
        case saplingRecipient
        case noteToPublic
        case noPendingTransaction
        case submit(String)

        var errorDescription: String? {
            switch self {
            case .saplingRecipient:
                return "A signing device can't sign to an old Sapling-only address. Use a u1… or t1… address."
            case .noteToPublic:
                return "A private note can only go to a shielded address. Remove the note, or use their u1… address."
            case .noPendingTransaction:
                return "No payment is waiting for this signature. Start again."
            case .submit(let reason):
                return "The server refused the payment: \(reason)"
            }
        }
    }
}

/// Pairing a signing device: the owner says whether the wallet is new or
/// already holds Zcash, and since when. A new wallet starts 1,000 blocks
/// back (seconds, with the exact tree state). A used one starts a little
/// before the month given, or, when unknown, where the device added Zcash:
/// Keystone with Zashi in December 2024, Cupcake after NU7.
enum PairingStart: Equatable {
    case new
    case since(year: Int, month: Int)
    case unknown

    /// Keystone's shielded Zcash (with Zashi) came on 19 December 2024.
    nonisolated static let keystoneYear = 2024, keystoneMonth = 12

    static func height(_ choice: PairingStart, cupcake: Bool, tip: Int, now: Date = Date()) -> Int {
        switch choice {
        case .new:
            return max(tip - 1_000, WatchOnly.orchardStart)
        case .since(let year, let month):
            return min(max(Birthday.estimate(year: year, month: month, tip: tip, now: now), WatchOnly.orchardStart), max(tip - 1_000, WatchOnly.orchardStart))
        case .unknown:
            if cupcake { return NetworkUpgrade.nu7Height }
            return Birthday.estimate(year: keystoneYear, month: keystoneMonth, tip: tip, now: now)
        }
    }
}
