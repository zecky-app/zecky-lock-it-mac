import AppKit
import AuthenticationServices
import CryptoKit
import Foundation

// Security keys (FIDO2, such as a YubiKey) as key ④ to release, as on the
// iPhone (Lock it 0.0.19). Pairing and checking go through Apple's own
// security key window. Nothing is sent anywhere: the key is plugged in or
// held to the Mac, and its answer is checked here against the public key
// saved when pairing.

// MARK: - The answer checks (WebAuthn), kept free of UI so they are tested

enum WebAuthn {
    /// The name keys are registered under. Must match zecky.app's
    /// apple-app-site-association (webcredentials).
    static let relyingParty = "zecky.app"

    struct DataError: Error, CustomStringConvertible { let description: String }
    private static func fail(_ why: String) -> DataError { DataError(description: why) }

    private static let userPresent: UInt8 = 0x01
    private static let attested: UInt8 = 0x40

    // A small CBOR reader: just what a security key's answers use.
    indirect enum Cbor: Equatable {
        case int(Int), bytes(Data), text(String), array([Cbor]), map([(Cbor, Cbor)]), bool(Bool), null
        static func == (a: Cbor, b: Cbor) -> Bool {
            switch (a, b) {
            case let (.int(x), .int(y)): return x == y
            case let (.bytes(x), .bytes(y)): return x == y
            case let (.text(x), .text(y)): return x == y
            case let (.bool(x), .bool(y)): return x == y
            case (.null, .null): return true
            default: return false
            }
        }
        subscript(key: Cbor) -> Cbor? {
            if case .map(let pairs) = self { return pairs.first { $0.0 == key }?.1 }
            return nil
        }
    }

    static func readCbor(_ bytes: [UInt8], at start: Int = 0, depth: Int = 0) throws -> (Cbor, Int) {
        guard depth <= 8 else { throw fail("CBOR nested too deep") }
        var pos = start
        func take(_ n: Int) throws -> ArraySlice<UInt8> {
            guard n >= 0, pos + n <= bytes.count else { throw fail("CBOR ends early") }
            defer { pos += n }
            return bytes[pos..<pos + n]
        }
        let head = try take(1).first!
        let major = head >> 5, info = head & 0x1f
        var arg = 0
        switch info {
        case 0..<24: arg = Int(info)
        case 24: arg = Int(try take(1).first!)
        case 25: let b = Array(try take(2)); arg = Int(b[0]) << 8 | Int(b[1])
        case 26: let b = Array(try take(4)); arg = Int(b[0]) << 24 | Int(b[1]) << 16 | Int(b[2]) << 8 | Int(b[3])
        default: throw fail("CBOR value not supported")
        }
        switch major {
        case 0: return (.int(arg), pos)
        case 1: return (.int(-1 - arg), pos)
        case 2: return (.bytes(Data(try take(arg))), pos)
        case 3: return (.text(String(decoding: try take(arg), as: UTF8.self)), pos)
        case 4:
            var list: [Cbor] = []
            for _ in 0..<arg { let (item, next) = try readCbor(bytes, at: pos, depth: depth + 1); list.append(item); pos = next }
            return (.array(list), pos)
        case 5:
            var pairs: [(Cbor, Cbor)] = []
            for _ in 0..<arg {
                let (k, a) = try readCbor(bytes, at: pos, depth: depth + 1)
                let (v, b) = try readCbor(bytes, at: a, depth: depth + 1)
                pairs.append((k, v)); pos = b
            }
            return (.map(pairs), pos)
        case 7:
            if info == 20 { return (.bool(false), pos) }
            if info == 21 { return (.bool(true), pos) }
            if info == 22 { return (.null, pos) }
            throw fail("CBOR value not supported")
        default: throw fail("CBOR value not supported")
        }
    }

    struct AuthData {
        let rpIdHash: Data
        let flags: UInt8
        let signCount: UInt32
        var credentialId: Data?
        /// Uncompressed P-256 public key: 0x04, x, y (65 bytes).
        var publicKey: Data?
    }

    static func parseAuthData(_ data: Data) throws -> AuthData {
        let b = [UInt8](data)
        guard b.count >= 37 else { throw fail("Key data too short") }
        let count = UInt32(b[33]) << 24 | UInt32(b[34]) << 16 | UInt32(b[35]) << 8 | UInt32(b[36])
        var auth = AuthData(rpIdHash: Data(b[0..<32]), flags: b[32], signCount: count)
        guard b[32] & attested != 0 else { return auth }
        guard b.count >= 55 else { throw fail("Key data too short") }
        let idLength = Int(b[53]) << 8 | Int(b[54])
        let idEnd = 55 + idLength
        guard idLength > 0, idEnd <= b.count else { throw fail("Key ID missing") }
        auth.credentialId = Data(b[55..<idEnd])
        let (cose, _) = try readCbor(b, at: idEnd)
        guard cose[.int(1)] == .int(2), cose[.int(3)] == .int(-7), cose[.int(-1)] == .int(1),
              case .bytes(let x)? = cose[.int(-2)], case .bytes(let y)? = cose[.int(-3)],
              x.count == 32, y.count == 32 else { throw fail("This kind of key is not supported") }
        auth.publicKey = Data([0x04]) + x + y
        return auth
    }

    private static func checkClientData(_ json: Data, type: String, challenge: Data) throws {
        guard let obj = try? JSONSerialization.jsonObject(with: json) as? [String: Any] else { throw fail("Key answer not readable") }
        guard obj["type"] as? String == type else { throw fail("Key answer is of the wrong kind") }
        guard let c = obj["challenge"] as? String, let got = base64URL(c) else { throw fail("Key answer has no challenge") }
        guard got == challenge else { throw fail("Key answer is for another request") }
    }

    private static func checkRp(_ auth: AuthData) throws {
        guard auth.rpIdHash == Data(SHA256.hash(data: Data(relyingParty.utf8))) else { throw fail("Key answer is for another app or site") }
        guard auth.flags & userPresent != 0 else { throw fail("The key was not touched") }
    }

    static func base64URL(_ s: String) -> Data? {
        var t = s.replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/")
        while t.count % 4 != 0 { t.append("=") }
        return Data(base64Encoded: t)
    }

    struct Paired: Codable, Equatable {
        var id: Data
        var publicKey: Data
        var signCount: UInt32
    }

    /// Checks a new key's answer and returns what Lock it keeps of it.
    static func readRegistration(credentialId: Data, attestationObject: Data, clientDataJSON: Data, challenge: Data) throws -> Paired {
        try checkClientData(clientDataJSON, type: "webauthn.create", challenge: challenge)
        let (att, _) = try readCbor([UInt8](attestationObject))
        guard case .bytes(let authBytes)? = att[.text("authData")] else { throw fail("Key answer not readable") }
        let auth = try parseAuthData(authBytes)
        try checkRp(auth)
        guard let id = auth.credentialId, let key = auth.publicKey else { throw fail("Key ID missing") }
        guard id == credentialId else { throw fail("Key ID does not match") }
        return Paired(id: id, publicKey: key, signCount: auth.signCount)
    }

    /// Checks a key's answer at release: everything, including the ES256
    /// signature over authenticatorData + SHA-256(clientDataJSON). Returns
    /// the paired key it came from and its new counter.
    static func readAssertion(credentialId: Data, authenticatorData: Data, clientDataJSON: Data, signature: Data,
                              challenge: Data, keys: [Paired]) throws -> (Paired, UInt32) {
        guard let key = keys.first(where: { $0.id == credentialId }) else { throw fail("This is not one of your keys") }
        try checkClientData(clientDataJSON, type: "webauthn.get", challenge: challenge)
        let auth = try parseAuthData(authenticatorData)
        try checkRp(auth)
        // Keys count their uses; a count that goes backwards means a copied key.
        if auth.signCount != 0 || key.signCount != 0, auth.signCount <= key.signCount { throw fail("This key may have been copied") }
        let pub = try P256.Signing.PublicKey(x963Representation: key.publicKey)
        let sig = try P256.Signing.ECDSASignature(derRepresentation: signature)
        var message = authenticatorData
        message.append(contentsOf: SHA256.hash(data: clientDataJSON))
        guard pub.isValidSignature(sig, for: message) else { throw fail("This key did not answer correctly") }
        return (key, auth.signCount)
    }
}

// MARK: - The saved keys

enum SecurityKeys {
    enum Role: String, Codable { case main, backup }

    struct Key: Codable, Equatable, Identifiable {
        var paired: WebAuthn.Paired
        var role: Role
        var added: Date
        var id: Data { paired.id }
    }

    /// "Lost my keys", while its 48 hours run.
    struct Removal: Codable, Equatable { var startedAt: Date; var startHeight: Int }

    struct State: Codable, Equatable {
        var keys: [Key] = []
        var phraseNeedsKey = false
        var removal: Removal?
        /// Highest block height seen while fully synced (iPhone re-check R1).
        var heightSeen = 0
    }

    enum Failure: Error, CustomStringConvertible {
        case cancelled, duplicate, none, wrong(String), unreadable, failed(String)
        var description: String {
            switch self {
            case .cancelled: return "No key was used."
            case .duplicate: return "This key is already added."
            case .none: return "No security key is added."
            case .wrong(let why): return "\(why). Nothing was sent."
            case .unreadable: return "Lock it could not read your security keys. Nothing was shown or sent. Quit Lock it and open it again; if it stays like this, restore from your 24 words."
            case .failed(let why): return why
            }
        }
    }

    private static let service = "app.zecky.lockit.mac.seckeys"

    /// Reads the saved state. Anything unreadable throws instead of counting
    /// as "no keys" (iPhone re-check R2): a damaged entry never switches
    /// the keys off.
    static func load() throws -> State {
        guard let data = try KeyStore.read(service: service) else { return State() }
        guard let state = try? JSONDecoder().decode(State.self, from: data) else { throw Failure.unreadable }
        return state
    }

    private static func save(_ state: State) throws {
        if state.keys.isEmpty { try KeyStore.delete(service: service); return }
        try KeyStore.save(try JSONEncoder().encode(state), service: service)
    }

    static func erase() {
        try? KeyStore.delete(service: service)
        try? KeyStore.delete(service: heightService)
    }

    /// The highest height seen while synced, in its own small item: it
    /// changes with every block, and the key list is never rewritten that
    /// often (iPhone audit C-06). Its presence also marks that keys were set
    /// up: if it is there but the key list is gone, Lock it fails closed.
    private static let heightService = "app.zecky.lockit.mac.seckeysheight"
    private static var heightItem: Int? {
        guard let data = try? KeyStore.read(service: heightService) else { return nil }
        return Int(String(decoding: data, as: UTF8.self))
    }
    static var heightSeen: Int { max(heightItem ?? 0, (try? load().heightSeen) ?? 0) }

    /// Fails closed: an unreadable entry, or a height marker without a key
    /// list, counts as "keys present" (iPhone re-check R2).
    static var hasKeys: Bool {
        guard let state = try? load() else { return true }
        return !state.keys.isEmpty || heightItem != nil
    }
    static var keys: [Key] { (try? load().keys) ?? [] }

    // MARK: Asking a key

    @MainActor
    static func check() async throws {
        let state = try load()
        guard !state.keys.isEmpty else { throw heightItem != nil ? Failure.unreadable : Failure.none }
        let challenge = randomBytes(32)
        let answer = try await KeyRequest.assert(challenge: challenge, ids: state.keys.map(\.id))
        let found: (WebAuthn.Paired, UInt32)
        do {
            found = try WebAuthn.readAssertion(credentialId: answer.credentialId, authenticatorData: answer.authenticatorData,
                                               clientDataJSON: answer.clientDataJSON, signature: answer.signature,
                                               challenge: challenge, keys: state.keys.map(\.paired))
        } catch { throw Failure.wrong(String(describing: error)) }
        var next = try load()
        if let i = next.keys.firstIndex(where: { $0.id == found.0.id }) { next.keys[i].paired.signCount = found.1 }
        try save(next)
    }

    /// Adds a key. With keys already paired, one of them is asked first:
    /// otherwise someone could add their own key and use it to remove yours.
    /// The first key is guarded by the owner check on the screen.
    @MainActor
    static func add(role: Role) async throws {
        let current = try load()
        guard current.removal == nil else { throw Failure.failed("Cancel the key removal first, or wait until it is done.") }
        if !current.keys.isEmpty { try await check() }
        let challenge = randomBytes(32)
        let userId = randomBytes(16) // random: nothing about you is on the key
        let answer = try await KeyRequest.register(challenge: challenge, userId: userId)
        let paired: WebAuthn.Paired
        do {
            paired = try WebAuthn.readRegistration(credentialId: answer.credentialId, attestationObject: answer.attestationObject,
                                                   clientDataJSON: answer.clientDataJSON, challenge: challenge)
        } catch { throw Failure.wrong(String(describing: error)) }
        var next = try load()
        guard !next.keys.contains(where: { $0.id == paired.id }) else { throw Failure.duplicate }
        next.keys.append(Key(paired: paired, role: role, added: Date()))
        try save(next)
        LockLog.add(.keys, role == .main ? "Security key added" : "Backup security key added")
    }

    /// Removes one key, after a tap of any paired key.
    @MainActor
    static func remove(_ id: Data) async throws {
        try await check()
        var next = try load()
        next.keys.removeAll { $0.id == id }
        if next.keys.count < LockRules.phraseKeyMinKeys { next.phraseNeedsKey = false }
        if next.keys.isEmpty {
            erase()
            LockLog.add(.keys, "Security key removed")
            return
        }
        try save(next)
        LockLog.add(.keys, "Security key removed")
    }

    @MainActor
    static func setPhraseNeedsKey(_ on: Bool) async throws {
        var next = try load()
        if on {
            guard next.keys.count >= LockRules.phraseKeyMinKeys else { throw Failure.failed("Add a backup key first.") }
        } else {
            try await check()
            next = try load()
        }
        next.phraseNeedsKey = on
        try save(next)
        LockLog.add(.keys, on ? "Security key for the recovery phrase: on" : "Security key for the recovery phrase: off")
    }

    static var phraseNeedsKey: Bool { (try? load().phraseNeedsKey) ?? true }

    // MARK: "Lost my keys"

    /// Remembers the highest height seen while fully synced, so a server
    /// that reports a lower one cannot shorten a removal (R1).
    static func noteSyncedHeight(_ height: Int) {
        guard height > 0, (try? load().keys.isEmpty == false) == true, height > (heightItem ?? 0) else { return }
        try? KeyStore.save(Data(String(height).utf8), service: heightService)
    }

    static var removal: Removal? { try? load().removal }

    static func startRemoval(syncedHeight: Int) throws {
        var s = try load()
        guard let start = LockRules.removalStartHeight(synced: syncedHeight, seen: heightSeen) else {
            throw Failure.failed(syncedHeight <= 0
                ? "Wait until Lock it is up to date, then try again."
                : "This server is behind what Lock it has seen before. Switch back to your usual server, then try again.")
        }
        s.removal = Removal(startedAt: Date(), startHeight: start)
        try save(s)
        LockLog.add(.keys, "Lost my keys: removal of all security keys started (48 hours)")
    }

    /// Changing the server while a removal runs starts the 48 hours again (R1).
    static func restartRemovalIfRunning() {
        guard var s = try? load(), let r = s.removal else { return }
        s.removal = Removal(startedAt: Date(), startHeight: max(r.startHeight, heightSeen))
        try? save(s)
    }

    @MainActor
    static func cancelRemoval() async throws {
        try await check()
        var s = try load()
        s.removal = nil
        try save(s)
        LockLog.add(.keys, "Lost my keys: removal cancelled")
    }

    /// Finishes the removal once both the network and the clock show 48
    /// hours, and only on one of the built-in public servers over TLS: a
    /// server of one's own could report blocks that do not exist (iPhone
    /// audit C-28).
    static func finishRemovalIfDue(syncedHeight: Int) -> Bool {
        guard Server.isBuiltIn,
              let s = try? load(), LockRules.removalDue(s.removal, now: Date(), networkHeight: syncedHeight) else { return false }
        erase()
        LockLog.add(.keys, "Lost my keys: all security keys removed after 48 hours")
        return true
    }

    static func randomBytes(_ n: Int) -> Data {
        var b = [UInt8](repeating: 0, count: n)
        _ = SecRandomCopyBytes(kSecRandomDefault, n, &b)
        return Data(b)
    }
}

// MARK: - Apple's security key window

@MainActor
final class KeyRequest: NSObject, ASAuthorizationControllerDelegate, ASAuthorizationControllerPresentationContextProviding {
    struct Registration { let credentialId: Data; let attestationObject: Data; let clientDataJSON: Data }
    struct Assertion { let credentialId: Data; let authenticatorData: Data; let clientDataJSON: Data; let signature: Data }

    private var continuation: CheckedContinuation<ASAuthorization, Error>?
    private var controller: ASAuthorizationController?
    private static var current: KeyRequest?

    private static func run(_ request: ASAuthorizationRequest) async throws -> ASAuthorization {
        let handler = KeyRequest()
        current = handler
        defer { current = nil }
        return try await withCheckedThrowingContinuation { c in
            handler.continuation = c
            let controller = ASAuthorizationController(authorizationRequests: [request])
            controller.delegate = handler
            controller.presentationContextProvider = handler
            handler.controller = controller
            controller.performRequests()
        }
    }

    static func register(challenge: Data, userId: Data) async throws -> Registration {
        let provider = ASAuthorizationSecurityKeyPublicKeyCredentialProvider(relyingPartyIdentifier: WebAuthn.relyingParty)
        let request = provider.createCredentialRegistrationRequest(challenge: challenge, displayName: "Zecky Lock it",
                                                                    name: "Zecky Lock it", userID: userId)
        request.credentialParameters = [ASAuthorizationPublicKeyCredentialParameters(algorithm: .ES256)]
        request.residentKeyPreference = .discouraged
        request.userVerificationPreference = .discouraged
        request.attestationPreference = .none
        let auth = try await run(request)
        guard let c = auth.credential as? ASAuthorizationSecurityKeyPublicKeyCredentialRegistration,
              let attestation = c.rawAttestationObject else { throw SecurityKeys.Failure.failed("Unexpected answer from the security key.") }
        return Registration(credentialId: c.credentialID, attestationObject: attestation, clientDataJSON: c.rawClientDataJSON)
    }

    static func assert(challenge: Data, ids: [Data]) async throws -> Assertion {
        let provider = ASAuthorizationSecurityKeyPublicKeyCredentialProvider(relyingPartyIdentifier: WebAuthn.relyingParty)
        let request = provider.createCredentialAssertionRequest(challenge: challenge)
        request.allowedCredentials = ids.map {
            ASAuthorizationSecurityKeyPublicKeyCredentialDescriptor(
                credentialID: $0, transports: ASAuthorizationSecurityKeyPublicKeyCredentialDescriptor.Transport.allSupported)
        }
        request.userVerificationPreference = .discouraged
        let auth = try await run(request)
        guard let c = auth.credential as? ASAuthorizationSecurityKeyPublicKeyCredentialAssertion,
              let data = c.rawAuthenticatorData, let sig = c.signature
        else { throw SecurityKeys.Failure.failed("Unexpected answer from the security key.") }
        return Assertion(credentialId: c.credentialID, authenticatorData: data, clientDataJSON: c.rawClientDataJSON, signature: sig)
    }

    nonisolated func presentationAnchor(for controller: ASAuthorizationController) -> ASPresentationAnchor {
        MainActor.assumeIsolated { NSApp.keyWindow ?? NSApp.windows.first ?? ASPresentationAnchor() }
    }

    nonisolated func authorizationController(controller: ASAuthorizationController, didCompleteWithAuthorization authorization: ASAuthorization) {
        MainActor.assumeIsolated { continuation?.resume(returning: authorization); continuation = nil }
    }

    nonisolated func authorizationController(controller: ASAuthorizationController, didCompleteWithError error: Error) {
        MainActor.assumeIsolated {
            let cancelled = (error as? ASAuthorizationError)?.code == .canceled
            continuation?.resume(throwing: cancelled ? SecurityKeys.Failure.cancelled
                                                     : SecurityKeys.Failure.failed("The key could not be read: \(error.localizedDescription)"))
            continuation = nil
        }
    }
}
