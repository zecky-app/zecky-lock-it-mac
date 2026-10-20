import SwiftUI

/// The main screen: balance and sync status. Quiet on purpose.
struct HomeView: View {
    @ObservedObject var engine: WalletEngine
    @State private var receiving = false

    var body: some View {
        VStack(spacing: 14) {
            Spacer()
            Text(Amount.zec(engine.total)).font(Theme.serif(56, weight: .medium))
            Text("ZEC").foregroundStyle(Theme.muted)
            if engine.total > engine.spendable {
                Text("\(Amount.zec(engine.total - engine.spendable)) ZEC available in a few minutes")
                    .font(.system(size: 13)).foregroundStyle(Theme.muted)
            }
            Spacer()
            HStack(spacing: 12) {
                SecondaryButton(title: "Receive") { receiving = true }.frame(width: 160)
            }
            .disabled(engine.status == .connecting)
            HStack(spacing: 8) {
                Circle().fill(dotColor).frame(width: 8, height: 8)
                Text(statusText).font(.system(size: 13)).foregroundStyle(Theme.muted)
            }
            .padding(.bottom, 24)
        }
        .frame(maxWidth: .infinity)
        .sheet(isPresented: $receiving) { ReceiveView(engine: engine) { receiving = false } }
    }

    private var statusText: String {
        switch engine.status {
        case .connecting: return "Connecting…"
        case .syncing(let pct): return "Syncing \(pct)%"
        case .upToDate: return "Up to date"
        case .failed(let text): return "Problem: \(text)"
        }
    }

    private var dotColor: Color {
        switch engine.status {
        case .upToDate: return Theme.green
        case .failed: return Theme.red
        default: return Theme.gold
        }
    }
}
