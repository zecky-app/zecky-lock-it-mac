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
        return "Not enough free space: about \(gb) GB more is needed. The node takes about 20 GB and needs room while it works."
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
        // 15–20 GB: deleted away from the screen's thread.
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
    }

    // MARK: Starting and stopping

    private struct Failure: LocalizedError {
        let message: String
        init(_ message: String) { self.message = message }
        var errorDescription: String? { message }
    }

    private func start() async {
        guard let p = paths else { fail(Failure("Lock it's folder could not be opened.")); return }
        phase = .starting
        problem = nil
        zainoRestarts = 0
        missedAnswers = 0
        do {
            try prepare(p)
            await stopLeftover(pidFile: p.zakuraPid)
            await stopLeftover(pidFile: p.zainoPid)
            let rpcTaken = await LocalRPC.portOpen(GoMaxConfig.rpcPort)
            let zainoTaken = await LocalRPC.portOpen(GoMaxConfig.zainoPort)
            if rpcTaken || zainoTaken {
                throw Failure("Another program already uses Go Max's ports on this Mac (\(rpcTaken ? GoMaxConfig.rpcPort : GoMaxConfig.zainoPort)), most likely a Zcash node started by hand. Stop it, then switch Go Max on again.")
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
        process.executableURL = url
        process.arguments = arguments
        process.environment = ProcessInfo.processInfo.environment.merging(environment) { $1 }
        let handle = try Self.logHandle(log)
        process.standardOutput = handle
        process.standardError = handle
        process.standardInput = FileHandle.nullDevice
        process.qualityOfService = .utility
        try process.run()
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
        kill(pid, SIGINT)
        for _ in 0..<120 where kill(pid, 0) == 0 { try? await Task.sleep(nanoseconds: 500_000_000) }
    }

    /// Waits until the node answers, at most 3 minutes (a large state can
    /// take a while to open after an unclean stop).
    private func waitForNode() async throws {
        for _ in 0..<90 {
            if await chainInfo() != nil { return }
            if zakura?.isRunning != true { throw Failure("The node stopped while starting. Its log is in the node's folder.") }
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
    }

    private func stopPrograms() async {
        await stop(zaino)
        await stop(zakura)
        zaino = nil
        zakura = nil
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
    }

    private func chainInfo() async -> GoMaxChainInfo? {
        GoMaxChainInfo(rpcResult: await LocalRPC.call("getblockchaininfo", port: GoMaxConfig.rpcPort))
    }

    /// One look at the node: phase, Zaino restarts, widening, switching over.
    private func tick() async {
        guard !busy, phase != .off, phase != .stopped, phase != .updating else { return }
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
        phase = next
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

        if next == .ready {
            wasEverReady = true
            if !widened { await widen(); return }
            // Only once Zaino accepts connections: it needs a while after a
            // start, and Lock it would say it can't reach the node meanwhile.
            if !switchedToNode {
                let listening = await LocalRPC.portOpen(GoMaxConfig.zainoPort)
                steadyLooks = (fresh?.atTip == true && listening) ? steadyLooks + 1 : 0
                if steadyLooks >= 3 { await switchToNode() }
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
        Self.previousServer = Server.port == 443 ? Server.host : "\(Server.host):\(Server.port)"
        Server.set(host: GoMaxConfig.host, port: GoMaxConfig.zainoPort)
        SecurityKeys.restartRemovalIfRunning()
        try? await engine?.switchServer()
    }

    /// Back to the server from before Go Max, if Lock it is on the node.
    private func restoreServer() async {
        switchedToNode = false
        steadyLooks = 0
        guard onNode else { Self.previousServer = nil; return }
        let parts = (Self.previousServer ?? Server.defaultHost).split(separator: ":")
        let host = parts.first.map(String.init) ?? Server.defaultHost
        let port = parts.count == 2 ? Int(parts[1]) ?? 443 : 443
        Server.set(host: host, port: port)
        Self.previousServer = nil
        SecurityKeys.restartRemovalIfRunning()
        try? await engine?.switchServer()
        if phase == .problem, let problem { self.problem = problem + " Lock it is back on \(host)." }
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
