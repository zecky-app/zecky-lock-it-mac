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

    private struct Info: Codable { var birthday: Int; var kind: Kind; var hasCode: Bool?; var usesPassword: Bool? }
    /// The sealed phrase while a new code is checked, before it replaces the old seal.
    private static let stagingService = "app.zecky.lockit.mac.sealed-staging"
    /// Wrong codes in a row, and until when the next try has to wait.
    private static let triesService = "app.zecky.lockit.mac.code-tries"
    private struct Tries: Codable { var count: Int; var until: Date? }
    /// `key` opens with Touch ID or the Mac password; `codeKey` only with the
    /// code or Lock it password. With both, both are needed.
    private struct Sealed: Codable { var key: Data?; var codeKey: Data?; var ephemeral: Data; var box: Data }

    enum Failure: Error, CustomStringConvertible {
        case cancelled
        case unavailable
        case damaged
        case sealing(String)
        case codeNeeded
        case wrongCode(wait: Date?)
        case mustWait(until: Date)
        var description: String {
            switch self {
            case .codeNeeded: return "Turn in your code first."
            case .wrongCode(let wait):
                if let wait { return "That is not the code. Try again in \(WalletVault.waitText(until: wait))." }
                return "That is not the code."
            case .mustWait(let until): return "Too many wrong codes. Try again in \(WalletVault.waitText(until: until))."
            case .cancelled: return "Not confirmed, so the lock stayed closed."
            case .unavailable: return "This Mac has no password or Touch ID set up, so the recovery phrase cannot be sealed. Set a login password in System Settings first."
            case .sealing(let why): return "The seal could not be made, so nothing changed. (\(why))"
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

    /// True when the lock has a 6-digit code on top of Touch ID.
    static var hasCode: Bool { info?.hasCode ?? false }

    /// True on a Mac without a login password, where the owner chose a
    /// Lock it password (10+ characters) as the only key.
    static var usesPassword: Bool { info?.usesPassword ?? false }

    /// A code or Lock it password has to be given before opening.
    static var needsSecret: Bool { hasCode || usesPassword }

    /// A code needs the Secure Enclave, so the chip itself checks it.
    static var canUseCode: Bool { kind == .secureEnclave && !usesPassword }

    static let minimumPassword = 10

    /// Until when a new code try has to wait, after wrong codes.
    static var waitUntil: Date? {
        guard let until = tries.until, until > Date() else { return nil }
        return until
    }

    static func waitText(until: Date) -> String {
        let seconds = max(1, Int(until.timeIntervalSinceNow.rounded(.up)))
        if seconds < 60 { return "\(seconds) seconds" }
        let minutes = (seconds + 59) / 60
        return minutes == 1 ? "1 minute" : "\(minutes) minutes"
    }

    private static var info: Info? {
        guard let data = (try? KeyStore.read(service: infoService)) ?? nil else { return nil }
        return try? JSONDecoder().decode(Info.self, from: data)
    }

    // MARK: Seal

    /// Seals a new or restored wallet. Needs no Touch ID: only opening does.
    /// With `password` (a Mac without a login password), that password is
    /// the only key: the chip, or the Keychain, checks it.
    static func save(_ wallet: StoredWallet, password: String? = nil) throws {
        let plain = try JSONEncoder().encode(wallet)
        let mode: Extra = password.map { Extra.passwordOnly($0) } ?? Extra.none
        var kind: Kind = .keychain
        if SecureEnclave.isAvailable, let sealed = try? sealInEnclave(plain, mode: mode) {
            try KeyStore.save(sealed, service: sealedService)
            try? KeyStore.delete(service: guardedService)
            kind = .secureEnclave
        } else {
            try saveGuarded(plain, passwordOnly: password != nil)
            try? KeyStore.delete(service: sealedService)
        }
        let info = Info(birthday: wallet.birthday, kind: kind, hasCode: false, usesPassword: password != nil)
        try KeyStore.save(try JSONEncoder().encode(info), service: infoService)
        resetTries()
        if let password, (try? open(LAContext(), info: info, code: password)) != plain {
            throw Failure.damaged
        }
    }

    /// What the seal needs besides itself: nothing more than Touch ID, Touch
    /// ID and a code, or only a Lock it password. The secret is handed to
    /// the chip when its key is made, so macOS never asks for it itself.
    private enum Extra { case none, code(String), passwordOnly(String) }

    /// Seals with a fresh Secure Enclave key. With `code`, the key also needs
    /// the 6-digit code (an application password the chip checks itself).
    private static func sealInEnclave(_ plain: Data, mode: Extra) throws -> Data {
        var owner: SecureEnclave.P256.KeyAgreement.PrivateKey?
        var code: SecureEnclave.P256.KeyAgreement.PrivateKey?
        switch mode {
        case .none:
            owner = try enclaveKey([.privateKeyUsage, .userPresence])
        case .code(let secret):
            owner = try enclaveKey([.privateKeyUsage, .userPresence])
            code = try enclaveKey([.privateKeyUsage, .applicationPassword], secret: secret)
        case .passwordOnly(let secret):
            code = try enclaveKey([.privateKeyUsage, .applicationPassword], secret: secret)
        }
        let ephemeral = P256.KeyAgreement.PrivateKey()
        let secrets = try [owner, code].compactMap { $0 }.map { try ephemeral.sharedSecretFromKeyAgreement(with: $0.publicKey) }
        let box = try AES.GCM.seal(plain, using: symmetricKey(secrets, ephemeral.publicKey))
        guard let combined = box.combined else { throw Failure.damaged }
        let sealed = Sealed(key: owner?.dataRepresentation, codeKey: code?.dataRepresentation,
                            ephemeral: ephemeral.publicKey.x963Representation, box: combined)
        return try JSONEncoder().encode(sealed)
    }

    private static func enclaveKey(_ flags: SecAccessControlCreateFlags, secret: String? = nil) throws -> SecureEnclave.P256.KeyAgreement.PrivateKey {
        var error: Unmanaged<CFError>?
        guard let access = SecAccessControlCreateWithFlags(nil, kSecAttrAccessibleWhenUnlockedThisDeviceOnly, flags, &error) else {
            throw Failure.sealing(error.map { String(describing: $0.takeRetainedValue()) } ?? "access control")
        }
        let context = LAContext()
        defer { context.invalidate() }
        if let secret { _ = context.setCredential(Data(secret.utf8), type: .applicationPassword) }
        do { return try SecureEnclave.P256.KeyAgreement.PrivateKey(accessControl: access, authenticationContext: context) }
        catch { throw Failure.sealing(String(describing: error)) }
    }

    /// One secret: the derivation the first sealed wallets used. Two: both
    /// go into the key, so neither alone opens the seal.
    private static func symmetricKey(_ secrets: [SharedSecret], _ ephemeral: P256.KeyAgreement.PublicKey) -> SymmetricKey {
        if secrets.count == 1 {
            return secrets[0].hkdfDerivedSymmetricKey(using: SHA256.self, salt: ephemeral.x963Representation,
                                                      sharedInfo: sealInfo, outputByteCount: 32)
        }
        var material = Data()
        for secret in secrets { secret.withUnsafeBytes { material.append(contentsOf: $0) } }
        defer { material.resetBytes(in: 0..<material.count) }
        return HKDF<SHA256>.deriveKey(inputKeyMaterial: SymmetricKey(data: material), salt: ephemeral.x963Representation,
                                      info: sealInfo + Data("-2".utf8), outputByteCount: 32)
    }

    private static func saveGuarded(_ plain: Data, passwordOnly: Bool) throws {
        guard let access = SecAccessControlCreateWithFlags(
            nil, kSecAttrAccessibleWhenUnlockedThisDeviceOnly, passwordOnly ? .applicationPassword : .userPresence, nil
        ) else { throw Failure.unavailable }
        try KeyStore.save(plain, service: guardedService, access: access)
    }

    // MARK: Unseal

    /// Asks for Touch ID or the Mac password, then opens the phrase. With a
    /// code on the lock, `code` must be the 6 digits; the chip checks them.
    /// The caller uses the phrase and lets it go straight away.
    static func unseal(reason: String, code: String? = nil) async throws -> StoredWallet {
        if needsSecret {
            guard code != nil else { throw Failure.codeNeeded }
            if let until = waitUntil { throw Failure.mustWait(until: until) }
        }
        let context = usesPassword ? LAContext() : try await confirmOwner(reason: reason)
        defer { context.invalidate() }

        if let legacy = try legacyLoad() { return legacy }
        guard let info else { throw Failure.damaged }
        let plain = try open(context, info: info, code: code)
        guard let wallet = try? JSONDecoder().decode(StoredWallet.self, from: plain) else { throw Failure.damaged }
        return wallet
    }

    private static func confirmOwner(reason: String) async throws -> LAContext {
        let context = LAContext()
        var error: NSError?
        guard context.canEvaluatePolicy(.deviceOwnerAuthentication, error: &error) else { throw Failure.unavailable }
        do {
            guard try await context.evaluatePolicy(.deviceOwnerAuthentication, localizedReason: reason) else { throw Failure.cancelled }
        } catch let failure as Failure { throw failure }
        catch { throw Failure.cancelled }
        return context
    }

    /// Opens the seal. With a code or Lock it password, that goes along as
    /// an application password the chip or Keychain checks; wrong ones count.
    private static func open(_ context: LAContext, info: Info, code: String?, service: String? = nil) throws -> Data {
        let secret = (info.hasCode ?? false) || (info.usesPassword ?? false)
        if secret {
            guard let code else { throw Failure.codeNeeded }
            _ = context.setCredential(Data(code.utf8), type: .applicationPassword)
        }
        do {
            let plain: Data
            switch info.kind {
            case .secureEnclave:
                plain = try openFromEnclave(context, service: service ?? sealedService)
            case .keychain:
                guard let data = try KeyStore.read(service: service ?? guardedService, context: context) else { throw Failure.damaged }
                plain = data
            }
            if secret { resetTries() }
            return plain
        } catch {
            if secret { throw Failure.wrongCode(wait: wrongTry()) }
            throw error
        }
    }

    // MARK: The code

    /// Puts a code on the lock, changes it, or removes it (`new` nil).
    /// One Touch ID. The phrase is sealed again under a new key, checked to
    /// open with the new code, and only then replaces the old seal.
    static func setCode(current: String?, new: String?) async throws {
        guard canUseCode else { throw Failure.sealing("a code needs this Mac's Secure Enclave") }
        if hasCode, let until = waitUntil { throw Failure.mustWait(until: until) }
        let reason = new == nil ? "remove the code from the lock" : (hasCode ? "change the code of the lock" : "put a code on the lock")
        let context = try await confirmOwner(reason: reason)
        defer { context.invalidate() }
        guard let info else { throw Failure.damaged }
        let plain = try open(context, info: info, code: current)

        let staged = try sealInEnclave(plain, mode: new.map { Extra.code($0) } ?? Extra.none)
        try KeyStore.save(staged, service: stagingService)
        _ = context.setCredential(new.map { Data($0.utf8) }, type: .applicationPassword)
        guard (try? openFromEnclave(context, service: stagingService)) == plain else {
            try? KeyStore.delete(service: stagingService)
            throw Failure.sealing("the new seal did not open with the new code")
        }
        try KeyStore.save(staged, service: sealedService)
        try? KeyStore.delete(service: stagingService)
        var updated = info
        updated.hasCode = new != nil
        try KeyStore.save(try JSONEncoder().encode(updated), service: infoService)
        resetTries()
    }

    private static var tries: Tries {
        guard let data = (try? KeyStore.read(service: triesService)) ?? nil,
              let tries = try? JSONDecoder().decode(Tries.self, from: data) else { return Tries(count: 0, until: nil) }
        return tries
    }

    /// Counts a wrong code. After 3 wrong codes each try waits longer:
    /// 30 s, 1 min, 5 min, 15 min, then an hour.
    private static func wrongTry() -> Date? {
        var t = tries
        t.count += 1
        let waits: [TimeInterval] = [0, 0, 30, 60, 300, 900, 3600]
        let wait = waits[min(t.count - 1, waits.count - 1)]
        t.until = wait > 0 ? Date().addingTimeInterval(wait) : nil
        try? KeyStore.save(try JSONEncoder().encode(t), service: triesService)
        return t.until
    }

    private static func resetTries() { try? KeyStore.delete(service: triesService) }

    private static func openFromEnclave(_ context: LAContext, service: String = sealedService) throws -> Data {
        guard let data = try KeyStore.read(service: service),
              let sealed = try? JSONDecoder().decode(Sealed.self, from: data) else { throw Failure.damaged }
        do {
            let ephemeral = try P256.KeyAgreement.PublicKey(x963Representation: sealed.ephemeral)
            let secrets = try [sealed.key, sealed.codeKey].compactMap { $0 }.map { blob in
                try SecureEnclave.P256.KeyAgreement.PrivateKey(dataRepresentation: blob, authenticationContext: context)
                    .sharedSecretFromKeyAgreement(with: ephemeral)
            }
            guard !secrets.isEmpty else { throw Failure.damaged }
            return try AES.GCM.open(try AES.GCM.SealedBox(combined: sealed.box), using: symmetricKey(secrets, ephemeral))
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
        try KeyStore.delete(service: stagingService)
        resetTries()
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
