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

    var errorDescription: String? {
        switch self {
        case .notUR(let seen):
            return seen.isEmpty
                ? "That QR code isn't from Seal it."
                : "That QR code isn't from Seal it (it starts with \"\(seen)…\")."
        case let .wrongType(expected, got):
            return expected == SealItURType.accounts
                ? "That's not the account QR code (scanned \(got)). In Seal it, show the account QR."
                : "That's not the signed transaction (scanned \(got))."
        case .badSequence: return "Couldn't read the moving QR code. Hold the phone steady and try again."
        case .missingField(let f): return "The QR code is missing the \(f)."
        case .noAccounts: return "The QR code holds no accounts."
        }
    }
}

// MARK: - Encoder (Mac screen -> signer camera)

/// Produces the frames of a (possibly animated) UR QR code. Call `nextPart()` on a timer.
final class SealItUREncoder {
    let type: String
    private let fountain: FountainEncoder
    private let singlePart: String?

    /// Keystone and Zashi use 200; Seal it returns 200 as well.
    init(type: String, message: Data, maxFragmentLen: Int = 200) {
        let fountain = FountainEncoder(message: message, maxFragmentLen: maxFragmentLen)
        self.type = type
        self.fountain = fountain
        self.singlePart = fountain.isSinglePart
            ? "ur:\(type)/" + Bytewords.encode(message, style: .minimal)
            : nil
    }

    var isSinglePart: Bool { singlePart != nil }
    var fragmentCount: Int { fountain.seqLen }

    /// Upper-case so the QR uses the denser alphanumeric mode (UR is case-insensitive).
    func nextPart() -> String {
        if let singlePart { return singlePart.uppercased() }
        let part = fountain.nextPart()
        let body = Bytewords.encode(part.cbor, style: .minimal)
        return "ur:\(type)/\(part.seqNum)-\(part.seqLen)/\(body)".uppercased()
    }

    static func pczt(_ pczt: Data) -> SealItUREncoder {
        SealItUREncoder(type: SealItURType.pczt, message: ZCBORWriter.pcztEnvelope(pczt))
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
            guard seq.count == 2, let seqNum = UInt32(seq[0]), let seqLen = Int(seq[1]) else {
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
    let seedFingerprint: [UInt8]
    let accounts: [Account]
}

enum SealItPayload {
    /// Parses `ur:zcash-accounts` (Keystone registry, emitted by Seal it and Keystone).
    static func parseAccounts(_ message: Data) throws -> SealItAccountExport {
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

    /// Parses `ur:zcash-pczt` -> raw PCZT bytes.
    static func parsePczt(_ message: Data) throws -> Data {
        let root = try ZCBORReader.decode(message)
        guard let pczt = root.value(forKey: 1)?.bytesValue else {
            throw SealItURError.missingField("signed transaction")
        }
        return pczt
    }
}
