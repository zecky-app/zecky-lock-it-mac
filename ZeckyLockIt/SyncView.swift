import SwiftUI

/// The numbers behind the sync details, kept free of UI so they are tested.
enum SyncMath {
    struct Problem: Equatable, Identifiable { let at: Date; let message: String; var id: Date { at } }
    struct Sample: Equatable { let at: Date; let height: Int }

    /// Newest first, at most 5; the same message again within a minute is
    /// the same problem (as on the iPhone, src/lib/syncProblems.ts).
    static func adding(_ p: Problem, to list: [Problem]) -> [Problem] {
        if let last = list.first, last.message == p.message, p.at.timeIntervalSince(last.at) < 60 { return list }
        return Array(([p] + list).prefix(5))
    }

    /// A new block or two behind counts as up to date on screen.
    static func nearlyCurrent(network: Int, wallet: Int) -> Bool {
        network > 0 && wallet > 0 && network - wallet <= 3
    }

    /// A block download or server call that broke off while syncing, such as
    /// "LightWalletService.blockStream failed." The engine retries by itself,
    /// so it is shown calmly, not as an error (as Lock it iPhone).
    static func isDroppedConnection(_ text: String) -> Bool {
        text.range(of: #"blockStream|LightWalletService\.\w+ failed|stream (failed|closed|reset)|connection reset|unavailable"#,
                   options: [.regularExpression, .caseInsensitive]) != nil
    }
    static let droppedText = "The connection to the Zcash server dropped for a moment. Lock it is trying again by itself."
    /// After this long without progress, another server is suggested.
    static let droppedPatience: TimeInterval = 180

    static func behind(network: Int, wallet: Int) -> Int? {
        guard network > 0, wallet > 0 else { return nil }
        return max(0, network - wallet)
    }

    /// Minutes to go at the recent pace, once there are a few samples.
    static func minutesLeft(behind: Int, samples: [Sample]) -> Int? {
        guard behind > 0, samples.count >= 3, let first = samples.first, let last = samples.last else { return nil }
        let seconds = last.at.timeIntervalSince(first.at)
        guard seconds > 0 else { return nil }
        let rate = Double(last.height - first.height) / seconds
        guard rate > 0 else { return nil }
        return max(1, Int((Double(behind) / rate / 60).rounded()))
    }

    /// How much of [birthday, tip) is checked, 0…1, from the engine's own
    /// list of ranges still to scan (as Lock it iPhone: syncProblems.ts).
    /// Each range is clipped to birthday…tip and overlaps count once. Nil
    /// while the network block is not known yet.
    static func checkedShare(toScan: [(first: Int, end: Int)], birthday: Int, tip: Int) -> Double? {
        let span = tip - birthday
        guard tip > 0, span > 0 else { return nil }
        let parts = toScan.map { (max($0.first, birthday), min($0.end, tip)) }
            .filter { $0.1 > $0.0 }
            .sorted { $0.0 < $1.0 }
        var open = 0
        var reach = birthday
        for (a, b) in parts {
            let from = max(a, reach)
            if b > from { open += b - from }
            reach = max(reach, b)
        }
        return max(0, min(1, Double(span - open) / Double(span)))
    }

    /// How far this wallet is checked without gaps from its own birthday:
    /// the first block still to check at or after the birthday, or the
    /// network block when none is left. Older ranges (another wallet's) do
    /// not count. Nil while the network block is not known.
    /// Older blocks still to check below the birthday (for another wallet):
    /// where they start and the share done. nil when there are none. The
    /// start is the lowest seen, so the share grows as the engine works.
    static func older(toScan: [(first: Int, end: Int)], birthday: Int, start remembered: Int?) -> (start: Int, share: Double)? {
        let below = toScan.compactMap { r -> (Int, Int)? in
            let end = min(r.end, birthday)
            return r.first < end ? (r.first, end) : nil
        }
        guard let lowest = below.map({ $0.0 }).min() else { return nil }
        let start = min(lowest, remembered ?? lowest)
        guard birthday > start else { return nil }
        let open = below.reduce(0) { $0 + ($1.1 - $1.0) }
        return (start, max(0, min(1, 1 - Double(open) / Double(birthday - start))))
    }

    static func checkedThrough(toScan: [(first: Int, end: Int)], birthday: Int, tip: Int) -> Int? {
        guard tip > 0, tip > birthday else { return nil }
        let starts = toScan.filter { $0.end > birthday && $0.first < tip }.map { max($0.first, birthday) }
        return starts.min() ?? tip
    }

    /// The ring's number: one decimal, rounded down, so a few hundred new
    /// blocks still move it. 100 only when the wallet really is up to date.
    static func ringPercent(share: Double, synced: Bool) -> Double {
        if synced { return 100 }
        return min(99.9, (share * 1000).rounded(.down) / 10)
    }

    /// How far along the span from the birthday to the network block the
    /// gap-free part reaches, 0…1.
    static func checkedFraction(birthday: Int, wallet: Int, network: Int) -> Double {
        let span = network - birthday
        guard span > 0, wallet > 0 else { return 0 }
        return max(0, min(1, Double(wallet - birthday) / Double(span)))
    }
}

/// Sync details, from the status line: the ring, the blocks, what is checked,
/// the server and recent problems. Read-only; nothing is sent anywhere.
struct SyncSheet: View {
    @ObservedObject var engine: WalletEngine
    let onClose: () -> Void

    /// Up to date for this wallet: every block since its birthday is checked,
    /// even while the engine still works on older blocks for another wallet.
    private var upToDate: Bool { engine.status == .upToDate || engine.openBlocks == 0 }
    private var network: Int { engine.networkHeight }
    private var wallet: Int { engine.walletCheckedTo ?? (upToDate && engine.walletHeight == 0 ? network : engine.walletHeight) }
    private var behind: Int? { SyncMath.behind(network: network, wallet: wallet) }
    /// Right after a start, the engine reports placeholder heights until it
    /// has read its own scan state. Until then the rows show "…".
    private var known: Bool { network > 0 && (upToDate || engine.checkedPercent != nil) }

    var body: some View {
        SheetScaffold(title: "Sync", subtitle: subtitle, width: 520, height: 640, onClose: onClose) {
            // Scrolls inside the sheet, so the title and Done always stay in view.
            ScrollView(showsIndicators: false) {
            VStack(alignment: .leading, spacing: 16) {
                ring.frame(maxWidth: .infinity)
                section("Blocks") {
                    line("Network", network > 0 ? n(network) : "…")
                    // Until the network block is known, the engine's own
                    // heights are placeholders: show "…" instead.
                    line("This wallet", known && wallet > 0 ? n(wallet) : engine.lastWalletCheckedTo.map { n($0) + " (last time)" } ?? "…")
                    line("Behind", behindText)
                    if known, let start = engine.olderStart, let share = engine.olderShare {
                        line("Older blocks", String(format: "%.0f%% checked", (share * 100).rounded(.down)) + " · from \(n(start))")
                    }
                    line("Block time", network == 0 ? "…" : BlockTime.spacing(at: network) == 25 ? "25 seconds (since NU7)" : "75 seconds")
                    line("Wallet birthday", engine.birthdayHeight > 0 ? "Block \(n(engine.birthdayHeight))" : "…", last: true)
                }
                section("Checked so far") {
                    VStack(alignment: .leading, spacing: 6) {
                        GeometryReader { g in
                            let f = engine.checkedPercent.map { $0 / 100 }
                                ?? SyncMath.checkedFraction(birthday: engine.birthdayHeight, wallet: wallet, network: network)
                            ZStack(alignment: .leading) {
                                Capsule().fill(Theme.ink)
                                Capsule().fill(Theme.gold).frame(width: max(f > 0 ? 6 : 0, g.size.width * f))
                            }
                        }
                        .frame(height: 10)
                        .accessibilityLabel(wallet >= network && network > 0 ? "Every block since the birthday is checked" : "Checked up to block \(n(wallet))")
                        HStack {
                            Text(engine.birthdayHeight > 0 ? n(engine.birthdayHeight) : "…")
                            Spacer()
                            Text(network > 0 ? n(network) : "…")
                        }
                        .font(Theme.text(11)).foregroundStyle(Theme.muted)
                        Text("Gold is checked without gaps. Lock it checks the newest blocks first, so payments can show before the dark part is done.")
                            .font(Theme.text(11)).foregroundStyle(Theme.muted)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    .padding(14)
                }
                section("Server") {
                    line("Server", Server.nodeLabel.map { "\($0) (\(Server.host))" } ?? Server.host)
                    line("Connection", Server.isHomeNode(Server.host) ? "Direct, to your own node" : "Encrypted (TLS)", last: true)
                }
                section("Recent problems") {
                    if engine.problems.isEmpty {
                        Text("None since Lock it opened.").font(Theme.text(13)).foregroundStyle(Theme.muted).padding(14)
                    } else {
                        ForEach(engine.problems) { p in
                            HStack(alignment: .top, spacing: 12) {
                                Text(p.at.formatted(date: .omitted, time: .shortened)).font(Theme.text(12)).foregroundStyle(Theme.muted)
                                    .frame(width: 54, alignment: .leading)
                                Text(p.message).font(Theme.text(12)).foregroundStyle(Theme.text)
                                    .fixedSize(horizontal: false, vertical: true)
                                Spacer(minLength: 0)
                            }
                            .padding(.horizontal, 14).padding(.vertical, 10)
                        }
                    }
                }
                Text("Kept on this Mac only while Lock it is open.").font(Theme.text(11)).foregroundStyle(Theme.muted)
            }
            .padding(.bottom, 8)
            }
        }
    }

    private var subtitle: String {
        switch engine.status {
        case .connecting: return "Connecting…"
        case .syncing: return engine.syncingText
        case .upToDate: return "Up to date"
        case .failed: return "Having trouble, see below"
        }
    }

    private var behindText: String {
        // Blocks since the wallet birthday still to check (the engine may also
        // be checking older ranges that are not this wallet's).
        guard known, let behind = upToDate ? 0 : (engine.openBlocks ?? behind) else { return "…" }
        if behind == 0 { return "Nothing" }
        let minutes = SyncMath.minutesLeft(behind: behind, samples: engine.heightSamples)
        return "\(n(behind)) blocks" + (minutes.map { ", about \($0) min" } ?? "")
    }

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    /// The ring counts every block from the wallet birthday to the network
    /// block (as Lock it iPhone), one decimal, never 100 before up to date,
    /// gliding to each new reading in half a second (straight there with
    /// Reduce Motion). "…" until the network block is known.
    private var ring: some View {
        let percent = engine.checkedPercent
        let shown = percent ?? 0
        return VStack(spacing: 8) {
            ZStack {
                Circle().stroke(Theme.line, lineWidth: 10)
                Circle().trim(from: 0, to: shown / 100)
                    .stroke(Theme.gold, style: StrokeStyle(lineWidth: 10, lineCap: .round))
                    .rotationEffect(.degrees(-90))
                VStack(spacing: 2) {
                    if percent == nil {
                        Text("…").font(Theme.serif(30, weight: .medium)).foregroundStyle(Theme.text)
                    } else {
                        GlidingPercent(value: shown).font(Theme.serif(30, weight: .medium)).foregroundStyle(Theme.text)
                    }
                    Text(upToDate ? "up to date" : "checked").font(Theme.text(12)).foregroundStyle(Theme.muted)
                }
            }
            .frame(width: 150, height: 150)
            .animation(reduceMotion ? nil : .easeOut(duration: 0.5), value: shown)
            Text(ringNote)
                .font(Theme.text(12)).foregroundStyle(Theme.muted)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(.vertical, 6)
        .accessibilityElement(children: .combine)
    }

    private var ringNote: String {
        guard engine.checkedPercent != nil else {
            let last = engine.lastCheckedPercent.map { " Last time: " + String(format: "%.1f", min(100, $0)) + "%." } ?? ""
            return (network > 0 ? "Reading where the wallet is…" : "Waiting for the network block") + last
        }
        if upToDate { return "Every block since the wallet birthday" }
        if let open = engine.openBlocks, open > 0 {
            return "Of all blocks since the wallet birthday. Catching up \(n(open)) new \(open == 1 ? "block" : "blocks")."
        }
        return "Of all blocks since the wallet birthday"
    }

    private func section<C: View>(_ title: String, @ViewBuilder _ rows: () -> C) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title.uppercased()).font(Theme.text(11, weight: .semibold)).tracking(2).foregroundStyle(Theme.gold).padding(.leading, 4)
            VStack(spacing: 0) { rows() }
                .background(Theme.surface, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
                .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).stroke(Theme.line))
        }
    }

    private func line(_ label: String, _ value: String, last: Bool = false) -> some View {
        HStack {
            Text(label).font(Theme.text(13)).foregroundStyle(Theme.muted)
            Spacer(minLength: 12)
            Text(value).font(Theme.text(13, weight: .medium)).foregroundStyle(Theme.text).textSelection(.enabled)
        }
        .padding(.horizontal, 14).frame(height: 40)
        .overlay(alignment: .bottom) { if !last { Rectangle().fill(Theme.line).frame(height: 1).padding(.leading, 14) } }
    }

    private func n(_ v: Int) -> String { v.formatted(.number.grouping(.automatic).locale(Locale(identifier: "en_US"))) }
}

/// "Locked for …": opened from the line under the balance. How long the
/// Zcash in this wallet has been in the lock, the milestone path and a few
/// highlights, all worked out on this Mac from the wallet history (as Lock
/// it iPhone's HoldingScreen). Nothing is sent or stored but which milestone
/// moment was already shown.
struct HoldingSheet: View {
    @ObservedObject var model: AppModel
    @ObservedObject var engine: WalletEngine
    let onClose: () -> Void

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var all = false
    /// The milestone moment: once, the first time the page opens that day.
    @State private var moment: Int?
    @State private var light: Double = 0

    private var summary: Holding.Summary? { Holding.summary(engine.holdingEntries) }

    var body: some View {
        let h = summary
        let held = h.map { Holding.heldFor(days: $0.days) }
        SheetScaffold(title: h == nil ? "Nothing locked" : "Locked \(held!)",
                      subtitle: h.map { "Since \(Self.date($0.since))" },
                      width: 520, height: 640, onClose: onClose) {
            ScrollView(showsIndicators: false) {
                VStack(alignment: .leading, spacing: 16) {
                    if let h {
                        ring(h)
                        if let moment {
                            Text("\(Milestone.name(moment)). \(Milestone.line(moment))")
                                .font(Theme.serif(17)).foregroundStyle(Theme.gold)
                                .frame(maxWidth: .infinity)
                                .opacity(light)
                        }
                        section("Milestones") { milestones(h) }
                        section("Highlights") { highlights(h) }
                    }
                    Text(h == nil ? "The count starts when Zcash comes into the lock."
                                  : "Worked out on this Mac from your own payments. Sending or receiving more never resets it; only an empty lock does.")
                        .font(Theme.text(11)).foregroundStyle(Theme.muted)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .padding(.bottom, 8)
            }
        }
        .onAppear { showMoment() }
    }

    // MARK: Ring

    private func ring(_ h: Holding.Summary) -> some View {
        let words = Holding.heldFor(days: h.days).replacingOccurrences(of: "for ", with: "").split(separator: " ")
        return ZStack {
            MilestoneRing(progress: Milestone.progress(after: h.days), diameter: 150,
                          glow: Milestone.reachedToday(after: h.days))
            VStack(spacing: 0) {
                if h.days < 1 {
                    Text("since today").font(Theme.serif(20)).foregroundStyle(Theme.text)
                } else {
                    Text(String(words.first ?? "")).font(Theme.serif(36, weight: .medium)).foregroundStyle(Theme.text)
                        .monospacedDigit()
                    Text(words.dropFirst().joined(separator: " ")).font(Theme.text(13)).foregroundStyle(Theme.muted)
                }
            }
        }
        .frame(width: 170, height: 170)
        .frame(maxWidth: .infinity)
        .accessibilityElement(children: .combine)
    }

    // MARK: Milestones

    private func milestones(_ h: Holding.Summary) -> some View {
        let full = Milestone.path(since: h.since, held: h.days)
        let path = all ? full : Milestone.shortPath(full)
        return Button { withAnimation(.easeOut(duration: 0.2)) { all.toggle() } } label: {
            VStack(alignment: .leading, spacing: 0) {
                ForEach(Array(path.enumerated()), id: \.element.days) { i, step in
                    stepRow(step, last: i == path.count - 1, nextReached: i + 1 < path.count && path[i + 1].reached)
                }
                Text(all ? "Show less" : "Show all milestones ›")
                    .font(Theme.text(12, weight: .medium)).foregroundStyle(Theme.gold)
                    .padding(.top, 6)
            }
            .padding(14)
            .frame(maxWidth: .infinity, alignment: .leading)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityHint(all ? "Shows fewer milestones" : "Shows every milestone")
    }

    private func stepRow(_ step: Milestone.Step, last: Bool, nextReached: Bool) -> some View {
        let next = step.progress != nil
        let dim = !step.reached && !next
        return HStack(alignment: .top, spacing: 12) {
            VStack(spacing: 0) {
                Circle()
                    .fill(step.reached ? Theme.gold : Color.clear)
                    .overlay(Circle().stroke(step.reached || next ? Theme.gold : Theme.line, lineWidth: 1.5))
                    .frame(width: 10, height: 10)
                    .padding(.top, 4)
                if !last {
                    Rectangle().fill(step.reached && nextReached ? Theme.gold : Theme.line)
                        .frame(width: 1.5).frame(maxHeight: .infinity)
                }
            }
            .frame(width: 12)
            VStack(alignment: .leading, spacing: 3) {
                Text(step.name).font(Theme.text(14, weight: .semibold))
                    .foregroundStyle(dim ? Theme.muted : Theme.text)
                Text(step.reached ? "\(step.length) · \(Self.date(step.at))"
                     : next ? "\(step.length) · in \(step.inDays ?? 0) \(step.inDays == 1 ? "day" : "days")"
                     : step.length)
                    .font(Theme.text(12)).foregroundStyle(Theme.muted.opacity(dim ? 0.7 : 1))
                if next {
                    GeometryReader { g in
                        ZStack(alignment: .leading) {
                            Capsule().fill(Theme.line)
                            Capsule().fill(Theme.gold).frame(width: max(3, g.size.width * (step.progress ?? 0)))
                        }
                    }
                    .frame(height: 4).padding(.top, 3)
                }
            }
            .padding(.bottom, last ? 0 : 12)
            .padding(.horizontal, moment == step.days ? 6 : 0)
            .background(alignment: .leading) {
                if moment == step.days {
                    RoundedRectangle(cornerRadius: 6).fill(Theme.gold.opacity(0.12 * light))
                }
            }
            Spacer(minLength: 0)
        }
        .fixedSize(horizontal: false, vertical: true)
    }

    // MARK: Highlights

    private func highlights(_ h: Holding.Summary) -> some View {
        let pace = Holding.pace(received: h.current.received, days: h.days)
        return VStack(spacing: 0) {
            line("Since", Self.date(h.since))
            line("Received since then", amount(h.current.received))
            if let pace { line("Stacking pace", "+\(amount(pace.zatoshi)) a \(pace.per.rawValue)") }
            line("Payments in", "\(h.current.paymentsIn)", last: h.current.largest == nil && h.longestBefore == nil)
            if let largest = h.current.largest {
                line("Largest payment in", "\(amount(largest.zatoshi)) · \(Self.date(largest.at))", last: h.longestBefore == nil)
            }
            if let longest = h.longestBefore {
                line("Longest before", Holding.heldFor(days: longest.days).replacingOccurrences(of: "for ", with: ""), last: true)
            }
        }
    }

    // MARK: The milestone moment

    private func showMoment() {
        guard let h = summary, Milestone.reachedToday(after: h.days) else { moment = nil; return }
        moment = h.days
        if MilestoneMoment.seen(since: h.since, days: h.days) || reduceMotion {
            MilestoneMoment.markSeen(since: h.since, days: h.days)
            light = 1
            return
        }
        MilestoneMoment.markSeen(since: h.since, days: h.days)
        light = 0
        withAnimation(.easeInOut(duration: 1.8).delay(0.4)) { light = 1 }
    }

    // MARK: Helpers

    private func amount(_ zatoshi: Int64) -> String { model.amountsHidden ? "••••" : Amount.text(zatoshi, model.unit) }

    static func date(_ d: Date) -> String {
        d.formatted(.dateTime.month(.abbreviated).day().year().locale(Locale(identifier: "en_US")))
    }

    private func section<C: View>(_ title: String, @ViewBuilder _ rows: () -> C) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title.uppercased()).font(Theme.text(11, weight: .semibold)).tracking(2).foregroundStyle(Theme.gold).padding(.leading, 4)
            VStack(spacing: 0) { rows() }
                .background(Theme.surface, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
                .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).stroke(Theme.line))
        }
    }

    private func line(_ label: String, _ value: String, last: Bool = false) -> some View {
        HStack {
            Text(label).font(Theme.text(13)).foregroundStyle(Theme.muted)
            Spacer(minLength: 12)
            Text(value).font(Theme.text(13, weight: .medium)).foregroundStyle(Theme.text).textSelection(.enabled)
        }
        .padding(.horizontal, 14).frame(height: 40)
        .overlay(alignment: .bottom) { if !last { Rectangle().fill(Theme.line).frame(height: 1).padding(.leading, 14) } }
    }
}

/// A percentage that SwiftUI animates between readings: "99.6%", always one
/// decimal, rounded down, and "100%" only at 100.
struct GlidingPercent: View, Animatable {
    var value: Double
    var animatableData: Double {
        get { value }
        set { value = newValue }
    }
    var body: some View {
        Text(value >= 100 ? "100%" : String(format: "%.1f%%", (value * 10).rounded(.down) / 10))
            .monospacedDigit()
    }
}
