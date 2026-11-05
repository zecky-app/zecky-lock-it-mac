//
//  SealItCBOR.swift
//  Zecky Lock it (Mac) — Seal it / Keystone air-gapped signing
//
//  A deliberately tiny CBOR reader/writer for the two payloads we exchange
//  with an offline signer (Seal it, Keystone):
//
//    ur:zcash-accounts  {1: bytes(32) seed_fingerprint,
//                        2: [ #49203 {1: ufvk text, 2: index uint, 3?: name text, ...} ]}
//    ur:zcash-pczt      {1: bytes pczt}
//
//  Hand-rolled instead of DCBOR because DCBOR rejects anything that isn't
//  strictly deterministic CBOR, and a signer's encoder doesn't have to be.
//  Unknown map keys are ignored.
//

import Foundation

indirect enum ZCBOR {
    case uint(UInt64)
    case negative(UInt64)
    case bytes(Data)
    case text(String)
    case array([ZCBOR])
    case map([(key: ZCBOR, value: ZCBOR)])
    case tag(UInt64, ZCBOR)
    case simple(UInt8)

    /// Value for an unsigned-integer key in a map, or nil.
    func value(forKey key: UInt64) -> ZCBOR? {
        guard case let .map(entries) = untagged else { return nil }
        for entry in entries {
            if case let .uint(k) = entry.key, k == key { return entry.value }
        }
        return nil
    }

    /// Strips any number of tags.
    var untagged: ZCBOR {
        if case let .tag(_, inner) = self { return inner.untagged }
        return self
    }

    var bytesValue: Data? { if case let .bytes(d) = untagged { return d }; return nil }
    var textValue: String? { if case let .text(s) = untagged { return s }; return nil }
    var uintValue: UInt64? { if case let .uint(n) = untagged { return n }; return nil }
    var arrayValue: [ZCBOR]? { if case let .array(a) = untagged { return a }; return nil }
}

enum ZCBORError: LocalizedError {
    case truncated
    case unsupported(String)
    case trailingBytes

    var errorDescription: String? {
        switch self {
        case .truncated: return "The QR data ended too early."
        case .unsupported(let what): return "Unsupported data in the QR code: \(what)."
        case .trailingBytes: return "Unexpected extra data in the QR code."
        }
    }
}

// MARK: - Reading

enum ZCBORReader {
    static func decode(_ data: Data) throws -> ZCBOR {
        let bytes = [UInt8](data)
        var index = 0
        let item = try readItem(bytes, &index, depth: 0)
        guard index == bytes.count else { throw ZCBORError.trailingBytes }
        return item
    }

    private static func readArgument(_ b: [UInt8], _ i: inout Int, _ info: UInt8) throws -> UInt64 {
        func take(_ n: Int) throws -> UInt64 {
            guard i + n <= b.count else { throw ZCBORError.truncated }
            var v: UInt64 = 0
            for k in 0..<n { v = (v << 8) | UInt64(b[i + k]) }
            i += n
            return v
        }
        switch info {
        case 0..<24: return UInt64(info)
        case 24: return try take(1)
        case 25: return try take(2)
        case 26: return try take(4)
        case 27: return try take(8)
        default: throw ZCBORError.unsupported("indefinite length")
        }
    }

    private static func readItem(_ b: [UInt8], _ i: inout Int, depth: Int) throws -> ZCBOR {
        guard depth < 32 else { throw ZCBORError.unsupported("nesting too deep") }
        guard i < b.count else { throw ZCBORError.truncated }
        let initial = b[i]
        i += 1
        let major = initial >> 5
        let info = initial & 0x1f
        let arg = try readArgument(b, &i, info)

        func takeData(_ n: UInt64) throws -> Data {
            guard n <= UInt64(b.count - i) else { throw ZCBORError.truncated }
            let d = Data(b[i ..< i + Int(n)])
            i += Int(n)
            return d
        }

        switch major {
        case 0: return .uint(arg)
        case 1: return .negative(arg)
        case 2: return .bytes(try takeData(arg))
        case 3:
            guard let s = String(data: try takeData(arg), encoding: .utf8) else {
                throw ZCBORError.unsupported("invalid text")
            }
            return .text(s)
        case 4:
            guard arg <= UInt64(b.count) else { throw ZCBORError.truncated }
            var items: [ZCBOR] = []
            for _ in 0..<arg { items.append(try readItem(b, &i, depth: depth + 1)) }
            return .array(items)
        case 5:
            guard arg <= UInt64(b.count) else { throw ZCBORError.truncated }
            var entries: [(key: ZCBOR, value: ZCBOR)] = []
            for _ in 0..<arg {
                let k = try readItem(b, &i, depth: depth + 1)
                let v = try readItem(b, &i, depth: depth + 1)
                entries.append((key: k, value: v))
            }
            return .map(entries)
        case 6:
            return .tag(arg, try readItem(b, &i, depth: depth + 1))
        default: // 7: simple values (false, true, null); floats are not expected
            guard info <= 24 else { throw ZCBORError.unsupported("floats") }
            return .simple(UInt8(truncatingIfNeeded: arg))
        }
    }
}

// MARK: - Writing

enum ZCBORWriter {
    /// CBOR head with the shortest argument encoding (deterministic).
    static func head(major: UInt8, _ value: UInt64) -> Data {
        let m = major << 5
        var d = Data()
        switch value {
        case 0..<24:
            d.append(m | UInt8(value))
        case 24...0xff:
            d.append(m | 24); d.append(UInt8(value))
        case 0x100...0xffff:
            d.append(m | 25)
            d.append(contentsOf: [UInt8(value >> 8), UInt8(value & 0xff)])
        case 0x1_0000...0xffff_ffff:
            d.append(m | 26)
            d.append(contentsOf: (0..<4).reversed().map { UInt8((value >> (8 * UInt64($0))) & 0xff) })
        default:
            d.append(m | 27)
            d.append(contentsOf: (0..<8).reversed().map { UInt8((value >> (8 * UInt64($0))) & 0xff) })
        }
        return d
    }

    /// `{1: bytes(pczt)}`, the `ur:zcash-pczt` body. Starts with 0xa1 0x01, which Seal it checks.
    static func pcztEnvelope(_ pczt: Data) -> Data {
        var d = Data([0xa1, 0x01])
        d.append(head(major: 2, UInt64(pczt.count)))
        d.append(pczt)
        return d
    }
}
