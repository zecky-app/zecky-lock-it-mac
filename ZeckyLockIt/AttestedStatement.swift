import AppKit
import SwiftUI
import CryptoKit
import Foundation
#if DEBUG
import DeviceCheck
import Network
import Security
#endif

/// Experiment (14 Nov 2026): an attested Go Max state confirmation.
/// A caught-up Go Max node on this Mac says "at height H the chain state
/// fingerprint is X", and App Attest adds "genuine, unmodified Lock it on a
/// real Apple device said so". Prototype only: debug builds, behind a
/// developer switch, nothing on-chain and no Zecky server.
///
/// Fingerprint v0 is what the node can answer deterministically at one
/// height: the block hash, the block commitments (which commit to the chain
/// history root), the Sapling, Orchard and Ironwood note commitment tree
/// roots and sizes, and the node's value pool totals. It does NOT cover the
/// spent-note (nullifier) sets or the transparent coin set; no Zcash node
/// offers a canonical hash of those today. So v0 confirms a checkpoint, not a
/// full state a new node could start from.
enum StateFingerprint {
    static let version = 0

    /// The fingerprint as sorted, compact JSON: the bytes that are hashed.
    /// Same rules as the Python check in docs (sort_keys, no spaces).
    static func canonicalJSON(_ object: [String: Any]) throws -> Data {
        try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys, .withoutEscapingSlashes])
    }

    static func sha256Hex(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    /// Builds v0 from the node's answers to getblock (verbosity 1) and
    /// z_gettreestate at the same height. Nil when a field is missing.
    static func make(block: [String: Any], treeState: [String: Any]) -> [String: Any]? {
        guard let height = block["height"] as? Int,
              let hash = block["hash"] as? String,
              let commitments = block["blockcommitments"] as? String,
              let trees = block["trees"] as? [String: Any],
              let pools = block["valuePools"] as? [[String: Any]],
              let supply = (block["chainSupply"] as? [String: Any])?["chainValueZat"] as? Int64,
              treeState["hash"] as? String == hash else { return nil }
        func root(_ pool: String) -> String? {
            ((treeState[pool] as? [String: Any])?["commitments"] as? [String: Any])?["finalRoot"] as? String
        }
        guard let sapling = root("sapling"), let orchard = root("orchard"), let ironwood = root("ironwood") else { return nil }
        var sizes: [String: Int64] = [:]
        for (name, value) in trees { if let size = (value as? [String: Any])?["size"] as? Int64 { sizes[name] = size } }
        var poolZat: [String: Int64] = [:]
        for pool in pools { if let id = pool["id"] as? String, let zat = pool["chainValueZat"] as? Int64 { poolZat[id] = zat } }
        return ["v": version, "network": "main", "height": height, "blockHash": hash,
                "blockCommitments": commitments, "saplingRoot": sapling, "orchardRoot": orchard,
                "ironwoodRoot": ironwood, "treeSizes": sizes, "poolsZat": poolZat, "chainSupplyZat": supply]
    }
}

/// What App Attest signs (v1): the fingerprint's hash together with a fresh
/// challenge from whoever asks, so an old statement cannot be replayed as a
/// new answer. Sorted, compact JSON; its SHA-256 is App Attest's client data.
enum StatementClientData {
    static let purpose = "zecky-go-max-state"

    static func json(fingerprintSHA256: String, challenge: String) throws -> Data {
        try StateFingerprint.canonicalJSON(["v": 1, "purpose": purpose,
                                            "fingerprintSHA256": fingerprintSHA256, "challenge": challenge])
    }

    /// A challenge is 32 random bytes as 64 lowercase hex characters, or
    /// empty for a statement nobody asked for.
    static func validChallenge(_ text: String) -> Bool {
        text.isEmpty || (text.count == 64 && text.allSatisfy { "0123456789abcdef".contains($0) })
    }
}

#if DEBUG
/// Before Lock it attests anything, it checks that the node it reads is its
/// own: this Lock it found Go Max's ports free, started the `zakurad` inside
/// Lock it on them, and that node is still running (its keeper lives exactly
/// as long as the node), so nothing else can hold the port. The `zakurad`
/// file inside Lock it is checked to be validly signed by the same team as
/// Lock it. macOS does not let a sandboxed app inspect other processes, not
/// even its own children (seen 14 Nov 2026: EPERM), so this is as far as Lock
/// it can check. Fails closed: when something cannot be checked, no statement.
enum OwnNodeCheck {
    struct Result { let executable: String }

    @MainActor
    static func run() -> (Result?, String) {
        guard GoMaxNode.shared.ownNodeRunning else {
            return (nil, "Go Max's node is not one this Lock it started on free ports.")
        }
        guard let url = GoMaxNode.helper("zakurad") else { return (nil, "This build has no node inside.") }
        guard let team = ownTeam() else { return (nil, "Could not read Lock it's own signature.") }
        guard fileSignedBy(team: team, url: url) else {
            return (nil, "The node inside Lock it is not validly signed by the same team as Lock it.")
        }
        let relative = url.resolvingSymlinksInPath().path.components(separatedBy: "/").suffix(3).joined(separator: "/")
        return (Result(executable: relative), "Lock it's own node")
    }

    static func ownTeam() -> String? {
        var me: SecCode?
        guard SecCodeCopySelf([], &me) == errSecSuccess, let me else { return nil }
        var staticCode: SecStaticCode?
        guard SecCodeCopyStaticCode(me, [], &staticCode) == errSecSuccess, let staticCode else { return nil }
        var info: CFDictionary?
        guard SecCodeCopySigningInformation(staticCode, SecCSFlags(rawValue: kSecCSSigningInformation), &info) == errSecSuccess,
              let dict = info as? [String: Any] else { return nil }
        return dict[kSecCodeInfoTeamIdentifier as String] as? String
    }

    /// The program file is intact and signed by this team.
    static func fileSignedBy(team: String, url: URL) -> Bool {
        var code: SecStaticCode?
        guard SecStaticCodeCreateWithPath(url as CFURL, [], &code) == errSecSuccess, let code else { return false }
        var requirement: SecRequirement?
        let text = "anchor apple generic and certificate leaf[subject.OU] = \"\(team)\"" as CFString
        guard SecRequirementCreateWithString(text, [], &requirement) == errSecSuccess else { return false }
        return SecStaticCodeCheckValidity(code, SecCSFlags(rawValue: kSecCSCheckAllArchitectures), requirement) == errSecSuccess
    }
}

/// The developer switch, the App Attest part and the local endpoint. Not
/// compiled into TestFlight or App Store builds.
@MainActor
final class AttestedStatementMaker: ObservableObject {
    static let shared = AttestedStatementMaker()
    static let switchKey = "developer.attestedStatements"
    static var enabled: Bool {
        get { UserDefaults.standard.bool(forKey: switchKey) }
        set { UserDefaults.standard.set(newValue, forKey: switchKey) }
    }
    private static let keyIdKey = "developer.appAttestKeyId"
    private static let attestationKey = "developer.appAttestAttestation"
    /// The local endpoint: GET /statement?challenge=<64 hex> on this Mac only.
    static let port: UInt16 = 8139

    @Published var status = "" { didSet { if !status.isEmpty, status != "Working…" { AttestLog.write(status) } } }
    @Published var working = false
    @Published var serving = false
    private var listener: NWListener?

    struct Failure: Error { let message: String }

    var supported: Bool {
        if #available(macOS 27, *) { return DCAppAttestService.shared.isSupported }
        return false
    }

    /// One statement: the node is checked, the fingerprint read 100 blocks
    /// below the tip, and App Attest signs it with the challenge. The first
    /// statement of a key attests it (one contact with Apple); later ones are
    /// assertions made on this Mac. Reads only from the node.
    func statement(challenge: String) async throws -> Data {
        guard #available(macOS 27, *), DCAppAttestService.shared.isSupported else {
            throw Failure(message: "App Attest is not supported on this Mac (macOS 27 or later, a normal Mac app).")
        }
        guard StatementClientData.validChallenge(challenge) else {
            throw Failure(message: "The challenge must be 64 lowercase hex characters (32 random bytes).")
        }
        let (own, why) = OwnNodeCheck.run()
        guard let own else { throw Failure(message: "No statement: \(why)") }
        let port = GoMaxConfig.rpcPort
        guard let info = await LocalRPC.call("getblockchaininfo", port: port) as? [String: Any],
              let tip = info["blocks"] as? Int,
              (info["verificationprogress"] as? Double ?? 0) >= 0.999 else {
            throw Failure(message: "Go Max's node is not caught up (or not running). Try again when it is up to date.")
        }
        let height = tip - 100
        guard let block = await LocalRPC.call("getblock", params: [String(height), 1], port: port) as? [String: Any],
              let tree = await LocalRPC.call("z_gettreestate", params: [String(height)], port: port) as? [String: Any],
              let fingerprint = StateFingerprint.make(block: block, treeState: tree) else {
            throw Failure(message: "The node did not answer with everything the fingerprint needs.")
        }
        let json = try StateFingerprint.canonicalJSON(fingerprint)
        let fingerprintHash = StateFingerprint.sha256Hex(json)
        let clientData = try StatementClientData.json(fingerprintSHA256: fingerprintHash, challenge: challenge)
        let digest = Data(SHA256.hash(data: clientData))
        let node = await LocalRPC.call("getinfo", port: port) as? [String: Any]
        let service = DCAppAttestService.shared
        var statement: [String: Any] = [
            "format": "zecky-attested-statement/v1",
            "fingerprint": fingerprint,
            "fingerprintJSON": String(decoding: json, as: UTF8.self),
            "fingerprintSHA256": fingerprintHash,
            "clientDataJSON": String(decoding: clientData, as: UTF8.self),
            "challenge": challenge,
            "height": height,
            "node": ["build": node?["build"] ?? "unknown", "subversion": node?["subversion"] ?? "unknown"],
            "nodeCheck": ["ownNode": true, "startedByThisLockItOnFreePorts": true, "executable": own.executable,
                          "executableSignedBySameTeamAsLockIt": true, "rpc": "127.0.0.1:\(port)"],
            "lockIt": ["version": Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") ?? "",
                       "build": Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") ?? ""],
            "appId": Self.applicationIdentifier() ?? "unknown",
            "createdAt": ISO8601DateFormatter().string(from: Date()),
        ]
        var keyId = UserDefaults.standard.string(forKey: Self.keyIdKey)
        if keyId == nil {
            keyId = try await service.generateKey()
            UserDefaults.standard.set(keyId, forKey: Self.keyIdKey)
        }
        guard let keyId else { throw Failure(message: "No App Attest key.") }
        if let saved = UserDefaults.standard.data(forKey: Self.attestationKey) {
            let assertion = try await service.generateAssertion(keyId, clientDataHash: digest)
            statement["kind"] = "assertion"
            statement["assertion"] = assertion.base64EncodedString()
            statement["keyAttestation"] = saved.base64EncodedString()
        } else {
            let attestation = try await service.attestKey(keyId, clientDataHash: digest)
            UserDefaults.standard.set(attestation, forKey: Self.attestationKey)
            statement["kind"] = "attestation"
            statement["attestation"] = attestation.base64EncodedString()
        }
        statement["keyId"] = keyId
        return try JSONSerialization.data(withJSONObject: statement, options: [.sortedKeys, .prettyPrinted, .withoutEscapingSlashes])
    }

    /// The button: a statement nobody asked for (empty challenge), saved
    /// where the developer chooses.
    func make() async {
        working = true
        defer { working = false }
        status = "Working…"
        do {
            let data = try await statement(challenge: "")
            save(data, name: "zecky-statement.json")
        } catch let failure as Failure {
            status = failure.message
        } catch {
            status = "App Attest said: \(error.localizedDescription) (\((error as NSError).domain) \((error as NSError).code))"
        }
    }

    private func save(_ data: Data, name: String) {
        let panel = NSSavePanel()
        panel.nameFieldStringValue = name
        panel.allowedContentTypes = [.json]
        guard panel.runModal() == .OK, let url = panel.url else { status = "Not saved."; return }
        do {
            try data.write(to: url)
            status = "Saved \(url.lastPathComponent)."
        } catch {
            status = "Could not save: \(error.localizedDescription)"
        }
    }

    // MARK: The local endpoint

    func startIfEnabled() {
        guard Self.enabled else { return }
        startServing()
        if AttestOnion.wanted { AttestOnion.shared.start() }
    }

    /// Listens on 127.0.0.1 only: nothing outside this Mac can ask.
    func startServing() {
        guard listener == nil, let port = NWEndpoint.Port(rawValue: Self.port) else { return }
        let parameters = NWParameters.tcp
        parameters.requiredLocalEndpoint = .hostPort(host: "127.0.0.1", port: port)
        parameters.allowLocalEndpointReuse = false
        guard let listener = try? NWListener(using: parameters) else { status = "Could not listen on port \(Self.port)."; return }
        listener.newConnectionHandler = { connection in
            Task { @MainActor in AttestedStatementMaker.shared.serve(connection) }
        }
        listener.stateUpdateHandler = { state in
            Task { @MainActor in
                switch state {
                case .ready: AttestedStatementMaker.shared.serving = true
                case .failed, .cancelled: AttestedStatementMaker.shared.serving = false
                default: break
                }
            }
        }
        listener.start(queue: .main)
        self.listener = listener
    }

    func stopServing() {
        listener?.cancel()
        listener = nil
        serving = false
    }

    private func serve(_ connection: NWConnection) {
        connection.start(queue: .main)
        connection.receive(minimumIncompleteLength: 1, maximumLength: 4096) { data, _, _, _ in
            let request = String(decoding: data ?? Data(), as: UTF8.self)
            Task { @MainActor in
                let (code, body) = await AttestedStatementMaker.shared.answer(request)
                let reason = code == 200 ? "OK" : (code == 400 ? "Bad Request" : "Service Unavailable")
                let head = "HTTP/1.1 \(code) \(reason)\r\nContent-Type: application/json\r\nContent-Length: \(body.count)\r\nConnection: close\r\n\r\n"
                connection.send(content: Data(head.utf8) + body, completion: .contentProcessed { _ in connection.cancel() })
            }
        }
    }

    /// GET /statement?challenge=<64 hex>. One at a time.
    func answer(_ request: String) async -> (Int, Data) {
        func fail(_ code: Int, _ message: String) -> (Int, Data) {
            AttestLog.write("Refused a request (\(code)): \(message)")
            return (code, (try? JSONSerialization.data(withJSONObject: ["error": message])) ?? Data())
        }
        guard let line = request.split(separator: "\r\n").first,
              line.hasPrefix("GET /statement?challenge="),
              let target = line.split(separator: " ").dropFirst().first else {
            return fail(400, "Use GET /statement?challenge=<64 hex characters>")
        }
        let challenge = String(target.dropFirst("/statement?challenge=".count))
        guard challenge.count == 64, StatementClientData.validChallenge(challenge) else {
            return fail(400, "The challenge must be 64 lowercase hex characters (32 random bytes).")
        }
        guard !working else { return fail(503, "Busy with another statement; try again in a moment.") }
        working = true
        defer { working = false }
        do {
            let data = try await statement(challenge: challenge)
            status = "Answered a challenge."
            return (200, data)
        } catch let failure as Failure {
            status = failure.message
            return fail(503, failure.message)
        } catch {
            status = "App Attest said: \(error.localizedDescription)"
            return fail(503, "App Attest: \(error.localizedDescription)")
        }
    }

    /// "TEAMID.app.zecky.lockit", from this app's own signature.
    static func applicationIdentifier() -> String? {
        guard let task = SecTaskCreateFromSelf(nil) else { return nil }
        return SecTaskCopyValueForEntitlement(task, "com.apple.application-identifier" as CFString, nil) as? String
    }
}

/// attest.log beside the node's logs (GoMax/logs), so "Show the logs" in
/// Technical details and "Show the node's logs" in Go Max open one folder
/// with zakurad, zainod, arti and attest. Holds no wallet data.
@MainActor
enum AttestLog {
    static var folder: URL? { GoMaxNode.folder?.appendingPathComponent("logs", isDirectory: true) }

    static func write(_ line: String) {
        guard let folder else { return }
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let text = "\(ISO8601DateFormatter().string(from: Date())) \(line)\n"
        guard let handle = try? GoMaxNode.logHandle(folder.appendingPathComponent("attest.log")) else { return }
        handle.write(Data(text.utf8))
        try? handle.close()
    }
}

/// The challenge endpoint as a Tor onion service, so other nodes and wallets
/// can ask from anywhere without learning this Mac's address. Arti (the Tor
/// Project's Tor in Rust, inside debug builds only) runs in Lock it's sandbox
/// and forwards the onion's port 80 to 127.0.0.1:8139. The onion key is made
/// on the first start and kept in Lock it's own folder, so the address stays
/// the same across restarts.
@MainActor
final class AttestOnion: ObservableObject {
    static let shared = AttestOnion()
    static let nickname = "zecky-attest"
    /// Arti's own SOCKS port on this Mac, for testing the onion from Terminal.
    static let socksPort = 9150

    @Published var state = "Off"
    @Published var address: String?
    private var process: Process?
    private var lifeline: Pipe?

    var available: Bool { GoMaxNode.helper("arti") != nil }

    /// "Also over Tor", remembered across starts.
    static var wanted: Bool {
        get { UserDefaults.standard.bool(forKey: "developer.attestOverTor") }
        set { UserDefaults.standard.set(newValue, forKey: "developer.attestOverTor") }
    }

    private var root: URL? { GoMaxNode.folder?.appendingPathComponent("arti", isDirectory: true) }

    private func config(_ root: URL) -> String {
        """
        # Written by Lock it (debug builds, attested-statement experiment).
        [storage]
        cache_dir = "\(root.appendingPathComponent("cache").path)"
        state_dir = "\(root.appendingPathComponent("state").path)"

        [logging]
        console = "info"

        [onion_services."\(Self.nickname)"]
        proxy_ports = [["80", "127.0.0.1:\(AttestedStatementMaker.port)"]]
        """
    }

    func start() {
        guard process == nil else { return }
        guard let arti = GoMaxNode.helper("arti"), let root else { state = "No Arti in this build."; return }
        do {
            let fm = FileManager.default
            for dir in ["cache", "state"] {
                try fm.createDirectory(at: root.appendingPathComponent(dir), withIntermediateDirectories: true)
            }
            guard let logs = AttestLog.folder else { state = "No log folder."; return }
            try fm.createDirectory(at: logs, withIntermediateDirectories: true)
            let configURL = root.appendingPathComponent("arti.toml")
            try config(root).write(to: configURL, atomically: true, encoding: .utf8)
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/bin/sh")
            process.arguments = ["-c", GoMaxNode.keeper, arti.path, "proxy", "-c", configURL.path]
            // Arti checks folder permissions all the way up; inside the
            // sandbox it cannot see every parent folder, so that check is off.
            process.environment = ProcessInfo.processInfo.environment.merging(["ARTI_FS_DISABLE_PERMISSION_CHECKS": "1"]) { $1 }
            let log = try GoMaxNode.logHandle(logs.appendingPathComponent("arti.log"))
            let lifeline = Pipe()
            process.standardOutput = log
            process.standardError = log
            process.standardInput = lifeline
            process.qualityOfService = .utility
            try process.run()
            self.process = process
            self.lifeline = lifeline
            state = "Starting Tor…"
            Task { await waitForAddress(arti: arti, configURL: configURL) }
        } catch {
            state = "Could not start Arti: \(error.localizedDescription)"
        }
    }

    func stop() {
        process?.interrupt()
        process = nil
        lifeline = nil
        address = nil
        state = "Off"
    }

    /// The onion address, from Arti's own keystore (it is made on the first
    /// start). Asked again for a minute while Tor bootstraps.
    private func waitForAddress(arti: URL, configURL: URL) async {
        for _ in 0..<30 {
            for command in ["onion-address", "onion-name"] {
                if let out = await Self.run(arti, ["-c", configURL.path, "hss", "--nickname", Self.nickname, command]),
                   let onion = out.split(whereSeparator: \.isWhitespace).map(String.init).first(where: { $0.hasSuffix(".onion") }) {
                    address = onion
                    state = "Answering over Tor"
                    return
                }
            }
            guard process?.isRunning == true else { state = "Arti stopped. See arti.log (Show the logs, below)."; return }
            try? await Task.sleep(nanoseconds: 2_000_000_000)
        }
        state = "Tor started, but no onion address yet. See arti.log (Show the logs, below)."
    }

    private static func run(_ program: URL, _ arguments: [String]) async -> String? {
        await withCheckedContinuation { continuation in
            let process = Process()
            process.executableURL = program
            process.arguments = arguments
            process.environment = ProcessInfo.processInfo.environment.merging(["ARTI_FS_DISABLE_PERMISSION_CHECKS": "1"]) { $1 }
            let out = Pipe()
            process.standardOutput = out
            process.standardError = Pipe()
            process.terminationHandler = { _ in
                let data = out.fileHandleForReading.readDataToEndOfFile()
                continuation.resume(returning: String(decoding: data, as: UTF8.self))
            }
            do { try process.run() } catch { continuation.resume(returning: nil) }
        }
    }
}

/// Asks another Go Max node for a statement over Tor, through Lock it's own
/// Arti (SOCKS5 on 127.0.0.1:9150), with a fresh challenge. Lock it checks
/// only that the answer is a v1 statement for exactly this challenge; the
/// full check (Apple's chain, the app, the key's signature) is
/// tools/verify-statement, run on the saved file.
@MainActor
final class AttestAsker: ObservableObject {
    static let shared = AttestAsker()
    @Published var status = "" { didSet { if !status.isEmpty, !status.hasPrefix("Asking ") { AttestLog.write(status) } } }
    @Published var working = false

    func ask(_ input: String) async {
        let onion = input.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            .replacingOccurrences(of: "http://", with: "").trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        guard onion.hasSuffix(".onion"), onion.count == 62 else { status = "That is not a v3 onion address (56 characters, then .onion)."; return }
        guard AttestOnion.shared.address != nil else { status = "Switch on \"Answer over Tor too\" first: asking goes through the same Tor."; return }
        var bytes = [UInt8](repeating: 0, count: 32)
        guard SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes) == errSecSuccess else { status = "No random bytes."; return }
        let challenge = bytes.map { String(format: "%02x", $0) }.joined()
        working = true
        status = "Asking \(onion.prefix(12))… over Tor"
        AttestLog.write("Asking \(onion) with challenge \(challenge)")
        defer { working = false }
        do {
            let body = try await Self.get(host: onion, path: "/statement?challenge=\(challenge)")
            guard let json = try? JSONSerialization.jsonObject(with: body) as? [String: Any] else {
                throw AskFailure("The answer is not JSON (\(body.count) bytes).")
            }
            if let error = json["error"] as? String { throw AskFailure("The node said: \(error)") }
            guard json["format"] as? String == "zecky-attested-statement/v1",
                  json["challenge"] as? String == challenge,
                  let client = json["clientDataJSON"] as? String,
                  client.contains("\"challenge\":\"\(challenge)\"") else {
                throw AskFailure("The answer is not a v1 statement for this challenge.")
            }
            let height = (json["height"] as? Int).map(String.init) ?? "?"
            let name = "asked-\(onion.prefix(8))-\(Int(Date().timeIntervalSince1970)).json"
            if let folder = AttestLog.folder { try body.write(to: folder.appendingPathComponent(name)) }
            status = "Answered for your challenge, height \(height). Saved \(name) in the logs folder; check it with verify_statement.py --challenge \(challenge)"
        } catch let failure as AskFailure {
            status = failure.message
        } catch {
            status = "Could not reach it over Tor: \(error.localizedDescription)"
        }
    }

    struct AskFailure: Error { let message: String; init(_ m: String) { message = m } }

    /// A plain HTTP GET to host:80 through SOCKS5 (the onion name is resolved
    /// by Tor, never on this Mac). Reads until the node closes.
    private static func get(host: String, path: String) async throws -> Data {
        let connection = NWConnection(host: "127.0.0.1", port: NWEndpoint.Port(rawValue: UInt16(AttestOnion.socksPort))!, using: .tcp)
        defer { connection.cancel() }
        try await withCheckedThrowingContinuation { (c: CheckedContinuation<Void, Error>) in
            // Handlers run one after another on the queue; clearing the
            // handler makes sure the continuation is resumed once.
            connection.stateUpdateHandler = { state in
                switch state {
                case .ready: connection.stateUpdateHandler = nil; c.resume()
                case .failed(let e), .waiting(let e): connection.stateUpdateHandler = nil; c.resume(throwing: e)
                default: break
                }
            }
            connection.start(queue: .global(qos: .utility))
        }
        try await send(connection, Data([5, 1, 0]))
        guard try await receive(connection, 2) == Data([5, 0]) else { throw AskFailure("Tor's SOCKS port refused the greeting.") }
        let name = Data(host.utf8)
        try await send(connection, Data([5, 1, 0, 3, UInt8(name.count)]) + name + Data([0, 80]))
        let reply = [UInt8](try await receive(connection, 4))
        guard reply.count == 4, reply[1] == 0 else {
            throw AskFailure("Tor could not reach that onion (SOCKS code \(reply.count > 1 ? Int(reply[1]) : -1)); it may be off or still publishing.")
        }
        let rest = reply[3] == 1 ? 6 : reply[3] == 4 ? 18 : Int(try await receive(connection, 1).first ?? 0) + 2
        _ = try await receive(connection, rest)
        try await send(connection, Data("GET \(path) HTTP/1.0\r\nHost: \(host)\r\nConnection: close\r\n\r\n".utf8))
        var response = Data()
        while response.count < 2_000_000 {
            let chunk = try await receiveSome(connection)
            if chunk.isEmpty { break }
            response += chunk
        }
        guard let split = response.range(of: Data("\r\n\r\n".utf8)) else { throw AskFailure("No HTTP answer.") }
        return Data(response[split.upperBound...])
    }

    private static func send(_ connection: NWConnection, _ data: Data) async throws {
        try await withCheckedThrowingContinuation { (c: CheckedContinuation<Void, Error>) in
            connection.send(content: data, completion: .contentProcessed { error in
                if let error { c.resume(throwing: error) } else { c.resume() }
            })
        }
    }

    private static func receive(_ connection: NWConnection, _ count: Int) async throws -> Data {
        try await withCheckedThrowingContinuation { (c: CheckedContinuation<Data, Error>) in
            connection.receive(minimumIncompleteLength: count, maximumLength: count) { data, _, _, error in
                if let error { c.resume(throwing: error) } else { c.resume(returning: data ?? Data()) }
            }
        }
    }

    private static func receiveSome(_ connection: NWConnection) async throws -> Data {
        try await withCheckedThrowingContinuation { (c: CheckedContinuation<Data, Error>) in
            connection.receive(minimumIncompleteLength: 1, maximumLength: 65_536) { data, _, isComplete, error in
                if let data, !data.isEmpty { c.resume(returning: data) }
                else if let error, !isComplete { c.resume(throwing: error) }
                else { c.resume(returning: Data()) }
            }
        }
    }
}

/// Settings › Go Max, debug builds only: the attested-statement experiment
/// as its own card under the node, since every statement comes from it.
struct GoMaxAttestCard: View {
    @ObservedObject private var maker = AttestedStatementMaker.shared
    @ObservedObject private var onion = AttestOnion.shared
    @ObservedObject private var asker = AttestAsker.shared
    @State private var on = AttestedStatementMaker.enabled
    @State private var tor = AttestOnion.wanted
    @State private var otherNode = ""
    @State private var copied = false

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(alignment: .firstTextBaseline) {
                Label("Attested statements", systemImage: "checkmark.seal")
                    .font(Theme.text(13, weight: .semibold)).foregroundStyle(Theme.text)
                    .labelStyle(GoldIconLabelStyle())
                Spacer()
                Text("DEVELOPER")
                    .font(Theme.text(9, weight: .semibold)).tracking(1.2).foregroundStyle(Theme.gold)
                    .padding(.horizontal, 7).padding(.vertical, 3)
                    .overlay(Capsule().stroke(Theme.gold.opacity(0.5)))
            }
            Text("This node confirms the chain at a height, signed with Apple's App Attest, to whoever sends it a fresh challenge. An experiment in debug builds only.")
                .font(Theme.text(12)).foregroundStyle(Theme.muted)
                .fixedSize(horizontal: false, vertical: true)

            settingRow("Answer challenges", detail: answerDetail, good: on && maker.serving && maker.supported, isOn: $on)
                .onChange(of: on) { value in
                    AttestedStatementMaker.enabled = value
                    if value { maker.startServing() } else { maker.stopServing(); onion.stop(); tor = false; AttestOnion.wanted = false }
                }

            if onion.available {
                settingRow("Also over Tor", detail: torDetail, good: onion.address != nil, isOn: $tor)
                    .disabled(!on).opacity(on ? 1 : 0.45)
                    .onChange(of: tor) { value in
                        AttestOnion.wanted = value
                        if value { onion.start() } else { onion.stop() }
                    }
                if tor, let address = onion.address {
                    HStack(spacing: 10) {
                        Text(address)
                            .font(.system(size: 11, design: .monospaced)).foregroundStyle(Theme.text)
                            .lineLimit(1).truncationMode(.middle).textSelection(.enabled)
                        Spacer(minLength: 4)
                        Button(copied ? "Copied" : "Copy") {
                            NSPasteboard.general.clearContents()
                            NSPasteboard.general.setString(address, forType: .string)
                            copied = true
                            Task { try? await Task.sleep(nanoseconds: 1_500_000_000); copied = false }
                        }
                        .buttonStyle(.plain).font(Theme.text(12, weight: .medium)).foregroundStyle(Theme.gold)
                    }
                    .padding(.horizontal, 12).padding(.vertical, 9)
                    .background(Theme.ink, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
                    .overlay(RoundedRectangle(cornerRadius: 8, style: .continuous).stroke(Theme.line))
                }
            }

            if on, tor, onion.address != nil {
                Divider().overlay(Theme.line)
                VStack(alignment: .leading, spacing: 8) {
                    Text("ASK ANOTHER NODE")
                        .font(Theme.text(10, weight: .semibold)).tracking(1.4).foregroundStyle(Theme.gold)
                    HStack(spacing: 10) {
                        TextField("its .onion address", text: $otherNode)
                            .textFieldStyle(.plain).font(.system(size: 11, design: .monospaced))
                            .padding(.horizontal, 10).padding(.vertical, 8)
                            .background(Theme.ink, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
                            .overlay(RoundedRectangle(cornerRadius: 8, style: .continuous).stroke(Theme.line))
                            .onSubmit { ask() }
                        Button(asker.working ? "Asking…" : "Ask over Tor") { ask() }
                            .buttonStyle(.plain).font(Theme.text(12, weight: .medium)).foregroundStyle(Theme.gold)
                            .disabled(asker.working || otherNode.isEmpty)
                            .opacity(otherNode.isEmpty ? 0.5 : 1)
                    }
                    if !asker.status.isEmpty {
                        Text(asker.status).font(Theme.text(11)).foregroundStyle(Theme.muted)
                            .fixedSize(horizontal: false, vertical: true).textSelection(.enabled)
                    }
                }
            }

            if on {
                Divider().overlay(Theme.line)
                HStack(spacing: 18) {
                    Button(maker.working ? "Working…" : "Make a statement…") { Task { await maker.make() } }
                        .disabled(maker.working)
                    if let logs = AttestLog.folder {
                        Button("Show the logs") { NSWorkspace.shared.activateFileViewerSelecting([logs]) }
                    }
                    Spacer()
                }
                .buttonStyle(.plain).font(Theme.text(12, weight: .medium)).foregroundStyle(Theme.gold)
                if !maker.status.isEmpty {
                    Text("Last: \(maker.status)").font(Theme.text(11)).foregroundStyle(Theme.muted)
                        .fixedSize(horizontal: false, vertical: true).textSelection(.enabled)
                }
            }
        }
        .card(padding: 16)
    }

    private var answerDetail: String {
        guard on else { return "Off. Nothing answers." }
        guard maker.supported else { return "App Attest is not available on this Mac." }
        return maker.serving ? "On this Mac only (127.0.0.1:\(String(AttestedStatementMaker.port)))" : "Starting…"
    }

    private var torDetail: String {
        guard on else { return "Needs Answer challenges." }
        return tor ? onion.state : "Off. Other nodes cannot reach this one."
    }

    private func ask() {
        guard !asker.working, !otherNode.isEmpty else { return }
        Task { await asker.ask(otherNode) }
    }

    private func settingRow(_ title: String, detail: String, good: Bool, isOn: Binding<Bool>) -> some View {
        HStack(alignment: .center, spacing: 12) {
            VStack(alignment: .leading, spacing: 3) {
                Text(title).font(Theme.text(13, weight: .medium)).foregroundStyle(Theme.text)
                HStack(spacing: 6) {
                    Circle().fill(good ? Theme.green : Theme.muted.opacity(0.6)).frame(width: 6, height: 6)
                    Text(detail).font(Theme.text(11)).foregroundStyle(good ? Theme.green : Theme.muted)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            Spacer()
            Toggle("", isOn: isOn).labelsHidden().toggleStyle(.switch).controlSize(.small).tint(Theme.gold)
        }
    }
}
#endif
