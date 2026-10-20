import SwiftUI

/// The main screen: balance, the three actions, Activity and sync status.
struct HomeView: View {
    @ObservedObject var model: AppModel
    @ObservedObject var engine: WalletEngine
    let wallet: StoredWallet

    var body: some View {
        VStack(spacing: 0) {
            VStack(spacing: 6) {
                Text(Amount.zec(engine.total)).font(Theme.serif(56, weight: .medium))
                Text("ZEC").font(Theme.text(13, weight: .medium)).foregroundStyle(Theme.muted)
                if engine.total > engine.spendable {
                    Text("\(Amount.zec(engine.total - engine.spendable)) ZEC available in a few minutes")
                        .font(Theme.text(13)).foregroundStyle(Theme.muted)
                }
            }
            .padding(.top, 36)

            HStack(spacing: 12) {
                SecondaryButton(title: "Receive") { model.sheet = .receive }.frame(width: 150)
                SecondaryButton(title: "Send") { model.sheet = .send }.frame(width: 150)
                SecondaryButton(title: "Settings") { model.sheet = .settings }.frame(width: 150)
            }
            .disabled(engine.status == .connecting)
            .padding(.vertical, 24)

            ActivityList(items: engine.activity)

            HStack(spacing: 8) {
                Circle().fill(dotColor).frame(width: 8, height: 8)
                Text(statusText).font(Theme.text(12)).foregroundStyle(Theme.muted)
            }
            .padding(.vertical, 14)
        }
        .frame(maxWidth: .infinity)
        .sheet(item: $model.sheet) { sheet in
            switch sheet {
            case .receive: ReceiveView(engine: engine) { model.sheet = nil }
            case .send: SendView(engine: engine, phrase: wallet.phrase) { model.sheet = nil }
            case .settings: SettingsView(model: model, wallet: wallet) { model.sheet = nil }
            }
        }
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

/// Past payments, newest first. Quiet: no addresses, just what and when.
struct ActivityList: View {
    let items: [WalletEngine.ActivityItem]

    private static let dateFormat: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US")
        f.dateFormat = "MMM d, yyyy · h:mm a"
        return f
    }()

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text("ACTIVITY").font(Theme.text(11, weight: .semibold)).tracking(1.2).foregroundStyle(Theme.muted)
                .padding(.horizontal, 32).padding(.bottom, 8)
            if items.isEmpty {
                Text("No payments yet.").font(Theme.text(13)).foregroundStyle(Theme.muted)
                    .padding(.horizontal, 32).padding(.top, 8)
                Spacer()
            } else {
                List(items) { item in
                    HStack {
                        Image(systemName: item.kind == .received ? "arrow.down.left" : "arrow.up.right")
                            .foregroundStyle(item.kind == .received ? Theme.green : Theme.gold)
                            .frame(width: 18)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(item.kind == .received ? "Received" : "Sent").font(Theme.text(14, weight: .medium))
                            Text(subtitle(item)).font(Theme.text(12)).foregroundStyle(Theme.muted)
                        }
                        Spacer()
                        Text("\(item.kind == .received ? "+" : "−")\(Amount.zec(item.amount)) ZEC")
                            .font(Theme.text(14, weight: .medium))
                            .foregroundStyle(item.state == .expired ? Theme.muted : Theme.text)
                            .strikethrough(item.state == .expired)
                    }
                    .padding(.vertical, 4)
                    .listRowBackground(Color.clear)
                    .listRowSeparatorTint(Theme.muted.opacity(0.2))
                }
                .listStyle(.plain)
                .scrollContentBackground(.hidden)
                .padding(.horizontal, 20)
            }
        }
        .frame(maxHeight: .infinity, alignment: .top)
    }

    private func subtitle(_ item: WalletEngine.ActivityItem) -> String {
        switch item.state {
        case .waiting: return "Waiting for a block"
        case .expired: return "Expired · never left your wallet"
        case .confirmed: return item.date.map { Self.dateFormat.string(from: $0) } ?? "Confirmed"
        }
    }
}
