//
//  SealItUR.swift
//  Zecky Lock it (Mac) — Seal it / Keystone air-gapped signing
//
//  UR ("Uniform Resources", Blockchain Commons) framing for the QR codes.
//  Uses URKit's public fountain coder + bytewords, and our own ZCBOR for the
//  payload, so non-deterministic CBOR from a signer can't break decoding.
//
//  Fountain coder + Bytewords: URFountain.swift (vendored from URKit, BSD-2-Clause-Patent)
//

import Foundation
import ZcashLightClientKit


enum SealItURType {
    static let accounts = "zcash-accounts"
    static let pczt = "zcash-pczt"
}

enum SealItURError: LocalizedError {
    case notUR(seen: String)
    case wrongType(expected: String, got: String)
    case badSequence
    case missingField(String)
    case noAccounts
    case badViewingKey

    var errorDescription: String? {
        switch self {
        case .notUR(let seen):
            return seen.isEmpty
                ? "That QR code isn't from Cupcake or Keystone."
                : "That QR code isn't from Cupcake or Keystone (it starts with \"\(seen)…\")."
        case let .wrongType(expected, got):
            return expected == SealItURType.accounts
                ? "That's not the QR code for connecting a wallet (scanned \(got)). On Cupcake or Keystone, show that QR code."
                : "That's not the signed transaction (scanned \(got))."
        case .badSequence: return "Couldn't read the moving QR code. Hold the phone steady and try again."
        case .missingField(let f): return "The QR code is missing the \(f)."
        case .noAccounts: return "The QR code holds no accounts."
        case .badViewingKey: return "That QR code holds no valid Zcash viewing key (mainnet)."
        }
    }
}

// MARK: - Encoder (Mac screen -> signer camera)

/// Produces the frames of a (possibly animated) UR QR code. Call `nextPart()` on a timer.
final class SealItUREncoder {
    let type: String
    private let fountain: FountainEncoder
    private let singlePart: String?
    /// Cupcake's reader (seen 22 Nov 2026) only takes the sequenced form
    /// "ur:type/1-1/…", even for one frame, and compares the type in lower
    /// case. For Cupcake wallets every frame is sequenced and lower case,
    /// and only the n plain frames are shown, over and over.
    let forCupcake: Bool

    /// Keystone and Zashi use 200; Seal it returns 200 as well.
    init(type: String, message: Data, maxFragmentLen: Int = 200, forCupcake: Bool = false) {
        let fountain = FountainEncoder(message: message, maxFragmentLen: maxFragmentLen)
        self.type = type
        self.fountain = fountain
        self.forCupcake = forCupcake
        self.singlePart = fountain.isSinglePart && !forCupcake
            ? "ur:\(type)/" + Bytewords.encode(message, style: .minimal)
            : nil
    }

    var isSinglePart: Bool { singlePart != nil }
    var fragmentCount: Int { fountain.seqLen }

    /// Upper-case so the QR uses the denser alphanumeric mode (UR is case-insensitive).
    func nextPart() -> String {
        if let singlePart { return singlePart.uppercased() }
        // Cupcake counts distinct frames and finishes at exactly n of n,
        // so it never takes the mixed frames after n: loop 1…n for it.
        if forCupcake, fountain.seqNum >= UInt32(fountain.seqLen) { fountain.seqNum = 0 }
        let part = fountain.nextPart()
        let body = Bytewords.encode(part.cbor, style: .minimal)
        let frame = "ur:\(type)/\(part.seqNum)-\(part.seqLen)/\(body)"
        return forCupcake ? frame : frame.uppercased()
    }

    static func pczt(_ pczt: Data, forCupcake: Bool = false) -> SealItUREncoder {
        SealItUREncoder(type: SealItURType.pczt, message: ZCBORWriter.pcztEnvelope(pczt), forCupcake: forCupcake)
    }
}

// MARK: - Decoder (signer screen -> Mac camera)

/// Feed every scanned QR string in; when `message` is non-nil the UR is complete.
final class SealItURDecoder {
    let expectedType: String
    private var fountain = FountainDecoder()
    private(set) var message: Data?

    init(expectedType: String) {
        self.expectedType = expectedType
    }

    var progress: Double {
        if message != nil { return 1 }
        return fountain.estimatedPercentComplete
    }

    func reset() {
        fountain = FountainDecoder()
        message = nil
    }

    /// Returns true once the full message has been received.
    @discardableResult
    func receive(_ raw: String) throws -> Bool {
        if message != nil { return true }
        // Cupcake shows its account as a plain QR, not a UR:
        // zcash-wallet:?label=<name>&private_key=<UFVK> (Cake Wallet's format).
        let plain = raw.trimmingCharacters(in: .whitespacesAndNewlines.union(.controlCharacters))
        if expectedType == SealItURType.accounts, plain.lowercased().hasPrefix("zcash-wallet:") {
            message = Data(plain.utf8)
            return true
        }
        // Tolerate stray bytes around the code (some scanners add a BOM or
        // control characters to binary-mode QR codes).
        let lowered = raw.lowercased()
        guard let start = lowered.range(of: "ur:") else {
            let seen = String(raw.unicodeScalars.filter { $0.value >= 0x20 && $0.value < 0x7f }.prefix(24).map(Character.init))
            throw SealItURError.notUR(seen: seen)
        }
        let s = String(lowered[start.lowerBound...])
            .trimmingCharacters(in: .whitespacesAndNewlines.union(.controlCharacters))
        let components = s.dropFirst(3).split(separator: "/").map(String.init)
        guard let type = components.first else { throw SealItURError.notUR(seen: "") }
        guard type == expectedType else {
            throw SealItURError.wrongType(expected: expectedType, got: type)
        }

        switch components.count {
        case 2: // single part: ur:type/body
            message = try Bytewords.decode(components[1], style: .minimal)
            return true

        case 3: // multi part: ur:type/seq-len/body
            let seq = components[1].split(separator: "-")
            guard seq.count == 2, let seqNum = UInt32(seq[0]), let seqLen = Int(seq[1]),
                  (1...FountainEncoder.Part.maxSeqLen).contains(seqLen) else {
                throw SealItURError.badSequence
            }
            let partCBOR = try Bytewords.decode(components[2], style: .minimal)
            let part = try FountainEncoder.Part(cbor: partCBOR)
            guard part.seqNum == seqNum, part.seqLen == seqLen else { return false }
            _ = fountain.receivePart(part)
            switch fountain.result {
            case .success(let data)?:
                message = data
                return true
            case .failure?:
                reset()
                throw SealItURError.badSequence
            case nil:
                return false
            }

        default:
            throw SealItURError.badSequence
        }
    }
}

// MARK: - Payloads

struct SealItAccountExport {
    struct Account {
        let ufvk: String
        let index: UInt32
        let name: String?
    }
    /// None for Cupcake, whose QR carries only the viewing key.
    let seedFingerprint: [UInt8]?
    let accounts: [Account]
    var fromCupcake: Bool { seedFingerprint == nil }
}

enum SealItPayload {
    /// Parses `ur:zcash-accounts` (Keystone registry, emitted by Seal it and Keystone).
    static func parseAccounts(_ message: Data) throws -> SealItAccountExport {
        if let text = String(data: message, encoding: .utf8), text.lowercased().hasPrefix("zcash-wallet:") {
            return try parseCupcake(text)
        }
        let root = try ZCBORReader.decode(message)
        guard let fingerprint = root.value(forKey: 1)?.bytesValue else {
            throw SealItURError.missingField("seed fingerprint")
        }
        guard let list = root.value(forKey: 2)?.arrayValue else {
            throw SealItURError.missingField("accounts")
        }
        let accounts: [SealItAccountExport.Account] = list.compactMap { item in
            // #49203 zcash-unified-full-viewing-key
            guard let ufvk = item.value(forKey: 1)?.textValue else { return nil }
            let index = UInt32(truncatingIfNeeded: item.value(forKey: 2)?.uintValue ?? 0)
            return .init(ufvk: ufvk, index: index, name: item.value(forKey: 3)?.textValue)
        }
        guard !accounts.isEmpty else { throw SealItURError.noAccounts }
        return SealItAccountExport(seedFingerprint: [UInt8](fingerprint), accounts: accounts)
    }

    /// Cupcake's account QR: `zcash-wallet:?label=<name>&private_key=<UFVK>`.
    /// The "private_key" is a viewing key (it cannot spend); it must be a
    /// valid mainnet unified full viewing key. No seed fingerprint or account
    /// number: Cupcake signs with its own account.
    static func parseCupcake(_ text: String) throws -> SealItAccountExport {
        guard let parts = URLComponents(string: text), parts.scheme?.lowercased() == "zcash-wallet",
              let ufvk = parts.queryItems?.first(where: { $0.name == "private_key" })?.value,
              (try? UnifiedFullViewingKey(encoding: ufvk, network: .mainnet)) != nil
        else { throw SealItURError.badViewingKey }
        let label = parts.queryItems?.first(where: { $0.name == "label" })?.value?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let name = (label?.isEmpty == false ? label! : "Cupcake").prefix(40)
        return SealItAccountExport(seedFingerprint: nil, accounts: [.init(ufvk: ufvk, index: 0, name: String(name))])
    }

    /// Parses `ur:zcash-pczt` -> raw PCZT bytes.
    static func parsePczt(_ message: Data) throws -> Data {
        let root = try ZCBORReader.decode(message)
        guard let pczt = root.value(forKey: 1)?.bytesValue else {
            throw SealItURError.missingField("signed transaction")
        }
        return pczt
    }
}

// MARK: - Cupcake's PCZT layout

/// Cupcake (Cake Wallet's offline signer, built on Zkool) reads and writes
/// PCZTs with the Zcash Shielded Assets branch of the pczt crate. Its layout
/// is the standard one (pczt 0.10, which Lock it, Zashi and Keystone use)
/// plus empty fields for assets:
///  - every Orchard/Ironwood spend: `rseed_split_note` after `rseed`, and
///    `asset` at the end;
///  - every Orchard/Ironwood output: `asset` at the end;
///  - the v2 encoding: an `issue` bundle at the very end.
/// Global, transparent and Sapling parts are the same byte for byte.
///
/// The PCZT is postcard: no field names, so this walks the whole layout and
/// copies it, adding the empty fields on the way to Cupcake and taking them
/// out of its signed reply. A filled-in asset or issue field means a ZSA
/// payment, which Lock it does not make, so it is refused rather than dropped.
/// Checked against both crates (pczt 0.10.0 and zcash-shielded-assets
/// librustzcash fb3b4de, which Cupcake 1.2.0 pins) with the vectors in the tests.
enum CupcakePczt {
    enum Failure: Error, LocalizedError, Equatable {
        case notPczt, unknownVersion(UInt32), truncated, trailingBytes, tooLong, zsaContent(String)
        var errorDescription: String? {
            switch self {
            case .notPczt: return "That is not a PCZT."
            case .unknownVersion(let v): return "Unknown PCZT version \(v)."
            case .truncated: return "The PCZT ends too early."
            case .trailingBytes: return "The PCZT has bytes after its end."
            case .tooLong: return "A number in the PCZT is too long."
            case .zsaContent(let field): return "Cupcake signed something with \(field), which Lock it does not send. Nothing was sent."
            }
        }
    }

    /// Lock it's PCZT, in the layout Cupcake reads.
    static func toCupcake(_ pczt: Data) throws -> Data {
        var walker = Walker(pczt, toCupcake: true)
        return try walker.run()
    }

    /// Cupcake's signed PCZT, back in the standard layout.
    static func fromCupcake(_ pczt: Data) throws -> Data {
        var walker = Walker(pczt, toCupcake: false)
        return try walker.run()
    }

    private struct Walker {
        let input: [UInt8]
        let toCupcake: Bool
        var at = 0
        var out: [UInt8] = []

        init(_ data: Data, toCupcake: Bool) {
            input = [UInt8](data); self.toCupcake = toCupcake
            out.reserveCapacity(input.count + 256)
        }

        mutating func run() throws -> Data {
            guard input.count >= 8, Array(input[0..<4]) == Array("PCZT".utf8) else { throw Failure.notPczt }
            let version = UInt32(input[4]) | UInt32(input[5]) << 8 | UInt32(input[6]) << 16 | UInt32(input[7]) << 24
            try raw(8)
            switch version {
            case 1:
                try global(); try transparent(); try sapling(v2: false); try orchard(v2: false)
            case 2:
                try global()
                try option { try $0.transparent() }
                try option { try $0.sapling(v2: true) }
                try option { try $0.orchard(v2: true) }   // Orchard
                try option { try $0.orchard(v2: true) }   // Ironwood
                try added("an asset issuance")             // issue
            default:
                throw Failure.unknownVersion(version)
            }
            guard at == input.count else { throw Failure.trailingBytes }
            return Data(out)
        }

        // MARK: postcard

        mutating func raw(_ n: Int) throws {
            guard n >= 0, input.count - at >= n else { throw Failure.truncated }
            out.append(contentsOf: input[at..<(at + n)]); at += n
        }

        /// Copies a varint and returns it. `max` bytes: 5 for u32, 10 for u64, 19 for i128.
        @discardableResult
        mutating func varint(max: Int = 10) throws -> UInt64 {
            var value: UInt64 = 0
            for i in 0..<max {
                guard at < input.count else { throw Failure.truncated }
                let byte = input[at]; at += 1; out.append(byte)
                if i < 10 { value |= UInt64(byte & 0x7f) << (7 * UInt64(i)) }
                if byte & 0x80 == 0 { return value }
            }
            throw Failure.tooLong
        }

        mutating func length() throws -> Int {
            let n = try varint()
            guard n <= UInt64(input.count - at) else { throw Failure.truncated }   // every item is at least a byte
            return Int(n)
        }

        mutating func bytes() throws { try raw(try length()) }   // Vec<u8>, String

        mutating func option(_ body: (inout Walker) throws -> Void) throws {
            guard at < input.count else { throw Failure.truncated }
            let tag = input[at]
            guard tag <= 1 else { throw Failure.notPczt }
            try raw(1)
            if tag == 1 { try body(&self) }
        }

        mutating func list(_ body: (inout Walker) throws -> Void) throws {
            for _ in 0..<(try length()) { try body(&self) }
        }

        /// A field only Cupcake's layout has: written as None for Cupcake,
        /// and must be None when read back.
        mutating func added(_ what: String) throws {
            if toCupcake { out.append(0); return }
            guard at < input.count else { throw Failure.truncated }
            guard input[at] == 0 else { throw Failure.zsaContent(what) }
            at += 1
        }

        mutating func opt32() throws { try option { try $0.raw(32) } }
        mutating func u32() throws { try varint(max: 5) }
        mutating func optU32() throws { try option { try $0.u32() } }
        mutating func proprietary() throws { try list { try $0.bytes(); try $0.bytes() } }   // BTreeMap<String, Vec<u8>>
        mutating func zip32() throws { try raw(32); try list { try $0.u32() } }
        mutating func witness() throws { try option { try $0.u32(); try $0.raw(32 * 32) } }

        // MARK: layout (pczt 0.10)

        mutating func global() throws {
            try u32(); try u32(); try u32()   // tx version, version group, branch
            try optU32()                      // fallback lock time
            try u32(); try u32()              // expiry height, coin type
            try raw(1)                        // tx modifiable
            try proprietary()
        }

        mutating func transparent() throws {
            try list { w in   // inputs
                try w.raw(32); try w.u32()
                try w.optU32(); try w.optU32(); try w.optU32()
                try w.option { try $0.bytes() }   // script sig
                try w.varint()                    // value
                try w.bytes()                     // script pubkey
                try w.option { try $0.bytes() }   // redeem script
                try w.list { try $0.raw(33); try $0.bytes() }   // partial signatures
                try w.raw(1)                                     // sighash type
                try w.list { try $0.raw(33); try $0.zip32() }    // bip32 derivation
                try w.list { try $0.raw(20); try $0.bytes() }    // ripemd160 preimages
                try w.list { try $0.raw(32); try $0.bytes() }    // sha256
                try w.list { try $0.raw(20); try $0.bytes() }    // hash160
                try w.list { try $0.raw(32); try $0.bytes() }    // hash256
                try w.proprietary()
            }
            try list { w in   // outputs
                try w.varint(); try w.bytes()
                try w.option { try $0.bytes() }
                try w.list { try $0.raw(33); try $0.zip32() }
                try w.option { try $0.bytes() }   // user address
                try w.proprietary()
            }
        }

        mutating func sapling(v2: Bool) throws {
            try list { w in   // spends
                try w.raw(96)                                // cv, nullifier, rk
                try w.option { try $0.raw(192) }             // proof
                try w.option { try $0.raw(64) }              // spend auth sig
                try w.option { try $0.raw(43) }              // recipient
                try w.option { try $0.varint() }             // value
                try w.opt32(); try w.opt32(); try w.opt32()  // rcm, rseed, rcv
                try w.option { try $0.raw(64) }              // proof generation key
                try w.witness(); try w.opt32()               // witness, alpha
                try w.option { try $0.zip32() }
                try w.opt32()                                // dummy ask
                try w.proprietary()
            }
            try list { w in   // outputs
                try w.raw(96)                                // cv, cmu, ephemeral key
                try w.bytes(); try w.bytes()                 // enc, out ciphertext
                try w.option { try $0.raw(192) }
                try w.option { try $0.raw(43) }
                try w.option { try $0.varint() }
                try w.opt32(); try w.opt32(); try w.opt32()  // rseed, rcv, ock
                try w.option { try $0.zip32() }
                try w.option { try $0.bytes() }              // user address
                try w.proprietary()
            }
            try varint(max: 19)                              // value sum (i128)
            if v2 { try opt32() } else { try raw(32) }       // anchor
            try opt32()                                      // bsk
        }

        mutating func orchard(v2: Bool) throws {
            try list { w in   // actions
                if v2 { try w.opt32() } else { try w.raw(32) }                       // cv net
                // spend
                if v2 { try w.opt32(); try w.opt32() } else { try w.raw(64) }       // nullifier, rk
                try w.option { try $0.raw(64) }              // spend auth sig
                try w.option { try $0.raw(43) }              // recipient
                try w.option { try $0.varint() }             // value
                try w.opt32(); try w.opt32()                 // rho, rseed
                try w.added("a split note")                  // rseed_split_note
                try w.option { try $0.raw(96) }              // fvk
                try w.witness(); try w.opt32()               // witness, alpha
                try w.option { try $0.zip32() }
                try w.opt32()                                // dummy sk
                try w.proprietary()
                try w.added("an asset")                      // asset
                // output
                if v2 { try w.opt32() } else { try w.raw(32) }                       // cmx
                try w.raw(32)                                // ephemeral key
                if v2 {                                      // EncCiphertext: Encrypted | MemoPlaintext, both bytes
                    guard try w.varint(max: 5) <= 1 else { throw Failure.notPczt }
                }
                try w.bytes(); try w.bytes()                 // enc, out ciphertext
                try w.option { try $0.raw(43) }
                try w.option { try $0.varint() }
                try w.opt32(); try w.opt32()                 // rseed, ock
                try w.option { try $0.zip32() }
                try w.option { try $0.bytes() }              // user address
                try w.proprietary()
                try w.added("an asset")                      // asset
                try w.opt32()                                // rcv
            }
            try raw(1)                                       // flags
            try varint(); try raw(1)                         // value sum (u64, bool)
            if v2 {
                try opt32()                                  // anchor
                guard try varint(max: 5) <= 1 else { throw Failure.zsaContent("a ZSA note version") }   // V2 | V3
            } else {
                try raw(32)
            }
            try option { try $0.bytes() }                    // proof
            try opt32()                                      // bsk
        }
    }
}
