import AppKit
import SwiftUI
import CryptoKit
import Foundation
import DeviceCheck
import Network
import Security

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

    /// The node's state, signed together with the challenge (v2): genuine is
    /// proven whatever the state; the fingerprint only when the node can vouch.
    struct NodeState {
        let state: String      // "up-to-date", "syncing" or "not-running"
        let tip: Int?          // the node's own height, when it runs
        let estimate: Int      // the clock's estimate of the network's height
        var dictionary: [String: Any] {
            var d: [String: Any] = ["state": state, "estimate": estimate]
            if let tip { d["tip"] = tip }
            return d
        }
    }

    static func jsonV2(fingerprintSHA256: String, challenge: String, node: NodeState) throws -> Data {
        try StateFingerprint.canonicalJSON(["v": 2, "purpose": purpose, "fingerprintSHA256": fingerprintSHA256,
                                            "challenge": challenge, "node": node.dictionary])
    }

    /// v3 (build 10, issue #3): everything a checker relies on is signed.
    /// Where the answer came from (app, Lock it's version, the node's
    /// version, the own-node check), when, and the onion address it answers
    /// on (a relay elsewhere is refused: issue #8, point 1).
    struct Provenance {
        let createdAt: String
        let appId: String
        let lockItVersion: String
        let lockItBuild: String
        let onion: String          // this node's onion address, or "" without Tor
        let nodeBuild: String
        let nodeSubversion: String
        let ownNode: Bool
    }

    static func jsonV3(fingerprintSHA256: String, challenge: String, node: NodeState, from p: Provenance) throws -> Data {
        var nodeFields = node.dictionary
        nodeFields["build"] = p.nodeBuild
        nodeFields["subversion"] = p.nodeSubversion
        return try StateFingerprint.canonicalJSON([
            "v": 3, "purpose": purpose, "challenge": challenge, "fingerprintSHA256": fingerprintSHA256,
            "createdAt": p.createdAt, "appId": p.appId, "onion": p.onion,
            "lockIt": ["version": p.lockItVersion, "build": p.lockItBuild],
            "node": nodeFields,
            "nodeCheck": ["ownNode": p.ownNode, "executableSignedBySameTeamAsLockIt": p.ownNode],
        ])
    }

    /// A challenge is 32 random bytes as 64 lowercase hex characters, or
    /// empty for a statement nobody asked for.
    static func validChallenge(_ text: String) -> Bool {
        text.isEmpty || (text.count == 64 && text.allSatisfy { "0123456789abcdef".contains($0) })
    }
}

/// A request line for the challenge endpoint:
/// `GET /statement?challenge=<64 hex>[&height=<H>]`. Parsed strictly: only
/// these two names, each once, nothing else.
struct StatementRequest: Equatable {
    let challenge: String
    let height: Int?

    struct Problem: Error, Equatable { let message: String }

    static func parse(_ line: String) -> Result<StatementRequest, Problem> {
        let parts = line.split(separator: " ")
        guard parts.count >= 2, parts[0] == "GET", parts[1].hasPrefix("/statement?") else {
            return .failure(Problem(message: "Use GET /statement?challenge=<64 hex characters>[&height=<block height>]"))
        }
        var challenge: String?
        var height: Int?
        for pair in parts[1].dropFirst("/statement?".count).split(separator: "&") {
            let kv = pair.split(separator: "=", maxSplits: 1).map(String.init)
            guard kv.count == 2 else { return .failure(Problem(message: "Every parameter needs a value.")) }
            switch kv[0] {
            case "challenge" where challenge == nil:
                guard kv[1].count == 64, StatementClientData.validChallenge(kv[1]) else {
                    return .failure(Problem(message: "The challenge must be 64 lowercase hex characters (32 random bytes)."))
                }
                challenge = kv[1]
            case "height" where height == nil:
                guard kv[1].count <= 9, kv[1].allSatisfy({ $0.isASCII && $0.isNumber }), let value = Int(kv[1]), value > 0 else {
                    return .failure(Problem(message: "The height must be a positive whole number."))
                }
                height = value
            default:
                return .failure(Problem(message: "Unknown or repeated parameter \(kv[0])."))
            }
        }
        guard let challenge else { return .failure(Problem(message: "A challenge is needed.")) }
        return .success(StatementRequest(challenge: challenge, height: height))
    }
}

/// Checks a statement the way tools/verify-statement does, inside Lock it:
/// Apple's certificate chain up to the pinned App Attestation root, the app,
/// the key, the signature over exactly this client data, and the challenge.
/// Used where Lock it must decide by itself whether a node is genuine
/// (finding other nodes, later pairing); never to vouch for this Mac itself.
struct StatementCheck {
    struct Result {
        let genuine: Bool
        let reason: String            // why not, or "genuine"
        let build: String?            // as Apple attests it
        let cdhash: String?           // as Apple attests it, when the app opted in
        let nodeState: [String: Any]?
        let height: Int?
        let hasFingerprint: Bool
        var attestedAt: Date? = nil   // start of Apple's key certificate (+60 s); Apple dates it about a day before the attestation
        var keyId: String? = nil
        var counter: Int? = nil       // how many answers the key has signed
    }

    /// macOS: the access policy of the key in the security chip, in the leaf's
    /// extension 1.2.840.113635.100.8.6. Apple: trust a Mac's key only with
    /// exactly this value (System Integrity Protection and full security on).
    static let macSecurePolicy = Data(base64Encoded: "MEAMAjExMDowCQwCb2uhAwEB/zAJDAJvYaEDAQH/MAsMBG9kZWyhAwEB/zAVDARvc2duoAYMBHJzZWMwBaYDAgEB")!

    /// Apple App Attestation Root CA (valid 2020-03-18 to 2045-03-15),
    /// SHA-256 1cb9823ba28ba6ad2d33a006941de2ae4f513ef1d4e831b9f7e0fa7b6242c932.
    static let appleRootBase64 = "MIICITCCAaegAwIBAgIQC/O+DvHN0uD7jG5yH2IXmDAKBggqhkjOPQQDAzBSMSYwJAYDVQQDDB1BcHBsZSBBcHAgQXR0ZXN0YXRpb24gUm9vdCBDQTETMBEGA1UECgwKQXBwbGUgSW5jLjETMBEGA1UECAwKQ2FsaWZvcm5pYTAeFw0yMDAzMTgxODMyNTNaFw00NTAzMTUwMDAwMDBaMFIxJjAkBgNVBAMMHUFwcGxlIEFwcCBBdHRlc3RhdGlvbiBSb290IENBMRMwEQYDVQQKDApBcHBsZSBJbmMuMRMwEQYDVQQIDApDYWxpZm9ybmlhMHYwEAYHKoZIzj0CAQYFK4EEACIDYgAERTHhmLW07ATaFQIEVwTtT4dyctdhNbJhFs/Ii2FdCgAHGbpphY3+d8qjuDngIN3WVhQUBHAoMeQ/cLiP1sOUtgjqK9auYen1mMEvRq9Sk3Jm5X8U62H+xTD3FE9TgS41o0IwQDAPBgNVHRMBAf8EBTADAQH/MB0GA1UdDgQWBBSskRBTM72+aEH/pwyp5frq5eWKoTAOBgNVHQ8BAf8EBAMCAQYwCgYIKoZIzj0EAwMDaAAwZQIwQgFGnByvsiVbpTKwSga0kP0e8EeDS4+sQmTvb7vn53O5+FRXgeLhpJ06ysC5PrOyAjEAp5U4xDgEgllF7En3VcE3iexZZtKeYnpqtijVoyFraWVIyd/dganmrduC1bmTBGwD"
    static let appleRootSHA256 = "1cb9823ba28ba6ad2d33a006941de2ae4f513ef1d4e831b9f7e0fa7b6242c932"

    /// The app every genuine node must be: this app's own identifier.
    /// `onion`: the address the answer was asked at. The signed answer must
    /// name exactly that address (a relay elsewhere is refused). Nil only
    /// for a statement read from a file.
    static func check(_ data: Data, expectedAppID: String, challenge: String, onion: String? = nil) -> Result {
        func no(_ why: String) -> Result {
            Result(genuine: false, reason: why, build: nil, cdhash: nil, nodeState: nil, height: nil, hasFingerprint: false)
        }
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return no("not a statement") }
        let format = json["format"] as? String
        // v1 and v2 left where the answer came from unsigned (issue #3).
        guard format == "zecky-attested-statement/v3" else {
            return no(format?.hasPrefix("zecky-attested-statement/") == true ? "older answer format, not fully checked" : "unknown format")
        }
        // Everything below is read from the signed client data only.
        guard let clientText = json["clientDataJSON"] as? String,
              let client = try? JSONSerialization.jsonObject(with: Data(clientText.utf8)) as? [String: Any],
              client["v"] as? Int == 3, client["purpose"] as? String == StatementClientData.purpose,
              client["challenge"] as? String == challenge, json["challenge"] as? String == challenge
        else { return no("not an answer to this challenge") }
        guard client["appId"] as? String == expectedAppID else { return no("another app") }
        if let onion {
            guard client["onion"] as? String == onion.lowercased() else {
                return no("the answer names another onion address than the one asked (a relay?)")
            }
        }
        let fingerprintHash = client["fingerprintSHA256"] as? String ?? ""
        if let text = json["fingerprintJSON"] as? String {
            guard StateFingerprint.sha256Hex(Data(text.utf8)) == fingerprintHash else { return no("fingerprint altered") }
        } else {
            guard fingerprintHash.isEmpty else { return no("signed fingerprint missing") }
        }
        guard let made = (client["createdAt"] as? String).flatMap({ ISO8601DateFormatter().date(from: $0) }) else {
            return no("no signed time")
        }
        let clientHash = Data(SHA256.hash(data: Data(clientText.utf8)))

        guard let keyIdText = json["keyId"] as? String, let keyId = Data(base64Encoded: keyIdText),
              let attText = (json["keyAttestation"] ?? json["attestation"]) as? String,
              let attData = Data(base64Encoded: attText),
              let att = try? ZCBORReader.decode(attData),
              att.value(forText: "fmt")?.textValue == "apple-appattest",
              let x5c = att.value(forText: "attStmt")?.value(forText: "x5c")?.arrayValue, x5c.count == 2,
              let leafData = x5c[0].bytesValue, let interData = x5c[1].bytesValue,
              let attAuth = att.value(forText: "authData")?.bytesValue, attAuth.count >= 55 else { return no("no key attestation") }

        // Apple's chain, at the time the statement says it was made.
        guard let rootData = Data(base64Encoded: appleRootBase64),
              StateFingerprint.sha256Hex(rootData) == appleRootSHA256,
              let root = SecCertificateCreateWithData(nil, rootData as CFData),
              let leaf = SecCertificateCreateWithData(nil, leafData as CFData),
              let inter = SecCertificateCreateWithData(nil, interData as CFData) else { return no("unreadable certificates") }
        var trust: SecTrust?
        guard SecTrustCreateWithCertificates([leaf, inter] as CFArray, SecPolicyCreateBasicX509(), &trust) == errSecSuccess,
              let trust else { return no("certificate chain") }
        SecTrustSetAnchorCertificates(trust, [root] as CFArray)
        SecTrustSetAnchorCertificatesOnly(trust, true)
        SecTrustSetNetworkFetchAllowed(trust, false)
        // Checked the way Apple intends: once, at the moment Apple attested
        // the key (the leaf is valid for three days; the key lives on in the
        // security chip and signs every later answer). Apple's intermediate
        // must still be valid today (to 2030).
        // Reading a certificate's dates needs macOS 15; checking another node
        // needs macOS 27 anyway (Genuine node), so older macOS never gets here.
        guard #available(macOS 15.0, *) else { return no("this Mac's macOS is too old to check Apple's certificates") }
        guard let issued = SecCertificateCopyNotValidBeforeDate(leaf) as Date?,
              let interEnds = SecCertificateCopyNotValidAfterDate(inter) as Date? else { return no("unreadable certificates") }
        let attestedAt = issued.addingTimeInterval(60)
        SecTrustSetVerifyDate(trust, attestedAt as CFDate)
        guard SecTrustEvaluateWithError(trust, nil) else { return no("not signed by Apple's App Attest") }
        guard interEnds > Date() else { return no("Apple's intermediate certificate has ended") }
        guard attestedAt <= made.addingTimeInterval(300) else { return no("key attested after the answer") }
        guard leafPolicy(SecCertificateCopyData(leaf) as Data) == macSecurePolicy else {
            return no("the Mac did not have System Integrity Protection and full security on")
        }

        // The attested key and the app it belongs to.
        guard let key = SecCertificateCopyKey(leaf),
              let point = SecKeyCopyExternalRepresentation(key, nil) as Data?,
              Data(SHA256.hash(data: point)) == keyId,
              let publicKey = try? P256.Signing.PublicKey(x963Representation: point) else { return no("key does not match") }
        let appHash = Data(SHA256.hash(data: Data(expectedAppID.utf8)))
        guard attAuth.prefix(32) == appHash else { return no("key belongs to another app") }
        let aaguid = attAuth[attAuth.startIndex + 37 ..< attAuth.startIndex + 53]
        guard aaguid == Data("appattest".utf8) + Data(repeating: 0, count: 7) || aaguid == Data("appattestdevelop".utf8) else {
            return no("unknown App Attest environment")
        }

        var facts: [String: ZCBOR] = [:]
        var counter = 0
        if json["kind"] as? String == "attestation" {
            facts = appleFacts(attAuth, attested: true)
            // Apple's nonce in the leaf covers exactly this client data.
            let nonce = Data(SHA256.hash(data: attAuth + clientHash))
            guard let inLeaf = leafNonce(SecCertificateCopyData(leaf) as Data), inLeaf == nonce else {
                return no("Apple's nonce does not cover this answer")
            }
        } else {
            // The key attestation's own data (environment, credential) is only
            // trusted once its nonce, over the client data it was made for, is
            // in Apple's certificate (issue #4). Older answers do not carry
            // that client data and are refused.
            guard let keyClientText = json["keyAttestationClientDataJSON"] as? String else {
                return no("older answer format: key attestation not bound")
            }
            let keyNonce = Data(SHA256.hash(data: attAuth + Data(SHA256.hash(data: Data(keyClientText.utf8)))))
            guard let inLeaf = leafNonce(SecCertificateCopyData(leaf) as Data), inLeaf == keyNonce else {
                return no("the key attestation does not match Apple's certificate")
            }
            guard let assertText = json["assertion"] as? String, let assertData = Data(base64Encoded: assertText),
                  let assertion = try? ZCBORReader.decode(assertData),
                  let signatureData = assertion.value(forText: "signature")?.bytesValue,
                  let auth = assertion.value(forText: "authenticatorData")?.bytesValue, auth.count >= 37,
                  auth.prefix(32) == appHash else { return no("no valid assertion") }
            let nonce = Data(SHA256.hash(data: auth + clientHash))
            guard let signature = try? P256.Signing.ECDSASignature(derRepresentation: signatureData),
                  publicKey.isValidSignature(signature, for: nonce) else { return no("the key did not sign this answer") }
            let count = auth[auth.startIndex + 33 ..< auth.startIndex + 37].reduce(0) { $0 << 8 | Int($1) }
            guard count > 0 else { return no("assertion counter") }
            counter = count
            // Apple's facts from this answer's signed data only: a key
            // attested by one build can be used by another (issue #2).
            facts = appleFacts(auth, attested: false)
        }
        // The credential in the (now bound) attestation is this key.
        let credentialLength = Int(attAuth[attAuth.startIndex + 53]) << 8 | Int(attAuth[attAuth.startIndex + 54])
        guard attAuth.count >= 55 + credentialLength,
              attAuth[attAuth.startIndex + 55 ..< attAuth.startIndex + 55 + credentialLength] == keyId else {
            return no("the attestation is for another key")
        }
        return Result(genuine: true, reason: "genuine",
                      build: facts["apple_bundle_version_01"]?.textValue,
                      cdhash: facts["apple_cd_hash_hash_01"]?.bytesValue.map { $0.map { String(format: "%02x", $0) }.joined() },
                      nodeState: client["node"] as? [String: Any],
                      height: (json["fingerprintJSON"] as? String).flatMap {
                          (try? JSONSerialization.jsonObject(with: Data($0.utf8)) as? [String: Any])?["height"] as? Int },
                      hasFingerprint: json["fingerprintJSON"] != nil,
                      attestedAt: attestedAt, keyId: keyIdText, counter: counter)
    }

    /// The policy in the leaf's extension 1.2.840.113635.100.8.6:
    /// SEQUENCE { [3] { OCTET STRING (66 bytes) } }.
    static func leafPolicy(_ der: Data) -> Data? {
        let oid: [UInt8] = [0x06, 0x09, 0x2A, 0x86, 0x48, 0x86, 0xF7, 0x63, 0x64, 0x08, 0x06]
        let prefix: [UInt8] = [0x30, 0x46, 0xA3, 0x44, 0x04, 0x42]
        let b = [UInt8](der)
        guard let at = b.indices.first(where: { b[$0...].starts(with: oid) }) else { return nil }
        let window = b[(at + oid.count)..<min(b.count, at + oid.count + 16)]
        guard let start = window.indices.first(where: { b[$0...].starts(with: prefix) }),
              start + prefix.count + 66 <= b.count else { return nil }
        return Data(b[(start + prefix.count)..<(start + prefix.count + 66)])
    }

    /// The extensions App Attest's service wrote into the signed
    /// authenticator data: build number, validation category, CDHash.
    static func appleFacts(_ auth: Data, attested: Bool) -> [String: ZCBOR] {
        let bytes = [UInt8](auth)
        guard bytes.count > 37, bytes[32] & 0x80 != 0 else { return [:] }
        var offset = 37
        if attested {
            guard bytes.count >= 55 else { return [:] }
            offset = 55 + (Int(bytes[53]) << 8 | Int(bytes[54]))
            guard offset <= bytes.count,
                  let cose = try? ZCBORReader.decodePrefix(Data(bytes[offset...])) else { return [:] }
            offset += cose.length
        }
        guard offset < bytes.count, let ext = try? ZCBORReader.decodePrefix(Data(bytes[offset...])),
              case let .map(entries) = ext.item else { return [:] }
        var out: [String: ZCBOR] = [:]
        for entry in entries { if let key = entry.key.textValue { out[key] = entry.value } }
        return out
    }

    /// The 32-byte nonce in the leaf's extension 1.2.840.113635.100.8.2.
    static func leafNonce(_ der: Data) -> Data? {
        let oid: [UInt8] = [0x06, 0x09, 0x2A, 0x86, 0x48, 0x86, 0xF7, 0x63, 0x64, 0x08, 0x02]
        let prefix: [UInt8] = [0x30, 0x24, 0xA1, 0x22, 0x04, 0x20]
        let b = [UInt8](der)
        guard let at = b.indices.first(where: { b[$0...].starts(with: oid) }) else { return nil }
        let window = b[(at + oid.count)..<min(b.count, at + oid.count + 16)]
        guard let start = window.indices.first(where: { b[$0...].starts(with: prefix) }),
              start + prefix.count + 32 <= b.count else { return nil }
        return Data(b[(start + prefix.count)..<(start + prefix.count + 32)])
    }
}

/// At most `perMinute` statements in any 60 seconds, so nobody can keep a
/// Mac busy through its onion address. Over Tor every request arrives from
/// 127.0.0.1, so the limit is for all askers together, not per asker.
struct RequestLimit {
    var perMinute = 6
    private(set) var recent: [Date] = []

    /// Counts the request when it is allowed; otherwise says how many seconds
    /// until the oldest one leaves the window.
    mutating func allow(at now: Date) -> (allowed: Bool, retryAfter: Int) {
        recent.removeAll { now.timeIntervalSince($0) >= 60 }
        guard recent.count < perMinute else {
            let wait = 60 - now.timeIntervalSince(recent[0])
            return (false, max(1, Int(wait.rounded(.up))))
        }
        recent.append(now)
        return (true, 0)
    }
}

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

    /// The program file is intact, signed through Apple's chain, and carries
    /// this team's identifier. Not a check on the certificate's OU: TestFlight
    /// and App Store builds are signed again by Apple, whose certificate
    /// names no team; the team identifier in the signature stays.
    static func fileSignedBy(team: String, url: URL) -> Bool {
        var code: SecStaticCode?
        guard SecStaticCodeCreateWithPath(url as CFURL, [], &code) == errSecSuccess, let code else { return false }
        var requirement: SecRequirement?
        guard SecRequirementCreateWithString("anchor apple generic" as CFString, [], &requirement) == errSecSuccess,
              SecStaticCodeCheckValidity(code, SecCSFlags(rawValue: kSecCSCheckAllArchitectures), requirement) == errSecSuccess
        else { return false }
        var info: CFDictionary?
        guard SecCodeCopySigningInformation(code, SecCSFlags(rawValue: kSecCSSigningInformation), &info) == errSecSuccess,
              let dict = info as? [String: Any] else { return false }
        return dict[kSecCodeInfoTeamIdentifier as String] as? String == team
    }
}

/// Genuine node: the switch, the App Attest part and the local endpoint.
/// In every build, off until the owner switches it on.
@MainActor
final class AttestedStatementMaker: ObservableObject {
    static let shared = AttestedStatementMaker()
    static let switchKey = "developer.attestedStatements"
    static var enabled: Bool {
        get { UserDefaults.standard.bool(forKey: switchKey) }
        set { UserDefaults.standard.set(newValue, forKey: switchKey) }
    }
    /// One key per App Attest environment: a key made by a development build
    /// (Xcode) cannot sign in a production build (TestFlight, App Store) and
    /// the other way round, and both share this app's settings.
    private static var environment: String {
        guard let task = SecTaskCreateFromSelf(nil) else { return "unknown" }
        return SecTaskCopyValueForEntitlement(task, "com.apple.developer.devicecheck.appattest-environment" as CFString, nil) as? String ?? "unknown"
    }
    private static var keyIdKey: String { "attest.\(environment).keyId" }
    private static var attestationKey: String { "attest.\(environment).attestation" }
    /// The client data the key's attestation was made over. Sent with every
    /// later answer, so a checker can recompute the attestation's nonce and
    /// bind its data to Apple's certificate (issue #4).
    private static var attestationClientDataKey: String { "attest.\(environment).attestationClientData" }

    /// "New address": also a new App Attest key, so answers from the new
    /// address cannot be linked to the old one by their key.
    static func forgetKeyForNewAddress() { forgetKey() }

    private static func forgetKey() {
        UserDefaults.standard.removeObject(forKey: keyIdKey)
        UserDefaults.standard.removeObject(forKey: attestationKey)
        UserDefaults.standard.removeObject(forKey: attestationClientDataKey)
    }
    /// The local endpoint: GET /statement?challenge=<64 hex> on this Mac only.
    static let port: UInt16 = 8139

    @Published var status = "" { didSet { if !status.isEmpty, status != "Working…" { AttestLog.write(status) } } }
    @Published var working = false
    @Published var serving = false
    private var listener: NWListener?
    private var limit = RequestLimit()
    private var openConnections = 0
    private var refusedBad = 0
    private var refusedOverLimit = 0
    private var refusalsLogged = Date.distantPast
    static let maxConnections = 8

    struct Failure: Error {
        let message: String
        /// For a height the node cannot answer for: "behind", "unsettled" or
        /// "not-kept", with the node's tip, so the asker can try another node
        /// or later instead of reading it as disagreement.
        var reason: String? = nil
        var tip: Int? = nil
    }

    /// Blocks below the tip before a height counts as settled.
    static let settledDepth = 100

    var supported: Bool {
        if #available(macOS 27, *) { return DCAppAttestService.shared.isSupported }
        return false
    }

    /// One statement: the node is checked, the fingerprint read 100 blocks
    /// below the tip, and App Attest signs it with the challenge. The first
    /// statement of a key attests it (one contact with Apple); later ones are
    /// assertions made on this Mac. Reads only from the node.
    /// A statement for `height`, or for the tip minus 100 when none is asked.
    func statement(challenge: String, height asked: Int? = nil) async throws -> Data {
        guard #available(macOS 27, *), DCAppAttestService.shared.isSupported else {
            throw Failure(message: "App Attest is not supported on this Mac (macOS 27 or later, a normal Mac app).")
        }
        guard StatementClientData.validChallenge(challenge) else {
            throw Failure(message: "The challenge must be 64 lowercase hex characters (32 random bytes).")
        }
        // v2: the proof that this is genuine Lock it does not depend on the
        // node. The node's state is signed with it, and the chain fingerprint
        // is added only for a height this node has checked and settled.
        let (own, _) = OwnNodeCheck.run()
        let port = GoMaxConfig.rpcPort
        var info: [String: Any]?
        if own != nil { info = await LocalRPC.call("getblockchaininfo", port: port) as? [String: Any] }
        let tip = info?["blocks"] as? Int
        let estimate = Birthday.estimatedTip()
        let caughtUp = (info?["verificationprogress"] as? Double ?? 0) >= 0.999
        let state: String
        if let tip { state = caughtUp ? "up-to-date" : "syncing" } else { state = "not-running" }

        var fingerprint: [String: Any]?
        var fingerprintNote: String?
        let height: Int? = asked ?? (state == "up-to-date" ? tip.map { $0 - Self.settledDepth } : nil)
        if let tip, let height {
            if height > tip {
                fingerprintNote = "behind"
            } else if height > tip - Self.settledDepth {
                fingerprintNote = "unsettled"
            } else if let block = await LocalRPC.call("getblock", params: [String(height), 1], port: port) as? [String: Any],
                      let tree = await LocalRPC.call("z_gettreestate", params: [String(height)], port: port) as? [String: Any],
                      let made = StateFingerprint.make(block: block, treeState: tree) {
                fingerprint = made
            } else {
                // Go Max keeps about four weeks of blocks; older ones are gone.
                fingerprintNote = "not-kept"
            }
        } else if asked != nil {
            fingerprintNote = state == "not-running" ? "not-running" : "behind"
        } else {
            fingerprintNote = state == "not-running" ? "not-running" : "syncing"
        }

        var json: Data?
        if let fingerprint { json = try StateFingerprint.canonicalJSON(fingerprint) }
        let fingerprintHash = json.map { StateFingerprint.sha256Hex($0) } ?? ""
        let nodeState = StatementClientData.NodeState(state: state, tip: tip, estimate: estimate)
        var node: [String: Any]?
        if own != nil { node = await LocalRPC.call("getinfo", port: port) as? [String: Any] }
        // v3: where the answer came from is signed with it (issue #3), and
        // the answer names the onion address it is served on.
        let provenance = StatementClientData.Provenance(
            createdAt: ISO8601DateFormatter().string(from: Date()),
            appId: Self.applicationIdentifier() ?? "unknown",
            lockItVersion: Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "",
            lockItBuild: Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "",
            onion: AttestOnion.shared.address?.lowercased() ?? "",
            nodeBuild: node?["build"] as? String ?? "unknown",
            nodeSubversion: node?["subversion"] as? String ?? "unknown",
            ownNode: own != nil)
        let clientData = try StatementClientData.jsonV3(fingerprintSHA256: fingerprintHash, challenge: challenge,
                                                        node: nodeState, from: provenance)
        let digest = Data(SHA256.hash(data: clientData))
        let service = DCAppAttestService.shared
        // Only what the signature covers, plus the evidence: no unsigned
        // copies of signed fields for anyone to read by mistake.
        var statement: [String: Any] = [
            "format": "zecky-attested-statement/v3",
            "fingerprintSHA256": fingerprintHash,
            "clientDataJSON": String(decoding: clientData, as: UTF8.self),
            "challenge": challenge,
        ]
        if fingerprint != nil, let json {
            // The text the signed hash covers (it names its height).
            statement["fingerprintJSON"] = String(decoding: json, as: UTF8.self)
        } else {
            // Why there is none: a note for people, not used by checkers.
            statement["fingerprintNote"] = fingerprintNote ?? "none"
        }
        // A stored key that no longer signs (made by another build, or lost
        // from the security chip) is forgotten, and a new one made once.
        var lastError: Error?
        // A key attested before its client data was kept (builds 8 and 9)
        // cannot be bound in later answers: replaced once.
        if UserDefaults.standard.data(forKey: Self.attestationKey) != nil,
           UserDefaults.standard.string(forKey: Self.attestationClientDataKey) == nil {
            AttestLog.write("This key's attestation cannot be bound in later answers; making a new key (one contact with Apple).")
            Self.forgetKey()
        }
        for attempt in 0..<2 {
            do {
                var keyId = UserDefaults.standard.string(forKey: Self.keyIdKey)
                if keyId == nil {
                    keyId = try await service.generateKey()
                    UserDefaults.standard.set(keyId, forKey: Self.keyIdKey)
                }
                guard let keyId else { throw Failure(message: "No App Attest key.") }
                if let saved = UserDefaults.standard.data(forKey: Self.attestationKey),
                   let savedClient = UserDefaults.standard.string(forKey: Self.attestationClientDataKey) {
                    let assertion = try await service.generateAssertion(keyId, clientDataHash: digest)
                    statement["kind"] = "assertion"
                    statement["assertion"] = assertion.base64EncodedString()
                    statement["keyAttestation"] = saved.base64EncodedString()
                    statement["keyAttestationClientDataJSON"] = savedClient
                } else {
                    let attestation = try await service.attestKey(keyId, clientDataHash: digest)
                    UserDefaults.standard.set(attestation, forKey: Self.attestationKey)
                    UserDefaults.standard.set(String(decoding: clientData, as: UTF8.self), forKey: Self.attestationClientDataKey)
                    statement["kind"] = "attestation"
                    statement["attestation"] = attestation.base64EncodedString()
                }
                statement["keyId"] = keyId
                lastError = nil
                break
            } catch let error as DCError where attempt == 0 && error.code != .serverUnavailable {
                AttestLog.write("App Attest key did not work (\(error.code.rawValue)); making a new key.")
                Self.forgetKey()
                lastError = error
            }
        }
        if let lastError { throw lastError }
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
        // Switched on before the explanation existed (debug builds): off
        // again until it has been read once.
        if Self.enabled && !AttestSupport.agreed { Self.enabled = false; AttestOnion.wanted = false }
        guard Self.enabled, AttestSupport.unavailableReason == nil else { return }
        startServing()
        if AttestOnion.wanted { AttestOnion.shared.start(); GenuineNodes.shared.start() }
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
        flushRefusals(force: true)
        listener?.cancel()
        listener = nil
        serving = false
    }

    /// One request's connection: closed once, by whichever comes first (the
    /// answer sent, or 10 s without a request).
    private final class Exchange {
        let connection: NWConnection
        var answering = false
        var closed = false
        init(_ connection: NWConnection) { self.connection = connection }
    }

    private func close(_ exchange: Exchange) {
        guard !exchange.closed else { return }
        exchange.closed = true
        exchange.connection.cancel()
        openConnections -= 1
    }

    private func serve(_ connection: NWConnection) {
        // A few connections at a time, and none kept open longer than needed:
        // a client that connects and sends nothing is dropped after 10 s.
        guard openConnections < Self.maxConnections else { connection.cancel(); return }
        openConnections += 1
        let exchange = Exchange(connection)
        connection.start(queue: .main)
        Task { @MainActor in
            try? await Task.sleep(nanoseconds: 10_000_000_000)
            if !exchange.answering { AttestedStatementMaker.shared.close(exchange) }
        }
        connection.receive(minimumIncompleteLength: 1, maximumLength: 4096) { data, _, _, _ in
            let request = String(decoding: data ?? Data(), as: UTF8.self)
            Task { @MainActor in
                let maker = AttestedStatementMaker.shared
                guard !exchange.closed else { return }
                exchange.answering = true
                let (code, body) = await maker.answer(request)
                let reason = [200: "OK", 400: "Bad Request", 404: "Not Found", 409: "Conflict", 410: "Gone", 429: "Too Many Requests"][code] ?? "Service Unavailable"
                let head = "HTTP/1.1 \(code) \(reason)\r\nContent-Type: application/json\r\nContent-Length: \(body.count)\r\nConnection: close\r\n\r\n"
                connection.send(content: Data(head.utf8) + body, completion: .contentProcessed { _ in
                    Task { @MainActor in maker.close(exchange) }
                })
            }
        }
    }

    static let usage = "Use GET /statement?challenge=<64 hex characters>[&height=<block height>]"

    /// GET /statement?challenge=<64 hex>[&height=<H>]. One at a time.
    func answer(_ request: String) async -> (Int, Data) {
        func body(_ fields: [String: Any]) -> Data {
            (try? JSONSerialization.data(withJSONObject: fields, options: [.sortedKeys])) ?? Data()
        }
        // Every request counts towards the limit, well-formed or not, so junk
        // cannot be sent faster than real questions.
        let now = Date()
        let verdict = limit.allow(at: now)
        guard verdict.allowed else {
            noteRefusal(overLimit: true, at: now)
            return (429, body(["error": "Too many requests; at most \(limit.perMinute) a minute.",
                               "reason": "limit", "retryAfter": verdict.retryAfter]))
        }
        guard let line = request.split(separator: "\r\n").first.map(String.init) else {
            noteRefusal(overLimit: false, at: now)
            return (400, body(["error": Self.usage]))
        }
        if line.hasPrefix("GET /peers ") || line == "GET /peers" {
            return GenuineNodes.shared.peersAnswer()
        }
        let parsed: StatementRequest
        switch StatementRequest.parse(line) {
        case .success(let request): parsed = request
        case .failure(let problem):
            // The answer may repeat the asker's words; the log never does.
            noteRefusal(overLimit: false, at: now)
            return (400, body(["error": problem.message]))
        }
        let challenge = parsed.challenge
        guard !working else {
            AttestLog.write("Busy: refused a request while answering another.")
            return (503, body(["error": "Busy with another statement; try again in a moment."]))
        }
        working = true
        defer { working = false }
        do {
            let data = try await statement(challenge: challenge, height: parsed.height)
            let summary = Self.summary(of: data)
            status = "Answered a challenge (\(challenge.prefix(8))…)\(summary)."
            return (200, data)
        } catch let failure as Failure {
            status = failure.message
            return (503, body(["error": failure.message]))
        } catch {
            status = "App Attest said: \(error.localizedDescription)"
            return (503, body(["error": "App Attest: \(error.localizedDescription)"]))
        }
    }

    /// Refused requests are counted and written as one line a minute at
    /// most, with the counts only, so a flood cannot fill the log or put the
    /// asker's text in it.
    private func noteRefusal(overLimit isOverLimit: Bool, at now: Date) {
        if isOverLimit { refusedOverLimit += 1 } else { refusedBad += 1 }
        flushRefusals(at: now)
    }

    func flushRefusals(at now: Date = Date(), force: Bool = false) {
        guard refusedOverLimit + refusedBad > 0, force || now.timeIntervalSince(refusalsLogged) >= 60 else { return }
        var parts: [String] = []
        if refusedBad > 0 { parts.append("\(refusedBad) malformed") }
        if refusedOverLimit > 0 { parts.append("\(refusedOverLimit) over the limit of \(limit.perMinute) a minute") }
        AttestLog.write("Refused \(parts.joined(separator: ", ")).")
        refusedBad = 0
        refusedOverLimit = 0
        refusalsLogged = now
    }

    /// " · up to date, fingerprint at 3,576,912" and the like, for the log.
    nonisolated static func summary(of statement: Data) -> String {
        guard let json = try? JSONSerialization.jsonObject(with: statement) as? [String: Any] else { return "" }
        let client = (json["clientDataJSON"] as? String).flatMap {
            try? JSONSerialization.jsonObject(with: Data($0.utf8)) as? [String: Any]
        }
        guard let node = (client?["node"] ?? json["nodeState"]) as? [String: Any],
              let state = node["state"] as? String else { return "" }
        var text = " · " + (state == "syncing" ? "syncing at block \((node["tip"] as? Int).map(String.init) ?? "?")"
                                              : state == "up-to-date" ? "up to date" : "node not running")
        let fingerprintHeight = (json["fingerprintJSON"] as? String).flatMap {
            (try? JSONSerialization.jsonObject(with: Data($0.utf8)) as? [String: Any])?["height"] as? Int }
        if let height = fingerprintHeight { text += ", fingerprint at \(height)" }
        else if let note = json["fingerprintNote"] as? String { text += ", no fingerprint (\(note))" }
        return text
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

    /// A new onion address for good: the old key is deleted from Arti's
    /// folders, so the old address never works again, for anyone. The App
    /// Attest key is replaced too (one more contact with Apple at the next
    /// answer), so the new address is not linkable to the old one.
    func newAddress() async {
        let wasRunning = process != nil
        stop()
        try? await Task.sleep(nanoseconds: 1_500_000_000)   // let Arti exit
        if let root {
            let fm = FileManager.default
            let state = root.appendingPathComponent("state")
            if let walker = fm.enumerator(at: state, includingPropertiesForKeys: [.isDirectoryKey]) {
                var doomed: [URL] = []
                for case let url as URL in walker where url.lastPathComponent == Self.nickname {
                    doomed.append(url)
                    walker.skipDescendants()
                }
                for url in doomed { try? fm.removeItem(at: url) }
                AttestLog.write("New onion address: removed \(doomed.count) folder(s) of the old onion key.")
            }
        }
        AttestedStatementMaker.forgetKeyForNewAddress()
        if wasRunning { start() }
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

    func ask(_ input: String, height heightText: String = "") async {
        let onion = input.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            .replacingOccurrences(of: "http://", with: "").trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        guard onion.hasSuffix(".onion"), onion.count == 62 else { status = "That is not a v3 onion address (56 characters, then .onion)."; return }
        guard AttestOnion.shared.address != nil else { status = "Switch on \"Answer over Tor too\" first: asking goes through the same Tor."; return }
        let trimmed = heightText.trimmingCharacters(in: .whitespaces)
        let height = trimmed.isEmpty ? nil : Int(trimmed)
        if !trimmed.isEmpty, height == nil || height! <= 0 { status = "The height must be a whole number, or empty for the node's own choice."; return }
        var bytes = [UInt8](repeating: 0, count: 32)
        guard SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes) == errSecSuccess else { status = "No random bytes."; return }
        let challenge = bytes.map { String(format: "%02x", $0) }.joined()
        working = true
        status = "Asking \(onion.prefix(12))… over Tor"
        AttestLog.write("Asking \(onion) with challenge \(challenge)")
        defer { working = false }
        do {
            let path = "/statement?challenge=\(challenge)" + (height.map { "&height=\($0)" } ?? "")
            let body: Data
            do {
                body = try await Self.get(host: onion, path: path)
            } catch is NWError {
                // A fresh Tor circuit to an onion sometimes drops on the
                // first try; one more try with the same challenge.
                status = "Asking again over a new circuit…"
                body = try await Self.get(host: onion, path: path)
            }
            guard let json = try? JSONSerialization.jsonObject(with: body) as? [String: Any] else {
                throw AskFailure("The answer is not JSON (\(body.count) bytes).")
            }
            if let error = json["error"] as? String {
                let tip = (json["tip"] as? Int).map { " (its tip: \($0))" } ?? ""
                throw AskFailure("The node said: \(error)\(tip)")
            }
            let format = json["format"] as? String
            guard format?.hasPrefix("zecky-attested-statement/") == true,
                  json["challenge"] as? String == challenge,
                  let client = json["clientDataJSON"] as? String,
                  client.contains("\"challenge\":\"\(challenge)\"") else {
                throw AskFailure("The answer is not a statement for this challenge.")
            }
            // A v2 node always answers; a fingerprint only for a height it can vouch for.
            // The height from the fingerprint text, which the signature covers.
            let signedHeight = (json["fingerprintJSON"] as? String).flatMap {
                (try? JSONSerialization.jsonObject(with: Data($0.utf8)) as? [String: Any])?["height"] as? Int }
            if let height, json["fingerprintJSON"] != nil, signedHeight != height {
                throw AskFailure("The answer is for another height than \(height).")
            }
            let summary = AttestedStatementMaker.summary(of: body)
            let name = "asked-\(onion.prefix(8))-\(Int(Date().timeIntervalSince1970)).json"
            if let folder = AttestLog.folder { try body.write(to: folder.appendingPathComponent(name)) }
            // Full check here, on this Mac: Apple's chain, the key, the
            // signature over this challenge, and the same app. The other
            // node's screen can say anything; this check is done by us.
            let check = StatementCheck.check(body, expectedAppID: AttestedStatementMaker.applicationIdentifier() ?? "",
                                             challenge: challenge, onion: onion)
            GenuineNodes.shared.noteManualCheck(onion, check)
            if check.genuine {
                let build = check.build.map { " build \($0)" } ?? ""
                // No date: Apple dates its key certificates about a day back
                // (seen 16 Nov 2026), so a date here would mislead.
                let since = ""
                status = "Genuine ✓ Zecky Lock it\(build)\(since)\(summary). Saved \(name) in the logs folder; verify_statement.py --challenge \(challenge)\(height.map { " --height \($0)" } ?? "") gives a second opinion."
            } else {
                status = "Not genuine: \(check.reason). Saved \(name) in the logs folder."
            }
        } catch let failure as AskFailure {
            status = failure.message
        } catch {
            status = "Could not reach it over Tor: \(error.localizedDescription)"
        }
    }

    struct AskFailure: Error { let message: String; init(_ m: String) { message = m } }

    /// A plain HTTP GET to host:80 through SOCKS5 (the onion name is resolved
    /// by Tor, never on this Mac). Reads until the node closes.
    static func get(host: String, path: String) async throws -> Data {
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

/// Whether this Mac can make attested statements, and the one-time "yes"
/// to the explanation shown before the first switch-on.
enum AttestSupport {
    static var agreed: Bool {
        get { UserDefaults.standard.bool(forKey: "experimental.attest.agreed") }
        set { UserDefaults.standard.set(newValue, forKey: "experimental.attest.agreed") }
    }

    /// nil when App Attest works here; otherwise why not, in two lines.
    static var unavailableReason: (title: String, detail: String)? {
        let v = ProcessInfo.processInfo.operatingSystemVersion
        guard v.majorVersion >= 27 else {
            let version = v.patchVersion > 0 ? "\(v.majorVersion).\(v.minorVersion).\(v.patchVersion)" : "\(v.majorVersion).\(v.minorVersion)"
            return ("Needs macOS 27, a free update for this Mac.",
                    "This Mac has macOS \(version). Every Mac that runs Lock it can update to macOS 27.")
        }
        if #available(macOS 27, *), DCAppAttestService.shared.isSupported { return nil }
        return ("App Attest is not available on this Mac.",
                "Attested statements need Apple's App Attest, which this Mac does not offer (for example with reduced security settings, or in a virtual machine).")
    }
}

/// Shown once, before the first switch-on: what is shared, with whom, and
/// that nothing uses it yet.
struct AttestConsentSheet: View {
    let onAgree: () -> Void
    let onCancel: () -> Void

    private let points = [
        "Only public chain data is shared. Nothing about your wallet.",
        "Once, Apple is contacted from this Mac's own internet address to set up a key. After that, answers go over Tor.",
        "Every statement carries the same key, so the statements this Mac makes can be linked to each other.",
        "You can switch it off at any time.",
    ]

    var body: some View {
        SheetScaffold(title: "Genuine node", subtitle: "Experimental. Off unless you switch it on.",
                      showsClose: false, width: 520, height: 470, onClose: onCancel) {
            VStack(alignment: .leading, spacing: 16) {
                Text("Wallets and other nodes that ask can check that this node is genuine Lock it on a real Mac: Apple's App Attest, the security chip in this Mac, signs its answers. Each answer also carries a fingerprint of the chain, which may later help new nodes start faster.")
                    .font(Theme.text(13)).foregroundStyle(Theme.text)
                    .fixedSize(horizontal: false, vertical: true)
                VStack(alignment: .leading, spacing: 10) {
                    ForEach(points, id: \.self) { point in
                        HStack(alignment: .firstTextBaseline, spacing: 10) {
                            Text("•").foregroundStyle(Theme.gold)
                            Text(point).font(Theme.text(12)).foregroundStyle(Theme.muted)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                    }
                }
                Spacer(minLength: 0)
                HStack(spacing: 12) {
                    SecondaryButton(title: "Not now", action: onCancel)
                    PrimaryButton(title: "Switch on", action: onAgree)
                }
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
    @ObservedObject private var known = GenuineNodes.shared
    @State private var share = GenuineNodes.sharing
    @State private var showKnown = false
    @State private var on = AttestedStatementMaker.enabled
    @State private var tor = AttestOnion.wanted
    @State private var otherNode = ""
    @State private var askHeight = ""
    @State private var copied = false
    @State private var showConsent = false
    @State private var showWhat = false
    @State private var confirmNewAddress = false

    static let explanation: [(title: String, text: String)] = [
        ("Why", "Go Max is open source, so anyone can build a changed copy that looks the same from outside: one that hides a payment, gives a wrong chain, or logs which wallets ask about what. A wallet connecting to a node cannot tell the difference. With this on, your node can show it is Lock it, signed by the Zecky team, on a real Mac with System Integrity Protection on: Apple's App Attest, the security chip in this Mac, signs its answers. It does not yet prove which exact code runs, or what chain data the node was given; that is being worked on in the open. Each question carries a fresh random code, so an old answer cannot be passed off as new, and anyone can check an answer with the free, open-source verifier in Lock it's code, without asking Zecky."),
        ("Where it leads", "First your iPhone checking it talks to your own genuine node, then a verified mark other wallets can adopt. While this is tested it is off unless you switch it on; once proven, Go Max will do it by itself."),
        ("What it proves, and what not", "That the answer comes from the Zecky team's app on a real Mac with its security on. Not yet which version or which source code: that needs builds anyone can reproduce, which is still to come."),
        ("The switches", "Answer checks: this Mac answers such questions. Also over Tor: wallets and nodes can reach it through a private onion address, without learning where this Mac is. Check another node: you ask a node yourself."),
        ("What it does not do", "Nothing about your wallet is shared, and your node and your Zcash are not changed. Genuine node answers on its onion address only, never on the node's peer-to-peer port or this Mac's home internet address, so nobody can link your home address to an attested node."),
    ]

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Label("Genuine node", systemImage: "checkmark.seal")
                .font(Theme.text(13, weight: .semibold)).foregroundStyle(Theme.text)
                .labelStyle(GoldIconLabelStyle())
            Text("Lets wallets and other nodes check that this node is genuine Lock it on a real Mac. Off unless you switch it on.")
                .font(Theme.text(12)).foregroundStyle(Theme.muted)
                .fixedSize(horizontal: false, vertical: true)
            Button(showWhat ? "Less" : "What is this?") { showWhat.toggle() }
                .buttonStyle(.plain).font(Theme.text(12, weight: .medium)).foregroundStyle(Theme.gold)
            if showWhat {
                VStack(alignment: .leading, spacing: 10) {
                    ForEach(Self.explanation, id: \.title) { part in
                        VStack(alignment: .leading, spacing: 3) {
                            Text(part.title).font(Theme.text(12, weight: .semibold)).foregroundStyle(Theme.text)
                            Text(part.text).font(Theme.text(12)).foregroundStyle(Theme.muted)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                    }
                }
            }
            if let unavailable = AttestSupport.unavailableReason {
                VStack(alignment: .leading, spacing: 3) {
                    Text(unavailable.title).font(Theme.text(12, weight: .semibold)).foregroundStyle(Theme.gold)
                    Text(unavailable.detail).font(Theme.text(12)).foregroundStyle(Theme.muted)
                        .fixedSize(horizontal: false, vertical: true)
                    if ProcessInfo.processInfo.operatingSystemVersion.majorVersion < 27,
                       let url = URL(string: "x-apple.systempreferences:com.apple.Software-Update-Settings.extension") {
                        Button("Open Software Update") { NSWorkspace.shared.open(url) }
                            .buttonStyle(.plain).font(Theme.text(12, weight: .medium)).foregroundStyle(Theme.gold)
                            .padding(.top, 2)
                    }
                }
            }

            settingRow("Answer checks", detail: answerDetail, good: on && maker.serving && maker.supported, isOn: $on)
                .disabled(AttestSupport.unavailableReason != nil).opacity(AttestSupport.unavailableReason == nil ? 1 : 0.45)
                .onChange(of: on) { value in
                    if value, !AttestSupport.agreed {
                        // First time: the explanation decides, not the switch.
                        on = false
                        showConsent = true
                        return
                    }
                    AttestedStatementMaker.enabled = value
                    if value { maker.startServing() } else { maker.stopServing(); onion.stop(); known.stop(); tor = false; AttestOnion.wanted = false }
                }

            if onion.available {
                settingRow("Also over Tor", detail: torDetail, good: onion.address != nil, isOn: $tor)
                    .disabled(!on).opacity(on ? 1 : 0.45)
                    .onChange(of: tor) { value in
                        AttestOnion.wanted = value
                        if value { onion.start(); known.start() } else { onion.stop(); known.stop() }
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
                    Button("New address…") { confirmNewAddress = true }
                        .buttonStyle(.plain).font(Theme.text(12, weight: .medium)).foregroundStyle(Theme.gold)
                }
            }

            if on, tor, onion.address != nil {
                Divider().overlay(Theme.line)
                VStack(alignment: .leading, spacing: 8) {
                    Text("CHECK ANOTHER NODE")
                        .font(Theme.text(10, weight: .semibold)).tracking(1.4).foregroundStyle(Theme.gold)
                    HStack(spacing: 10) {
                        TextField("its .onion address", text: $otherNode)
                            .textFieldStyle(.plain).font(.system(size: 11, design: .monospaced))
                            .padding(.horizontal, 10).padding(.vertical, 8)
                            .background(Theme.ink, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
                            .overlay(RoundedRectangle(cornerRadius: 8, style: .continuous).stroke(Theme.line))
                            .onSubmit { ask() }
                        TextField("height", text: $askHeight)
                            .textFieldStyle(.plain).font(.system(size: 11, design: .monospaced))
                            .frame(width: 78)
                            .padding(.horizontal, 10).padding(.vertical, 8)
                            .background(Theme.ink, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
                            .overlay(RoundedRectangle(cornerRadius: 8, style: .continuous).stroke(Theme.line))
                            .help("Optional. Empty: the node answers for its tip minus 100.")
                            .onSubmit { ask() }
                        Button(asker.working ? "Checking…" : "Check over Tor") { ask() }
                            .buttonStyle(.plain).font(Theme.text(12, weight: .medium)).foregroundStyle(Theme.gold)
                            .disabled(asker.working || otherNode.isEmpty)
                            .opacity(otherNode.isEmpty ? 0.5 : 1)
                    }
                    if !asker.status.isEmpty {
                        Text(asker.status).font(Theme.text(11)).foregroundStyle(Theme.muted)
                            .fixedSize(horizontal: false, vertical: true).textSelection(.enabled)
                    }
                }

                Divider().overlay(Theme.line)
                VStack(alignment: .leading, spacing: 8) {
                    Text("FINDING OTHER NODES · EXPERIMENTAL")
                        .font(Theme.text(10, weight: .semibold)).tracking(1.4).foregroundStyle(Theme.gold)
                    Text("Lock it asks the genuine nodes it knows for the ones they know, checks every one itself, and checks them again about once a day. Only genuine ones are kept.")
                        .font(Theme.text(12)).foregroundStyle(Theme.muted)
                        .fixedSize(horizontal: false, vertical: true)
                    settingRow("Share my address with other Go Max nodes",
                               detail: share ? "On · other genuine nodes can pass your address on" : "Off · your node can find others, others cannot find it",
                               good: share, isOn: $share)
                        .onChange(of: share) { GenuineNodes.sharing = $0 }
                    Button {
                        showKnown.toggle()
                    } label: {
                        HStack(spacing: 6) {
                            Image(systemName: "checkmark.seal").foregroundStyle(known.genuineCount > 0 ? Theme.green : Theme.muted)
                            Text("Genuine nodes known: \(known.genuineCount)").foregroundStyle(Theme.text)
                            if !known.nodes.isEmpty {
                                Image(systemName: showKnown ? "chevron.up" : "chevron.down").foregroundStyle(Theme.muted)
                            }
                        }
                        .font(Theme.text(12, weight: .medium))
                    }
                    .buttonStyle(.plain).disabled(known.nodes.isEmpty)
                    if showKnown {
                        ForEach(known.nodes) { node in
                            HStack(spacing: 8) {
                                Circle().fill(node.genuine ? Theme.green : Theme.muted.opacity(0.6)).frame(width: 6, height: 6)
                                Text("\(node.onion.prefix(10))…\(node.onion.dropLast(6).suffix(4))")
                                    .font(.system(size: 11, design: .monospaced)).foregroundStyle(Theme.text)
                                    .textSelection(.enabled)
                                Text(knownDetail(node)).font(Theme.text(11)).foregroundStyle(Theme.muted)
                                Spacer(minLength: 4)
                                Button("Remove") { known.remove(node.onion) }
                                    .buttonStyle(.plain).font(Theme.text(11, weight: .medium)).foregroundStyle(Theme.gold)
                            }
                        }
                    }
                }
            }

            if on {
                Divider().overlay(Theme.line)
                VStack(alignment: .leading, spacing: 4) {
                    Text("CHAIN CONFIRMATIONS · EXPERIMENTAL")
                        .font(Theme.text(10, weight: .semibold)).tracking(1.4).foregroundStyle(Theme.gold)
                    Text("Each answer also carries a fingerprint of the chain at a settled block. Later, new Go Max nodes could start much faster from a point many genuine nodes confirm. Nothing uses this yet.")
                        .font(Theme.text(12)).foregroundStyle(Theme.muted)
                        .fixedSize(horizontal: false, vertical: true)
                }
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
        .alert("A new address?", isPresented: $confirmNewAddress) {
            Button("Cancel", role: .cancel) {}
            Button("New address", role: .destructive) { Task { await onion.newAddress() } }
        } message: {
            Text("The current address stops working for good, for everyone who has it. Your node gets a new address and a new key, which contacts Apple once more at the next answer.")
        }
        .sheet(isPresented: $showConsent) {
            AttestConsentSheet {
                showConsent = false
                AttestSupport.agreed = true
                on = true
            } onCancel: {
                showConsent = false
            }
        }
    }

    private var answerDetail: String {
        guard on else { return "Off" }
        guard maker.supported else { return "App Attest is not available on this Mac." }
        return maker.serving ? "On · this Mac (127.0.0.1:\(String(AttestedStatementMaker.port)))" : "Starting…"
    }

    private var torDetail: String {
        guard on else { return "Needs Answer checks" }
        return tor ? onion.state : "Off · other nodes cannot reach this one"
    }

    private func knownDetail(_ node: GenuineNodes.Node) -> String {
        var parts: [String] = []
        if let build = node.build { parts.append("build \(build)") }
        if let checked = node.lastChecked {
            parts.append("checked " + RelativeDateTimeFormatter().localizedString(for: checked, relativeTo: Date()))
        }
        if node.failures > 0 { parts.append("unreachable \(node.failures)×") }
        if node.learnedFrom != "manual" { parts.append("via \(node.learnedFrom.prefix(6))…") }
        return parts.joined(separator: " · ")
    }

    private func ask() {
        guard !asker.working, !otherNode.isEmpty else { return }
        Task { await asker.ask(otherNode, height: askHeight) }
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

/// Go Max nodes finding each other (docs/discovery.md). Asking is allowed
/// whenever "Also over Tor" runs; being found is the separate "Share my
/// address" switch, off by default. Every address is checked by Lock it
/// itself (StatementCheck) before it counts, and again about once a day.
/// The list lives in GoMax/genuine-nodes.json and holds onion addresses
/// and check times only, no wallet data.
@MainActor
final class GenuineNodes: ObservableObject {
    static let shared = GenuineNodes()

    struct Node: Codable, Identifiable, Equatable {
        var onion: String
        var learnedFrom: String          // "manual" or the onion that passed it on
        var lastChecked: Date?
        var lastGenuine: Date?
        var nextCheck: Date
        var build: String?
        var failures: Int = 0
        var shares: Bool = false         // answered /peers the last time we asked
        var lastAskedPeers: Date?
        var keyId: String?
        var counter: Int?                // the key's answer count at the last check
        var id: String { onion }
        var genuine: Bool { lastGenuine != nil && failures == 0 }
    }

    static let maxNodes = 50
    static let maxPeersAnswer = 20
    static let maxFailures = 3
    static let shareWindow: TimeInterval = 7 * 24 * 3600

    @Published private(set) var nodes: [Node] = []
    @Published var status = ""
    private var loop: Task<Void, Never>?

    static var sharing: Bool {
        get { UserDefaults.standard.bool(forKey: "attest.shareAddress") }
        set { UserDefaults.standard.set(newValue, forKey: "attest.shareAddress") }
    }

    private static var file: URL? { GoMaxNode.folder?.appendingPathComponent("genuine-nodes.json") }

    init() {
        if let file = Self.file, let data = try? Data(contentsOf: file) {
            let decoder = JSONDecoder(); decoder.dateDecodingStrategy = .iso8601
            nodes = (try? decoder.decode([Node].self, from: data)) ?? []
        }
    }

    var genuineCount: Int { nodes.filter(\.genuine).count }

    private func save() {
        guard let file = Self.file else { return }
        let encoder = JSONEncoder(); encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try? encoder.encode(nodes).write(to: file, options: .atomic)
    }

    /// A v3 onion name: 56 base32 characters (a–z, 2–7), then ".onion".
    nonisolated static func validOnion(_ text: String) -> Bool {
        guard text.count == 62, text.hasSuffix(".onion") else { return false }
        return text.dropLast(6).allSatisfy { c in (c >= "a" && c <= "z") || (c >= "2" && c <= "7") }
    }

    private var ownAddress: String? { AttestOnion.shared.address?.lowercased() }

    private static func nextDailyCheck(from now: Date = Date()) -> Date {
        // About once a day, at a random time, so checks do not line up.
        now.addingTimeInterval(Double.random(in: 18 * 3600...30 * 3600))
    }

    /// The owner checked this node by hand in "Check another node".
    func noteManualCheck(_ onion: String, _ result: StatementCheck.Result) {
        guard onion != ownAddress else { return }
        let now = Date()
        if let i = nodes.firstIndex(where: { $0.onion == onion }) {
            apply(result, to: i, at: now)
        } else if result.genuine {
            guard nodes.count < Self.maxNodes else { return }
            nodes.append(Node(onion: onion, learnedFrom: "manual", lastChecked: now, lastGenuine: now,
                              nextCheck: Self.nextDailyCheck(from: now), build: result.build,
                              keyId: result.keyId, counter: result.counter))
        }
        save()
    }

    private func apply(_ result: StatementCheck.Result, to i: Int, at now: Date) {
        nodes[i].lastChecked = now
        nodes[i].nextCheck = Self.nextDailyCheck(from: now)
        // Apple: a key's count must go up with every answer. Same key, same or
        // lower count: an old answer played back, or a copy. Not kept.
        if result.genuine, let key = result.keyId, key == nodes[i].keyId,
           let before = nodes[i].counter, let count = result.counter, count <= before {
            nodes[i].failures = Self.maxFailures
            AttestLog.write("Dropped \(nodes[i].onion.prefix(8))…: its key's count did not go up.")
            return
        }
        if result.genuine {
            nodes[i].lastGenuine = now
            nodes[i].build = result.build
            nodes[i].failures = 0
            nodes[i].keyId = result.keyId
            nodes[i].counter = result.counter
        } else {
            nodes[i].failures = Self.maxFailures      // answered, but not genuine: dropped
        }
    }

    func remove(_ onion: String) {
        nodes.removeAll { $0.onion == onion }
        save()
    }

    /// GET /peers: genuine nodes checked in the last week that share their
    /// address themselves. Only when this node shares too.
    func peersAnswer() -> (Int, Data) {
        guard Self.sharing else {
            return (404, (try? JSONSerialization.data(withJSONObject: ["error": "This node does not share addresses."])) ?? Data())
        }
        let since = Date().addingTimeInterval(-Self.shareWindow)
        let list = nodes.filter { $0.genuine && $0.shares && ($0.lastGenuine ?? .distantPast) >= since }
            .prefix(Self.maxPeersAnswer).map(\.onion)
        let body = ["v": 1, "peers": Array(list)] as [String: Any]
        return (200, (try? JSONSerialization.data(withJSONObject: body, options: [.sortedKeys])) ?? Data())
    }

    func start() {
        guard loop == nil else { return }
        loop = Task { @MainActor [weak self] in
            // A first round a few minutes after Tor is up, then every 30 min
            // a look at what is due. Most rounds do nothing.
            try? await Task.sleep(nanoseconds: 180_000_000_000)
            while !Task.isCancelled {
                await self?.discoveryRound()
                try? await Task.sleep(nanoseconds: 1_800_000_000_000)
            }
        }
    }

    func stop() { loop?.cancel(); loop = nil }

    private func discoveryRound() async {
        guard AttestedStatementMaker.enabled, AttestOnion.shared.address != nil, !AttestAsker.shared.working else { return }
        let now = Date()
        // 1. Re-check what is due, one at a time, with a pause between.
        for onion in nodes.filter({ $0.nextCheck <= now }).map(\.onion) {
            await checkOne(onion)
            try? await Task.sleep(nanoseconds: 15_000_000_000)
        }
        nodes.removeAll { $0.failures >= Self.maxFailures }
        // 2. Ask genuine nodes for the nodes they know, once a day each.
        let dayAgo = now.addingTimeInterval(-24 * 3600)
        for onion in nodes.filter({ $0.genuine && ($0.lastAskedPeers ?? .distantPast) < dayAgo }).map(\.onion) {
            await askPeers(onion)
            try? await Task.sleep(nanoseconds: 15_000_000_000)
        }
        nodes.removeAll { $0.failures >= Self.maxFailures }
        save()
        status = "Genuine nodes known: \(genuineCount)."
        AttestLog.write("Discovery round: \(genuineCount) genuine of \(nodes.count) known.")
    }

    /// A fresh challenge to the node, then Lock it's own full check.
    private func checkOne(_ onion: String) async {
        let result = await Self.check(onion)
        guard let i = nodes.firstIndex(where: { $0.onion == onion }) else { return }
        if let result {
            apply(result, to: i, at: Date())
            if !result.genuine { AttestLog.write("Dropped \(onion.prefix(8))…: \(result.reason)") }
        } else {
            nodes[i].failures += 1
            nodes[i].lastChecked = Date()
            // Unreachable: try again in a few hours rather than a day.
            nodes[i].nextCheck = Date().addingTimeInterval(Double.random(in: 3 * 3600...6 * 3600))
        }
    }

    /// nil when the node could not be reached or gave no statement.
    static func check(_ onion: String) async -> StatementCheck.Result? {
        var bytes = [UInt8](repeating: 0, count: 32)
        guard SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes) == errSecSuccess else { return nil }
        let challenge = bytes.map { String(format: "%02x", $0) }.joined()
        guard let body = try? await AttestAsker.get(host: onion, path: "/statement?challenge=\(challenge)"),
              let json = try? JSONSerialization.jsonObject(with: body) as? [String: Any],
              json["error"] == nil else { return nil }
        return StatementCheck.check(body, expectedAppID: AttestedStatementMaker.applicationIdentifier() ?? "",
                                    challenge: challenge, onion: onion)
    }

    private func askPeers(_ onion: String) async {
        guard let i = nodes.firstIndex(where: { $0.onion == onion }) else { return }
        nodes[i].lastAskedPeers = Date()
        guard let body = try? await AttestAsker.get(host: onion, path: "/peers"),
              let json = try? JSONSerialization.jsonObject(with: body) as? [String: Any],
              let peers = json["peers"] as? [String] else {
            if let j = nodes.firstIndex(where: { $0.onion == onion }) { nodes[j].shares = false }
            return
        }
        if let j = nodes.firstIndex(where: { $0.onion == onion }) { nodes[j].shares = true }
        // New addresses count only once they pass a check of their own.
        for peer in peers.prefix(Self.maxPeersAnswer).map({ $0.lowercased() })
        where Self.validOnion(peer) && peer != ownAddress && !nodes.contains(where: { $0.onion == peer }) {
            guard nodes.count < Self.maxNodes else { break }
            try? await Task.sleep(nanoseconds: 15_000_000_000)
            guard let result = await Self.check(peer), result.genuine else { continue }
            let now = Date()
            nodes.append(Node(onion: peer, learnedFrom: onion, lastChecked: now, lastGenuine: now,
                              nextCheck: Self.nextDailyCheck(from: now), build: result.build,
                              keyId: result.keyId, counter: result.counter))
            AttestLog.write("Found a genuine node \(peer.prefix(8))… (build \(result.build ?? "?")) via \(onion.prefix(8))…")
        }
    }
}
