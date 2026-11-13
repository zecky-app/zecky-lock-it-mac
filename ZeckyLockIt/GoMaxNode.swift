import AppKit
import Foundation
import Network

/// Go Max: runs the node and its light-wallet server inside Lock it.
///
/// One switch. On starts Zakura (the node) and Zaino (the light-wallet
/// server) from inside the app, with the settings from GoMax.swift. The node
/// checks the chain, keeps a window of recent blocks, and when it is at the
/// tip Lock it switches its own server to it. Off stops both and keeps the
/// data; Remove deletes it. The programs run while Lock it is open.
///
/// Both programs talk only to this Mac (127.0.0.1), apart from the node's
/// peer-to-peer connections to other Zcash nodes. Lock it reads the node's
/// status over its JSON-RPC on this Mac; nothing here uses the web.
@MainActor
final class GoMaxNode: ObservableObject {
    static let shared = GoMaxNode()

    @Published private(set) var phase: GoMaxPhase = .off
    @Published private(set) var info: GoMaxChainInfo?
    @Published private(set) var retention = GoMaxConfig.retentionSyncing
    /// The last thing that went wrong, in plain words.
    @Published private(set) var problem: String?

    /// The wallet engine, to switch its server. Set when the wallet starts.
    weak var engine: WalletEngine?

    // MARK: Remembered settings

    private static let enabledKey = "goMax.enabled"
    private static let widenedKey = "goMax.widened"
    /// The server before Go Max, in the Keychain like the server itself.
    private static let previousService = "app.zecky.lockit.mac.gomax.previous"

    var enabled: Bool {
        get { UserDefaults.standard.bool(forKey: Self.enabledKey) }
        set { UserDefaults.standard.set(newValue, forKey: Self.enabledKey); objectWillChange.send() }
    }
    private var widened: Bool {
        get { UserDefaults.standard.bool(forKey: Self.widenedKey) }
        set { UserDefaults.standard.set(newValue, forKey: Self.widenedKey) }
    }
    private static var previousServer: String? {
        get { (try? KeyStore.read(service: previousService)).flatMap { $0 }.map { String(decoding: $0, as: UTF8.self) } }
        set {
            if let newValue { try? KeyStore.save(Data(newValue.utf8), service: previousService) }
            else { try? KeyStore.delete(service: previousService) }
        }
    }

    // MARK: Where things are

    /// The two programs, next to Lock it's own in Contents/MacOS. A build
    /// without them (no GoMax/bin on the Mac that built it) has no Go Max.
    static func helper(_ name: String) -> URL? {
        guard let url = Bundle.main.url(forAuxiliaryExecutable: name),
              FileManager.default.isExecutableFile(atPath: url.path) else { return nil }
        return url
    }
    static var isAvailable: Bool { helper("zakurad") != nil && helper("zainod") != nil }

    /// Lock it's own folder (the sandbox container), left out of Time Machine.
    private static var folder: URL? {
        try? FileManager.default.url(for: .applicationSupportDirectory, in: .userDomainMask, appropriateFor: nil, create: true)
            .appendingPathComponent("GoMax", isDirectory: true)
    }
    private struct Paths {
        let root, zakuraData, zainoData, logs, zakuraConfig, zainoConfig, zakuraLog, zainoLog, zakuraPid, zainoPid: URL
        init(_ root: URL) {
            self.root = root
            zakuraData = root.appendingPathComponent("zakura", isDirectory: true)
            zainoData = root.appendingPathComponent("zaino", isDirectory: true)
            logs = root.appendingPathComponent("logs", isDirectory: true)
            zakuraConfig = root.appendingPathComponent("zakura.toml")
            zainoConfig = root.appendingPathComponent("zainod.toml")
            zakuraLog = logs.appendingPathComponent("zakura.log")
            zainoLog = logs.appendingPathComponent("zaino.log")
            zakuraPid = root.appendingPathComponent("zakura.pid")
            zainoPid = root.appendingPathComponent("zaino.pid")
        }
    }
    private var paths: Paths? { Self.folder.map(Paths.init) }

    /// Whether the node has data on this Mac (so Remove means something).
    var hasData: Bool {
        guard let p = paths else { return false }
        return FileManager.default.fileExists(atPath: p.zakuraData.path)
    }

    var logsFolder: URL? { paths?.logs }

    // MARK: State

    private var zakura: Process?
    private var zaino: Process?
    /// The writing ends that tell each program Lock it is still there.
    private var lifelines: [Process: Pipe] = [:]
    private var timer: Timer?
    private var busy = false
    private var wasEverReady = false
    /// Lock it was switched to the node in this run; switched back on a
    /// problem or Off. Only once per run, so a server picked by hand while
    /// Go Max is on is respected.
    private var switchedToNode = false
    private var zainoRestarts = 0
    /// Looks in a row with the node at the tip and Zaino listening. Lock it
    /// is switched over after three (half a minute): right after a start
    /// Zaino is still a few blocks behind the node, and the wallet's
    /// requests for the newest blocks fail until it has caught up.
    private var steadyLooks = 0
    /// Answers the node missed in a row while running. A node busy checking
    /// blocks can be slow to answer; only a minute of silence is a problem.
    private var missedAnswers = 0
    private var awake: NSObjectProtocol?
    private var loaded = false

    /// Up to date by the node's own count, but no new block for five
    /// minutes (blocks come every 25 seconds): this Mac has most likely lost
    /// its connection. The node cannot tell by itself.
    @Published private(set) var quietMinutes: Int?
    /// The node has had no connection to any other Zcash node for a minute
    /// (six looks in a row): it cannot fetch blocks, whatever it still has
    /// to catch up. Offline, or a network that blocks Zcash nodes.
    @Published private(set) var disconnected = false
    /// How many other Zcash nodes the node is connected to, as it last said.
    @Published private(set) var peers: Int?
    /// The wallet still has to check blocks from here, and the node no
    /// longer has them (it keeps only recent blocks): Lock it reads from its
    /// server until they are checked. Nil otherwise.
    @Published private(set) var olderFrom: Int?
    /// Lock it reads from the node, the node moves on, and the wallet has
    /// not heard of a new block for five minutes.
    @Published private(set) var walletQuiet = false
    private var reconnectedWhileQuiet = false
    /// Lock it went back to its server and the engine could not connect to
    /// it yet; it is tried again for a minute.
    @Published private(set) var unsettled = false
    private var looksWithoutPeers = 0
    private var lastBlocks = 0
    private var lastBlockChange = Date()
    private var lastLook = Date()

    // MARK: The node version's last block (GoMaxSupport)

    private static let lastHeightKey = "goMax.lastHeight"
    private static let lastHeightTimeKey = "goMax.lastHeightTime"
    private static let expiredChoiceKey = "goMax.expiredChoice"

    /// At the stop, with Lock it still reading from the node and no choice
    /// made yet: the home screen opens the Go Max page once.
    @Published private(set) var needsChoice = false

    /// What the owner chose at the stop: "server" or "wait". nil before.
    private(set) var expiredChoice: String? {
        get { UserDefaults.standard.string(forKey: Self.expiredChoiceKey) }
        set {
            if let newValue { UserDefaults.standard.set(newValue, forKey: Self.expiredChoiceKey) }
            else { UserDefaults.standard.removeObject(forKey: Self.expiredChoiceKey) }
            objectWillChange.send()
        }
    }

    /// The newest network height anyone reports right now: the node, or the
    /// server Lock it reads from. 0 when nothing answers.
    private var liveHeight: Int {
        max(zakura?.isRunning == true ? max(info?.blocks ?? 0, info?.estimatedHeight ?? 0) : 0, engine?.networkHeight ?? 0)
    }

    /// Remembered across restarts (a public number, nothing about a wallet),
    /// so the stop is recognised when the node can no longer say it itself.
    private func rememberHeight() {
        let live = liveHeight
        guard live > UserDefaults.standard.integer(forKey: Self.lastHeightKey) else { return }
        UserDefaults.standard.set(live, forKey: Self.lastHeightKey)
        UserDefaults.standard.set(Date().timeIntervalSince1970, forKey: Self.lastHeightTimeKey)
    }

    /// Whether this node version still follows the chain, is near its last
    /// block, or past it.
    var support: GoMaxSupport.State {
        let now = Date()
        let live = liveHeight
        if live > 0 { return GoMaxSupport.state(reported: live, seenAt: nil, now: now) }
        let seen = UserDefaults.standard.double(forKey: Self.lastHeightTimeKey)
        return GoMaxSupport.state(reported: UserDefaults.standard.integer(forKey: Self.lastHeightKey),
                                  seenAt: seen > 0 ? Date(timeIntervalSince1970: seen) : nil, now: now)
    }

    /// Whether Lock it reads the chain from the node on this Mac right now.
    var readsFromNode: Bool { onNode }

    /// The server Lock it would go back to.
    var fallbackServer: String {
        (Self.previousServer ?? Server.defaultHost).split(separator: ":").first.map(String.init) ?? Server.defaultHost
    }

    /// The stop is reached: the programs are stopped and Go Max waits for an
    /// update of Lock it. Lock it's server is left as it is until the owner
    /// chooses (or as chosen before): nothing is switched silently.
    private func expire() async {
        stopPolling()
        await stopPrograms()
        quietMinutes = nil
        problem = nil
        phase = .expired
        if expiredChoice == "server" { await restoreServer() }
        needsChoice = onNode && expiredChoice == nil
    }

    /// The owner's choice at the stop: read the chain from the server again.
    func useServerWhileExpired() async {
        expiredChoice = "server"
        needsChoice = false
        await restoreServer()
    }

    /// The owner's choice at the stop: stay on the own node and wait.
    func waitWhileExpired() {
        expiredChoice = "wait"
        needsChoice = false
    }

    private init() {
        phase = hasData ? .stopped : .off
        retention = GoMaxConfig.retention(widened: widened)
        _ = NotificationCenter.default.addObserver(forName: NSApplication.willTerminateNotification, object: nil, queue: .main) { _ in
            MainActor.assumeIsolated { GoMaxNode.shared.stopAtQuit() }
        }
    }

    // MARK: The switch

    /// Once, when the wallet starts: if Go Max was on, start it again.
    func load(engine: WalletEngine) {
        self.engine = engine
        guard !loaded else { return }
        loaded = true
        if enabled && Self.isAvailable {
            wasEverReady = widened
            Task { await start() }
        } else if Self.previousServer != nil {
            // Go Max is off, but Lock it was left on the node it had been
            // switched to (a quit while switching off): back to the server.
            Task { await restoreServer() }
        }
    }

    /// What stands in the way of switching on, or nil.
    func blocker() -> String? {
        guard Self.isAvailable else { return "This build of Lock it has no node inside." }
        // A node that already has its data needs no new room to start again.
        if hasData { return nil }
        let values = try? URL(fileURLWithPath: NSHomeDirectory())
            .resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey])
        let free: Int64 = values?.volumeAvailableCapacityForImportantUsage ?? 0
        let missing = GoMaxConfig.missingBytes(free: free)
        guard missing > 0 else { return nil }
        let gb = Int((Double(missing) / 1e9).rounded(.up))
        return "Not enough free space: about \(gb) GB more is needed. The node takes 15 GB to start, about 22 GB after a month, and needs room while it works."
    }

    func switchOn() async {
        if let blocker = blocker() { problem = blocker; return }
        enabled = true
        // A node that reached the tip before (its window was widened there)
        // is catching up, not checking history from the start.
        wasEverReady = wasEverReady || widened
        await start()
    }

    /// Off: both programs stop, the data stays, Lock it goes back to its server.
    func switchOff() async {
        enabled = false
        quietMinutes = nil
        needsChoice = false
        expiredChoice = nil
        stopPolling()
        // First back to the server, then the programs: stopping the node can
        // take a minute, and a quit in that minute must not leave Lock it
        // pointing at a node that is gone.
        await restoreServer()
        await stopPrograms()
        problem = nil
        phase = hasData ? .stopped : .off
    }

    /// Removes the node and its data. Lock it is a light wallet again.
    func remove() async {
        await switchOff()
        // 15–22 GB: deleted away from the screen's thread.
        if let root = paths?.root { await Task.detached { _ = try? FileManager.default.removeItem(at: root) }.value }
        widened = false
        Self.previousServer = nil
        wasEverReady = false
        info = nil
        retention = GoMaxConfig.retentionSyncing
        phase = .off
    }

    /// For Erase everything: Go Max off and gone, with its settings.
    func eraseAll() async {
        await remove()
        UserDefaults.standard.removeObject(forKey: Self.enabledKey)
        UserDefaults.standard.removeObject(forKey: Self.widenedKey)
        UserDefaults.standard.removeObject(forKey: Self.lastHeightKey)
        UserDefaults.standard.removeObject(forKey: Self.lastHeightTimeKey)
    }

    // MARK: Starting and stopping

    private struct Failure: LocalizedError {
        let message: String
        init(_ message: String) { self.message = message }
        var errorDescription: String? { message }
    }

    private func start() async {
        guard let p = paths else { fail(Failure("Lock it's folder could not be opened.")); return }
        // Past its last block the node refuses to run: say so, without starting it.
        if support == .ended { await expire(); return }
        expiredChoice = nil
        needsChoice = false
        phase = .starting
        problem = nil
        zainoRestarts = 0
        missedAnswers = 0
        do {
            try prepare(p)
            await stopLeftover(pidFile: p.zakuraPid)
            await stopLeftover(pidFile: p.zainoPid)
            // A node from the Lock it before this one may still be closing: it
            // is told to stop when its Lock it goes (see `keeper`), and closing
            // its database can take a minute. This Lock it cannot see or stop
            // it (the sandbox keeps each run of Lock it apart), so it waits.
            var port = await takenPort()
            for _ in 0..<45 where port != nil {
                try? await Task.sleep(nanoseconds: 2_000_000_000)
                port = await takenPort()
            }
            if let port {
                throw Failure("A Zcash node is already running on this Mac and uses Go Max's port \(port). If you did not start one yourself, it is left over from an earlier Lock it: restart this Mac, then switch Go Max on again.")
            }
            let r = GoMaxConfig.retention(widened: widened)
            retention = r
            try GoMaxConfig.zakura(dataDir: p.zakuraData.path, retention: r).write(to: p.zakuraConfig, atomically: true, encoding: .utf8)
            try GoMaxConfig.zaino(dataDir: p.zainoData.path).write(to: p.zainoConfig, atomically: true, encoding: .utf8)
            try startZakura(p)
            holdAwake(true)
            try await waitForNode()
            try startZaino(p)
            startPolling()
        } catch {
            fail(error)
        }
    }

    private func prepare(_ p: Paths) throws {
        let fm = FileManager.default
        for dir in [p.root, p.zakuraData, p.zainoData, p.logs] {
            try fm.createDirectory(at: dir, withIntermediateDirectories: true)
        }
        var root = p.root
        var values = URLResourceValues()
        values.isExcludedFromBackup = true
        try? root.setResourceValues(values)
    }

    private func startZakura(_ p: Paths) throws {
        // Info shows the sync in the log; it holds blocks and peers, never wallet data.
        zakura = try launch("zakurad", ["-c", p.zakuraConfig.path, "start"], log: p.zakuraLog, pidFile: p.zakuraPid,
                            environment: ["ZAKURA_TRACING__FILTER": "info"])
    }

    private func startZaino(_ p: Paths) throws {
        // Warnings only: at info Zaino logs the calls Lock it makes, with
        // addresses. For finding a fault, Lock it can be opened once with
        // detailed logs: open "Zecky Lock it.app" --args -goMax.detailedLogs YES
        // (not remembered; the log stays in Lock it's own folder).
        let level = UserDefaults.standard.bool(forKey: "goMax.detailedLogs") ? "info" : "warn"
        zaino = try launch("zainod", ["start", "--config", p.zainoConfig.path], log: p.zainoLog, pidFile: p.zainoPid,
                           environment: ["RUST_LOG": level, "ZAINOLOG_COLOR": "false"])
    }

    private func launch(_ name: String, _ arguments: [String], log: URL, pidFile: URL, environment: [String: String]) throws -> Process {
        guard let url = Self.helper(name) else { throw Failure("This build of Lock it has no node inside.") }
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/sh")
        process.arguments = ["-c", Self.keeper, url.path] + arguments
        // The lifeline: Lock it holds the writing end for as long as it
        // lives. However Lock it goes, the end closes and the keeper tells
        // the program to stop.
        let lifeline = Pipe()
        process.environment = ProcessInfo.processInfo.environment.merging(environment) { $1 }
        let handle = try Self.logHandle(log)
        process.standardOutput = handle
        process.standardError = handle
        process.standardInput = lifeline
        process.qualityOfService = .utility
        try process.run()
        lifelines[process] = lifeline
        try? String(process.processIdentifier).write(to: pidFile, atomically: true, encoding: .utf8)
        return process
    }

    /// The log, appended to; started afresh once it passes 20 MB.
    private static func logHandle(_ url: URL) throws -> FileHandle {
        let fm = FileManager.default
        if !fm.fileExists(atPath: url.path) { fm.createFile(atPath: url.path, contents: nil) }
        let handle = try FileHandle(forWritingTo: url)
        let attributes = try? fm.attributesOfItem(atPath: url.path)
        let size = (attributes?[.size] as? NSNumber)?.int64Value ?? 0
        if size > 20_000_000 { try handle.truncate(atOffset: 0) }
        try handle.seekToEnd()
        return handle
    }

    /// A node left running when Lock it last stopped without closing it
    /// (a crash, a forced quit): asked to stop before a new one starts. The
    /// sandbox only lets Lock it signal its own programs.
    private func stopLeftover(pidFile: URL) async {
        defer { try? FileManager.default.removeItem(at: pidFile) }
        guard let text = try? String(contentsOf: pidFile, encoding: .utf8),
              let pid = Int32(text.trimmingCharacters(in: .whitespacesAndNewlines)),
              pid > 1, pid != getpid(), kill(pid, 0) == 0 else { return }
        _ = await Self.stopCleanly([pid])
    }

    /// The first of Go Max's two ports that something on this Mac answers on.
    private func takenPort() async -> Int? {
        if await LocalRPC.portOpen(GoMaxConfig.rpcPort) { return GoMaxConfig.rpcPort }
        if await LocalRPC.portOpen(GoMaxConfig.zainoPort) { return GoMaxConfig.zainoPort }
        return nil
    }

    /// Each program runs under a few lines of shell that keep watch for it.
    /// The shell starts the program ($0 with its arguments) and waits. When
    /// Lock it asks it to stop, or when Lock it is gone (force quit, a crash,
    /// a stop from Xcode: the lifeline on its input closes), it tells the
    /// program to stop the way Ctrl-C does, so the node closes its database
    /// and frees its ports. Before this, a node could outlive its Lock it
    /// and keep the ports (seen 12 Nov), and the next Lock it has no way to
    /// stop it: the sandbox lets a run of Lock it signal only what it
    /// started itself.
    private static let keeper = """
    exec 3<&0
    "$0" "$@" </dev/null 3<&- &
    c=$!
    ( read -r _ <&3; kill -INT $c 2>/dev/null ) &
    w=$!
    exec 3<&-
    trap 'kill -INT $c 2>/dev/null' INT
    trap 'kill -TERM $c 2>/dev/null' TERM
    while kill -0 $c 2>/dev/null; do wait $c; done
    kill $w 2>/dev/null
    exit 0
    """

    /// Asks processes to stop as Ctrl-C does, so the node closes its
    /// database; after a minute more firmly, then by force. True when all
    /// are gone.
    private static func stopCleanly(_ pids: [pid_t]) async -> Bool {
        func alive() -> [pid_t] { pids.filter { kill($0, 0) == 0 } }
        for (signal, halfSeconds) in [(SIGINT, 120), (SIGTERM, 20), (SIGKILL, 10)] {
            let left = alive()
            if left.isEmpty { return true }
            for pid in left { kill(pid, signal) }
            for _ in 0..<halfSeconds where !alive().isEmpty { try? await Task.sleep(nanoseconds: 500_000_000) }
        }
        return alive().isEmpty
    }

    /// Waits until the node answers, at most 3 minutes (a large state can
    /// take a while to open after an unclean stop).
    private func waitForNode() async throws {
        for _ in 0..<90 {
            if await chainInfo() != nil { return }
            if zakura?.isRunning != true { throw Failure(GoMaxWords.stoppedWhileStarting) }
            try? await Task.sleep(nanoseconds: 2_000_000_000)
        }
        throw Failure("The node did not answer within 3 minutes of starting.")
    }

    /// Asks a program to stop (as Ctrl-C does), so the node closes its
    /// database cleanly; forced after a minute.
    private func stop(_ process: Process?) async {
        guard let process, process.isRunning else { return }
        process.interrupt()
        for _ in 0..<120 where process.isRunning { try? await Task.sleep(nanoseconds: 500_000_000) }
        if process.isRunning {
            process.terminate()
            for _ in 0..<10 where process.isRunning { try? await Task.sleep(nanoseconds: 500_000_000) }
        }
        lifelines[process] = nil
    }

    private func stopPrograms() async {
        await stop(zaino)
        await stop(zakura)
        zaino = nil
        zakura = nil
        lifelines.removeAll()
        if let p = paths {
            try? FileManager.default.removeItem(at: p.zainoPid)
            try? FileManager.default.removeItem(at: p.zakuraPid)
        }
        holdAwake(false)
    }

    /// Lock it is quitting: both programs are asked to stop, and the node
    /// gets up to 20 seconds to close its database. If it needs longer it
    /// finishes on its own; the next start waits for it.
    private func stopAtQuit() {
        stopPolling()
        zaino?.interrupt()
        zakura?.interrupt()
        let until = Date().addingTimeInterval(20)
        while zakura?.isRunning == true && Date() < until { usleep(200_000) }
    }

    /// While the node is checking history or catching up, the Mac does not
    /// fall asleep on its own. Up to date, it sleeps as usual. Closing the
    /// lid still sleeps; the node carries on afterwards.
    private func holdAwake(_ on: Bool) {
        if on, awake == nil {
            awake = ProcessInfo.processInfo.beginActivity(options: [.idleSystemSleepDisabled], reason: "Go Max is checking the Zcash chain")
        } else if !on, let token = awake {
            ProcessInfo.processInfo.endActivity(token)
            awake = nil
        }
    }

    private func fail(_ error: Error) {
        stopPolling()
        if support == .ended { Task { await expire() }; return }
        problem = (error as? LocalizedError)?.errorDescription ?? "Something went wrong."
        phase = .problem
        Task { await restoreServer() }
    }

    // MARK: Watching

    private func startPolling() {
        stopPolling()
        timer = Timer.scheduledTimer(withTimeInterval: 10, repeats: true) { _ in
            Task { @MainActor in await GoMaxNode.shared.tick() }
        }
        Task { await tick() }
    }

    private func stopPolling() {
        timer?.invalidate()
        timer = nil
        looksWithoutPeers = 0
        disconnected = false
        peers = nil
        olderFrom = nil
        walletQuiet = false
        reconnectedWhileQuiet = false
    }

    /// The oldest block the wallet still has to check, when the node no
    /// longer has it. Nil when the node can serve the wallet, and when it
    /// cannot be told (the wallet is not open, or the node does not answer).
    private func missingOlderBlock(nodeBlocks: Int) async -> Int? {
        guard let engine, let oldest = await engine.oldestBlockToCheck(), oldest <= nodeBlocks else { return nil }
        return GoMaxReading.missing(oldestNeeded: oldest, nodeBlocks: nodeBlocks,
                                    nodeHasIt: await LocalRPC.hasBlock(oldest, port: GoMaxConfig.rpcPort))
    }

    /// Lock it reads from the node: does the wallet still hear new blocks?
    /// Connects once more when it has gone quiet, and says so on the page.
    private func watchWallet(_ fresh: GoMaxChainInfo?) async {
        guard let engine, let fresh else { return }
        guard GoMaxReading.walletQuiet(nodeBlocks: fresh.blocks, walletNetwork: engine.networkHeight) else {
            walletQuiet = false
            reconnectedWhileQuiet = false
            return
        }
        walletQuiet = true
        if !reconnectedWhileQuiet {
            reconnectedWhileQuiet = true
            try? await engine.switchServer()
        }
    }

    /// How many other Zcash nodes the node is connected to; nil when it does not say.
    private func peerCount() async -> Int? {
        (await LocalRPC.call("getpeerinfo", port: GoMaxConfig.rpcPort) as? [Any])?.count
    }

    private func chainInfo() async -> GoMaxChainInfo? {
        GoMaxChainInfo(rpcResult: await LocalRPC.call("getblockchaininfo", port: GoMaxConfig.rpcPort))
    }

    /// One look at the node: phase, Zaino restarts, widening, switching over.
    private func tick() async {
        guard !busy, phase != .off, phase != .stopped, phase != .updating, phase != .expired else { return }
        busy = true
        defer { busy = false }
        let nodeRunning = zakura?.isRunning == true
        let fresh = nodeRunning ? await chainInfo() : nil
        if nodeRunning && fresh == nil && phase != .starting {
            missedAnswers += 1
            if missedAnswers < 6 { return }
        } else {
            missedAnswers = 0
        }
        let next = GoMaxPhase.next(after: phase, running: nodeRunning, info: fresh, wasEverReady: wasEverReady)
        if let fresh { info = fresh }
        rememberHeight()
        // The network is past this node version's last block (the node has
        // stopped by itself, or is about to): not a problem, the stop.
        if support == .ended { await expire(); return }
        phase = next
        // After a pause in the looks (the Mac slept), the count starts again.
        let now = Date()
        if now.timeIntervalSince(lastLook) > 60 { lastBlockChange = now }
        lastLook = now
        if let fresh, fresh.blocks != lastBlocks { lastBlocks = fresh.blocks; lastBlockChange = now }
        let quiet = Int(now.timeIntervalSince(lastBlockChange) / 60)
        quietMinutes = next == .ready && quiet >= 5 ? quiet : nil
        let count = fresh != nil ? await peerCount() : nil
        peers = count
        if let count {
            looksWithoutPeers = count == 0 ? looksWithoutPeers + 1 : 0
        } else {
            looksWithoutPeers = 0
        }
        disconnected = looksWithoutPeers >= 6
        if next == .problem {
            problem = nodeRunning ? "The node stopped answering." : "The node stopped. Its log is in the node's folder."
            stopPolling()
            await stopPrograms()
            await restoreServer()
            return
        }
        holdAwake(next != .ready)

        // Zaino gives up after a few failed probes when the node restarts or
        // is busy; it is started again as long as the node answers.
        if zaino?.isRunning == true { zainoRestarts = 0 }
        if zaino?.isRunning != true, fresh != nil, let p = paths {
            zainoRestarts += 1
            guard zainoRestarts <= 5 else {
                fail(Failure("The light-wallet server keeps stopping. Its log is in the node's folder."))
                return
            }
            try? startZaino(p)
            return
        }

        // The node keeps only recent blocks. A wallet with older blocks
        // still to check reads those from its server: back there if Lock it
        // is on the node, and not onto the node until they are checked.
        // The page says so (olderFrom); nothing is switched silently.
        // Not during the first check of history: the node does not have
        // those blocks yet, and Lock it is not on the node then.
        var missing: Int?
        if let fresh, next == .ready || next == .catchingUp {
            missing = await missingOlderBlock(nodeBlocks: fresh.blocks)
            olderFrom = missing
        }
        if let missing, onNode, Self.previousServer != nil {
            await restoreServer()
            olderFrom = missing
            return
        }

        if next == .ready {
            wasEverReady = true
            if !widened { await widen(); return }
            // Only once Zaino accepts connections: it needs a while after a
            // start, and Lock it would say it can't reach the node meanwhile.
            if !switchedToNode {
                let listening = await LocalRPC.portOpen(GoMaxConfig.zainoPort)
                steadyLooks = (fresh?.atTip == true && listening) ? steadyLooks + 1 : 0
                if steadyLooks >= 3, missing == nil { await switchToNode() }
            } else if onNode {
                await watchWallet(fresh)
            }
        }
    }

    /// At the tip for the first time: keep about a month of blocks from now
    /// on. The node restarts once to take the setting; Zaino after it.
    private func widen() async {
        guard let p = paths else { return }
        phase = .updating
        do {
            await stop(zaino)
            await stop(zakura)
            try GoMaxConfig.zakura(dataDir: p.zakuraData.path, retention: GoMaxConfig.retentionAtTip)
                .write(to: p.zakuraConfig, atomically: true, encoding: .utf8)
            try startZakura(p)
            try await waitForNode()
            try startZaino(p)
            widened = true
            retention = GoMaxConfig.retentionAtTip
            phase = .ready
            // The next look switches Lock it over, once Zaino is listening.
        } catch {
            fail(error)
        }
    }

    // MARK: Lock it's server

    private var onNode: Bool { Server.host == GoMaxConfig.host && Server.port == GoMaxConfig.zainoPort }

    /// Lock it reads the chain from its own node from here on. The server
    /// before is kept, to go back to.
    private func switchToNode() async {
        switchedToNode = true
        guard !onNode else { return }
        let host = Server.host, port = Server.port
        Self.previousServer = port == 443 ? host : "\(host):\(port)"
        Server.set(host: GoMaxConfig.host, port: GoMaxConfig.zainoPort)
        SecurityKeys.restartRemovalIfRunning()
        do {
            try await engine?.switchServer()
        } catch {
            // The node's light-wallet server did not pass the engine's check
            // in time. Lock it stays on its server (the engine went on with
            // it) and tries again at a later look.
            Server.set(host: host, port: port)
            Self.previousServer = nil
            switchedToNode = false
            steadyLooks = 0
        }
    }

    /// Back to the server from before Go Max, if Lock it is on the node.
    private func restoreServer() async {
        switchedToNode = false
        steadyLooks = 0
        walletQuiet = false
        reconnectedWhileQuiet = false
        guard onNode else { Self.previousServer = nil; return }
        let parts = (Self.previousServer ?? Server.defaultHost).split(separator: ":")
        let host = parts.first.map(String.init) ?? Server.defaultHost
        let port = parts.count == 2 ? Int(parts[1]) ?? 443 : 443
        Server.set(host: host, port: port)
        Self.previousServer = nil
        SecurityKeys.restartRemovalIfRunning()
        do {
            try await engine?.switchServer()
            unsettled = false
        } catch {
            // The server did not answer in time. Lock it's setting names it
            // already, so the engine is pointed at it again until it takes.
            unsettled = true
            settleEngine(on: host)
        }
        if phase == .problem, let problem { self.problem = problem + " Lock it is back on \(host)." }
    }

    /// Tries for a minute to point the engine at Lock it's server, as long
    /// as that is still the server chosen.
    private func settleEngine(on host: String) {
        Task {
            for _ in 0..<12 {
                try? await Task.sleep(nanoseconds: 5_000_000_000)
                guard self.unsettled, Server.host == host, let engine = self.engine else { return }
                do {
                    try await engine.switchServer()
                    self.unsettled = false
                    return
                } catch { continue }
            }
        }
    }
}

/// Zakura's JSON-RPC on this Mac, over a plain TCP connection to 127.0.0.1.
/// Not the web: nothing here can reach another machine.
enum LocalRPC {
    /// The `result` of a call, or nil when the node does not answer.
    static func call(_ method: String, port: Int) async -> Any? {
        let request: [String: Any] = ["jsonrpc": "2.0", "id": 1, "method": method, "params": [Any]()]
        guard let body = try? JSONSerialization.data(withJSONObject: request) else { return nil }
        let head = "POST / HTTP/1.1\r\nHost: 127.0.0.1:\(port)\r\nContent-Type: application/json\r\nContent-Length: \(body.count)\r\nConnection: close\r\n\r\n"
        guard let response = await exchange(Data(head.utf8) + body, port: port, timeout: 5),
              let json = self.body(of: response),
              let object = try? JSONSerialization.jsonObject(with: json) as? [String: Any] else { return nil }
        return object["result"]
    }

    /// Whether the node still has this block in full. A pruned node answers
    /// "block not found" for a block it has dropped. Nil when it does not answer.
    static func hasBlock(_ height: Int, port: Int) async -> Bool? {
        let request: [String: Any] = ["jsonrpc": "2.0", "id": 1, "method": "getblock", "params": [String(height), 1]]
        guard let body = try? JSONSerialization.data(withJSONObject: request) else { return nil }
        let head = "POST / HTTP/1.1\r\nHost: 127.0.0.1:\(port)\r\nContent-Type: application/json\r\nContent-Length: \(body.count)\r\nConnection: close\r\n\r\n"
        guard let response = await exchange(Data(head.utf8) + body, port: port, timeout: 5) else { return nil }
        return blockFound(in: response)
    }

    /// Reads the answer to `getblock`: true with a result, false with an
    /// error from the node, nil when it is not an answer at all.
    static func blockFound(in response: Data) -> Bool? {
        // The node answers an unknown block with an HTTP error status and a
        // JSON-RPC error in the body, so the body is read whatever the status.
        guard let split = response.range(of: Data("\r\n\r\n".utf8)) else { return nil }
        let head = String(decoding: response[..<split.lowerBound], as: UTF8.self).lowercased()
        let raw = Data(response[split.upperBound...])
        let json = head.contains("transfer-encoding: chunked") ? (dechunk(raw) ?? raw) : raw
        guard let object = try? JSONSerialization.jsonObject(with: json) as? [String: Any] else { return nil }
        if let result = object["result"], !(result is NSNull) { return true }
        if let error = object["error"], !(error is NSNull) { return false }
        return nil
    }

    /// Whether something on this Mac accepts connections on the port.
    static func portOpen(_ port: Int) async -> Bool {
        await exchange(Data(), port: port, timeout: 1) != nil
    }

    /// The body of an HTTP 200 answer, chunked or not; nil otherwise.
    static func body(of response: Data) -> Data? {
        guard let split = response.range(of: Data("\r\n\r\n".utf8)) else { return nil }
        let head = String(decoding: response[..<split.lowerBound], as: UTF8.self).lowercased()
        guard head.hasPrefix("http/1.1 200") || head.hasPrefix("http/1.0 200") else { return nil }
        let body = Data(response[split.upperBound...])
        return head.contains("transfer-encoding: chunked") ? dechunk(body) : body
    }

    static func dechunk(_ data: Data) -> Data? {
        var out = Data()
        var i = data.startIndex
        let crlf = Data("\r\n".utf8)
        while true {
            guard let line = data[i...].range(of: crlf) else { return nil }
            let text = String(decoding: data[i..<line.lowerBound], as: UTF8.self)
            guard let size = Int(text.split(separator: ";").first?.trimmingCharacters(in: .whitespaces) ?? "", radix: 16) else { return nil }
            if size == 0 { return out }
            let start = line.upperBound
            guard data.distance(from: start, to: data.endIndex) >= size else { return nil }
            let end = data.index(start, offsetBy: size)
            out.append(data[start..<end])
            i = data.index(end, offsetBy: 2, limitedBy: data.endIndex) ?? data.endIndex
        }
    }

    /// Sends `request` and reads until the other side closes. An empty
    /// request only checks that the port accepts a connection.
    private static func exchange(_ request: Data, port: Int, timeout: TimeInterval) async -> Data? {
        guard let nwPort = NWEndpoint.Port(rawValue: UInt16(clamping: port)) else { return nil }
        return await withCheckedContinuation { (continuation: CheckedContinuation<Data?, Never>) in
            let connection = NWConnection(host: NWEndpoint.Host("127.0.0.1"), port: nwPort, using: .tcp)
            let queue = DispatchQueue(label: "app.zecky.lockit.gomax.rpc")
            let box = Box()
            func finish(_ value: Data?) {
                box.once {
                    connection.cancel()
                    continuation.resume(returning: value)
                }
            }
            func receive() {
                connection.receive(minimumIncompleteLength: 1, maximumLength: 65_536) { data, _, isComplete, error in
                    if let data { box.append(data) }
                    if isComplete || error != nil { finish(box.received) } else { receive() }
                }
            }
            connection.stateUpdateHandler = { state in
                switch state {
                case .ready:
                    if request.isEmpty { finish(Data()); return }
                    connection.send(content: request, completion: .contentProcessed { error in
                        if error != nil { finish(nil) } else { receive() }
                    })
                // Refused shows as waiting on this Mac's own address.
                case .waiting, .failed, .cancelled: finish(nil)
                default: break
                }
            }
            connection.start(queue: queue)
            queue.asyncAfter(deadline: .now() + timeout) { finish(nil) }
        }
    }

    /// What one exchange has received, and its end, which comes once from
    /// whichever callback is first. The callbacks run on one queue; the lock
    /// is for the timeout.
    private final class Box: @unchecked Sendable {
        private let lock = NSLock()
        private var done = false
        private var data = Data()
        func append(_ more: Data) { lock.lock(); data.append(more); lock.unlock() }
        var received: Data? { lock.lock(); defer { lock.unlock() }; return data.isEmpty ? nil : data }
        func once(_ block: () -> Void) {
            lock.lock()
            guard !done else { lock.unlock(); return }
            done = true
            lock.unlock()
            block()
        }
    }
}
