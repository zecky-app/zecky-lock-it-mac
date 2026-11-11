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
    /// `birthday`: for a brand-new Seal it wallet, a recent height avoids scanning
    /// years of chain.
    @discardableResult
    func importAccount(fromAccountsUR message: Data, birthday: BlockHeight?) async throws -> AccountUUID {
        let export = try SealItPayload.parseAccounts(message)
        let account = export.accounts[0]

        // Don't import the same signer account twice.
        for existing in await sealItAccounts()
        where existing.seedFingerprint == export.seedFingerprint
            && existing.hdAccountIndex?.index == account.index {
            return existing.id
        }

        return try await synchronizer.importAccount(
            ufvk: account.ufvk,
            seedFingerprint: export.seedFingerprint,
            zip32AccountIndex: Zip32AccountIndex(account.index),
            purpose: .spending,          // as Zashi does for Keystone: enables PCZT spending
            name: account.name.flatMap { $0.isEmpty ? nil : $0 } ?? "Seal it",
            keySource: Self.keySource,
            birthday: birthday
        )
    }

    /// Removes a sealed wallet from Lock it. Its keys stay on the phone, so it
    /// can be paired again at any time.
    func removeAccount(_ id: AccountUUID) async throws {
        reset()
        try await synchronizer.deleteAccount(id)
    }

    /// A safe birthday for a brand-new signer seed: a little below the chain tip.
    func recentBirthday() async -> BlockHeight? {
        guard let tip = try? await synchronizer.latestHeight() else { return nil }
        return max(tip - 1_000, 0)
    }

    // MARK: Sending

    /// Starts sealing a payment priced on the Send screen (the same checks
    /// and receipt as the lock; Sapling-only addresses are refused there).
    func startSend(from account: AccountUUID, proposal: Proposal) async {
        reset()
        do {
            step = .preparing("Building the payment…")
            try NetworkUpgrade.checkReleases(networkHeight: (try? await synchronizer.latestHeight()) ?? 0)
            let pczt = try await synchronizer.createPCZTFromProposal(accountUUID: account, proposal: proposal)

            // Proofs are made here on the Mac, on the full PCZT, while the phone signs.
            let sync = synchronizer
            provingTask = Task { try await sync.addProofsToPCZT(pczt: pczt) }

            let redacted = try await synchronizer.redactPCZTForSigner(pczt: pczt)
            step = .showUnsigned(.pczt(redacted))
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
            let signed = try SealItPayload.parsePczt(message)
            guard let provingTask else { throw FlowError.noPendingTransaction }

            step = .preparing("Finishing the proofs…")
            let proven = try await provingTask.value

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
                return "Seal it can't sign to an old Sapling-only address. Use a u1… or t1… address."
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
