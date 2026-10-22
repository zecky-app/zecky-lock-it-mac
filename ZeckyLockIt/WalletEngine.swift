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
    /// Public servers over TLS. Your own node (Rock it) on a private address
    /// (home network, this Mac, or Tailscale) without it: at home the traffic
    /// stays inside your network, and Tailscale encrypts it on the way.
    static var endpoint: LightWalletEndpoint { LightWalletEndpoint(address: host, port: port, secure: !isHomeNode(host)) }

    /// 10/8, 172.16/12, 192.168/16, 127/8 or Tailscale's 100.64/10. Same
    /// ranges as the iPhone app.
    static func isHomeNode(_ host: String) -> Bool {
        let parts = host.split(separator: ".")
        guard parts.count == 4 else { return false }
        let n = parts.compactMap { Int($0) }
        guard n.count == 4, n.allSatisfy({ (0...255).contains($0) }) else { return false }
        return n[0] == 10 || n[0] == 127 || (n[0] == 192 && n[1] == 168)
            || (n[0] == 172 && (16...31).contains(n[1])) || (n[0] == 100 && (64...127).contains(n[1]))
    }

    static var isRockIt: Bool { isHomeNode(host) }

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
    @Published private(set) var activity: [ActivityItem] = []
    /// When the current holding began: the first payment in, counted again
    /// from the next payment in if the wallet was ever completely emptied.
    @Published private(set) var lockedSince: Date?

    /// One line in Activity.
    struct ActivityItem: Identifiable, Equatable {
        enum Kind { case received, sent }
        enum State { case waiting, confirmed, expired }
        let id: Data
        let kind: Kind
        let amount: Int64
        let date: Date?
        let state: State
    }

    private var synchronizer: SDKSynchronizer?
    private var account: AccountUUID?
    private var cancellables = Set<AnyCancellable>()

    /// Starts the wallet. Normally without the phrase: the engine only
    /// needs it once, to create the account, and for some upgrades. Then
    /// this returns false and the caller unseals and calls again with it.
    @discardableResult
    func start(birthday: Int, seed: [UInt8]? = nil) async -> Bool {
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
            switch try await synchronizer.prepare(with: seed, walletBirthday: birthday, name: "Zecky", keySource: nil) {
            case .success: break
            case .seedRequired: return false
            case .seedNotRelevant:
                status = .failed("The wallet data on this Mac belongs to other words. Erase and restore with your 24 words.")
                return true
            }
            guard let first = try await synchronizer.listAccounts().first?.id else {
                if seed == nil { return false }
                status = .failed("The wallet account could not be created.")
                return true
            }
            account = first
            try await synchronizer.start(retry: false)
        } catch {
            status = .failed(String(describing: error))
        }
        return true
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
    // MARK: Orchard → Ironwood

    /// Zcash still in the Orchard pool. Since NU6.3 (Ironwood, 28 July 2026,
    /// block 3,428,143) Orchard only allows withdrawals; new Zcash lands in
    /// Ironwood. Only wallets restored from before then can hold Orchard funds.
    @Published var orchardHeld: Int64 = 0

    /// One move of everything in Orchard to this wallet's own Ironwood
    /// receiver: the engine's own migration, with the fee taken so no change
    /// goes back to Orchard. Sapling and Ironwood funds are not touched.
    func planIronwoodMove() async throws -> SendPlan {
        guard let synchronizer, let account else { throw EngineError.notReady }
        let proposal = try await synchronizer.proposeOrchardToIronwoodMigration(accountUUID: account)
        let fee = proposal.totalFeeRequired().amount
        return SendPlan(proposal: proposal, to: "Ironwood", amount: max(0, orchardHeld - fee), fee: fee, toSelf: true)
    }

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

    /// Signs with a key derived from the seed for this payment only, and
    /// hands the result to the server. The caller wipes the seed after.
    func send(_ plan: SendPlan, seed: [UInt8]) async throws -> SendOutcome {
        guard let synchronizer else { throw EngineError.notReady }
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
        await refreshActivity()
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
        activity = []
        lockedSince = nil
        spendable = 0
        total = 0
        orchardHeld = 0
        status = .connecting
    }

    /// Re-reads the wallet's payments, newest first.
    func refreshActivity() async {
        guard let synchronizer, let txs = try? await synchronizer.allTransactions() else { return }
        activity = txs.map { tx in
            let kind: ActivityItem.Kind = tx.isSentTransaction ? .sent : .received
            let state: ActivityItem.State
            if tx.minedHeight != nil { state = .confirmed }
            else if tx.isExpiredUmined == true { state = .expired }
            else { state = .waiting }
            return ActivityItem(id: tx.rawID, kind: kind, amount: Int64(tx.value.amount.magnitude),
                                date: tx.blockTime.map { Date(timeIntervalSince1970: $0) }, state: state)
        }
        .sorted { ($0.date ?? .distantFuture) > ($1.date ?? .distantFuture) }

        var running: Int64 = 0
        var since: Date?
        for item in activity.reversed() where item.state == .confirmed {
            if item.kind == .received {
                if running <= 0 { since = item.date }
                running += item.amount
            } else {
                running -= item.amount
                if running <= 0 { since = nil }
            }
        }
        lockedSince = since
    }

    private func apply(_ state: SynchronizerState) {
        switch state.syncStatus {
        case .unprepared: status = .connecting
        case .syncing(let progress, _): status = .syncing(Int((progress * 100).rounded(.down)))
        case .upToDate:
            status = .upToDate
            Task { await refreshActivity() }
        case .stopped: break
        case .error(let error): status = .failed(String(describing: error))
        }
        var spendable: Int64 = 0
        var total: Int64 = 0
        var orchard: Int64 = 0
        for balance in state.accountsBalances.values {
            orchard += balance.orchardBalance.total().amount
            for pool in [balance.saplingBalance, balance.orchardBalance, balance.ironwoodBalance] {
                spendable += pool.spendableValue.amount
                total += pool.total().amount
            }
            total += balance.unshielded.amount
        }
        self.spendable = spendable
        self.total = total
        self.orchardHeld = orchard
    }
}
