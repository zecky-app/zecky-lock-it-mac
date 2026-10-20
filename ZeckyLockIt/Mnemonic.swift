import CommonCrypto
import CryptoKit
import Foundation

/// BIP39 recovery phrases (English, 24 words), as used by the iPhone app.
///
/// Kept small and in this repository instead of adding a package. Proven
/// against the official BIP39 test vectors in `WalletSelfTest`.
enum Mnemonic {
    enum Failure: Error, CustomStringConvertible {
        case wordlistTampered
        case wrongLength
        case unknownWord(String)
        case badChecksum
        case seedDerivation

        var description: String {
            switch self {
            case .wordlistTampered: return "The built-in word list is not the official BIP39 English list."
            case .wrongLength: return "A recovery phrase has 12, 15, 18, 21 or 24 words."
            case .unknownWord(let w): return "“\(w)” is not one of the recovery words."
            case .badChecksum: return "These words are not a valid recovery phrase. Check each word and the order."
            case .seedDerivation: return "Could not turn the phrase into a key."
            }
        }
    }

    /// SHA-256 of the official BIP39 english.txt (one word per line).
    private static let wordlistSHA256 = "2f5eed53a4727b4bf8880d8f3f199efc90e58503646d9ff8eff3a2ed3b24dbda"

    /// The 2048 words, loaded once and checked against the official hash.
    static let words: Result<[String], Failure> = {
        guard let url = Bundle.main.url(forResource: "bip39-english", withExtension: "txt"),
              let data = try? Data(contentsOf: url) else { return .failure(.wordlistTampered) }
        let hash = SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
        guard hash == wordlistSHA256 else { return .failure(.wordlistTampered) }
        let list = String(decoding: data, as: UTF8.self).split(separator: "\n").map(String.init)
        guard list.count == 2048 else { return .failure(.wordlistTampered) }
        return .success(list)
    }()

    /// Lowercases and collapses whitespace so typed or pasted phrases compare cleanly.
    static func normalize(_ phrase: String) -> String {
        phrase.lowercased().split(whereSeparator: { $0.isWhitespace }).joined(separator: " ")
    }

    /// Words for `entropy` (16 to 32 bytes, multiple of 4). 32 bytes gives 24 words.
    static func phrase(from entropy: [UInt8]) throws -> String {
        let list = try words.get()
        guard [16, 20, 24, 28, 32].contains(entropy.count) else { throw Failure.wrongLength }
        let checksumBits = entropy.count * 8 / 32
        let hash = Array(SHA256.hash(data: entropy))
        var bits: [Bool] = []
        for byte in entropy { for i in (0..<8).reversed() { bits.append(byte >> i & 1 == 1) } }
        for i in 0..<checksumBits { bits.append(hash[i / 8] >> (7 - i % 8) & 1 == 1) }
        var result: [String] = []
        for chunk in stride(from: 0, to: bits.count, by: 11) {
            var index = 0
            for bit in bits[chunk..<chunk + 11] { index = index << 1 | (bit ? 1 : 0) }
            result.append(list[index])
        }
        return result.joined(separator: " ")
    }

    /// Throws a plain-language error when the phrase is not valid.
    static func validate(_ phrase: String) throws {
        let list = try words.get()
        let parts = normalize(phrase).split(separator: " ").map(String.init)
        guard [12, 15, 18, 21, 24].contains(parts.count) else { throw Failure.wrongLength }
        var bits: [Bool] = []
        for word in parts {
            guard let index = list.firstIndex(of: word) else { throw Failure.unknownWord(word) }
            for i in (0..<11).reversed() { bits.append(index >> i & 1 == 1) }
        }
        let checksumBits = bits.count / 33
        let entropyBits = bits.count - checksumBits
        var entropy: [UInt8] = []
        for start in stride(from: 0, to: entropyBits, by: 8) {
            var byte: UInt8 = 0
            for bit in bits[start..<start + 8] { byte = byte << 1 | (bit ? 1 : 0) }
            entropy.append(byte)
        }
        let hash = Array(SHA256.hash(data: entropy))
        for i in 0..<checksumBits where bits[entropyBits + i] != (hash[i / 8] >> (7 - i % 8) & 1 == 1) {
            throw Failure.badChecksum
        }
    }

    static func isValid(_ phrase: String) -> Bool { (try? validate(phrase)) != nil }

    /// The 64-byte BIP39 seed (PBKDF2-HMAC-SHA512, 2048 rounds). Zecky uses
    /// no passphrase, the same as the iPhone app.
    static func seed(from phrase: String, passphrase: String = "") throws -> [UInt8] {
        try validate(phrase)
        let password = Array(normalize(phrase).decomposedStringWithCompatibilityMapping.utf8)
        let salt = Array(("mnemonic" + passphrase).decomposedStringWithCompatibilityMapping.utf8)
        var out = [UInt8](repeating: 0, count: 64)
        let status = password.withUnsafeBufferPointer { pw in
            CCKeyDerivationPBKDF(
                CCPBKDFAlgorithm(kCCPBKDF2),
                pw.baseAddress.map { UnsafeRawPointer($0).assumingMemoryBound(to: Int8.self) }, pw.count,
                salt, salt.count,
                CCPseudoRandomAlgorithm(kCCPRFHmacAlgSHA512), 2048,
                &out, out.count)
        }
        guard status == kCCSuccess else { throw Failure.seedDerivation }
        return out
    }
}
