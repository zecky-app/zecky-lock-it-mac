import Foundation

/// Checks the wallet building blocks against known answers. Uses only
/// public BIP39 test vectors and fresh random values: never a real phrase,
/// and nothing is stored or shown.
enum WalletSelfTest {
    private struct Vector { let entropy: [UInt8]; let phrase: String; let seedHex: String }

    // Official BIP39 vectors (passphrase "TREZOR").
    private static let vectors: [Vector] = [
        Vector(entropy: [UInt8](repeating: 0x00, count: 16),
               phrase: "abandon abandon abandon abandon abandon abandon abandon abandon abandon abandon abandon about",
               seedHex: "c55257c360c07c72029aebc1b53c05ed0362ada38ead3e3e9efa3708e53495531f09a6987599d18264c1e1c92f2cf141630c7a3c4ab7c81b2f001698e7463b04"),
        Vector(entropy: [UInt8](repeating: 0x7f, count: 32),
               phrase: "legal winner thank year wave sausage worth useful legal winner thank year wave sausage worth useful legal winner thank year wave sausage worth title",
               seedHex: "bc09fca1804f7e69da93c2f2028eb238c227f2e9dda30cd63699232578480a4021b146ad717fbb7e451ce9eb835f43620bf5c514db0f8add49f5d121449d3e87"),
        Vector(entropy: [UInt8](repeating: 0xff, count: 32),
               phrase: Array(repeating: "zoo", count: 23).joined(separator: " ") + " vote",
               seedHex: "dd48c104698c30cfe2b6142103248622fb7bb0ff692eebb00089b32d22484e1613912f0a5b694407be899ffd31ed3992c456cdf60f5d4564b8ba3f05a69890ad"),
    ]

    static func run() -> String {
        do {
            for (i, v) in vectors.enumerated() {
                guard try Mnemonic.phrase(from: v.entropy) == v.phrase else { return "Wallet: vector \(i + 1) words differ" }
                let seed = try Mnemonic.seed(from: v.phrase, passphrase: "TREZOR")
                guard seed.map({ String(format: "%02x", $0) }).joined() == v.seedHex else { return "Wallet: vector \(i + 1) seed differs" }
            }
            // A wrong last word must be refused.
            let broken = Array(repeating: "abandon", count: 12).joined(separator: " ")
            guard !Mnemonic.isValid(broken) else { return "Wallet: accepted an invalid phrase" }
            // Fresh phrases: 24 valid words, never the same twice.
            let a = try Mnemonic.phrase(from: Entropy.secure(32))
            let b = try Mnemonic.phrase(from: Entropy.secure(32))
            guard a.split(separator: " ").count == 24, Mnemonic.isValid(a), Mnemonic.isValid(b), a != b else {
                return "Wallet: new phrase check failed"
            }
            // Birthday estimates match the iPhone app's numbers.
            let now = DateComponents(calendar: Calendar(identifier: .gregorian), timeZone: TimeZone(identifier: "UTC"),
                                     year: 2026, month: 10, day: 20, hour: 12).date!
            let got = [Birthday.estimate(year: 2024, month: 1, tip: 3_524_515, now: now),
                       Birthday.estimate(year: 2019, month: 6, tip: 3_524_515, now: now),
                       Birthday.estimate(year: 2026, month: 10, tip: 3_524_515, now: now),
                       Birthday.estimate(year: 2016, month: 1, tip: 3_524_515, now: now)]
            guard got == [2_308_070, 536_652, 3_499_377, 419_200] else { return "Wallet: birthday estimates differ \(got)" }
            return "Wallet: OK (BIP39 vectors, new phrases, birthdays)"
        } catch {
            return "Wallet: \(error)"
        }
    }
}
