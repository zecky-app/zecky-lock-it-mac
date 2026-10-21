import Foundation
import LocalAuthentication
import Security

/// Secrets in the Mac Keychain, this device only.
///
/// Same promise as the iPhone app: items live in the data protection
/// Keychain with `WhenUnlockedThisDeviceOnly`, so they are never synced to
/// iCloud Keychain, never restored to another Mac, and unreadable while the
/// Mac is locked. Nothing here is ever logged.
enum KeyStore {
    /// The recovery phrase. Kept apart from every other item.
    static let phraseService = "app.zecky.lockit.mac.phrase"

    enum Failure: Error, CustomStringConvertible {
        case keychain(OSStatus)
        case unexpectedData

        var description: String {
            switch self {
            case .keychain(let status):
                let text = SecCopyErrorMessageString(status, nil) as String? ?? "unknown"
                return "Keychain error \(status): \(text)"
            case .unexpectedData:
                return "Keychain returned unexpected data"
            }
        }
    }

    private static func query(_ service: String) -> [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: "zecky",
            kSecUseDataProtectionKeychain as String: true,
            kSecAttrSynchronizable as String: false,
        ]
    }

    /// Stores `data`, replacing anything already stored for `service`.
    /// With `access`, reading it later needs what that access asks for
    /// (for example Touch ID or the Mac password).
    static func save(_ data: Data, service: String, access: SecAccessControl? = nil) throws {
        try delete(service: service)
        var item = query(service)
        if let access {
            item[kSecAttrAccessControl as String] = access
        } else {
            item[kSecAttrAccessible as String] = kSecAttrAccessibleWhenUnlockedThisDeviceOnly
        }
        item[kSecValueData as String] = data
        let status = SecItemAdd(item as CFDictionary, nil)
        guard status == errSecSuccess else { throw Failure.keychain(status) }
    }

    /// Returns the stored data, or nil when nothing is stored. A `context`
    /// that already confirmed the owner opens a guarded item without asking
    /// again; without one, a guarded item is never shown a prompt.
    static func read(service: String, context: LAContext? = nil) throws -> Data? {
        var q = query(service)
        if let context {
            q[kSecUseAuthenticationContext as String] = context
        } else {
            let silent = LAContext()
            silent.interactionNotAllowed = true
            q[kSecUseAuthenticationContext as String] = silent
        }
        q[kSecReturnData as String] = true
        q[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: AnyObject?
        let status = SecItemCopyMatching(q as CFDictionary, &result)
        if status == errSecItemNotFound { return nil }
        guard status == errSecSuccess else { throw Failure.keychain(status) }
        guard let data = result as? Data else { throw Failure.unexpectedData }
        return data
    }

    /// Removes the item. Nothing stored is not an error.
    static func delete(service: String) throws {
        let status = SecItemDelete(query(service) as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else {
            throw Failure.keychain(status)
        }
    }

    /// The protection the Keychain actually recorded for an item, so a
    /// test can prove it is "this device only" and not synced.
    static func protection(service: String) throws -> (accessible: String, synced: Bool)? {
        var q = query(service)
        q[kSecReturnAttributes as String] = true
        q[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: AnyObject?
        let status = SecItemCopyMatching(q as CFDictionary, &result)
        if status == errSecItemNotFound { return nil }
        guard status == errSecSuccess else { throw Failure.keychain(status) }
        guard let attributes = result as? [String: Any] else { throw Failure.unexpectedData }
        let accessible = attributes[kSecAttrAccessible as String] as? String ?? "?"
        let synced = (attributes[kSecAttrSynchronizable as String] as? Bool) ?? false
        return (accessible, synced)
    }
}

/// "Confirm it's you": Touch ID, or the Mac login password when there is
/// no Touch ID. Guards showing the recovery phrase, like Face ID on iPhone.
enum OwnerCheck {
    /// False on a Mac without a login password (and so without Touch ID).
    static var available: Bool {
        var error: NSError?
        return LAContext().canEvaluatePolicy(.deviceOwnerAuthentication, error: &error)
    }

    static func confirm(reason: String) async -> Bool {
        let context = LAContext()
        var error: NSError?
        guard context.canEvaluatePolicy(.deviceOwnerAuthentication, error: &error) else { return false }
        return (try? await context.evaluatePolicy(.deviceOwnerAuthentication, localizedReason: reason)) ?? false
    }
}

/// Self-test with a random dummy value. Never touches the recovery phrase.
enum KeyStoreSelfTest {
    static func run() -> String {
        let service = "app.zecky.lockit.mac.selftest"
        var dummy = Data(count: 32)
        let random = dummy.withUnsafeMutableBytes { SecRandomCopyBytes(kSecRandomDefault, 32, $0.baseAddress!) }
        guard random == errSecSuccess else { return "Keychain: random source failed" }
        do {
            try KeyStore.save(dummy, service: service)
            guard try KeyStore.read(service: service) == dummy else { return "Keychain: read back a different value" }
            guard let p = try KeyStore.protection(service: service) else { return "Keychain: item missing after save" }
            let deviceOnly = p.accessible == (kSecAttrAccessibleWhenUnlockedThisDeviceOnly as String)
            guard deviceOnly, !p.synced else { return "Keychain: wrong protection (\(p.accessible), synced \(p.synced))" }
            try KeyStore.delete(service: service)
            guard try KeyStore.read(service: service) == nil else { return "Keychain: delete did not remove the item" }
            return "Keychain: OK (this device only, not synced)"
        } catch {
            try? KeyStore.delete(service: service)
            return "Keychain: \(error)"
        }
    }
}
