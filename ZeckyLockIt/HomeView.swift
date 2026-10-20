import Combine
import SwiftUI

/// The main screen: the lock, what is locked and for how long.
/// Lock more is easy; opening the lock takes a deliberate moment.
struct HomeView: View {
    @ObservedObject var model: AppModel
    @ObservedObject var engine: WalletEngine
    let wallet: StoredWallet

    @State private var tilt: CGSize = .zero

    var body: some View {
        ZStack {
            VStack(spacing: 0) {
                VStack(spacing: 10) {
                    PadlockView(open: model.lockOpen, size: 190, tilt: tilt)
                        .animation(.spring(response: 0.55, dampingFraction: 0.62), value: model.lockOpen)
                        .animation(.easeOut(duration: 0.35), value: tilt)

                    Text(model.lockOpen ? "OPEN" : "LOCKED")
                        .font(Theme.text(12, weight: .semibold)).tracking(1.4)
                        .foregroundStyle(model.lockOpen ? Theme.red : Theme.green)
                        .padding(.horizontal, 14).frame(height: 28)
                        .background((model.lockOpen ? Theme.red : Theme.green).opacity(0.15))
                        .clipShape(Capsule())
                        .padding(.top, 6)

                    HStack(alignment: .firstTextBaseline, spacing: 12) {
                        Text(Amount.zec(engine.total)).font(Theme.serif(72, weight: .medium))
                        Text("ZEC").font(Theme.text(16, weight: .medium)).foregroundStyle(Theme.muted)
                    }
                    .padding(.top, 4)

                    Text(heldLine).font(Theme.text(14)).foregroundStyle(Theme.muted)
                    if engine.total > engine.spendable {
                        Text("\(Amount.zec(engine.total - engine.spendable)) ZEC locks in within a few minutes")
                            .font(Theme.text(13)).foregroundStyle(Theme.muted)
                    }

                    HStack(spacing: 12) {
                        PrimaryButton(title: "Lock more") { model.sheet = .receive }.frame(width: 170)
                        SecondaryButton(title: "Open the lock") { model.askToOpen() }.frame(width: 170)
                    }
                    .disabled(engine.status == .connecting)
                    .padding(.top, 18)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .background(
                    RadialGradient(colors: [Theme.gold.opacity(0.13), .clear], center: UnitPoint(x: 0.5, y: 0.36),
                                   startRadius: 0, endRadius: 330))
                .onContinuousHover { phase in
                    switch phase {
                    case .active(let point):
                        tilt = CGSize(width: (point.x / 380 - 1).clamped, height: (point.y / 300 - 1).clamped)
                    case .ended:
                        tilt = .zero
                    }
                }

                HStack {
                    HStack(spacing: 8) {
                        Circle().fill(dotColor).frame(width: 8, height: 8)
                        Text(statusText).font(Theme.text(12)).foregroundStyle(Theme.muted)
                    }
                    Spacer()
                    HStack(spacing: 20) {
                        Button("Activity") { model.sheet = .activity }
                        Button("Settings") { model.sheet = .settings }
                    }
                    .buttonStyle(.plain)
                    .font(Theme.text(12))
                    .foregroundStyle(Theme.muted)
                }
                .padding(.horizontal, 20)
                .frame(height: 44)
                .overlay(alignment: .top) { Rectangle().fill(Theme.surface).frame(height: 1) }
            }

            if model.asking {
                OpenLockPrompt(days: heldDays) { model.openLock() } onKeep: { model.keepLocked() }
                    .transition(.opacity)
            }
        }
        .animation(.easeInOut(duration: 0.2), value: model.asking)
        .sheet(item: $model.sheet, onDismiss: { model.sheetClosed() }) { sheet in
            switch sheet {
            case .receive: ReceiveView(engine: engine) { model.sheet = nil }
            case .send: SendView(engine: engine, phrase: wallet.phrase) { model.sheet = nil }
            case .settings: SettingsView(model: model, wallet: wallet) { model.sheet = nil }
            case .activity: ActivitySheet(engine: engine) { model.sheet = nil }
            }
        }
    }

    private var heldDays: Int? {
        guard let since = engine.lockedSince else { return nil }
        return max(0, Calendar.current.dateComponents([.day], from: since, to: Date()).day ?? 0)
    }

    private var heldLine: String {
        guard let since = engine.lockedSince, let days = heldDays else {
            return engine.total > 0 ? "Locked on this Mac" : "Nothing locked yet. Choose Lock more to begin."
        }
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US")
        f.dateFormat = "MMMM d, yyyy"
        return "Locked for \(days) \(days == 1 ? "day" : "days") · since \(f.string(from: since))"
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

private extension CGFloat {
    var clamped: CGFloat { Swift.min(1, Swift.max(-1, self)) }
}

/// "Really open the lock?": the safe choice is the main button, and
/// opening needs a tick and a short wait.
struct OpenLockPrompt: View {
    let days: Int?
    let onOpen: () -> Void
    let onKeep: () -> Void

    @State private var agreed = false
    @State private var countdown = 10
    private let timer = Timer.publish(every: 1, on: .main, in: .common).autoconnect()

    var body: some View {
        ZStack {
            Color(red: 0.04, green: 0.04, blue: 0.055).opacity(0.8).ignoresSafeArea()
                .onTapGesture {}
            VStack(alignment: .leading, spacing: 16) {
                Text("Really open the lock?").font(Theme.serif(32, weight: .medium))
                Text(intro).font(Theme.text(14)).foregroundStyle(Theme.muted)
                    .fixedSize(horizontal: false, vertical: true)
                Toggle(isOn: $agreed) {
                    Text("I am opening it myself, and nobody is telling me to.").font(Theme.text(14))
                }
                .toggleStyle(.checkbox)
                .padding(14)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(Theme.ink)
                .clipShape(RoundedRectangle(cornerRadius: 8))
                HStack(spacing: 12) {
                    PrimaryButton(title: "Keep it locked", action: onKeep)
                        .keyboardShortcut(.cancelAction)
                    SecondaryButton(title: countdown > 0 ? "Open in \(countdown) s" : "Open the lock") {
                        if agreed && countdown == 0 { onOpen() }
                    }
                    .opacity(agreed && countdown == 0 ? 1 : 0.45)
                }
                .padding(.top, 4)
            }
            .padding(.horizontal, 38).padding(.vertical, 34)
            .frame(width: 470)
            .background(Theme.surface)
            .clipShape(RoundedRectangle(cornerRadius: 14))
            .overlay(RoundedRectangle(cornerRadius: 14).stroke(Color.white.opacity(0.06)))
        }
        .onReceive(timer) { _ in if countdown > 0 { countdown -= 1 } }
    }

    private var intro: String {
        let held = days.map { "This Zcash has been locked for \($0) \($0 == 1 ? "day" : "days"). " } ?? ""
        return held + "Nobody legitimate will ever rush you, ask for your 24 words, or tell you to move your Zcash to keep it safe."
    }
}

/// Activity as its own sheet: the savings record.
struct ActivitySheet: View {
    @ObservedObject var engine: WalletEngine
    let onClose: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("Activity").font(Theme.serif(24, weight: .medium))
                Spacer()
                Button("Done", action: onClose).keyboardShortcut(.cancelAction)
            }
            .padding(.horizontal, 28).padding(.top, 24)
            ActivityList(items: engine.activity)
        }
        .frame(width: 540, height: 560)
        .background(Theme.ink)
        .foregroundStyle(Theme.text)
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
            if items.isEmpty {
                Text("Nothing locked or released yet.").font(Theme.text(13)).foregroundStyle(Theme.muted)
                    .padding(.horizontal, 28).padding(.top, 8)
                Spacer()
            } else {
                List(items) { item in
                    HStack {
                        Image(systemName: item.kind == .received ? "lock.fill" : "lock.open")
                            .foregroundStyle(item.kind == .received ? Theme.green : Theme.gold)
                            .frame(width: 18)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(item.kind == .received ? "Locked" : "Released").font(Theme.text(14, weight: .medium))
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
                .padding(.horizontal, 16)
            }
        }
        .frame(maxHeight: .infinity, alignment: .top)
    }

    private func subtitle(_ item: WalletEngine.ActivityItem) -> String {
        switch item.state {
        case .waiting: return "Waiting for a block"
        case .expired: return "Expired · never left the lock"
        case .confirmed: return item.date.map { Self.dateFormat.string(from: $0) } ?? "Confirmed"
        }
    }
}
