import Foundation

/// The private addresses this wallet has handed out, newest first. Kept in
/// the Keychain on this Mac only: anyone holding the list could link
/// payments to these addresses to you.
enum AddressBook {
    private static let service = "app.zecky.lockit.mac.addresses"

    static func load() -> [String] {
        guard let data = (try? KeyStore.read(service: service)) ?? nil,
              let list = try? JSONDecoder().decode([String].self, from: data) else { return [] }
        return list
    }

    static func save(_ list: [String]) {
        if let data = try? JSONEncoder().encode(list) { try? KeyStore.save(data, service: service) }
    }

    static func clear() { try? KeyStore.delete(service: service) }

    /// The address to show: the newest one never paid. Only when every one
    /// has been paid is a fresh one made. Addresses the wallet was paid on
    /// but that are not in the list (after a restore) are added first.
    @MainActor
    static func addressToShow(engine: WalletEngine) async throws -> String {
        var list = load()
        let usage = try await engine.addressUsage()
        let discovered = usage.keys.filter { !list.contains($0) && $0.hasPrefix("u1") }.sorted()
        if !discovered.isEmpty { list.append(contentsOf: discovered); save(list) }
        if let unused = list.first(where: { (usage[$0] ?? 0) == 0 }) { return unused }
        let fresh = try await engine.freshShieldedAddress()
        list.insert(fresh, at: 0)
        save(list)
        return fresh
    }
}
