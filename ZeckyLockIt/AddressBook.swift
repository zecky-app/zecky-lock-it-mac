import Foundation
import ZcashLightClientKit

/// The private addresses each wallet has handed out, newest first, one list
/// per wallet on the key ring. Kept in the Keychain on this Mac only: anyone
/// holding a list could link payments to these addresses to you.
enum AddressBook {
    /// One list per wallet, by the wallet's id.
    private static let service = "app.zecky.lockit.mac.addressesByWallet"
    /// The earlier single list, shared by every wallet. It could hand one
    /// wallet's address out on another wallet's Receive, so it is dropped.
    private static let sharedService = "app.zecky.lockit.mac.addresses"

    private static func all() -> [String: [String]] {
        try? KeyStore.delete(service: sharedService)
        guard let data = (try? KeyStore.read(service: service)) ?? nil,
              let lists = try? JSONDecoder().decode([String: [String]].self, from: data) else { return [:] }
        return lists
    }

    private static func store(_ lists: [String: [String]]) {
        if let data = try? JSONEncoder().encode(lists) { try? KeyStore.save(data, service: service) }
    }

    static func load(_ wallet: AccountUUID) -> [String] { all()[KeyRingVault.hex(wallet)] ?? [] }

    static func save(_ list: [String], for wallet: AccountUUID) {
        var lists = all()
        lists[KeyRingVault.hex(wallet)] = list
        store(lists)
    }

    /// Forgets one wallet's list (when that wallet is erased).
    static func forget(_ wallet: AccountUUID) {
        var lists = all()
        lists[KeyRingVault.hex(wallet)] = nil
        store(lists)
    }

    static func clear() {
        try? KeyStore.delete(service: service)
        try? KeyStore.delete(service: sharedService)
    }

    /// The address to show for the wallet chosen on the key ring: its newest
    /// one never paid. Only when every one has been paid is a fresh one made.
    /// Addresses it was paid on but that are not in its list (after a
    /// restore) are added first. Every address comes from that wallet's own
    /// account in the engine.
    @MainActor
    static func addressToShow(engine: WalletEngine) async throws -> (wallet: AccountUUID, address: String) {
        guard let wallet = engine.currentAccount else { throw WalletEngine.EngineError.notReady }
        var list = load(wallet)
        let usage = try await engine.addressUsage(of: wallet)
        let discovered = usage.keys.filter { !list.contains($0) && $0.hasPrefix("u1") }.sorted()
        if !discovered.isEmpty { list.append(contentsOf: discovered); save(list, for: wallet) }
        if let unused = list.first(where: { (usage[$0] ?? 0) == 0 }) { return (wallet, unused) }
        let fresh = try await engine.freshShieldedAddress(of: wallet)
        list.insert(fresh, at: 0)
        save(list, for: wallet)
        return (wallet, fresh)
    }
}
