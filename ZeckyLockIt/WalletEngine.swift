import Combine
import Foundation
import ZcashLightClientKit

/// The light-wallet server. Same default as the iPhone app.
enum Server {
    static let host = "zec.rocks"
    static let port = 443
    static var endpoint: LightWalletEndpoint { LightWalletEndpoint(address: host, port: port, secure: true) }
}

/// Where the engine keeps its files: the app's own sandbox container,
/// excluded from Time Machine like the iPhone excludes iCloud backups.
enum WalletFiles {
    static func base(_ name: String) throws -> URL {
        let fm = FileManager.default
        var url = try fm.url(for: .applicationSupportDirectory, in: .userDomainMask, appropriateFor: nil, create: true)
            .appendingPathComponent(name, isDirectory: true)
        try fm.createDirectory(at: url, withIntermediateDirectories: true)
        var values = URLResourceValues()
        values.isExcludedFromBackup = true
        try url.setResourceValues(values)
        return url
    }

    static func initializer(base: URL, alias: ZcashSynchronizerAlias) -> Initializer {
        Initializer(
            cacheDbURL: nil,
            fsBlockDbRoot: base.appendingPathComponent("fs_cache", isDirectory: true),
            generalStorageURL: base.appendingPathComponent("general", isDirectory: true),
            dataDbURL: base.appendingPathComponent("data.db"),
            torDirURL: base.appendingPathComponent("tor", isDirectory: true),
            endpoint: Server.endpoint,
            network: ZcashNetworkBuilder.network(for: .mainnet),
            spendParamsURL: base.appendingPathComponent("sapling-spend.params"),
            outputParamsURL: base.appendingPathComponent("sapling-output.params"),
            saplingParamsSourceURL: .default,
            alias: alias,
            loggingPolicy: .noLogging,
            isTorEnabled: false,
            isExchangeRateEnabled: false
        )
    }
}

/// The chain height, asked once, without any wallet.
enum ChainTip {
    static func latest() async throws -> Int {
        let base = try WalletFiles.base("ChainTip")
        let synchronizer = SDKSynchronizer(initializer: WalletFiles.initializer(base: base, alias: .custom("chaintip")))
        return try await synchronizer.latestHeight()
    }
}

/// Runs the Zcash engine for the stored wallet and publishes what the
/// screens need: status and balance.
@MainActor
final class WalletEngine: ObservableObject {
    enum Status: Equatable {
        case connecting
        case syncing(Int)
        case upToDate
        case failed(String)
    }

    @Published private(set) var status: Status = .connecting
    @Published private(set) var spendable: Int64 = 0
    @Published private(set) var total: Int64 = 0

    private var synchronizer: SDKSynchronizer?
    private var cancellables = Set<AnyCancellable>()

    func start(_ wallet: StoredWallet) async {
        do {
            let base = try WalletFiles.base("Wallet")
            let synchronizer = SDKSynchronizer(initializer: WalletFiles.initializer(base: base, alias: .custom("zecky-main")))
            self.synchronizer = synchronizer
            synchronizer.stateStream
                .receive(on: DispatchQueue.main)
                .sink { [weak self] state in self?.apply(state) }
                .store(in: &cancellables)
            let seed = try Mnemonic.seed(from: wallet.phrase)
            _ = try await synchronizer.prepare(with: seed, walletBirthday: wallet.birthday, name: "Zecky", keySource: nil)
            try await synchronizer.start(retry: false)
        } catch {
            status = .failed(String(describing: error))
        }
    }

    func stop() {
        synchronizer?.stop()
        cancellables.removeAll()
        synchronizer = nil
    }

    private func apply(_ state: SynchronizerState) {
        switch state.syncStatus {
        case .unprepared: status = .connecting
        case .syncing(let progress, _): status = .syncing(Int((progress * 100).rounded(.down)))
        case .upToDate: status = .upToDate
        case .stopped: break
        case .error(let error): status = .failed(String(describing: error))
        }
        var spendable: Int64 = 0
        var total: Int64 = 0
        for balance in state.accountsBalances.values {
            for pool in [balance.saplingBalance, balance.orchardBalance, balance.ironwoodBalance] {
                spendable += pool.spendableValue.amount
                total += pool.total().amount
            }
            total += balance.unshielded.amount
        }
        self.spendable = spendable
        self.total = total
    }
}
