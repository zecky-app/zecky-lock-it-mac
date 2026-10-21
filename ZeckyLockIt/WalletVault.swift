import CryptoKit
import Foundation
import LocalAuthentication
import Security

/// The wallet's secret part: phrase and birthday. Only ever held in memory
/// for as long as it is needed, never kept for the whole session.
struct StoredWallet: Codable, Equatable {
    var phrase: String
    var birthday: Int
}

/// The recovery phrase, sealed.
///
/// On a Mac with a Secure Enclave (Apple silicon, or Intel with a T2 chip)
/// the phrase is encrypted with a key that is created inside the Secure
/// Enclave and never leaves it. That key only works on this Mac, and only
/// after Touch ID or the Mac password. Without it the stored data is
/// unreadable, also for Zecky Lock it itself.
///
/// On a Mac without a Secure Enclave the phrase sits in a Keychain item that
/// itself requires Touch ID or the Mac password to be read.
///
/// Both are "this device only", never synced and never in a backup. The
/// birthday is stored next to it in the open: it is not a secret, and lets
/// the wallet start without unsealing anything.
enum WalletVault {
    private static let checkService = "app.zecky.lockit.mac.phrase-unconfirmed"
    /// The sealed phrase (Secure Enclave) and its key's wrapped form.
    private static let sealedService = "app.zecky.lockit.mac.sealed"
    /// The phrase behind Touch ID, on Macs without a Secure Enclave.
    private static let guardedService = "app.zecky.lockit.mac.guarded"
    /// Birthday and how the phrase is sealed. No secrets.
    private static let infoService = "app.zecky.lockit.mac.wallet-info"
    /// Domain separation for the key derivation. Never change.
    private static let sealInfo = Data("zecky-lockit-seal-v1".utf8)

    enum Kind: String, Codable { case secureEnclave, keychain }

    private struct Info: Codable { var birthday: Int; var kind: Kind }
    private struct Sealed: Codable { var key: Data; var ephemeral: Data; var box: Data }

    enum Failure: Error, CustomStringConvertible {
        case cancelled
        case unavailable
        case damaged
        var description: String {
            switch self {
            case .cancelled: return "Not confirmed, so the lock stayed closed."
            case .unavailable: return "This Mac has no password or Touch ID set up, so the recovery phrase cannot be sealed. Set a login password in System Settings first."
            case .damaged: return "The sealed recovery phrase could not be opened. Restore with your 24 words."
            }
        }
    }

    // MARK: Without unsealing

    /// True when a wallet is stored on this Mac, sealed or still open.
    static var exists: Bool { info != nil || legacyExists }

    /// The wallet's birthday block. Readable without Touch ID.
    static var birthday: Int? { info?.birthday ?? legacyBirthday }

    /// How the phrase is sealed on this Mac, for Settings.
    static var kind: Kind? { info?.kind }

    private static var info: Info? {
        guard let data = (try? KeyStore.read(service: infoService)) ?? nil else { return nil }
        return try? JSONDecoder().decode(Info.self, from: data)
    }

    // MARK: Seal

    /// Seals a new or restored wallet. Needs no Touch ID: only opening does.
    static func save(_ wallet: StoredWallet) throws {
        let plain = try JSONEncoder().encode(wallet)
        let kind: Kind
        if SecureEnclave.isAvailable {
            try sealInEnclave(plain)
            try? KeyStore.delete(service: guardedService)
            kind = .secureEnclave
        } else {
            try saveGuarded(plain)
            try? KeyStore.delete(service: sealedService)
            kind = .keychain
        }
        try KeyStore.save(try JSONEncoder().encode(Info(birthday: wallet.birthday, kind: kind)), service: infoService)
    }

    private static func sealInEnclave(_ plain: Data) throws {
        guard let access = SecAccessControlCreateWithFlags(
            nil, kSecAttrAccessibleWhenUnlockedThisDeviceOnly, [.privateKeyUsage, .userPresence], nil
        ) else { throw Failure.unavailable }
        let key = try SecureEnclave.P256.KeyAgreement.PrivateKey(accessControl: access)
        let ephemeral = P256.KeyAgreement.PrivateKey()
        let secret = try ephemeral.sharedSecretFromKeyAgreement(with: key.publicKey)
        let box = try AES.GCM.seal(plain, using: symmetricKey(secret, ephemeral.publicKey))
        guard let combined = box.combined else { throw Failure.damaged }
        let sealed = Sealed(key: key.dataRepresentation, ephemeral: ephemeral.publicKey.x963Representation, box: combined)
        try KeyStore.save(try JSONEncoder().encode(sealed), service: sealedService)
    }

    private static func symmetricKey(_ secret: SharedSecret, _ ephemeral: P256.KeyAgreement.PublicKey) -> SymmetricKey {
        secret.hkdfDerivedSymmetricKey(using: SHA256.self, salt: ephemeral.x963Representation,
                                       sharedInfo: sealInfo, outputByteCount: 32)
    }

    private static func saveGuarded(_ plain: Data) throws {
        guard let access = SecAccessControlCreateWithFlags(
            nil, kSecAttrAccessibleWhenUnlockedThisDeviceOnly, .userPresence, nil
        ) else { throw Failure.unavailable }
        try KeyStore.save(plain, service: guardedService, access: access)
    }

    // MARK: Unseal

    /// Asks for Touch ID or the Mac password, then opens the phrase. The
    /// caller uses it and lets it go straight away.
    static func unseal(reason: String) async throws -> StoredWallet {
        let context = LAContext()
        var error: NSError?
        guard context.canEvaluatePolicy(.deviceOwnerAuthentication, error: &error) else { throw Failure.unavailable }
        do {
            guard try await context.evaluatePolicy(.deviceOwnerAuthentication, localizedReason: reason) else { throw Failure.cancelled }
        } catch let failure as Failure { throw failure }
        catch { throw Failure.cancelled }
        defer { context.invalidate() }

        if let legacy = try legacyLoad() { return legacy }
        guard let info else { throw Failure.damaged }
        let plain: Data
        switch info.kind {
        case .secureEnclave: plain = try openFromEnclave(context)
        case .keychain:
            guard let data = try KeyStore.read(service: guardedService, context: context) else { throw Failure.damaged }
            plain = data
        }
        guard let wallet = try? JSONDecoder().decode(StoredWallet.self, from: plain) else { throw Failure.damaged }
        return wallet
    }

    private static func openFromEnclave(_ context: LAContext) throws -> Data {
        guard let data = try KeyStore.read(service: sealedService),
              let sealed = try? JSONDecoder().decode(Sealed.self, from: data) else { throw Failure.damaged }
        do {
            let key = try SecureEnclave.P256.KeyAgreement.PrivateKey(dataRepresentation: sealed.key, authenticationContext: context)
            let ephemeral = try P256.KeyAgreement.PublicKey(x963Representation: sealed.ephemeral)
            let secret = try key.sharedSecretFromKeyAgreement(with: ephemeral)
            return try AES.GCM.open(try AES.GCM.SealedBox(combined: sealed.box), using: symmetricKey(secret, ephemeral))
        } catch {
            throw Failure.damaged
        }
    }

    // MARK: From the first test builds

    /// Builds before sealing kept the phrase in an open Keychain item.
    /// Seals it, proves the seal opens to the very same words, and only
    /// then removes the open item. One Touch ID prompt, once.
    static func sealOlderWallet() async throws {
        guard let old = try legacyLoad() else { return }
        try save(old)
        let context = LAContext()
        guard try await context.evaluatePolicy(.deviceOwnerAuthentication,
                                               localizedReason: "seal your recovery phrase in this Mac") else { throw Failure.cancelled }
        defer { context.invalidate() }
        let plain: Data
        switch info?.kind {
        case .secureEnclave: plain = try openFromEnclave(context)
        case .keychain:
            guard let data = try KeyStore.read(service: guardedService, context: context) else { throw Failure.damaged }
            plain = data
        case nil: throw Failure.damaged
        }
        guard (try? JSONDecoder().decode(StoredWallet.self, from: plain)) == old else { throw Failure.damaged }
        try KeyStore.delete(service: KeyStore.phraseService)
    }

    static var legacyExists: Bool { ((try? KeyStore.read(service: KeyStore.phraseService)) ?? nil) != nil }
    private static var legacyBirthday: Int? { (try? legacyLoad())??.birthday }
    private static func legacyLoad() throws -> StoredWallet? {
        guard let data = try KeyStore.read(service: KeyStore.phraseService) else { return nil }
        return try JSONDecoder().decode(StoredWallet.self, from: data)
    }

    // MARK: Erase

    /// Removes the sealed phrase and its key. Without them nothing can be
    /// opened again on this Mac; only the 24 words on paper bring it back.
    static func eraseAll() throws {
        try KeyStore.delete(service: sealedService)
        try KeyStore.delete(service: guardedService)
        try KeyStore.delete(service: infoService)
        try KeyStore.delete(service: KeyStore.phraseService)
        phraseUnconfirmed = false
    }

    /// True until the owner has shown they wrote the words down.
    static var phraseUnconfirmed: Bool {
        get { ((try? KeyStore.read(service: checkService)) ?? nil) != nil }
        set {
            if newValue { try? KeyStore.save(Data("unconfirmed".utf8), service: checkService) }
            else { try? KeyStore.delete(service: checkService) }
        }
    }
}

/// Overwrites secret bytes once they are no longer needed.
enum Wipe {
    static func bytes(_ bytes: inout [UInt8]) {
        bytes.withUnsafeMutableBytes { buffer in
            guard let base = buffer.baseAddress else { return }
            memset_s(base, buffer.count, 0, buffer.count)
        }
        bytes.removeAll()
    }
}
