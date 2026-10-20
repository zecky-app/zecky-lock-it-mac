import CryptoKit
import Foundation
import Security

/// Everything that becomes a key starts here. Same rules as the iPhone app:
/// the system's secure generator is the only primary source, two draws are
/// checked, and any doubt stops wallet creation instead of quietly using
/// weaker randomness.
enum Entropy {
    enum Failure: Error, CustomStringConvertible {
        case generatorBroken
        case generatorRepeated
        case unsupportedLength

        var description: String {
            switch self {
            case .generatorBroken:
                return "This Mac’s secure random generator is not working correctly. For your safety no wallet was created."
            case .generatorRepeated:
                return "The secure random generator repeated itself. For your safety no wallet was created."
            case .unsupportedLength:
                return "Unsupported key length."
            }
        }
    }

    private static let lock = NSLock()
    private static var pool: [Double] = []
    private static var previous: [UInt8]?

    /// Call on user interaction. Cheap; feeds the second, weak source.
    static func noteEvent() {
        lock.lock(); defer { lock.unlock() }
        pool.append(ProcessInfo.processInfo.systemUptime)
        if pool.count > 64 { pool.removeFirst() }
    }

    private static func osRandom(_ count: Int) throws -> [UInt8] {
        var bytes = [UInt8](repeating: 0, count: count)
        guard SecRandomCopyBytes(kSecRandomDefault, count, &bytes) == errSecSuccess else {
            throw Failure.generatorBroken
        }
        return bytes
    }

    /// `length` bytes for key material: two draws from the secure generator,
    /// checked, then hashed together with the weak second source.
    static func secure(_ length: Int = 32) throws -> [UInt8] {
        guard (16...32).contains(length) else { throw Failure.unsupportedLength }
        let first = try osRandom(32)
        let second = try osRandom(32)
        // 32 truly random bytes all but always hold far more than 8 different values.
        if Set(first).count < 8 || Set(second).count < 8 || first == second { throw Failure.generatorBroken }
        lock.lock(); defer { lock.unlock() }
        if let previous, previous == first { throw Failure.generatorRepeated }
        previous = first
        let weak = (pool + [ProcessInfo.processInfo.systemUptime, Date().timeIntervalSince1970])
            .map { String($0) }.joined(separator: "|")
        var hasher = SHA256()
        hasher.update(data: Data("zecky-entropy-v1".utf8))
        hasher.update(data: first)
        hasher.update(data: second)
        hasher.update(data: Data(weak.utf8))
        return Array(Array(hasher.finalize()).prefix(length))
    }
}
