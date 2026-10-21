import Combine
import SwiftUI

/// The main screen: the lock, what is locked and for how long.
/// Lock more is easy; opening the lock takes a deliberate moment.
struct HomeView: View {
    @ObservedObject var model: AppModel
    @ObservedObject var engine: WalletEngine
    @ObservedObject var prices: PriceFeed
    let wallet: StoredWallet

    @State private var tilt: CGSize = .zero
    @State private var area: CGSize = .zero
    @Environment(\.colorScheme) private var scheme

    /// The plate on the lock: the value when a currency is chosen, else the state.
    private var plateText: String {
        if prices.currency != .none {
            if model.amountsHidden { return "≈ ••••" }
            return prices.value(of: engine.total) ?? "…"
        }
        return model.lockOpen ? "OPEN" : "LOCKED"
    }

    var body: some View {
        ZStack {
            VStack(spacing: 0) {
                ZStack(alignment: .top) {
                    HStack(alignment: .firstTextBaseline, spacing: 10) {
                        Text("ZECKY").font(Theme.text(13, weight: .semibold)).tracking(5.5).foregroundStyle(Theme.gold)
                        Text("Lock it").font(Theme.serif(15)).foregroundStyle(Theme.muted)
                    }
                    .padding(.top, 14)
                    .frame(maxWidth: .infinity)
                    .overlay(alignment: .trailing) {
                      HStack(spacing: 2) {
                        Button { model.themeMode = scheme == .dark ? .light : .dark } label: {
                            Image(systemName: scheme == .dark ? "sun.max" : "moon")
                                .font(.system(size: 14))
                                .foregroundStyle(Theme.muted)
                                .frame(width: 32, height: 32)
                                .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .help(scheme == .dark ? "Light theme" : "Dark theme")
                        .accessibilityLabel(scheme == .dark ? "Switch to light theme" : "Switch to dark theme")
                        Button { model.amountsHidden.toggle() } label: {
                            Image(systemName: model.amountsHidden ? "eye.slash" : "eye")
                                .font(.system(size: 14))
                                .foregroundStyle(Theme.muted)
                                .frame(width: 32, height: 32)
                                .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .help(model.amountsHidden ? "Show amounts" : "Hide amounts")
                        .accessibilityLabel(model.amountsHidden ? "Show amounts" : "Hide amounts")
                      }
                      .padding(.trailing, 14).padding(.top, 10)
                    }

                    VStack(spacing: 8) {
                        ZStack {
                            Medallion(tilt: tilt, diameter: 760)
                                .animation(.easeOut(duration: 0.6), value: tilt)
                                .frame(width: 330, height: 330)
                            MilestoneRing(progress: milestone?.progress ?? 0, diameter: 320)
                                .opacity(engine.lockedSince == nil ? 0.5 : 1)
                                .animation(.easeOut(duration: 1.2), value: milestone?.progress ?? 0)
                            Button { if !model.lockOpen && engine.status != .connecting { model.askToOpen() } } label: {
                                PadlockView(open: model.lockOpen, size: 212, tilt: tilt, plateText: plateText)
                                    .animation(.spring(response: 0.55, dampingFraction: 0.62), value: model.lockOpen)
                                    .animation(.easeOut(duration: 0.35), value: tilt)
                                    .contentShape(Rectangle())
                            }
                            .buttonStyle(.plain)
                            .help("Open the lock")
                            .accessibilityHint("Asks whether you really want to open the lock")
                            .offset(y: 6)
                        }
                        .frame(height: 330)

                        // The plate shows LOCKED / OPEN unless it shows the value.
                        if prices.currency != .none {
                            Text(model.lockOpen ? "OPEN" : "LOCKED")
                                .font(Theme.text(11, weight: .semibold)).tracking(1.6)
                                .foregroundStyle(model.lockOpen ? Theme.red : Theme.green)
                                .padding(.horizontal, 12).frame(height: 24)
                                .background((model.lockOpen ? Theme.red : Theme.green).opacity(0.15))
                                .clipShape(Capsule())
                                .padding(.top, 2)
                        }

                        Button { if !model.amountsHidden { model.unit = model.unit == .zec ? .zats : .zec } } label: {
                            VStack(spacing: 2) {
                                HStack(alignment: .firstTextBaseline, spacing: 10) {
                                    Text(balanceText).font(Theme.serif(balanceSize, weight: .medium))
                                        .lineLimit(1).minimumScaleFactor(0.5)
                                    Text(model.unit.rawValue).font(Theme.text(15, weight: .medium)).foregroundStyle(Theme.muted)
                                }
                            }
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .help(model.amountsHidden ? "" : "Click to show in \(model.unit == .zec ? "zats" : "ZEC")")
                        .accessibilityHint("Switches between ZEC and zats")

                        VStack(spacing: 3) {
                            Text(heldLine).font(Theme.text(13)).foregroundStyle(Theme.muted)
                            if let m = milestone, engine.lockedSince != nil {
                                Text("Next milestone: \(m.name) · in \(m.inDays) \(m.inDays == 1 ? "day" : "days")")
                                    .font(Theme.text(12, weight: .medium)).foregroundStyle(Theme.gold)
                            }
                        }
                        if engine.status == .upToDate && engine.total > engine.spendable {
                            Text(model.amountsHidden
                                 ? "Part of your balance locks in within a few minutes"
                                 : "\(Amount.text(engine.total - engine.spendable, model.unit)) locks in within a few minutes")
                                .font(Theme.text(12)).foregroundStyle(Theme.muted)
                        }

                        HStack(spacing: 12) {
                            PrimaryButton(title: "Lock more") { model.sheet = .receive }.frame(width: 160)
                            SecondaryButton(title: "Open the lock") { model.askToOpen() }
                                .background(Theme.ink.opacity(0.7), in: RoundedRectangle(cornerRadius: 8))
                                .frame(width: 160)
                        }
                        .disabled(engine.status == .connecting)
                        .padding(.top, 12)

                        if let last = engine.activity.first {
                            Button { model.sheet = .activity } label: {
                                HStack(spacing: 6) {
                                    Image(systemName: last.kind == .received ? "lock.fill" : "lock.open")
                                        .font(.system(size: 10))
                                    Text(lastLine(last))
                                    Image(systemName: "chevron.right").font(.system(size: 9, weight: .semibold))
                                }
                                .font(Theme.text(12))
                                .foregroundStyle(Theme.muted)
                                .contentShape(Rectangle())
                            }
                            .buttonStyle(.plain)
                            .help("Open Activity")
                            .padding(.top, 14)
                        }
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .padding(.top, 20)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .background(GeometryReader { geo in
                    Color.clear.onAppear { area = geo.size }.onChange(of: geo.size) { area = $0 }
                })
                .onContinuousHover { phase in
                    switch phase {
                    case .active(let point):
                        let w = max(area.width, 1), h = max(area.height, 1)
                        tilt = CGSize(width: (point.x / (w / 2) - 1).clamped, height: (point.y / (h / 2) - 1).clamped)
                    case .ended:
                        tilt = .zero
                    }
                }

                HStack {
                    HStack(spacing: 8) {
                        Circle().fill(dotColor).frame(width: 8, height: 8)
                        Text(statusText).font(Theme.text(12)).foregroundStyle(Theme.muted)
                        Text("·").foregroundStyle(Theme.muted.opacity(0.6))
                        Label("Shielded", systemImage: "shield.lefthalf.filled")
                            .labelStyle(.titleAndIcon)
                            .font(Theme.text(12)).foregroundStyle(Theme.muted)
                            .help("Lock it only uses shielded addresses: amounts, senders and receivers stay private on the blockchain.")
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
            // While "Really open the lock?" is up, nothing behind it can be
            // clicked, tabbed to or read out.
            .disabled(model.asking)
            .accessibilityHidden(model.asking)

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
            case .settings: SettingsView(model: model, prices: prices, wallet: wallet) { model.sheet = nil }
            case .activity: ActivitySheet(model: model, engine: engine) { model.sheet = nil }
            }
        }
    }

    /// Calendar days, so a payment from yesterday evening counts as 1 day.
    private var balanceText: String {
        model.amountsHidden ? Amount.hiddenText : Amount.number(engine.total, model.unit)
    }

    /// Long zats amounts shrink to stay on one line, like on iPhone.
    private var balanceSize: CGFloat {
        switch balanceText.count {
        case ...8: return 60
        case ...11: return 48
        case ...14: return 38
        default: return 30
        }
    }

    private var milestone: (name: String, inDays: Int, progress: Double)? {
        Milestone.next(after: heldDays ?? 0)
    }

    private func lastLine(_ item: WalletEngine.ActivityItem) -> String {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US")
        f.dateFormat = "MMM d"
        let what = item.kind == .received ? "Last locked" : "Last released"
        let when = item.date.map { f.string(from: $0) } ?? "waiting for a block"
        if model.amountsHidden { return "\(what) · \(when)" }
        let sign = item.kind == .received ? "+" : "−"
        return "\(what) \(sign)\(Amount.text(item.amount, model.unit)) · \(when)"
    }

    private var heldDays: Int? {
        guard let since = engine.lockedSince else { return nil }
        let cal = Calendar.current
        let days = cal.dateComponents([.day], from: cal.startOfDay(for: since), to: cal.startOfDay(for: Date())).day ?? 0
        return max(0, days)
    }

    private var heldLine: String {
        guard let since = engine.lockedSince, let days = heldDays else {
            return engine.total > 0 ? "Locked on this Mac" : "Nothing locked yet. Choose Lock more to begin."
        }
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US")
        f.dateFormat = "MMMM d, yyyy"
        if days == 0 { return "Locked since today" }
        return "Locked for \(days) \(days == 1 ? "day" : "days") · since \(f.string(from: since))"
    }

    private var statusText: String {
        switch engine.status {
        case .connecting: return "Connecting…"
        case .syncing(let pct): return pct >= 100 ? "Finishing…" : "Syncing \(pct)%"
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
            Theme.scrim.ignoresSafeArea()
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
        let held: String
        switch days {
        case .none: held = ""
        case .some(0): held = "This Zcash was locked today. "
        case .some(let d): held = "This Zcash has been locked for \(d) \(d == 1 ? "day" : "days"). "
        }
        return held + "Nobody legitimate will ever rush you, ask for your 24 words, or tell you to move your Zcash to keep it safe."
    }
}

/// Activity as its own sheet: the savings record.
struct ActivitySheet: View {
    @ObservedObject var model: AppModel
    @ObservedObject var engine: WalletEngine
    let onClose: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("Activity").font(Theme.serif(24, weight: .medium))
                Spacer()
                Button("Done", action: onClose).buttonStyle(HeaderButtonStyle()).keyboardShortcut(.cancelAction)
            }
            .padding(.horizontal, 28).padding(.top, 24)
            ActivityList(items: engine.activity, unit: model.unit, hidden: model.amountsHidden)
        }
        .frame(width: 540, height: 560)
        .background(Theme.ink)
        .foregroundStyle(Theme.text)
    }
}

/// Past payments, newest first. Quiet: no addresses, just what and when.
struct ActivityList: View {
    let items: [WalletEngine.ActivityItem]
    var unit: Amount.Unit = .zec
    var hidden = false

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
                        Text(hidden ? "Amount hidden" : "\(item.kind == .received ? "+" : "−")\(Amount.text(item.amount, unit))")
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
