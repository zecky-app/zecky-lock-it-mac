import Combine
import Foundation
import ZcashLightClientKit

/// The light-wallet server, over TLS. Same default and choices as the
/// iPhone app. Not secret, so kept in the app's settings.
enum Server {
    static let defaultHost = "zec.rocks"
    static let presets: [(label: String, host: String)] = [
        ("Default", "zec.rocks"),
        ("Europe", "eu.zec.rocks"),
        ("North America", "na.zec.rocks"),
        ("South America", "sa.zec.rocks"),
        ("Asia Pacific", "ap.zec.rocks"),
    ]
    static var host: String { UserDefaults.standard.string(forKey: "server.host") ?? defaultHost }
    static var port: Int { let p = UserDefaults.standard.integer(forKey: "server.port"); return p == 0 ? 443 : p }
    static var endpoint: LightWalletEndpoint { LightWalletEndpoint(address: host, port: port, secure: true) }

    static func set(host: String, port: Int) {
        UserDefaults.standard.set(host, forKey: "server.host")
        UserDefaults.standard.set(port, forKey: "server.port")
    }

    static func reset() {
        UserDefaults.standard.removeObject(forKey: "server.host")
        UserDefaults.standard.removeObject(forKey: "server.port")
    }
}

/// Where the engine keeps its files: the app's own sandbox container,
/// excluded from Time Machine like the iPhone excludes iCloud backups.
enum WalletFiles {
    static func base(_ name: String) throws -> URL {
        let fm = FileManager.default
        var url = try fm.url(for: .applicationSupportDirectory, in: .userDomainMask, appropriateFor: nil, create: true)
            .appendingPathComponent(name, isDirectory: true)
        try fm.createDirectory(at: url, withIntermediateDirectories: true)
        var values = URLResourceValues()
        values.isExcludedFromBackup = true
        try url.setResourceValues(values)
        return url
    }

    static func initializer(base: URL, alias: ZcashSynchronizerAlias) -> Initializer {
        Initializer(
            cacheDbURL: nil,
            fsBlockDbRoot: base.appendingPathComponent("fs_cache", isDirectory: true),
            generalStorageURL: base.appendingPathComponent("general", isDirectory: true),
            dataDbURL: base.appendingPathComponent("data.db"),
            torDirURL: base.appendingPathComponent("tor", isDirectory: true),
            endpoint: Server.endpoint,
            network: ZcashNetworkBuilder.network(for: .mainnet),
            spendParamsURL: base.appendingPathComponent("sapling-spend.params"),
            outputParamsURL: base.appendingPathComponent("sapling-output.params"),
            saplingParamsSourceURL: .default,
            alias: alias,
            loggingPolicy: .noLogging,
            isTorEnabled: false,
            isExchangeRateEnabled: false
        )
    }
}

/// The chain height, asked once, without any wallet.
enum ChainTip {
    static func latest() async throws -> Int {
        let base = try WalletFiles.base("ChainTip")
        let synchronizer = SDKSynchronizer(initializer: WalletFiles.initializer(base: base, alias: .custom("chaintip")))
        return try await synchronizer.latestHeight()
    }
}

/// Runs the Zcash engine for the stored wallet and publishes what the
/// screens need: status and balance.
@MainActor
final class WalletEngine: ObservableObject {
    enum Status: Equatable {
        case connecting
        case syncing(Int)
        case upToDate
        case failed(String)
    }

    @Published private(set) var status: Status = .connecting
    @Published private(set) var spendable: Int64 = 0
    @Published private(set) var total: Int64 = 0

    private var synchronizer: SDKSynchronizer?
    private var account: AccountUUID?
    private var cancellables = Set<AnyCancellable>()

    func start(_ wallet: StoredWallet) async {
        do {
            // The engine keeps a wallet name taken for the whole app session,
            // so after an erase the same instance is reused for the next wallet.
            let synchronizer: SDKSynchronizer
            if let existing = self.synchronizer {
                synchronizer = existing
            } else {
                let base = try WalletFiles.base("Wallet")
                synchronizer = SDKSynchronizer(initializer: WalletFiles.initializer(base: base, alias: .custom("zecky-main")))
                self.synchronizer = synchronizer
                synchronizer.stateStream
                    .receive(on: DispatchQueue.main)
                    .sink { [weak self] state in self?.apply(state) }
                    .store(in: &cancellables)
            }
            status = .connecting
            let seed = try Mnemonic.seed(from: wallet.phrase)
            _ = try await synchronizer.prepare(with: seed, walletBirthday: wallet.birthday, name: "Zecky", keySource: nil)
            account = try await synchronizer.listAccounts().first?.id
            try await synchronizer.start(retry: false)
        } catch {
            status = .failed(String(describing: error))
        }
    }

    enum EngineError: Error, CustomStringConvertible {
        case notReady
        var description: String { "The wallet is still starting. Try again in a moment." }
    }

    /// A new shielded-only address (Sapling + Orchard, no transparent part).
    /// Every one belongs to the same account and the same balance.
    func freshShieldedAddress() async throws -> String {
        guard let synchronizer, let account else { throw EngineError.notReady }
        return try await synchronizer.getCustomUnifiedAddress(accountUUID: account, receivers: [.sapling, .orchard]).stringEncoded
    }

    /// How many incoming payments each of the wallet's own addresses received.
    func addressUsage() async throws -> [String: Int] {
        guard let synchronizer else { throw EngineError.notReady }
        var counts: [String: Int] = [:]
        for tx in try await synchronizer.allTransactions() where !tx.isSentTransaction {
            var paidTo = Set<String>()
            for output in await synchronizer.getTransactionOutputs(for: tx) where !output.isChange {
                if case .address(let recipient) = output.recipient { paidTo.insert(recipient.stringEncoded) }
            }
            for address in paidTo { counts[address, default: 0] += 1 }
        }
        return counts
    }

    // MARK: Sending

    /// A checked, priced payment, ready for the review screen.
    struct SendPlan {
        let proposal: Proposal
        let to: String
        let amount: Int64
        let fee: Int64
        let toSelf: Bool
    }

    enum SendOutcome {
        /// Delivered to the server.
        case sent
        /// Created and stored, but not delivered yet. The engine resends it
        /// until it is mined or expires, so the owner must not retry.
        case saved
    }

    enum SendError: Error, CustomStringConvertible {
        case badAddress, tooLittle, notEnough, refused(String)
        var description: String {
            switch self {
            case .badAddress: return "That is not a valid Zcash address."
            case .tooLittle: return "Enter an amount above zero."
            case .notEnough: return "Not enough available for this amount plus the fee."
            case .refused(let why): return "The server refused the payment. Nothing was sent. (\(why))"
            }
        }
    }

    /// Prices a payment of `amount` zatoshi, or of everything spendable when nil.
    func plan(to address: String, amount: Int64?) async throws -> SendPlan {
        guard let synchronizer, let account else { throw EngineError.notReady }
        let trimmed = address.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let recipient = try? Recipient(trimmed, network: .mainnet) else { throw SendError.badAddress }
        let own = Set(AddressBook.load())
            .union([(try? await synchronizer.getUnifiedAddress(accountUUID: account).stringEncoded) ?? ""])
        let toSelf = own.contains(trimmed)

        if let amount {
            guard amount > 0 else { throw SendError.tooLittle }
            do {
                let proposal = try await synchronizer.proposeTransfer(
                    accountUUID: account, recipient: recipient, amount: Zatoshi(amount), memo: nil)
                return SendPlan(proposal: proposal, to: trimmed, amount: amount,
                                fee: proposal.totalFeeRequired().amount, toSelf: toSelf)
            } catch {
                if amount > spendable { throw SendError.notEnough }
                throw error
            }
        }
        // Max: the fee depends on how many notes are used, so start from the
        // minimum and adjust until amount + fee is exactly the spendable balance.
        var fee: Int64 = 10_000
        for _ in 0..<12 {
            let amount = spendable - fee
            guard amount > 0 else { throw SendError.notEnough }
            let proposal = try await synchronizer.proposeTransfer(
                accountUUID: account, recipient: recipient, amount: Zatoshi(amount), memo: nil)
            let quoted = proposal.totalFeeRequired().amount
            if quoted == fee {
                return SendPlan(proposal: proposal, to: trimmed, amount: amount, fee: fee, toSelf: toSelf)
            }
            fee = quoted
        }
        throw SendError.notEnough
    }

    /// Signs with a key derived from the phrase for this payment only, and
    /// hands the result to the server.
    func send(_ plan: SendPlan, phrase: String) async throws -> SendOutcome {
        guard let synchronizer else { throw EngineError.notReady }
        let seed = try Mnemonic.seed(from: phrase)
        let key = try DerivationTool(networkType: .mainnet)
            .deriveUnifiedSpendingKey(seed: seed, accountIndex: Zip32AccountIndex(0))
        var outcome: SendOutcome = .sent
        for try await result in try await synchronizer.createProposedTransactions(proposal: plan.proposal, spendingKey: key) {
            switch result {
            case .success: break
            case .grpcFailure: outcome = .saved
            case .submitFailure(_, let code, let description): throw SendError.refused("\(code): \(description)")
            case .notAttempted: outcome = .saved
            }
        }
        return outcome
    }

    /// True while a payment we made is created but not yet mined or expired.
    func hasWaitingPayment() async -> Bool {
        guard let synchronizer, let txs = try? await synchronizer.allTransactions() else { return false }
        return txs.contains { $0.isSentTransaction && $0.minedHeight == nil && $0.isExpiredUmined != true }
    }

    /// Uses another server from now on.
    func switchServer() async throws {
        guard let synchronizer else { return }
        status = .connecting
        try await synchronizer.switchTo(endpoint: Server.endpoint)
    }

    /// Removes the wallet database and everything the engine stored.
    func erase() async throws {
        guard let synchronizer else { return }
        synchronizer.stop()
        for try await _ in synchronizer.wipe().values {}
        account = nil
        spendable = 0
        total = 0
        status = .connecting
    }

    private func apply(_ state: SynchronizerState) {
        switch state.syncStatus {
        case .unprepared: status = .connecting
        case .syncing(let progress, _): status = .syncing(Int((progress * 100).rounded(.down)))
        case .upToDate: status = .upToDate
        case .stopped: break
        case .error(let error): status = .failed(String(describing: error))
        }
        var spendable: Int64 = 0
        var total: Int64 = 0
        for balance in state.accountsBalances.values {
            for pool in [balance.saplingBalance, balance.orchardBalance, balance.ironwoodBalance] {
                spendable += pool.spendableValue.amount
                total += pool.total().amount
            }
            total += balance.unshielded.amount
        }
        self.spendable = spendable
        self.total = total
    }
}
