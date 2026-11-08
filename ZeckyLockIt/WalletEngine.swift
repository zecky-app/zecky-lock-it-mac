import Combine
import Foundation
import ZcashLightClientKit
import libzcashlc

/// The light-wallet server, over TLS. Same default and choices as the
/// iPhone app. The chosen server can name your own node (a home or Tailscale
/// address), so it is kept in the Keychain (this Mac only, never synced or
/// in a backup), not in the app's settings file (iPhone audit C-29).
enum Server {
    static let defaultHost = "zec.rocks"
    static let presets: [(label: String, host: String)] = [
        ("Default", "zec.rocks"),
        ("Europe", "eu.zec.rocks"),
        ("North America", "na.zec.rocks"),
        ("South America", "sa.zec.rocks"),
        ("Asia Pacific", "ap.zec.rocks"),
    ]
    static var host: String { saved?.host ?? defaultHost }
    static var port: Int { saved?.port ?? 443 }

    private struct Saved: Codable, Equatable { var host: String; var port: Int }
    private static let service = "app.zecky.lockit.mac.server"
    private static var loaded = false
    private static var cache: Saved?

    private static var saved: Saved? {
        if !loaded {
            loaded = true
            cache = (try? KeyStore.read(service: service)).flatMap { $0 }.flatMap { try? JSONDecoder().decode(Saved.self, from: $0) }
            // Once: move a server chosen by an earlier version out of the settings file.
            if let host = UserDefaults.standard.string(forKey: "server.host") {
                let port = UserDefaults.standard.integer(forKey: "server.port")
                if cache == nil { set(host: host, port: port == 0 ? 443 : port) }
                UserDefaults.standard.removeObject(forKey: "server.host")
                UserDefaults.standard.removeObject(forKey: "server.port")
            }
        }
        return cache
    }
    /// Public servers over TLS. Your own node (Rock it) on a private address
    /// (home network, this Mac, or Tailscale) without it: at home the traffic
    /// stays inside your network, and Tailscale encrypts it on the way.
    static var endpoint: LightWalletEndpoint { LightWalletEndpoint(address: host, port: port, secure: !isHomeNode(host)) }

    /// 10/8, 172.16/12, 192.168/16, 127/8 or Tailscale's 100.64/10. Same
    /// ranges as the iPhone app.
    static func isHomeNode(_ host: String) -> Bool {
        let parts = host.split(separator: ".", omittingEmptySubsequences: false)
        // No leading zeros: "010" can be read as octal by the system and
        // point at a public address (iPhone audit C-27).
        guard parts.count == 4,
              parts.allSatisfy({ $0.range(of: #"^(0|[1-9][0-9]{0,2})$"#, options: .regularExpression) != nil })
        else { return false }
        let n = parts.compactMap { Int($0) }
        guard n.count == 4, n.allSatisfy({ (0...255).contains($0) }) else { return false }
        return n[0] == 10 || n[0] == 127 || (n[0] == 192 && n[1] == 168)
            || (n[0] == 172 && (16...31).contains(n[1])) || (n[0] == 100 && (64...127).contains(n[1]))
    }

    static var isRockIt: Bool { isHomeNode(host) }

    /// One of the built-in public servers, reached over TLS.
    static var isBuiltIn: Bool { port == 443 && presets.contains { $0.host == host } }

    /// Where your own node is reached. None of these proves it is really
    /// your node: a home address can be answered by another network's
    /// device with the same numbers, and a 100.x address is only a
    /// Tailscale IP. Said so plainly, as on the iPhone (self-audit N2, R4).
    enum NodeKind { case homeNetwork, tailscaleIP, thisMac }
    static func nodeKind(_ host: String) -> NodeKind? {
        guard isHomeNode(host) else { return nil }
        let n = host.split(separator: ".").compactMap { Int($0) }
        if n.first == 127 { return .thisMac }
        if n.first == 100 { return .tailscaleIP }
        return .homeNetwork
    }

    /// "Rock it · home network" for the status line and Settings.
    static var nodeLabel: String? {
        switch nodeKind(host) {
        case .homeNetwork?: return "Rock it · home network"
        case .tailscaleIP?: return "Rock it · Tailscale IP"
        case .thisMac?: return "Rock it · this Mac"
        case nil: return nil
        }
    }

    static func set(host: String, port: Int) {
        let value = Saved(host: host, port: port)
        if let data = try? JSONEncoder().encode(value) { try? KeyStore.save(data, service: service) }
        loaded = true
        cache = value
    }

    /// Your own server (host:port), kept when you switch to a public one,
    /// so switching back needs no typing. In the Keychain like the server
    /// itself: a home or Tailscale address is private.
    private static let ownService = "app.zecky.lockit.mac.server.own"
    static var ownServer: String? {
        (try? KeyStore.read(service: ownService)).flatMap { $0 }.map { String(decoding: $0, as: UTF8.self) }
    }
    static func rememberOwn(_ text: String) {
        try? KeyStore.save(Data(text.utf8), service: ownService)
    }

    static func reset() {
        try? KeyStore.delete(service: service)
        try? KeyStore.delete(service: ownService)
        UserDefaults.standard.removeObject(forKey: "server.host")
        UserDefaults.standard.removeObject(forKey: "server.port")
        loaded = true
        cache = nil
    }
}

/// Where the engine keeps its files: the app's own sandbox container,
/// excluded from Time Machine like the iPhone excludes iCloud backups.
enum WalletFiles {
    /// The Sapling parameters shipped in the app (as Lock it iPhone, audit
    /// C-24): copied next to the wallet before the engine starts, under the
    /// names the engine looks for. The engine finds them there, checks their
    /// SHA-1 and never downloads them from download.z.cash. The build checks
    /// their SHA-256 (scripts/check-engine.sh).
    static func placeSaplingParams(base: URL, aliasName: String) {
        let fm = FileManager.default
        for name in ["sapling-spend", "sapling-output"] {
            let target = base.appendingPathComponent("\(aliasName)_\(name).params")
            guard !fm.fileExists(atPath: target.path),
                  let source = Bundle.main.url(forResource: name, withExtension: "params") else { continue }
            try? fm.copyItem(at: source, to: target)
        }
    }

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

    /// The small folder used to ask the chain height before a wallet exists.
    /// Holds no wallet data; removed on Erase so nothing is left behind.
    static func removeChainTip() {
        guard let url = try? FileManager.default.url(for: .applicationSupportDirectory, in: .userDomainMask, appropriateFor: nil, create: false)
            .appendingPathComponent("ChainTip", isDirectory: true) else { return }
        try? FileManager.default.removeItem(at: url)
    }

    static func initializer(base: URL, alias: ZcashSynchronizerAlias) -> Initializer {
        if case .custom(let name) = alias, name != "chaintip" { placeSaplingParams(base: base, aliasName: name) }
        return Initializer(
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

    @Published private(set) var status: Status = .connecting {
        didSet {
            if case .failed(let text) = status { recordProblem(text) }
            if status == .connecting { if connectingSince == nil { connectingSince = Date() } }
            else { connectingSince = nil }
        }
    }
    /// Since when the engine is trying to reach the server, to say so
    /// instead of "Connecting…" forever (iPhone t16).
    @Published private(set) var connectingSince: Date? = Date()
    /// Since when the connection keeps dropping while syncing; cleared as
    /// soon as syncing moves forward.
    @Published private(set) var droppedSince: Date?

    /// True when the server has not answered for 30 seconds, or the engine
    /// reported a connection error.
    func serverUnreachable(now: Date = Date()) -> Bool {
        if let since = connectingSince, now.timeIntervalSince(since) > 30 { return true }
        // A dropped connection retries by itself; only after 3 minutes
        // without progress is another server suggested.
        if let since = droppedSince { return now.timeIntervalSince(since) > SyncMath.droppedPatience }
        if case .failed(let text) = status {
            let t = text.lowercased()
            return ["unavailable", "timed out", "timeout", "connect", "grpc", "network", "deadline", "unreachable", "refused"].contains { t.contains($0) }
        }
        return false
    }
    @Published private(set) var spendable: Int64 = 0
    @Published private(set) var total: Int64 = 0
    @Published private(set) var activity: [ActivityItem] = []
    /// When the current holding began: the first payment in after the lock
    /// was last empty (from the history; see Holding).
    @Published private(set) var lockedSince: Date?
    /// The confirmed history of the wallet on the key ring, for the count.
    @Published private(set) var holdingEntries: [HoldingEntry] = []
    /// Payments to that wallet still waiting for their block, in zatoshi.
    @Published private(set) var pendingIn: Int64 = 0

    /// Fully synced at least once on this Mac. After a restore the newest
    /// blocks are scanned first, so the count waits for this; later
    /// catch-ups keep it (no flicker at launch). Cleared on Erase.
    static let syncedOnceKey = "app.zecky.lockit.mac.syncedOnce"
    @Published private(set) var syncedOnce = UserDefaults.standard.bool(forKey: WalletEngine.syncedOnceKey)

    /// One line in Activity.
    struct ActivityItem: Identifiable, Equatable {
        enum Kind { case received, sent }
        enum State { case waiting, confirmed, expired }
        let id: Data
        let kind: Kind
        let amount: Int64
        let date: Date?
        let state: State
        var minedHeight: Int? = nil
    }

    /// The network's latest block, from the engine's state.
    @Published var networkHeight: Int = 0

    // How long until Zcash that is still confirming can be used, as on the
    // iPhone (src/lib/confirmations.ts): 10 confirmations for Zcash from
    // someone else, 3 for the wallet's own change. A block takes about 75 s,
    // and 25 s from NU7 (BlockTime).
    nonisolated static let confirmationsReceived = 10
    nonisolated static let confirmationsOwn = 3

    struct Waiting: Equatable { let confirmations: Int; let needed: Int; let minutes: Int }

    /// The payment that becomes usable last, or nil.
    nonisolated static func slowestWaiting(_ items: [ActivityItem], networkHeight: Int) -> Waiting? {
        guard networkHeight > 0 else { return nil }
        var best: (w: Waiting, left: Int)?
        for item in items where item.state != .expired {
            let needed = item.kind == .received ? confirmationsReceived : confirmationsOwn
            let confirmations = item.minedHeight.map { max(0, min(needed, networkHeight - $0 + 1)) } ?? 0
            guard confirmations < needed else { continue }
            let left = needed - confirmations
            if best == nil || left > best!.left {
                best = (Waiting(confirmations: confirmations, needed: needed,
                                minutes: max(1, Int((Double(BlockTime.seconds(from: networkHeight, to: networkHeight + left)) / 60).rounded()))), left)
            }
        }
        return best?.w
    }

    /// "usable in about 6 minutes · 4/10 confirmations"
    nonisolated static func waitingText(_ w: Waiting?, networkHeight: Int = 0) -> String {
        guard let w else {
            let minutes = networkHeight >= NetworkUpgrade.nu7Height ? 4 : 12
            return "usable within about \(minutes) minutes"
        }
        let time = w.minutes <= 1 ? "about a minute" : "about \(w.minutes) minutes"
        let progress = w.confirmations == 0 ? "waiting for a block" : "\(w.confirmations)/\(w.needed) confirmations"
        return "usable in \(time) · \(progress)"
    }

    private var synchronizer: SDKSynchronizer?
    private var account: AccountUUID?
    private var cancellables = Set<AnyCancellable>()

    /// Starts the wallet. Normally without the phrase: the engine only
    /// needs it once, to create the account, and for some upgrades. Then
    /// this returns false and the caller unseals and calls again with it.
    @discardableResult
    func start(birthday: Int, seed: [UInt8]? = nil) async -> Bool {
        birthdayHeight = birthday
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
            // The wallet's own account: the one made from the 24 words, not a
            // Seal it watch-only account imported next to it.
            let all = try await synchronizer.listAccounts()
            // The wallet that holds the lock: the first one, or the one the
            // lock passed to when that was erased.
            let lead = UserDefaults.standard.string(forKey: Self.leadKey)
            guard let first = (all.first(where: { lead != nil && KeyRingVault.hex($0.id) == lead })
                               ?? all.first(where: { $0.keySource == nil })
                               ?? all.first(where: { !SealItFlow.isSealIt($0) && $0.keySource != Self.macKeySource }))?.id else {
                if seed == nil { return false }
                status = .failed("The wallet account could not be created.")
                return true
            }
            account = first
            await refreshSealedWallets()
            try await synchronizer.start(retry: false)
            // Ask the server for today's block right away, instead of
            // waiting until the engine has prepared its first batch.
            if networkHeight == 0, let tip = try? await synchronizer.latestHeight(), tip > 0, networkHeight == 0 {
                networkHeight = tip
            }
        } catch {
            status = .failed(String(describing: error))
        }
        return true
    }

    /// The engine and the wallet's own account, for the Seal it flow.
    var sdk: SDKSynchronizer? { synchronizer }
    var mainAccount: AccountUUID? { account }

    /// Balance of the signer's watch-only account(s), kept apart from the lock.
    @Published private(set) var signerSpendable: Int64 = 0
    @Published private(set) var signerTotal: Int64 = 0
    /// The Seal it wallets on the key ring, in the order they were added.
    @Published private(set) var sealedWallets: [Account] = []
    /// Extra wallets with their keys on this Mac (words in the key ring vault).
    @Published private(set) var macWallets: [Account] = []

    nonisolated static let macKeySource = "lockit"
    /// The account whose words hold the lock, once the lock has passed on.
    nonisolated static let leadKey = "app.zecky.lockit.mac.leadAccount"
    /// The wallet whose words hold the lock ("This Mac" until renamed).
    @Published private(set) var leadWallet: Account?

    func refreshSealedWallets() async {
        guard let synchronizer else { sealedWallets = []; macWallets = []; leadWallet = nil; return }
        let all = (try? await synchronizer.listAccounts()) ?? []
        sealedWallets = all.filter { SealItFlow.isSealIt($0) }
        macWallets = all.filter { $0.keySource == Self.macKeySource && $0.id != account }
        leadWallet = all.first { $0.id == account }
    }

    /// The lock has passed to `successor` (see WalletVault.handOver): it
    /// becomes the wallet the engine starts with, and the old one goes.
    func handLead(to successor: AccountUUID) async throws {
        guard let synchronizer, let old = account, successor != old else { throw EngineError.notReady }
        account = successor
        UserDefaults.standard.set(KeyRingVault.hex(successor), forKey: Self.leadKey)
        focus = nil
        try await synchronizer.deleteAccount(old)
        await refreshSealedWallets()
        await refreshActivity()
    }

    /// The wallet on the key ring the screens show: nil is the main wallet.
    @Published var focus: AccountUUID? {
        didSet { if focus != oldValue { Task { await refreshActivity() } } }
    }

    private var current: AccountUUID? { focus ?? account }

    /// What the chosen wallet can spend now.
    var focusSpendable: Int64 {
        guard let focus else { return spendable }
        return signerBalances[focus]?.spendable ?? 0
    }

    /// What a given wallet can spend now: nil is the one on the key ring.
    func spendable(of account: AccountUUID?) -> Int64 {
        guard let account else { return focusSpendable }
        if account == self.account { return spendable }
        return signerBalances[account]?.spendable ?? 0
    }

    /// Adds a wallet with its own 24 words on this Mac. Returns its account.
    func addMacWallet(name: String, phrase: String, birthday: Int) async throws -> AccountUUID {
        guard let synchronizer else { throw EngineError.notReady }
        var seed = try Mnemonic.seed(from: phrase)
        defer { Wipe.bytes(&seed) }
        let tool = DerivationTool(networkType: .mainnet)
        let usk = try tool.deriveUnifiedSpendingKey(seed: seed, accountIndex: Zip32AccountIndex(0))
        let ufvk = try tool.deriveUnifiedFullViewingKey(from: usk)
        // The engine wants the seed's ZIP 32 fingerprint together with the
        // account index (both or neither). It comes from the engine itself.
        var fingerprint = [UInt8](repeating: 0, count: 32)
        let made = seed.withUnsafeBufferPointer { s in
            fingerprint.withUnsafeMutableBufferPointer { f in
                zcashlc_seed_fingerprint(s.baseAddress, UInt(s.count), f.baseAddress)
            }
        }
        guard made else { throw EngineError.notReady }
        let id = try await synchronizer.importAccount(
            ufvk: ufvk.stringEncoded, seedFingerprint: fingerprint, zip32AccountIndex: Zip32AccountIndex(0),
            purpose: .spending, name: name, keySource: Self.macKeySource, birthday: BlockHeight(birthday))
        await refreshSealedWallets()
        return id
    }

    /// Removes a wallet from the key ring (never the main one).
    func removeWallet(_ id: AccountUUID) async throws {
        guard let synchronizer, id != account else { return }
        if focus == id { focus = nil }
        try await synchronizer.deleteAccount(id)
        await refreshSealedWallets()
    }

    /// Per sealed wallet: (usable, total) in zatoshi.
    @Published private(set) var signerBalances: [AccountUUID: (spendable: Int64, total: Int64)] = [:]

    enum EngineError: Error, CustomStringConvertible {
        case notReady
        var description: String { "The wallet is still starting. Try again in a moment." }
    }

    /// A new shielded-only address (Sapling + Orchard, no transparent part).
    /// Every one belongs to the same account and the same balance.
    func freshShieldedAddress() async throws -> String {
        guard let synchronizer, let current else { throw EngineError.notReady }
        return try await synchronizer.getCustomUnifiedAddress(accountUUID: current, receivers: [.sapling, .orchard]).stringEncoded
    }

    /// How many incoming payments each of the wallet's own addresses received.
    func addressUsage() async throws -> [String: Int] {
        guard let synchronizer else { throw EngineError.notReady }
        var counts: [String: Int] = [:]
        for tx in try await synchronizer.allTransactions() where !tx.isSentTransaction && tx.accountUUID == current {
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
        var memo: String? = nil
        /// Lock it in and the Ironwood move: Zcash stays in this wallet, so
        /// they do not need the open lock. Only set by planLockIn and
        /// planIronwoodMove.
        var staysInWallet = false
    }

    enum SendOutcome {
        /// Delivered to the server.
        case sent
        /// Created and stored, but not delivered yet. The engine resends it
        /// until it is mined or expires, so the owner must not retry.
        case saved
    }

    enum SendError: Error, CustomStringConvertible {
        case badAddress, tooLittle, belowFee, notEnough, noteToPublic, refused(String), lockClosed, busy
        var description: String {
            switch self {
            case .badAddress: return "That is not a valid Zcash address."
            case .tooLittle: return "Enter an amount above zero."
            case .belowFee: return "This amount is not more than the fee, so nothing would arrive. Enter a larger amount."
            case .notEnough: return "Not enough available for this amount plus the fee."
            case .noteToPublic: return "A private note can only go to a shielded address. Remove the note, or use their shielded address."
            case .refused(let why): return "The server refused the payment. Nothing was sent. (\(why))"
            case .lockClosed: return "The lock closed before the payment was signed. Nothing was sent. Open the lock and try again."
            case .busy: return "Another payment is being sent right now. Wait until it is done."
            }
        }
    }

    /// What to show when pricing a payment failed: the engine's "not enough
    /// funds" in plain words, never its raw text.
    nonisolated static func planProblem(_ error: Error) -> String {
        if let e = error as? ZcashError, case .rustProposalInsufficientFunds = e { return SendError.notEnough.description }
        return String(describing: error)
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
        try NetworkUpgrade.checkReleases(networkHeight: networkHeight)
        let proposal = try await synchronizer.proposeOrchardToIronwoodMigration(accountUUID: account)
        let fee = proposal.totalFeeRequired().amount
        return SendPlan(proposal: proposal, to: "Ironwood", amount: max(0, orchardHeld - fee), fee: fee, toSelf: true, staysInWallet: true)
    }

    // MARK: Outside the lock

    /// Zcash on a public (transparent) address. Lock it never hands one out,
    /// but a wallet restored from another app can have some.
    @Published var outsideTheLock: Int64 = 0

    /// Locks public Zcash in: shields it into this wallet's private pool.
    func planLockIn() async throws -> SendPlan {
        guard let synchronizer, let account else { throw EngineError.notReady }
        try NetworkUpgrade.checkReleases(networkHeight: networkHeight)
        guard let proposal = try await synchronizer.proposeShielding(
            accountUUID: account, shieldingThreshold: Zatoshi(10_000), memo: .empty, transparentReceiver: nil)
        else { throw SendError.tooLittle }
        let fee = proposal.totalFeeRequired().amount
        return SendPlan(proposal: proposal, to: "Lock it in", amount: max(0, outsideTheLock - fee), fee: fee, toSelf: true, staysInWallet: true)
    }

    /// Prices a payment from `from` (nil: the wallet on the key ring).
    func plan(to address: String, amount: Int64?, memo text: String? = nil, feeIncluded: Bool = false,
              from: AccountUUID? = nil) async throws -> SendPlan {
        guard let synchronizer, let account = from ?? current else { throw EngineError.notReady }
        try NetworkUpgrade.checkReleases(networkHeight: networkHeight)
        let spendable = self.spendable(of: account)
        let trimmed = address.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let recipient = try? Recipient(trimmed, network: .mainnet) else { throw SendError.badAddress }
        var memo: Memo?
        if let text {
            switch recipient { case .transparent, .tex: throw SendError.noteToPublic; default: break }
            memo = try Memo(string: text)
        }
        let own = Set(AddressBook.load())
            .union([(try? await synchronizer.getUnifiedAddress(accountUUID: account).stringEncoded) ?? ""])
        let toSelf = own.contains(trimmed)

        if let amount, feeIncluded {
            // Fee included (as Lock it iPhone): the receiver gets the amount
            // minus the fee. Start from the smallest fee (two ZIP-317
            // actions, 10,000 zats) and follow the engine's quote, as Max
            // does. Asking for the whole amount first would need the amount
            // plus a fee, which a whole balance cannot cover.
            guard amount > 0 else { throw SendError.tooLittle }
            guard amount <= spendable else { throw SendError.notEnough }
            var fee: Int64 = 10_000
            var tried = Set<Int64>()
            var closest: SendPlan?
            for _ in 0..<24 {
                let net = amount - fee
                guard net > 0 else { break }
                guard tried.insert(fee).inserted else { break }
                do {
                    let proposal = try await synchronizer.proposeTransfer(
                        accountUUID: account, recipient: recipient, amount: Zatoshi(net), memo: memo)
                    let quoted = proposal.totalFeeRequired().amount
                    let plan = SendPlan(proposal: proposal, to: trimmed, amount: net, fee: quoted, toSelf: toSelf, memo: text)
                    if quoted == fee { return plan }
                    if quoted < fee {
                        // Fits, with (fee - quoted) left in the wallet; try
                        // giving the receiver that bit too.
                        if closest == nil || net > closest!.amount { closest = plan }
                    }
                    fee = quoted
                } catch ZcashError.rustProposalInsufficientFunds {
                    fee += 5_000
                }
            }
            if let closest { return closest }
            throw amount <= 10_000 ? SendError.belowFee : SendError.notEnough
        }
        if let amount {
            guard amount > 0 else { throw SendError.tooLittle }
            do {
                let proposal = try await synchronizer.proposeTransfer(
                    accountUUID: account, recipient: recipient, amount: Zatoshi(amount), memo: memo)
                return SendPlan(proposal: proposal, to: trimmed, amount: amount,
                                fee: proposal.totalFeeRequired().amount, toSelf: toSelf, memo: text)
            } catch {
                if amount > spendable { throw SendError.notEnough }
                throw error
            }
        }
        // Max: everything spendable leaves, minus exactly the fee, so nothing
        // is left behind. The fee depends on how many notes are spent and on
        // whether a change output is needed, so try, read the engine's quote,
        // and adjust: a rejected try means the fee was too low (one more
        // ZIP-317 action is 5,000 zats); a lower quote means change would be
        // left over, so the amount can go up.
        var fee: Int64 = 10_000
        var tried = Set<Int64>()
        var closest: SendPlan?
        var lastError: Error?
        for _ in 0..<24 {
            let amount = spendable - fee
            guard amount > 0 else { break }
            guard tried.insert(fee).inserted else { break }
            do {
                let proposal = try await synchronizer.proposeTransfer(
                    accountUUID: account, recipient: recipient, amount: Zatoshi(amount), memo: memo)
                let quoted = proposal.totalFeeRequired().amount
                let plan = SendPlan(proposal: proposal, to: trimmed, amount: amount, fee: quoted, toSelf: toSelf, memo: text)
                if quoted == fee { return plan }
                if quoted < fee {
                    // Works, but (fee - quoted) would stay behind as change.
                    if closest == nil || amount > closest!.amount { closest = plan }
                    fee = quoted
                } else {
                    fee = quoted
                }
            } catch {
                lastError = error
                fee += 5_000
            }
        }
        if let closest { return closest }
        if spendable <= 10_000 { throw SendError.notEnough }
        throw lastError ?? SendError.notEnough
    }

    /// Set by the app: whether the lock is open right now. Starts closed.
    var lockIsOpen: () -> Bool = { false }
    private var sendingNow = false

    /// Signs with a key derived from the seed for this payment only, and
    /// hands the result to the server. The caller wipes the seed after.
    func send(_ plan: SendPlan, seed: [UInt8]) async throws -> SendOutcome {
        guard let synchronizer else { throw EngineError.notReady }
        // One payment at a time, whatever the screens do (iPhone audit C-23).
        guard !sendingNow else { throw SendError.busy }
        sendingNow = true
        defer { sendingNow = false }
        // The wallet itself checks the lock, not only the screen (iPhone
        // audit C-09): anything that leaves the wallet needs the open lock,
        // right before the key is made.
        guard plan.staysInWallet || LockRules.maySend(lockOpen: lockIsOpen()) else { throw SendError.lockClosed }
        // Checked again right before signing: the upgrade may have come
        // closer while the payment was being reviewed.
        try NetworkUpgrade.checkReleases(networkHeight: networkHeight)
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
    /// Whether a payment sent from this wallet (nil: the one on the key ring)
    /// is still waiting for its block. Other wallets' payments do not count.
    func hasWaitingPayment(from wallet: AccountUUID? = nil) async -> Bool {
        guard let synchronizer, let txs = try? await synchronizer.allTransactions() else { return false }
        let id = wallet ?? current
        return txs.contains {
            $0.accountUUID == id && $0.isSentTransaction && $0.minedHeight == nil && $0.isExpiredUmined != true
        }
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
        leadWallet = nil
        UserDefaults.standard.removeObject(forKey: Self.leadKey)
        signerSpendable = 0
        signerTotal = 0
        signerBalances = [:]
        sealedWallets = []
        macWallets = []
        focus = nil
        activity = []
        lockedSince = nil
        holdingEntries = []
        pendingIn = 0
        syncedOnce = false
        spendable = 0
        total = 0
        orchardHeld = 0
        outsideTheLock = 0
        status = .connecting
    }

    /// Re-reads the wallet's payments, newest first.
    func refreshActivity() async {
        guard let synchronizer, let txs = try? await synchronizer.allTransactions() else { return }
        activity = txs.filter { $0.accountUUID == current }.map { tx in
            let kind: ActivityItem.Kind = tx.isSentTransaction ? .sent : .received
            let state: ActivityItem.State
            if tx.minedHeight != nil { state = .confirmed }
            else if tx.isExpiredUmined == true { state = .expired }
            else { state = .waiting }
            return ActivityItem(id: tx.rawID, kind: kind, amount: Int64(tx.value.amount.magnitude),
                                date: tx.blockTime.map { Date(timeIntervalSince1970: $0) }, state: state,
                                minedHeight: tx.minedHeight.map { Int($0) })
        }
        .sorted { ($0.date ?? .distantFuture) > ($1.date ?? .distantFuture) }

        // How long it has been in the lock: from the wallet history alone, as
        // Lock it iPhone. Only payments in a block count. The engine's value
        // is the signed balance change and a send's already includes its fee.
        // Internal moves (locking in, the Ironwood move, a payment to an own
        // address, which changes the balance by the fee only) never start
        // anything.
        let mine = txs.filter { $0.accountUUID == current && $0.isExpiredUmined != true }
        holdingEntries = mine.compactMap { tx -> HoldingEntry? in
            guard let height = tx.minedHeight, let time = tx.blockTime else { return nil }
            return HoldingEntry(height: Int(height), date: Date(timeIntervalSince1970: time),
                                change: tx.value.amount,
                                internalMove: tx.isShielding || tx.poolCrossingValue != nil)
        }
        pendingIn = mine.filter { $0.minedHeight == nil && $0.value.amount > 0 }.reduce(0) { $0 + $1.value.amount }
        lockedSince = Holding.since(holdingEntries)
    }

    // MARK: Sync details (as Lock it iPhone's sync sheet)

    /// Up to date for what the screen shows: also while the engine quickly
    /// checks a new block or two (every 25 seconds), so the status line and
    /// the dot do not flicker with each block.
    var isCurrent: Bool {
        switch status {
        case .upToDate: return true
        case .syncing: return SyncMath.nearlyCurrent(network: networkHeight, wallet: walletHeight)
        default: return false
        }
    }

    /// Bumped when the security keys change outside the settings screen.
    @Published var keysChanged = 0

    /// The wallet's birthday block, from start.
    @Published private(set) var birthdayHeight = 0
    /// Every block up to here is checked, without gaps.
    @Published private(set) var walletHeight = 0
    /// The engine's progress, 0…1 (1 when up to date).
    @Published private(set) var syncFraction = 0.0
    /// The last few problems, newest first. In memory only: gone when Lock
    /// it quits. Plain messages, no addresses or amounts.
    @Published private(set) var problems: [SyncMath.Problem] = []
    /// Recent (time, wallet height) samples for a rough time to go.
    private(set) var heightSamples: [SyncMath.Sample] = []

    private func recordProblem(_ message: String) {
        problems = SyncMath.adding(SyncMath.Problem(at: Date(), message: message), to: problems)
    }

    // Keeps macOS from slowing Lock it down (App Nap) while it checks
    // blocks. The Mac can still sleep; dropped once up to date.
    private var busyToken: NSObjectProtocol?

    private func keepAwake(_ busy: Bool) {
        if busy, busyToken == nil {
            busyToken = ProcessInfo.processInfo.beginActivity(
                options: .userInitiatedAllowingIdleSystemSleep,
                reason: "Checking blocks")
        } else if !busy, let token = busyToken {
            ProcessInfo.processInfo.endActivity(token)
            busyToken = nil
        }
    }

    private func apply(_ state: SynchronizerState) {
        let scanned = Int(state.fullyScannedHeight)
        if case .error(let error) = state.syncStatus, SyncMath.isDroppedConnection(String(describing: error)) {
            if droppedSince == nil { droppedSince = Date() }
            recordProblem(SyncMath.droppedText)
            return
        }
        if scanned > walletHeight || state.syncStatus == .upToDate { droppedSince = nil }
        if scanned > 0, scanned != walletHeight {
            walletHeight = scanned
            heightSamples = Array((heightSamples + [SyncMath.Sample(at: Date(), height: scanned)]).suffix(15))
        }
        // Security keys: remember the highest height seen while synced, and
        // finish a "Lost my keys" removal once its 48 hours are over.
        if isCurrent, networkHeight > 0 {
            SecurityKeys.noteSyncedHeight(networkHeight)
            if SecurityKeys.removal != nil, SecurityKeys.finishRemovalIfDue(syncedHeight: networkHeight) { keysChanged += 1 }
        }
        switch state.syncStatus {
        case .syncing(let progress, _): syncFraction = Double(max(0, min(1, progress)))
        case .upToDate: syncFraction = 1
        default: break
        }
        switch state.syncStatus {
        case .syncing: keepAwake(true)
        case .upToDate, .stopped, .error: keepAwake(false)
        default: break
        }
        switch state.syncStatus {
        case .unprepared: status = .connecting
        case .syncing(let progress, _): status = .syncing(max(0, min(100, Int((progress * 100).rounded(.down)))))
        case .upToDate:
            status = .upToDate
            if !syncedOnce {
                syncedOnce = true
                UserDefaults.standard.set(true, forKey: Self.syncedOnceKey)
            }
            Task { await refreshActivity() }
        case .stopped: break
        case .error(let error): status = .failed(String(describing: error))
        }
        var spendable: Int64 = 0
        var total: Int64 = 0
        var orchard: Int64 = 0
        var unshielded: Int64 = 0
        var sapling: Int64 = 0
        var ironwood: Int64 = 0
        // Only the wallet's own account counts for the lock; a signer's
        // account (Seal it) is shown on its own sheet.
        var signerSpendable: Int64 = 0
        var signerTotal: Int64 = 0
        var perSigner: [AccountUUID: (spendable: Int64, total: Int64)] = [:]
        for (id, balance) in state.accountsBalances where id != account {
            var usable: Int64 = 0
            var all: Int64 = balance.unshielded.amount
            for pool in [balance.saplingBalance, balance.orchardBalance, balance.ironwoodBalance] {
                usable += pool.spendableValue.amount
                all += pool.total().amount
            }
            perSigner[id] = (usable, all)
            signerSpendable += usable
            signerTotal += all
        }
        self.signerSpendable = signerSpendable
        self.signerTotal = signerTotal
        self.signerBalances = perSigner
        for (id, balance) in state.accountsBalances where id == account {
            orchard += balance.orchardBalance.total().amount
            unshielded += balance.unshielded.amount
            sapling += balance.saplingBalance.total().amount
            ironwood += balance.ironwoodBalance.total().amount
            for pool in [balance.saplingBalance, balance.orchardBalance, balance.ironwoodBalance] {
                spendable += pool.spendableValue.amount
                total += pool.total().amount
            }
            total += balance.unshielded.amount
        }
        self.spendable = spendable
        self.total = total
        self.orchardHeld = orchard
        if state.latestBlockHeight > 0 { self.networkHeight = Int(state.latestBlockHeight) }
        self.outsideTheLock = unshielded
        self.pools = Pools(ironwood: ironwood, orchard: orchard, sapling: sapling, transparent: unshielded)
        refreshCheckedPercent()
    }

    // MARK: How much is checked (the sync ring, as Lock it iPhone)

    /// The share of every block from the wallet birthday to the network block
    /// that is checked, one decimal, worked out from the engine's own list of
    /// ranges still to scan. The engine's progress only covers its current
    /// batch, so after a night closed it jumped from 0 to 100; this starts
    /// near the top (e.g. 99.6) instead. Nil until the network block is known.
    @Published private(set) var checkedPercent: Double?
    /// Blocks between the wallet birthday and the network block still to
    /// check, from the same ranges (nil until known).
    @Published private(set) var openBlocks: Int?
    /// How far this wallet is checked without gaps from its own birthday.
    @Published private(set) var walletCheckedTo: Int?

    /// "Syncing 99.6%" from the checked share; "Syncing…" until it is known.
    var syncingText: String {
        // Every block since the birthday checked; the engine is only on older
        // blocks for another wallet.
        if openBlocks == 0 { return "Up to date · checking older blocks" }
        return checkedPercent.map { "Syncing " + String(format: "%.1f", min(99.9, $0)) + "%" } ?? "Syncing…"
    }
    private var overviewAt = Date.distantPast
    private var readingOverview = false

    private func refreshCheckedPercent() {
        if status == .upToDate { checkedPercent = 100; openBlocks = 0; walletCheckedTo = networkHeight > 0 ? networkHeight : nil; return }
        guard let synchronizer, !readingOverview, Date().timeIntervalSince(overviewAt) >= 2 else { return }
        guard networkHeight > 0, birthdayHeight > 0 else { checkedPercent = nil; openBlocks = nil; walletCheckedTo = nil; return }
        readingOverview = true
        overviewAt = Date()
        Task {
            defer { readingOverview = false }
            // Read only: the engine's scan state, nothing is changed.
            guard let overview = try? await synchronizer.scanOverview() else { return }
            let ranges = overview.toScan.map { (first: Int($0.first), end: Int($0.end)) }
            guard let share = SyncMath.checkedShare(toScan: ranges, birthday: birthdayHeight, tip: networkHeight) else { return }
            let open = Int(((1 - share) * Double(networkHeight - birthdayHeight)).rounded())
            openBlocks = open
            checkedPercent = SyncMath.ringPercent(share: share, synced: status == .upToDate || open == 0)
            walletCheckedTo = SyncMath.checkedThrough(toScan: ranges, birthday: birthdayHeight, tip: networkHeight)
        }
    }

    /// Your Zcash by pool, straight from the engine's balance report.
    struct Pools: Equatable { var ironwood: Int64 = 0, orchard: Int64 = 0, sapling: Int64 = 0, transparent: Int64 = 0 }
    @Published var pools = Pools()
}
