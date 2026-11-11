import Combine
import SwiftUI
import ZcashLightClientKit

/// The main screen: the lock, what is locked and for how long.
/// Lock more is easy; opening the lock takes a deliberate moment.
struct HomeView: View {
    @ObservedObject var model: AppModel
    @ObservedObject var engine: WalletEngine
    @ObservedObject var prices: PriceFeed
    @ObservedObject private var goMax = GoMaxNode.shared

    @State private var tilt: CGSize = .zero
    @State private var area: CGSize = .zero
    @Environment(\.colorScheme) private var scheme

    /// The plate on the lock: the value when a currency is chosen, else the state.
    /// The plate is engraved: LOCKED or OPEN, never a number that moves.
    private var plateText: String { model.lockOpen ? "OPEN" : (model.isSealedSelected ? "SEALED" : "LOCKED") }

    /// The balance of the wallet chosen on the key ring.
    private var shownTotal: Int64 {
        guard let id = model.selectedWallet else { return engine.total }
        return engine.signerBalances[id]?.total ?? 0
    }

    /// The value in the chosen currency, small under the balance.
    private var valueLine: String? {
        guard prices.currency != .none, !model.amountsHidden else { return nil }
        return prices.value(of: shownTotal)
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
                        KeyRing(model: model, engine: engine)
                            .padding(.top, 4)
                            .padding(.bottom, 18)
                        ZStack {
                            Medallion(tilt: tilt, diameter: 760)
                                .animation(.easeOut(duration: 0.6), value: tilt)
                                .frame(width: 330, height: 330)
                            if !model.isSealedSelected, let days = heldDays {
                                EngravedRings(count: Milestone.engraved(after: days), newestBright: Milestone.engravedToday(after: days), diameter: 640)
                                    .frame(width: 330, height: 330)
                            }
                            ChainHeartbeat(height: engine.networkHeight, active: engine.isCurrent, diameter: 356)
                            MilestoneRing(progress: Milestone.progress(after: heldDays ?? 0), diameter: 320,
                                          glow: heldDays.map { Milestone.reachedToday(after: $0) } ?? false)
                                .opacity(heldDays == nil ? 0.5 : 1)
                                .animation(.easeOut(duration: 1.2), value: Milestone.progress(after: heldDays ?? 0))
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

                        if model.selectedWallet != nil {
                            heldLineView
                        } else {
                        VStack(spacing: 3) {
                            heldLineView
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
                        }

                        if model.lockOpen && engine.networkHeight > 0 && NetworkUpgrade.releasesPaused(networkHeight: engine.networkHeight) {
                            Text(NetworkUpgrade.pausedText)
                                .font(Theme.text(12)).foregroundStyle(Theme.gold)
                                .multilineTextAlignment(.center).frame(maxWidth: 420)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                        Group {
                            if model.lockOpen {
                                HStack(spacing: 12) {
                                    BrassButton(title: "Send Zcash",
                                                icon: model.isSealedSelected ? "envelope.fill" : "lock.open.fill") {
                                        if model.isSealedSelected {
                                            // Sealed wallet: the phone signs; the lock closes when done.
                                            model.released = true
                                            model.sealItSending = true
                                            model.sheet = .signer
                                        } else {
                                            model.sheet = .send
                                        }
                                    }
                                        .frame(width: 210)
                                    SecondaryButton(title: "Close the lock") { model.closeLock() }
                                        .frame(width: 160)
                                        .keyboardShortcut(.cancelAction)
                                }
                            } else {
                                BrassButton(title: "Receive",
                                            icon: model.isSealedSelected ? "envelope.fill" : "lock.fill") {
                                    model.sealItSending = false
                                    model.sheet = model.isSealedSelected ? .signer : .receive
                                }
                                    .frame(width: 230)
                                    .disabled(engine.status == .connecting)
                            }
                        }
                        .padding(.top, 12)
                        if let note = model.openNote {
                            Text(note).font(Theme.text(12)).foregroundStyle(Theme.muted)
                        }
                        // A calm payment line under the button, as on the iPhone:
                        // "Receiving +x ›" or "Sending −x ›" while a payment waits
                        // for its block; the details are in Activity. Its place
                        // is always kept, so nothing moves when it comes and goes.
                        Button { engine.cancelledPayment = nil; model.sheet = .activity } label: {
                            Text(paymentLine.map { "\($0) ›" } ?? " ")
                                .font(Theme.text(12)).foregroundStyle(paymentLineNeedsAttention ? Theme.gold : Theme.muted)
                                .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .disabled(paymentLine == nil)
                        .opacity(paymentLine == nil ? 0 : 1)
                        .animation(.easeInOut(duration: 0.3), value: paymentLine == nil)
                        .help("Open Activity")
                        .accessibilityHint("Opens Activity")
                        .frame(height: 18)
                        .padding(.top, 6)
                        timeLockLine


                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .padding(.top, 20)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                // Go Max, above Settings: your own node, one click from home.
                .overlay(alignment: .bottomTrailing) {
                    if GoMaxNode.isAvailable {
                        GoMaxButton(node: GoMaxNode.shared) { model.openGoMax() }
                            .padding(.trailing, 20).padding(.bottom, 14)
                    }
                }
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
                        Circle().fill(unreachable ? Theme.red : dotColor).frame(width: 8, height: 8)
                        if unreachable {
                            Button { model.openNetworkSettings() } label: {
                                HStack(spacing: 4) {
                                    Text("Can't reach \(Server.nodeLabel ?? Server.host)")
                                    Text("· Choose another server").fontWeight(.semibold)
                                    Image(systemName: "chevron.right").font(.system(size: 9, weight: .semibold))
                                }
                                .font(Theme.text(12)).foregroundStyle(Theme.red)
                                .contentShape(Rectangle())
                            }
                            .buttonStyle(.plain)
                            .help(failedDetail)
                        } else {
                            Button { model.sheet = .sync } label: {
                                Text(statusText).font(Theme.text(12)).foregroundStyle(nodeQuiet ? Theme.gold : Theme.muted).contentShape(Rectangle())
                            }
                            .buttonStyle(.plain)
                            .help("Sync details")
                        }
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
        .onReceive(clock) { now = $0 }
        .overlay { panel }
        .overlay { ArrivalToast(model: model, engine: engine) }
        .overlay { if model.tourShown { TourCard(model: model).transition(.opacity) } }
        .animation(.easeInOut(duration: 0.2), value: model.tourShown)
        .animation(.easeOut(duration: 0.15), value: model.sheet?.isPanel == true)
        .sheet(item: sheetBinding, onDismiss: { model.sheetClosed() }) { sheet in
            switch sheet {
            case .receive, .activity, .sync, .holding: EmptyView()
            case .send: SendView(engine: engine, prices: prices, opened: model.opened, signing: { model.signing = $0 }, onReleased: { model.released = true }) { model.sheet = nil }
            case .settings: SettingsView(model: model, prices: prices) { model.sheet = nil }
            case .ironwood: IronwoodSheet(model: model, engine: engine, kind: .ironwood) { model.sheet = nil }
            case .lockIn: IronwoodSheet(model: model, engine: engine, kind: .lockIn) { model.sheet = nil }
            case .signer: SignerSheet(model: model, engine: engine) { model.sheet = nil }
            case .addWallet: AddWalletSheet(model: model, engine: engine, kind: model.adding ?? .new) { model.sheet = nil }
            case .walletWords: WalletWordsSheet(model: model, engine: engine) { model.sheet = nil }
            case .eraseWallet: EraseWalletSheet(model: model, engine: engine) { model.sheet = nil }
            }
        }
    }

    /// The sheets proper: everything except the read-only panels.
    private var sheetBinding: Binding<AppModel.Sheet?> {
        Binding(get: { model.sheet.flatMap { $0.isPanel ? nil : $0 } },
                set: { new in if new != nil || model.sheet?.isPanel != true { model.sheet = new } })
    }

    /// Receive, Activity and Sync: over the main screen; a click beside
    /// the panel (or Done, or Esc) goes back.
    @ViewBuilder private var panel: some View {
        if let sheet = model.sheet, sheet.isPanel {
            ZStack {
                Color.black.opacity(0.45)
                    .contentShape(Rectangle())
                    .onTapGesture { model.sheet = nil }
                    .accessibilityLabel("Close")
                Group {
                    switch sheet {
                    case .receive: ReceiveView(engine: engine, prices: prices) { model.sheet = nil }
                    case .activity: ActivitySheet(model: model, engine: engine) { model.sheet = nil }
                    case .holding: HoldingSheet(model: model, engine: engine) { model.sheet = nil }
                    default: SyncSheet(engine: engine) { model.sheet = nil }
                    }
                }
                .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
                .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous).stroke(Theme.gold.opacity(0.25), lineWidth: 1))
                .shadow(color: .black.opacity(0.4), radius: 30, y: 12)
            }
            .transition(.opacity)
        }
    }

    /// Calendar days, so a payment from yesterday evening counts as 1 day.
    private var balanceText: String {
        model.amountsHidden ? Amount.hiddenText : Amount.number(shownTotal, model.unit)
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


    /// "Receiving +0.001 ZEC" or "Sending −0.5 ZEC" while a payment waits for
    /// its block (as on the iPhone); nil when there is none.
    /// A payment that has not been sent yet, or one that was cancelled unsent.
    private var paymentLineNeedsAttention: Bool {
        engine.cancelledPayment != nil || engine.activity.contains { $0.undelivered }
    }

    private var paymentLine: String? {
        // Activity follows the wallet on the key ring, so this works for a
        // sealed wallet too.
        if let waiting = engine.activity.first(where: { $0.state == .waiting }) {
            let what = waiting.kind == .received ? "Receiving" : (waiting.undelivered ? "Not sent yet" : "Sending")
            if model.amountsHidden { return what }
            let sign = waiting.kind == .received ? "+" : "−"
            return "\(what) \(sign)\(Amount.text(waiting.amount, model.unit))"
        }
        // Nothing waiting, but a payment expired without ever being sent.
        if let cancelled = engine.cancelledPayment {
            return model.amountsHidden ? "A payment was not sent and is cancelled"
                : "Not sent: your payment of \(Amount.text(cancelled, model.unit)) is cancelled. Nothing left the lock"
        }
        return nil
    }

    /// How long the wallet on the key ring has been held, as Lock it iPhone.
    /// An empty lock has no count, whatever the history says. The count waits
    /// until the wallet has been fully synced once on this Mac (after a
    /// restore the newest blocks are scanned first, so it would jump), and is
    /// left out when the history does not reach back to the start (a restore
    /// from a later date).
    private var heldDays: Int? {
        guard shownTotal > 0, engine.status == .upToDate || engine.syncedOnce,
              Holding.historyComplete(engine.holdingEntries, pendingIn: engine.pendingIn, balance: shownTotal),
              let since = engine.lockedSince else { return nil }
        return Holding.days(since: since)
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

    /// The line under the balance. With a count it opens the holding page.
    @ViewBuilder private var heldLineView: some View {
        if let heldLine {
            if heldDays != nil {
                Button { model.sheet = .holding } label: {
                    HStack(spacing: 4) {
                        Text(heldLine)
                        Image(systemName: "chevron.right").font(.system(size: 9, weight: .semibold)).opacity(0.7)
                    }
                    .font(Theme.text(13)).foregroundStyle(Theme.muted)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .help("Milestones and highlights")
            } else {
                Text(heldLine).font(Theme.text(13)).foregroundStyle(Theme.muted)
            }
        }
    }

    /// One quiet line, the largest unit only and never a date (a date was
    /// read as an unlock date). An empty lock shows no line at all.
    private var heldLine: String? {
        guard shownTotal > 0 else { return nil }
        guard let days = heldDays else { return "Locked on this Mac" }
        return "Locked \(Holding.heldFor(days: days))"
    }

    @State private var now = Date()
    private let clock = Timer.publish(every: 5, on: .main, in: .common).autoconnect()
    private var unreachable: Bool { let _ = now; return engine.serverUnreachable(now: now) }
    private var failedDetail: String {
        if case .failed(let text) = engine.status { return "Technical detail: \(text)" }
        return "No answer from the server for more than 30 seconds."
    }

    private var statusText: String { baseStatus + (Server.nodeLabel.map { " · \($0)" } ?? "") }

    /// Lock it reads from the node on this Mac, and that node has had no new
    /// block for five minutes: the wallet is level with the node, the node
    /// is not level with the network. Same words and color as the Go Max coin.
    private var nodeQuiet: Bool { Server.nodeKind(Server.host) == .thisMac && goMax.quietMinutes != nil }

    private var baseStatus: String {
        if nodeQuiet { return "No new blocks · check connection" }
        if engine.droppedSince != nil { return "Connection dropped · trying again…" }
        if engine.isCurrent { return "Up to date" }
        switch engine.status {
        case .connecting: return "Connecting…"
        case .syncing: return engine.syncingText
        case .upToDate: return "Up to date"
        case .failed(let text): return "Problem: \(text)"
        }
    }

    private var dotColor: Color {
        if nodeQuiet { return Theme.gold }
        if engine.isCurrent { return Theme.green }
        switch engine.status {
        case .upToDate: return Theme.green
        case .failed: return Theme.red
        default: return Theme.gold
        }
    }
}

/// The key ring: the wallet on this Mac and every Seal it wallet, with "+".
/// The lock in the middle opens whichever wallet is chosen here.
private struct KeyRing: View {
    @ObservedObject var model: AppModel
    @ObservedObject var engine: WalletEngine

    var body: some View {
        HStack(spacing: 8) {
            let items = orderedItems
            ForEach(Array(items.enumerated()), id: \.element.key) { index, item in
                switch item {
                case .main:
                    chip(title: engine.leadWallet.map { WalletNames.display($0, lead: true) } ?? "This Mac",
                         icon: "lock.fill", on: model.selectedWallet == nil) { choose(nil) }
                        .contextMenu {
                            if let lead = engine.leadWallet {
                                Button("Rename…") { newName = WalletNames.display(lead, lead: true); renaming = lead }
                            }
                            Divider()
                            moveButtons(item, index: index, count: items.count)
                            Divider()
                            Button("Erase this wallet…") { model.startErasing(nil) }
                        }
                case .mac(let wallet):
                    chip(title: WalletNames.name(for: wallet, fallback: "Wallet"), icon: "lock.fill", on: model.selectedWallet == wallet.id) {
                        choose(wallet.id)
                    }
                    .contextMenu {
                        Button("Rename…") { newName = WalletNames.name(for: wallet, fallback: ""); renaming = wallet }
                        Button("Show its words…") { model.startShowingWords(wallet.id) }
                        Divider()
                        moveButtons(item, index: index, count: items.count)
                        Divider()
                        Button("Erase this wallet…") { model.startErasing(wallet.id) }
                    }
                case .sealed(let wallet):
                    chip(title: WalletNames.name(for: wallet, fallback: "Seal it"), icon: "envelope.fill", on: model.selectedWallet == wallet.id) {
                        choose(wallet.id)
                    }
                    .contextMenu {
                        Button("Rename…") { newName = WalletNames.name(for: wallet, fallback: ""); renaming = wallet }
                        Divider()
                        moveButtons(item, index: index, count: items.count)
                        Divider()
                        Button("Remove from Lock it…") { removing = wallet }
                    }
                }
            }
            Menu {
                Button("Pair Seal it (offline phone)") {
                    model.sealItPairing = true
                    model.sealItSending = false
                    model.sheet = .signer
                }
                Divider()
                Button("New wallet on this Mac") { model.startAdding(.new) }
                Button("Restore a wallet with 24 words") { model.startAdding(.restore) }
            } label: {
                Image(systemName: "plus")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(Theme.gold)
                    .frame(width: 26, height: 26)
                    .overlay(Circle().stroke(Theme.gold.opacity(0.5), lineWidth: 1))
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            .fixedSize()
            .help("Add a wallet to the key ring")
        }
        .disabled(model.lockOpen)
        .onAppear { Task { await engine.refreshSealedWallets() } }
        .confirmationDialog(removeTitle, isPresented: Binding(get: { removing != nil }, set: { if !$0 { removing = nil } })) {
            Button("Remove", role: .destructive) {
                guard let wallet = removing else { return }
                Task {
                    if model.selectedWallet == wallet.id { model.selectedWallet = nil }
                    try? await engine.removeWallet(wallet.id)
                    KeyRingVault.remove(id: wallet.id)
                    WalletNames.forget(wallet.id)
                }
            }
            Button("Keep it", role: .cancel) {}
        } message: {
            Text(removeMessage)
        }
        .alert("Rename wallet", isPresented: Binding(get: { renaming != nil }, set: { if !$0 { renaming = nil } })) {
            TextField("Name", text: $newName)
            Button("Rename") {
                if let wallet = renaming { WalletNames.rename(wallet.id, to: newName) }
                renaming = nil
                Task { await engine.refreshSealedWallets() }
            }
            Button("Cancel", role: .cancel) { renaming = nil }
        }
    }

    @State private var removing: Account?
    /// The owner's order of the chips (see KeyRingOrder); kept on this Mac.
    @State private var order = KeyRingOrder.saved

    private enum Item {
        case main, mac(Account), sealed(Account)
        var key: String {
            switch self {
            case .main: return KeyRingOrder.main
            case .mac(let a), .sealed(let a): return KeyRingVault.hex(a.id)
            }
        }
    }

    /// This Mac, the Mac wallets and the Seal it wallets, in the owner's order.
    private var orderedItems: [Item] {
        let all: [Item] = [.main] + engine.macWallets.map(Item.mac) + engine.sealedWallets.map(Item.sealed)
        let keys = KeyRingOrder.ordered(all.map(\.key), saved: order)
        return keys.compactMap { key in all.first { $0.key == key } }
    }

    @ViewBuilder private func moveButtons(_ item: Item, index: Int, count: Int) -> some View {
        Button("Move left") { move(item, by: -1) }.disabled(index == 0)
        Button("Move right") { move(item, by: 1) }.disabled(index == count - 1)
    }

    private func move(_ item: Item, by step: Int) {
        let current = orderedItems.map(\.key)
        order = KeyRingOrder.moved(item.key, by: step, in: current)
        KeyRingOrder.saved = order
    }
    @State private var renaming: Account?
    @State private var newName = ""

    private var removeTitle: String { "Remove \"\(removing?.name ?? "this wallet")\" from Lock it?" }

    private var removeMessage: String {
        guard let removing else { return "" }
        if SealItFlow.isSealIt(removing) {
            return "Its keys and Zcash stay on your Seal it phone. You can pair it again at any time."
        }
        return "Its words are deleted from this Mac. Only remove it if you have its 24 words written down, or it is empty."
    }

    private func choose(_ id: AccountUUID?) {
        guard !model.lockOpen else { return }
        withAnimation(.easeInOut(duration: 0.2)) { model.selectedWallet = id }
    }

    private func chip(title: String, icon: String, on: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 6) {
                Image(systemName: icon).font(.system(size: 10, weight: .semibold))
                Text(title).font(Theme.text(12, weight: on ? .semibold : .regular))
            }
            .foregroundStyle(on ? Theme.onGold : Theme.text)
            .padding(.horizontal, 12).frame(height: 26)
            .background(on ? Theme.gold : Theme.surface, in: Capsule())
            .overlay(Capsule().stroke(Theme.line, lineWidth: on ? 0 : 1))
        }
        .buttonStyle(.plain)
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
        case .some(let d): held = d < 1 ? "This Zcash was locked today. " : "This Zcash has been locked \(Holding.heldFor(days: d)). "
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
        case all = "All", locked = "Received", released = "Sent", lock = "The lock"
        var id: Self { self }
    }
    @State private var filter: Filter = .all
    /// The payment whose details are open, by its ID.
    @State private var chosen: Data?

    private var events: [LockLog.Entry] { let _ = model.timeLockChanged; return LockLog.entries }
    private var chosenItem: WalletEngine.ActivityItem? { chosen.flatMap { id in engine.activity.first { $0.id == id } } }

    private var entries: [ActivityEntry] {
        let payments = engine.activity.map { ActivityEntry.payment($0) }
        let lock = events.map { ActivityEntry.event($0) }
        let chosen: [ActivityEntry]
        switch filter {
        // Payments only: changes to the lock have their own filter.
        case .all: chosen = payments
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
                      subtitle: "Everything you received and sent. Changes to the lock are under The lock.",
                      height: 640, onClose: onClose) {
            if let item = chosenItem {
                PaymentDetail(item: item, engine: engine, unit: model.unit, hidden: model.amountsHidden) { chosen = nil }
            } else if engine.activity.isEmpty && events.isEmpty {
                VStack(spacing: 14) {
                    Spacer()
                    PadlockView(open: false, size: 90)
                    Text("Nothing locked yet").font(Theme.serif(20, weight: .medium))
                    Text("When Zcash arrives at your address, it shows up here.")
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
                    ActivityList(entries: entries, unit: model.unit, hidden: model.amountsHidden) { chosen = $0.id }
                }
            }
        }
    }

    private var summary: some View {
        let confirmed = engine.activity.filter { $0.state == .confirmed }
        let lockedIn = confirmed.filter { $0.kind == .received }.reduce(Int64(0)) { $0 + $1.amount }
        let released = confirmed.filter { $0.kind == .sent }.reduce(Int64(0)) { $0 + $1.amount }
        return HStack(spacing: 0) {
            stat("RECEIVED", model.amountsHidden ? Amount.hiddenText : (lockedIn > 0 ? "+" : "") + Amount.text(lockedIn, model.unit),
                 lockedIn > 0 ? Theme.green : Theme.muted)
            Rectangle().fill(Theme.line).frame(width: 1, height: 34)
            stat("SENT", model.amountsHidden ? Amount.hiddenText : (released > 0 ? "−" : "") + Amount.text(released, model.unit),
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

/// One payment, opened from Activity: everything this Mac knows about it,
/// read from the wallet's own data. No link to a website: looking a payment
/// up on a block explorer tells that site which payment is yours. The ID can
/// be selected and copied, and where it goes is the owner's choice.
struct PaymentDetail: View {
    let item: WalletEngine.ActivityItem
    @ObservedObject var engine: WalletEngine
    var unit: Amount.Unit = .zec
    var hidden = false
    let onBack: () -> Void

    @State private var note: String?
    @State private var working = false
    @State private var ownNodeNote: String?

    private static let dateFormat: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US")
        f.dateFormat = "MMM d, yyyy · h:mm a"
        return f
    }()

    private var received: Bool { item.kind == .received }

    private var status: String {
        switch item.state {
        case .waiting: return item.undelivered ? "Not sent yet · Lock it keeps trying" : "Sent · waiting for a block"
        case .expired: return "Expired · never left the lock"
        case .confirmed:
            // Right after opening, the network's height is not known yet.
            guard let mined = item.minedHeight, engine.networkHeight >= mined else { return "In a block" }
            let count = engine.networkHeight - mined + 1
            return "In a block · \(count) confirmation\(count == 1 ? "" : "s")"
        }
    }

    private func amount(_ zatoshi: Int64) -> String { hidden ? "Amount hidden" : Amount.exact(zatoshi, unit) }
    /// What the other side got: a sent amount includes the network fee.
    private var paid: Int64 { max(0, item.amount - (item.fee ?? 0)) }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Button(action: onBack) {
                HStack(spacing: 4) {
                    Image(systemName: "chevron.left").font(.system(size: 10, weight: .semibold))
                    Text("Activity").font(Theme.text(13, weight: .medium))
                }
                .foregroundStyle(Theme.gold).contentShape(Rectangle())
            }
            .buttonStyle(.plain)

            VStack(spacing: 0) {
                line(received ? "Received" : (item.undelivered ? "Payment" : "Sent"),
                     hidden ? amount(paid) : (received ? "+" : "−") + amount(paid), first: true)
                if let fee = item.fee {
                    line("Network fee", amount(fee))
                    line("Out of the lock in total", amount(item.amount))
                }
                line("Status", status, tint: item.state == .waiting ? Theme.gold : Theme.text)
                if let date = item.date { line("When", Self.dateFormat.string(from: date)) }
                if let mined = item.minedHeight { line("Block", mined.formatted(.number.locale(Locale(identifier: "en_US")))) }
                if let note { line("Private note", note) }
            }
            .card(padding: 4)

            VStack(alignment: .leading, spacing: 6) {
                Text("TRANSACTION ID").font(Theme.text(11, weight: .semibold)).tracking(1.4).foregroundStyle(Theme.muted)
                Text(item.txid)
                    .font(.system(size: 12, design: .monospaced))
                    .textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
                Text("Select it to copy. Looking it up on a website tells that site this payment is yours.")
                    .font(Theme.text(12)).foregroundStyle(Theme.muted)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .card()

            if item.undelivered {
                Text("Lock it keeps trying for \(engine.retryText), while it is open and this Mac is awake. After that the payment expires and nothing leaves the lock. It cannot be cancelled, so do not pay again.")
                    .font(Theme.text(13)).foregroundStyle(Theme.gold)
                    .fixedSize(horizontal: false, vertical: true)
                if engine.canSendThroughOwnNode {
                    SecondaryButton(title: working ? "Sending…" : "Send through my own node") {
                        guard !working else { return }
                        working = true
                        Task {
                            defer { working = false }
                            do {
                                let outcome = try await engine.sendThroughOwnNode()
                                ownNodeNote = outcome == .sent ? nil : "Your own node did not take it (\(engine.ownNodeAnswer ?? "no answer"))."
                            } catch { ownNodeNote = String(describing: error) }
                        }
                    }
                    .frame(width: 260)
                    Text(ownNodeNote ?? "Other Zcash nodes then see it coming from your internet address.")
                        .font(Theme.text(12)).foregroundStyle(ownNodeNote == nil ? Theme.muted : Theme.red)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            Spacer(minLength: 0)
        }
        .task(id: item.id) { note = await engine.note(for: item.id) }
    }

    private func line(_ label: String, _ value: String, tint: Color = Theme.text, first: Bool = false) -> some View {
        VStack(spacing: 0) {
            if !first { Rectangle().fill(Theme.line).frame(height: 1) }
            HStack(alignment: .top, spacing: 16) {
                Text(label).font(Theme.text(13)).foregroundStyle(Theme.muted)
                Spacer(minLength: 12)
                Text(value).font(Theme.text(13, weight: .medium)).foregroundStyle(tint)
                    .multilineTextAlignment(.trailing)
                    .textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .padding(.horizontal, 12).padding(.vertical, 10)
        }
    }
}

/// Newest first, grouped by month. Quiet: no addresses, just what and when.
struct ActivityList: View {
    let entries: [ActivityEntry]
    var unit: Amount.Unit = .zec
    var hidden = false
    /// Clicking a payment opens its details.
    var onSelect: ((WalletEngine.ActivityItem) -> Void)? = nil

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
                                case .payment(let item):
                                    if let onSelect {
                                        Button { onSelect(item) } label: { row(item).contentShape(Rectangle()) }
                                            .buttonStyle(.plain)
                                            .help("Details")
                                    } else {
                                        row(item)
                                    }
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
                Text(locked ? "Received" : (item.undelivered ? "Payment" : "Sent")).font(Theme.text(14, weight: .medium))
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
        case .waiting: return item.undelivered ? "Not sent yet · Lock it keeps trying" : "Waiting for a block"
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
                      subtitle: kind == .ironwood ? "Once, inside your own wallet." : "From the transparent address into the lock.",
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
                    Text(kind == .ironwood ? "Moved. It shows in Ironwood once it is in a block, and stays locked." : "Locking in. Once it is in a block it is locked in ✓, shielded like the rest.")
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
                 : "This Zcash arrived on a transparent address of this wallet, so its amount and sender are visible on the blockchain. Lock it in, and from then on it is shielded like the rest. Lock it never hands out a transparent address itself.")
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
            wallet = try await WalletVault.unseal(reason: kind == .ironwood ? "move your Zcash to Ironwood" : "lock your transparent Zcash in", code: code, fresh: false)
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

/// Three quiet steps, as on Lock it iPhone. Skip is always there.
struct TourCard: View {
    @ObservedObject var model: AppModel
    @State private var step = 0

    private let steps: [(title: String, text: String)] = [
        ("Receive", "Click Receive for your address. Zcash sent to it goes straight into the lock."),
        ("Click the lock to send", "The lock opens with a deliberate click. Send takes out only what you choose; the rest stays locked. It closes again by itself."),
        ("Choose your keys", "Decide what is asked before the lock opens: Touch ID, a Zecky code, a short pause, a security key. Settings › Keys to the lock."),
    ]

    var body: some View {
        ZStack {
            Color.black.opacity(0.45).contentShape(Rectangle())
            VStack(alignment: .leading, spacing: 12) {
                HStack {
                    Text("\(step + 1) OF \(steps.count)").font(Theme.text(11, weight: .semibold)).tracking(2).foregroundStyle(Theme.gold)
                    Spacer()
                    Button("Skip") { model.finishTour() }.buttonStyle(.plain).font(Theme.text(12)).foregroundStyle(Theme.muted)
                }
                Text(steps[step].title).font(Theme.serif(26, weight: .medium))
                Text(steps[step].text).font(Theme.text(14)).foregroundStyle(Theme.muted)
                    .fixedSize(horizontal: false, vertical: true)
                HStack {
                    if step == steps.count - 1 {
                        Button("Choose my keys now") {
                            model.finishTour()
                            model.settingsPage = .keys
                            model.sheet = .settings
                        }
                        .buttonStyle(.plain).font(Theme.text(13, weight: .medium)).foregroundStyle(Theme.gold)
                    }
                    Spacer()
                    PrimaryButton(title: step == steps.count - 1 ? "Done" : "Next") {
                        if step == steps.count - 1 { model.finishTour() } else { step += 1 }
                    }
                    .frame(width: 140)
                    .keyboardShortcut(.defaultAction)
                }
                .padding(.top, 6)
            }
            .padding(24)
            .frame(width: 420)
            .background(Theme.surface, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 16, style: .continuous).stroke(Theme.gold.opacity(0.25)))
            .shadow(color: .black.opacity(0.4), radius: 30, y: 12)
        }
    }
}

/// The order of the wallets on the key ring, chosen by the owner with Move
/// left / Move right. Kept on this Mac only, as wallet ids; a wallet it does
/// not know yet follows in the usual order (this Mac, Mac wallets, Seal it).
enum KeyRingOrder {
    static let key = "app.zecky.lockit.mac.keyRingOrder"
    static let main = "main"

    static var saved: [String] {
        get { UserDefaults.standard.stringArray(forKey: key) ?? [] }
        set { UserDefaults.standard.set(newValue, forKey: key) }
    }

    /// `ids` in the saved order; ids not saved yet keep their place after them.
    static func ordered(_ ids: [String], saved: [String]) -> [String] {
        let known = saved.filter { ids.contains($0) }
        return known + ids.filter { !known.contains($0) }
    }

    /// `order` with `id` moved one place left (-1) or right (+1).
    static func moved(_ id: String, by step: Int, in order: [String]) -> [String] {
        guard let i = order.firstIndex(of: id), order.indices.contains(i + step) else { return order }
        var result = order
        result.swapAt(i, i + step)
        return result
    }

    /// For Erase wallet.
    static func erase() { UserDefaults.standard.removeObject(forKey: key) }
}
