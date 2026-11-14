import AppKit
import SwiftUI
import CryptoKit
import Foundation
#if DEBUG
import DeviceCheck
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

#if DEBUG
/// The developer switch and the App Attest part. Not compiled into TestFlight
/// or App Store builds.
@MainActor
final class AttestedStatementMaker: ObservableObject {
    static let switchKey = "developer.attestedStatements"
    static var enabled: Bool {
        get { UserDefaults.standard.bool(forKey: switchKey) }
        set { UserDefaults.standard.set(newValue, forKey: switchKey) }
    }
    private static let keyIdKey = "developer.appAttestKeyId"
    private static let attestationKey = "developer.appAttestAttestation"

    @Published var status = ""
    @Published var working = false

    var supported: Bool {
        if #available(macOS 27, *) { return DCAppAttestService.shared.isSupported }
        return false
    }

    /// Reads the fingerprint 100 blocks below the node's tip, attests it (the
    /// first time) or asserts it (after that), and asks where to save the
    /// statement file. Reads only from the node; writes nothing to it.
    func make() async {
        working = true
        defer { working = false }
        guard #available(macOS 27, *), DCAppAttestService.shared.isSupported else {
            status = "App Attest is not supported on this Mac (macOS 27 or later, a normal Mac app)."
            return
        }
        let port = GoMaxConfig.rpcPort
        status = "Reading the node…"
        guard let info = await LocalRPC.call("getblockchaininfo", port: port) as? [String: Any],
              let tip = info["blocks"] as? Int,
              (info["verificationprogress"] as? Double ?? 0) >= 0.999 else {
            status = "Go Max's node is not caught up (or not running). Try again when it is up to date."
            return
        }
        let height = tip - 100
        guard let block = await LocalRPC.call("getblock", params: [String(height), 1], port: port) as? [String: Any],
              let tree = await LocalRPC.call("z_gettreestate", params: [String(height)], port: port) as? [String: Any],
              let fingerprint = StateFingerprint.make(block: block, treeState: tree),
              let json = try? StateFingerprint.canonicalJSON(fingerprint) else {
            status = "The node did not answer with everything the fingerprint needs."
            return
        }
        let digest = Data(SHA256.hash(data: json))
        let node = await LocalRPC.call("getinfo", port: port) as? [String: Any]
        do {
            let service = DCAppAttestService.shared
            var keyId = UserDefaults.standard.string(forKey: Self.keyIdKey)
            var statement: [String: Any] = [
                "format": "zecky-attested-statement/v0",
                "fingerprint": fingerprint,
                "fingerprintJSON": String(decoding: json, as: UTF8.self),
                "fingerprintSHA256": StateFingerprint.sha256Hex(json),
                "height": height,
                "node": ["build": node?["build"] ?? "unknown", "subversion": node?["subversion"] ?? "unknown"],
                "lockIt": ["version": Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") ?? "",
                           "build": Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") ?? ""],
                "appId": Self.applicationIdentifier() ?? "unknown",
                "createdAt": ISO8601DateFormatter().string(from: Date()),
            ]
            if keyId == nil {
                status = "Making an App Attest key…"
                keyId = try await service.generateKey()
                UserDefaults.standard.set(keyId, forKey: Self.keyIdKey)
            }
            guard let keyId else { return }
            if let saved = UserDefaults.standard.data(forKey: Self.attestationKey) {
                // The key is attested already: this statement is an assertion
                // by that key, carrying the key's attestation for the verifier.
                status = "Signing with the attested key…"
                let assertion = try await service.generateAssertion(keyId, clientDataHash: digest)
                statement["kind"] = "assertion"
                statement["assertion"] = assertion.base64EncodedString()
                statement["keyAttestation"] = saved.base64EncodedString()
            } else {
                status = "Asking Apple to attest the key (once per install)…"
                let attestation = try await service.attestKey(keyId, clientDataHash: digest)
                UserDefaults.standard.set(attestation, forKey: Self.attestationKey)
                statement["kind"] = "attestation"
                statement["attestation"] = attestation.base64EncodedString()
            }
            statement["keyId"] = keyId
            let file = try JSONSerialization.data(withJSONObject: statement, options: [.sortedKeys, .prettyPrinted, .withoutEscapingSlashes])
            save(file, name: "zecky-statement-\(height).json")
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

    /// "TEAMID.app.zecky.lockit", from this app's own signature.
    static func applicationIdentifier() -> String? {
        guard let task = SecTaskCreateFromSelf(nil) else { return nil }
        return SecTaskCopyValueForEntitlement(task, "com.apple.application-identifier" as CFString, nil) as? String
    }
}

/// Settings › About › Technical details, debug builds only: the developer
/// switch for attested statements.
struct DeveloperAttestRow: View {
    @StateObject private var maker = AttestedStatementMaker()
    @State private var on = AttestedStatementMaker.enabled

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Toggle("Attested statements (developer)", isOn: $on)
                .toggleStyle(.switch).controlSize(.mini)
                .font(Theme.text(12)).foregroundStyle(Theme.muted)
                .onChange(of: on) { value in AttestedStatementMaker.enabled = value }
            if on {
                Text(maker.supported ? "App Attest: supported on this Mac" : "App Attest: not supported on this Mac")
                    .font(Theme.text(11)).foregroundStyle(Theme.muted)
                Button(maker.working ? "Working…" : "Make an attested statement…") { Task { await maker.make() } }
                    .buttonStyle(.plain).font(Theme.text(12, weight: .medium)).foregroundStyle(Theme.gold)
                    .disabled(maker.working)
                if !maker.status.isEmpty {
                    Text(maker.status).font(Theme.text(11)).foregroundStyle(Theme.muted)
                        .fixedSize(horizontal: false, vertical: true).textSelection(.enabled)
                }
            }
        }
        .padding(.top, 6)
    }
}
#endif
