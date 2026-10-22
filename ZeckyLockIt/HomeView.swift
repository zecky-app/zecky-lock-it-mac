import Combine
import SwiftUI

/// The main screen: the lock, what is locked and for how long.
/// Lock more is easy; opening the lock takes a deliberate moment.
struct HomeView: View {
    @ObservedObject var model: AppModel
    @ObservedObject var engine: WalletEngine
    @ObservedObject var prices: PriceFeed

    @State private var tilt: CGSize = .zero
    @State private var area: CGSize = .zero
    @Environment(\.colorScheme) private var scheme

    /// The plate on the lock: the value when a currency is chosen, else the state.
    /// The plate is engraved: LOCKED or OPEN, never a number that moves.
    private var plateText: String { model.lockOpen ? "OPEN" : "LOCKED" }

    /// The value in the chosen currency, small under the balance.
    private var valueLine: String? {
        guard prices.currency != .none, !model.amountsHidden else { return nil }
        return prices.value(of: engine.total)
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
                        Button { model.lockNow(manual: true) } label: {
                            Image(systemName: "lock.fill")
                                .font(.system(size: 13))
                                .foregroundStyle(Theme.gold)
                                .frame(width: 32, height: 32)
                                .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .help("Lock Zecky Lock it now (⇧⌘L)")
                        .accessibilityLabel("Lock Zecky Lock it now")
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
                        if let valueLine {
                            Text(valueLine).font(Theme.text(13)).foregroundStyle(Theme.muted)
                                .padding(.top, -4)
                        }

                        VStack(spacing: 3) {
                            heldText
                            if engine.orchardHeld > 0 && engine.status == .upToDate {
                                Button { model.sheet = .ironwood } label: {
                                    HStack(spacing: 4) {
                                        Text(model.amountsHidden ? "Part of your Zcash is in the old Orchard pool" : "\(Amount.text(engine.orchardHeld, model.unit)) in the old Orchard pool")
                                        Text("· Move it to Ironwood").fontWeight(.semibold)
                                        Image(systemName: "chevron.right").font(.system(size: 9, weight: .semibold))
                                    }
                                    .font(Theme.text(12)).foregroundStyle(Theme.gold)
                                    .contentShape(Rectangle())
                                }
                                .buttonStyle(.plain)
                                .padding(.top, 2)
                            }
                            if engine.outsideTheLock > 0 && engine.status == .upToDate {
                                Button { model.sheet = .lockIn } label: {
                                    HStack(spacing: 4) {
                                        Text(model.amountsHidden ? "Zcash waiting outside the lock" : "+\(Amount.text(engine.outsideTheLock, model.unit)) waiting outside the lock")
                                        Text("· Lock it in").fontWeight(.semibold)
                                        Image(systemName: "chevron.right").font(.system(size: 9, weight: .semibold))
                                    }
                                    .font(Theme.text(12)).foregroundStyle(Theme.gold)
                                    .contentShape(Rectangle())
                                }
                                .buttonStyle(.plain)
                                .padding(.top, 2)
                            }
                        }
                        if engine.status == .upToDate && engine.total > engine.spendable {
                            let wait = WalletEngine.waitingText(WalletEngine.slowestWaiting(engine.activity, networkHeight: engine.networkHeight))
                            Text(model.amountsHidden
                                 ? "Part of your balance: \(wait)"
                                 : "\(Amount.text(engine.total - engine.spendable, model.unit)) locking in · \(wait)")
                                .font(Theme.text(12)).foregroundStyle(Theme.gold)
                        }

                        Group {
                            if model.lockOpen {
                                HStack(spacing: 12) {
                                    BrassButton(title: "Release Zcash", icon: "lock.open.fill") { model.sheet = .send }
                                        .frame(width: 210)
                                    SecondaryButton(title: "Close the lock") { model.closeLock() }
                                        .frame(width: 160)
                                        .keyboardShortcut(.cancelAction)
                                }
                            } else {
                                BrassButton(title: "Lock more", icon: "lock.fill") { model.sheet = .receive }
                                    .frame(width: 230)
                                    .disabled(engine.status == .connecting)
                            }
                        }
                        .padding(.top, 12)
                        if let note = model.openNote {
                            Text(note).font(Theme.text(12)).foregroundStyle(Theme.muted)
                        }
                        timeLockLine

                        if let waiting = engine.activity.first(where: { $0.state == .waiting }) {
                            Button { model.sheet = .activity } label: {
                                HStack(spacing: 6) {
                                    Image(systemName: waiting.kind == .received ? "lock.fill" : "lock.open")
                                        .font(.system(size: 10))
                                    Text(waitingLine(waiting))
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
            .disabled(model.asking || model.askingCode || model.timeLockShown)
            .accessibilityHidden(model.asking || model.askingCode || model.timeLockShown)

            if model.asking {
                OpenLockPrompt(days: heldDays) { model.countdownDone() } onKeep: { model.keepLocked() }
                    .transition(.opacity)
            }
            if model.timeLockShown {
                TimeLockPrompt(phase: TimeLock.phase,
                               onAsk: { model.startTimeLockWait() },
                               onCancelRequest: { model.cancelTimeLockRequest() },
                               onKeep: { model.keepLocked() },
                               onBreakGlass: { model.breakGlass() })
                    .transition(.opacity)
            }
            if model.askingCode {
                ZStack {
                    Theme.scrim.ignoresSafeArea().onTapGesture {}
                    CodePrompt(action: "Open",
                               submit: { code in await model.unsealToOpen(code: code) },
                               onDone: { model.openLock() },
                               onCancel: { model.keepLocked() })
                        .padding(.horizontal, 40).padding(.vertical, 30)
                        .frame(width: 560)
                        .background(Theme.surface, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
                        .overlay(RoundedRectangle(cornerRadius: 18, style: .continuous).stroke(Theme.gold.opacity(0.25), lineWidth: 1))
                        .shadow(color: .black.opacity(0.35), radius: 30, y: 12)
                }
                .transition(.opacity)
            }
        }
        .animation(.easeInOut(duration: 0.2), value: model.asking)
        .animation(.easeInOut(duration: 0.2), value: model.askingCode)
        .animation(.easeInOut(duration: 0.2), value: model.timeLockShown)
        .sheet(item: $model.sheet, onDismiss: { model.sheetClosed() }) { sheet in
            switch sheet {
            case .receive: ReceiveView(engine: engine) { model.sheet = nil }
            case .send: SendView(engine: engine, prices: prices, opened: model.opened, signing: { model.signing = $0 }, onReleased: { model.released = true }) { model.sheet = nil }
            case .settings: SettingsView(model: model, prices: prices) { model.sheet = nil }
            case .activity: ActivitySheet(model: model, engine: engine) { model.sheet = nil }
            case .ironwood: IronwoodSheet(model: model, engine: engine, kind: .ironwood) { model.sheet = nil }
            case .lockIn: IronwoodSheet(model: model, engine: engine, kind: .lockIn) { model.sheet = nil }
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

    /// Only while a payment waits for a block.
    private func waitingLine(_ item: WalletEngine.ActivityItem) -> String {
        let what = item.kind == .received ? "Locking in" : "Releasing"
        if model.amountsHidden { return "\(what) · waiting for a block" }
        let sign = item.kind == .received ? "+" : "−"
        return "\(what) \(sign)\(Amount.text(item.amount, model.unit)) · waiting for a block"
    }

    private var heldDays: Int? {
        guard let since = engine.lockedSince else { return nil }
        let cal = Calendar.current
        let days = cal.dateComponents([.day], from: cal.startOfDay(for: since), to: cal.startOfDay(for: Date())).day ?? 0
        return max(0, days)
    }

    /// Under Lock more: where the time lock stands, when one is on.
    @ViewBuilder
    private var timeLockLine: some View {
        let _ = model.timeLockChanged
        if TimeLock.brokenNotice, let when = TimeLock.lastBroken {
            HStack(spacing: 10) {
                ZStack {
                    Circle().stroke(Theme.red, lineWidth: 1.5).frame(width: 20, height: 20)
                    Image(systemName: "hammer.fill").font(.system(size: 9)).foregroundStyle(Theme.red)
                }
                Text("Glass broken on \(TimeLock.when(when)). The time lock is off now.")
                    .font(Theme.text(12, weight: .medium)).foregroundStyle(Theme.red)
                Button("OK") { model.seenBrokenGlass() }
                    .buttonStyle(.plain).font(Theme.text(12, weight: .semibold)).foregroundStyle(Theme.text)
                    .padding(.horizontal, 10).frame(height: 24)
                    .overlay(Capsule().stroke(Theme.muted.opacity(0.5)))
            }
            .padding(.horizontal, 14).padding(.vertical, 8)
            .background(Theme.red.opacity(0.10), in: Capsule())
        }
        switch TimeLock.phase {
        case .waiting(let until):
            Label("The lock can be opened from \(TimeLock.when(until))", systemImage: "clock")
                .font(Theme.text(12, weight: .medium)).foregroundStyle(Theme.gold)
        case .ready(let until):
            Label("The lock can be opened until \(TimeLock.when(until))", systemImage: "clock.badge.checkmark")
                .font(Theme.text(12, weight: .medium)).foregroundStyle(Theme.green)
        default:
            EmptyView()
        }
    }

    /// One line: how long it is locked, and the next milestone in gold.
    private var heldText: Text {
        guard engine.lockedSince != nil, let days = heldDays else {
            return Text(engine.total > 0 ? "Locked on this Mac" : "Nothing locked yet. Choose Lock more to begin.")
                .font(Theme.text(13)).foregroundColor(Theme.muted)
        }
        let held = Text(days == 0 ? "Locked since today" : "Locked for \(days) \(days == 1 ? "day" : "days")")
            .font(Theme.text(13)).foregroundColor(Theme.muted)
        guard let m = milestone else { return held }
        return held + Text(" · \(m.name) in \(m.inDays) \(m.inDays == 1 ? "day" : "days")")
            .font(Theme.text(13, weight: .medium)).foregroundColor(Theme.gold)
    }

    private var statusText: String { baseStatus + (Server.isRockIt ? " · Rock it" : "") }

    private var baseStatus: String {
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
    @State private var countdown = Keys.wait
    private let total = max(1, Keys.wait)
    private let timer = Timer.publish(every: 1, on: .main, in: .common).autoconnect()

    var body: some View {
        ZStack {
            Theme.scrim.ignoresSafeArea()
                .onTapGesture {}
            VStack(spacing: 18) {
                // A small lock inside a gold ring that fills while you wait.
                ZStack {
                    Circle().stroke(Theme.gold.opacity(0.15), lineWidth: 3)
                    Circle()
                        .trim(from: 0, to: Double(total - countdown) / Double(total))
                        .stroke(Theme.gold, style: StrokeStyle(lineWidth: 3, lineCap: .round))
                        .rotationEffect(.degrees(-90))
                        .animation(.linear(duration: 1), value: countdown)
                    PadlockView(open: false, size: 62)
                    if countdown > 0 {
                        Text("\(countdown)")
                            .font(Theme.text(11, weight: .semibold)).foregroundStyle(Theme.gold)
                            .offset(y: 58)
                    }
                }
                .frame(width: 104, height: 104)
                .padding(.bottom, 4)

                Text("Really open the lock?").font(Theme.serif(32, weight: .medium))
                Text(intro).font(Theme.text(14)).foregroundStyle(Theme.muted)
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
                Toggle(isOn: $agreed) {
                    Text("I am opening it myself, and nobody is telling me to.").font(Theme.text(14))
                }
                .toggleStyle(.checkbox)
                .padding(14)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(Theme.ink, in: RoundedRectangle(cornerRadius: 10))
                .overlay(RoundedRectangle(cornerRadius: 10).stroke(agreed ? Theme.gold.opacity(0.6) : Theme.line))
                HStack(spacing: 12) {
                    PrimaryButton(title: "Keep it locked", action: onKeep)
                        .keyboardShortcut(.cancelAction)
                    SecondaryButton(title: countdown > 0 ? "Open in \(countdown) s" : "Open the lock") {
                        if agreed && countdown == 0 { onOpen() }
                    }
                    .opacity(agreed && countdown == 0 ? 1 : 0.45)
                }
                .padding(.top, 2)
            }
            .padding(.horizontal, 40).padding(.top, 30).padding(.bottom, 32)
            .frame(width: 480)
            .background(Theme.surface, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 18, style: .continuous).stroke(Theme.gold.opacity(0.25), lineWidth: 1))
            .shadow(color: .black.opacity(0.35), radius: 30, y: 12)
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

/// Activity: the record of every time Zcash was locked or released.
struct ActivitySheet: View {
    @ObservedObject var model: AppModel
    @ObservedObject var engine: WalletEngine
    let onClose: () -> Void

    enum Filter: String, CaseIterable, Identifiable {
        case all = "All", locked = "Locked", released = "Released", lock = "The lock"
        var id: Self { self }
    }
    @State private var filter: Filter = .all

    private var events: [LockLog.Entry] { let _ = model.timeLockChanged; return LockLog.entries }

    private var entries: [ActivityEntry] {
        let payments = engine.activity.map { ActivityEntry.payment($0) }
        let lock = events.map { ActivityEntry.event($0) }
        let chosen: [ActivityEntry]
        switch filter {
        case .all: chosen = payments + lock
        case .locked: chosen = payments.filter { $0.isLocked }
        case .released: chosen = payments.filter { $0.isReleased }
        case .lock: chosen = lock
        }
        // Waiting payments first, then newest first.
        return chosen.sorted { a, b in
            switch (a.date, b.date) {
            case (nil, nil): return false
            case (nil, _): return true
            case (_, nil): return false
            case let (x?, y?): return x > y
            }
        }
    }

    var body: some View {
        SheetScaffold(title: "Activity",
                      subtitle: "Every time you locked more, released, or changed the lock.",
                      height: 640, onClose: onClose) {
            if engine.activity.isEmpty && events.isEmpty {
                VStack(spacing: 14) {
                    Spacer()
                    PadlockView(open: false, size: 90)
                    Text("Nothing locked yet").font(Theme.serif(20, weight: .medium))
                    Text("When Zcash arrives at your Lock more address, it shows up here.")
                        .font(Theme.text(13)).foregroundStyle(Theme.muted).multilineTextAlignment(.center)
                    Spacer()
                }
                .frame(maxWidth: .infinity)
            } else {
                summary
                    .padding(.bottom, 12)
                HStack(spacing: 6) {
                    ForEach(Filter.allCases) { f in
                        Chip(title: f.rawValue, on: filter == f) { filter = f }
                    }
                    Spacer()
                }
                .padding(.bottom, 12)
                if entries.isEmpty {
                    Text(filter == .lock ? "No changes to the lock yet." : "Nothing here yet.")
                        .font(Theme.text(13)).foregroundStyle(Theme.muted)
                        .frame(maxWidth: .infinity).padding(.top, 30)
                    Spacer()
                } else {
                    ActivityList(entries: entries, unit: model.unit, hidden: model.amountsHidden)
                }
            }
        }
    }

    private var summary: some View {
        let confirmed = engine.activity.filter { $0.state == .confirmed }
        let lockedIn = confirmed.filter { $0.kind == .received }.reduce(Int64(0)) { $0 + $1.amount }
        let released = confirmed.filter { $0.kind == .sent }.reduce(Int64(0)) { $0 + $1.amount }
        return HStack(spacing: 0) {
            stat("LOCKED IN", model.amountsHidden ? Amount.hiddenText : (lockedIn > 0 ? "+" : "") + Amount.text(lockedIn, model.unit),
                 lockedIn > 0 ? Theme.green : Theme.muted)
            Rectangle().fill(Theme.line).frame(width: 1, height: 34)
            stat("RELEASED", model.amountsHidden ? Amount.hiddenText : (released > 0 ? "−" : "") + Amount.text(released, model.unit),
                 released > 0 ? Theme.gold : Theme.muted)
            Rectangle().fill(Theme.line).frame(width: 1, height: 34)
            stat("ENTRIES", "\(engine.activity.count + events.count)", Theme.text)
        }
        .card(padding: 14)
    }

    private func stat(_ label: String, _ value: String, _ color: Color) -> some View {
        VStack(spacing: 4) {
            Text(label).font(Theme.text(10, weight: .semibold)).tracking(1.3).foregroundStyle(Theme.muted)
            Text(value).font(Theme.text(14, weight: .semibold)).foregroundStyle(color)
                .lineLimit(1).minimumScaleFactor(0.7)
        }
        .frame(maxWidth: .infinity)
    }
}

/// One line in Activity: a payment, or something that happened to the lock.
enum ActivityEntry: Identifiable {
    case payment(WalletEngine.ActivityItem)
    case event(LockLog.Entry)

    var id: String {
        switch self {
        case .payment(let item): return "p" + item.id.map { String(format: "%02x", $0) }.joined()
        case .event(let entry): return "e" + entry.id.uuidString
        }
    }
    var date: Date? {
        switch self {
        case .payment(let item): return item.date
        case .event(let entry): return entry.date
        }
    }
    var isLocked: Bool { if case .payment(let i) = self { return i.kind == .received }; return false }
    var isReleased: Bool { if case .payment(let i) = self { return i.kind == .sent }; return false }
}

/// Newest first, grouped by month. Quiet: no addresses, just what and when.
struct ActivityList: View {
    let entries: [ActivityEntry]
    var unit: Amount.Unit = .zec
    var hidden = false

    private static let dateFormat: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US")
        f.dateFormat = "MMM d · h:mm a"
        return f
    }()
    private static let monthFormat: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US")
        f.dateFormat = "MMMM yyyy"
        return f
    }()

    private var groups: [(title: String, items: [ActivityEntry])] {
        var result: [(String, [ActivityEntry])] = []
        for entry in entries {
            let title = entry.date.map { Self.monthFormat.string(from: $0).uppercased() } ?? "WAITING"
            if let last = result.last, last.0 == title { result[result.count - 1].1.append(entry) }
            else { result.append((title, [entry])) }
        }
        return result
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                ForEach(groups, id: \.title) { group in
                    VStack(alignment: .leading, spacing: 8) {
                        Text(group.title).font(Theme.text(11, weight: .semibold)).tracking(1.4).foregroundStyle(Theme.muted)
                        VStack(spacing: 0) {
                            ForEach(Array(group.items.enumerated()), id: \.element.id) { index, entry in
                                if index > 0 { Rectangle().fill(Theme.line).frame(height: 1).padding(.leading, 52) }
                                switch entry {
                                case .payment(let item): row(item)
                                case .event(let event): eventRow(event)
                                }
                            }
                        }
                        .card(padding: 4)
                    }
                }
            }
            .padding(.bottom, 8)
        }
        .scrollIndicators(.never)
    }

    private func eventRow(_ event: LockLog.Entry) -> some View {
        let (title, icon, tint): (String, String, Color) = {
            switch event.kind {
            case .glassBroken: return ("Time lock broken", "hammer.fill", Theme.red)
            case .timeLock: return ("Time lock", "clock.fill", Theme.gold)
            case .code: return ("Code", "lock.rotation", Theme.gold)
            case .addressBook: return ("Address book", "person.crop.circle", Theme.gold)
            case .keys: return ("Keys to the lock", "key.fill", Theme.gold)
            }
        }()
        return HStack(spacing: 12) {
            ZStack {
                Circle().fill(tint.opacity(0.14))
                Image(systemName: icon).font(.system(size: 13, weight: .semibold)).foregroundStyle(tint)
            }
            .frame(width: 34, height: 34)
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(Theme.text(14, weight: .medium)).foregroundStyle(event.kind == .glassBroken ? Theme.red : Theme.text)
                Text("\(event.text) · \(Self.dateFormat.string(from: event.date))")
                    .font(Theme.text(12)).foregroundStyle(Theme.muted)
            }
            Spacer()
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 10)
    }

    private func row(_ item: WalletEngine.ActivityItem) -> some View {
        let locked = item.kind == .received
        let tint = item.state == .expired ? Theme.muted : (locked ? Theme.green : Theme.gold)
        return HStack(spacing: 12) {
            ZStack {
                Circle().fill(tint.opacity(0.14))
                Image(systemName: locked ? "lock.fill" : "lock.open.fill")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(tint)
            }
            .frame(width: 34, height: 34)
            VStack(alignment: .leading, spacing: 2) {
                Text(locked ? "Locked" : "Released").font(Theme.text(14, weight: .medium))
                Text(subtitle(item)).font(Theme.text(12)).foregroundStyle(item.state == .waiting ? Theme.gold : Theme.muted)
            }
            Spacer()
            Text(hidden ? "Amount hidden" : "\(locked ? "+" : "−")\(Amount.text(item.amount, unit))")
                .font(Theme.text(14, weight: .semibold))
                .foregroundStyle(item.state == .expired ? Theme.muted : (locked ? Theme.green : Theme.text))
                .strikethrough(item.state == .expired)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 10)
    }

    private func subtitle(_ item: WalletEngine.ActivityItem) -> String {
        switch item.state {
        case .waiting: return "Waiting for a block"
        case .expired: return "Expired · never left the lock"
        case .confirmed: return item.date.map { Self.dateFormat.string(from: $0) } ?? "Confirmed"
        }
    }
}

/// Moves inside the wallet itself: Orchard into Ironwood, or public
/// (transparent) Zcash locked in to the private pool. Nothing leaves.
struct IronwoodSheet: View {
    @ObservedObject var model: AppModel
    @ObservedObject var engine: WalletEngine
    enum Kind { case ironwood, lockIn }
    let kind: Kind
    let onClose: () -> Void

    private var held: Int64 { kind == .ironwood ? engine.orchardHeld : engine.outsideTheLock }

    private enum Stage { case loading, ready(WalletEngine.SendPlan), code(WalletEngine.SendPlan), moving, done, failed(String) }
    @State private var stage: Stage = .loading
    @State private var note: String?

    var body: some View {
        SheetScaffold(title: kind == .ironwood ? "Move to Ironwood" : "Lock it in",
                      subtitle: kind == .ironwood ? "Once, inside your own wallet." : "From the public address into the lock.",
                      closeLabel: "Close", showsClose: !isMoving, height: 560, onClose: onClose) {
            switch stage {
            case .loading:
                VStack { Spacer(); ProgressView().controlSize(.small); Spacer() }.frame(maxWidth: .infinity)
            case .ready(let plan): ready(plan)
            case .code(let plan):
                CodePrompt(action: kind == .ironwood ? "Move" : "Lock it in",
                           submit: { code in await unseal(code: code) },
                           onDone: { Task { await move(plan) } },
                           onCancel: { stage = .ready(plan) })
            case .moving:
                VStack(spacing: 14) {
                    Spacer()
                    PadlockView(open: true, size: 90)
                    ProgressView().controlSize(.small)
                    Text(kind == .ironwood ? "Moving…" : "Locking in…").font(Theme.text(13)).foregroundStyle(Theme.muted)
                    Spacer()
                }
                .frame(maxWidth: .infinity)
            case .done:
                VStack(spacing: 16) {
                    Spacer()
                    PadlockView(open: false, size: 100)
                    Text(kind == .ironwood ? "Moved. It shows in Ironwood once it is in a block, and stays locked." : "Locking in. Once it is in a block it is locked in ✓, private like the rest.")
                        .font(Theme.text(14)).foregroundStyle(Theme.muted).multilineTextAlignment(.center)
                    Spacer()
                    PrimaryButton(title: "Done", action: onClose).frame(width: 180).keyboardShortcut(.defaultAction)
                }
                .frame(maxWidth: .infinity)
            case .failed(let why):
                VStack(spacing: 14) {
                    Spacer()
                    Text(why).font(Theme.text(13)).foregroundStyle(Theme.red).multilineTextAlignment(.center)
                    Text(kind == .ironwood ? "Nothing was moved." : "Nothing was locked in.").font(Theme.text(13)).foregroundStyle(Theme.muted)
                    Spacer()
                }
                .frame(maxWidth: .infinity)
            }
        }
        .task { await load() }
    }

    private var isMoving: Bool { if case .moving = stage { return true } else { return false } }

    private func ready(_ plan: WalletEngine.SendPlan) -> some View {
        VStack(alignment: .leading, spacing: 14) {
            Text(kind == .ironwood
                 ? "Since the Ironwood upgrade (28 July 2026) the Orchard pool only lets Zcash out; new Zcash goes to Ironwood. Part of yours is still in Orchard. Move it once to Ironwood, in this same wallet, and it stays as private as before. Your other Zcash is not touched."
                 : "This Zcash arrived on a public address of this wallet, so its amount and sender are visible on the blockchain. Lock it in, and from then on it is private like the rest. Lock it never hands out a public address itself.")
                .font(Theme.text(13)).foregroundStyle(Theme.muted)
                .fixedSize(horizontal: false, vertical: true)
            VStack(spacing: 8) {
                row(kind == .ironwood ? "In Orchard now" : "Outside the lock", Amount.text(held, model.unit))
                row("Network fee", Amount.text(plan.fee, model.unit))
                Rectangle().fill(Theme.line).frame(height: 1)
                row(kind == .ironwood ? "Arrives in Ironwood" : "Locked in", Amount.text(plan.amount, model.unit), strong: true)
            }
            .card(padding: 16)
            if let note { Text(note).font(Theme.text(12)).foregroundStyle(Theme.red) }
            Spacer(minLength: 0)
            HStack {
                Text("Your time lock does not apply: nothing leaves your wallet.")
                    .font(Theme.text(11)).foregroundStyle(Theme.muted)
                Spacer()
                BrassButton(title: kind == .ironwood ? "Move to Ironwood" : "Lock it in",
                            icon: kind == .ironwood ? "arrow.right.circle.fill" : "lock.fill") { Task { await start(plan) } }
                    .frame(width: 230)
            }
        }
    }

    private func row(_ label: String, _ value: String, strong: Bool = false) -> some View {
        HStack {
            Text(label).font(Theme.text(13)).foregroundStyle(Theme.muted)
            Spacer()
            Text(model.amountsHidden ? Amount.hiddenText : value)
                .font(Theme.text(14, weight: strong ? .semibold : .medium))
                .foregroundStyle(strong ? Theme.gold : Theme.text)
        }
    }

    @State private var wallet: StoredWallet?

    private func load() async {
        do { stage = .ready(try await (kind == .ironwood ? engine.planIronwoodMove() : engine.planLockIn())) }
        catch { stage = .failed(String(describing: error)) }
    }

    private func start(_ plan: WalletEngine.SendPlan) async {
        note = nil
        if WalletVault.needsSecret { stage = .code(plan); return }
        if let message = await unseal(code: nil) { note = message; return }
        await move(plan)
    }

    private func unseal(code: String?) async -> String? {
        do {
            wallet = try await WalletVault.unseal(reason: kind == .ironwood ? "move your Zcash to Ironwood" : "lock your public Zcash in", code: code, fresh: false)
            return nil
        } catch WalletVault.Failure.cancelled {
            return kind == .ironwood ? "Not confirmed, so nothing was moved." : "Not confirmed, so nothing was locked in."
        } catch { return String(describing: error) }
    }

    private func move(_ plan: WalletEngine.SendPlan) async {
        guard let opened = wallet else { stage = .ready(plan); return }
        wallet = nil
        stage = .moving
        model.signing = true
        defer { model.signing = false }
        do {
            var seed = try Mnemonic.seed(from: opened.phrase)
            defer { Wipe.bytes(&seed) }
            _ = try await engine.send(plan, seed: seed)
            stage = .done
        } catch {
            stage = .failed(String(describing: error))
        }
    }
}
