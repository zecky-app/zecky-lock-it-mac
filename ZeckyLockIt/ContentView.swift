import SwiftUI
import ZcashLightClientKit

// Mac test build: asks one light-wallet server for the current block
// height through the official Zcash SDK. No wallet, no keys, no seed.
struct ContentView: View {
    @State private var status = "Asking eu.zec.rocks for the block height…"

    var body: some View {
        VStack(spacing: 8) {
            Text("Zecky Lock it")
                .font(.system(size: 28, weight: .medium, design: .serif))
            Text("Mac test build")
                .foregroundStyle(.secondary)
            Text(status)
                .font(.system(.body, design: .monospaced))
                .padding(.top, 12)
                .textSelection(.enabled)
        }
        .frame(minWidth: 420, minHeight: 280)
        .padding()
        .task { await checkHeight() }
    }

    private func checkHeight() async {
        do {
            let height = try await HeightCheck.latestHeight()
            status = "Block height: \(height.formatted(.number.grouping(.automatic).locale(Locale(identifier: "en_US"))))"
        } catch {
            status = "Failed: \(error)"
        }
    }
}

enum HeightCheck {
    static func latestHeight() async throws -> BlockHeight {
        let fm = FileManager.default
        // Inside the app sandbox this is the app's own container.
        let base = try fm.url(for: .applicationSupportDirectory, in: .userDomainMask, appropriateFor: nil, create: true)
            .appendingPathComponent("HeightCheck", isDirectory: true)
        try fm.createDirectory(at: base, withIntermediateDirectories: true)

        let initializer = Initializer(
            cacheDbURL: nil,
            fsBlockDbRoot: base.appendingPathComponent("fs_cache", isDirectory: true),
            generalStorageURL: base.appendingPathComponent("general", isDirectory: true),
            dataDbURL: base.appendingPathComponent("data.db"),
            torDirURL: base.appendingPathComponent("tor", isDirectory: true),
            endpoint: LightWalletEndpoint(address: "eu.zec.rocks", port: 443, secure: true),
            network: ZcashNetworkBuilder.network(for: .mainnet),
            spendParamsURL: base.appendingPathComponent("sapling-spend.params"),
            outputParamsURL: base.appendingPathComponent("sapling-output.params"),
            saplingParamsSourceURL: .default,
            loggingPolicy: .noLogging,
            isTorEnabled: false,
            isExchangeRateEnabled: false
        )
        let synchronizer = SDKSynchronizer(initializer: initializer)
        return try await synchronizer.latestHeight()
    }
}
