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

    private var upToDate: Bool { engine.status == .upToDate }
    private var network: Int { engine.networkHeight }
    private var wallet: Int { upToDate && engine.walletHeight == 0 ? network : engine.walletHeight }
    private var behind: Int? { SyncMath.behind(network: network, wallet: wallet) }

    var body: some View {
        SheetScaffold(title: "Sync", subtitle: subtitle, width: 520, height: 640, onClose: onClose) {
            // Scrolls inside the sheet, so the title and Done always stay in view.
            ScrollView(showsIndicators: false) {
            VStack(alignment: .leading, spacing: 16) {
                ring.frame(maxWidth: .infinity)
                section("Blocks") {
                    line("Network", network > 0 ? n(network) : "…")
                    line("This wallet", wallet > 0 ? n(wallet) : "…")
                    line("Behind", behindText)
                    line("Block time", BlockTime.spacing(at: max(network, 1)) == 25 ? "25 seconds (since NU7)" : "75 seconds")
                    line("Wallet birthday", engine.birthdayHeight > 0 ? "Block \(n(engine.birthdayHeight))" : "…", last: true)
                }
                section("Checked so far") {
                    VStack(alignment: .leading, spacing: 6) {
                        GeometryReader { g in
                            let f = SyncMath.checkedFraction(birthday: engine.birthdayHeight, wallet: wallet, network: network)
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
        case .syncing(let pct): return pct >= 100 ? "Finishing…" : "Syncing \(pct)%"
        case .upToDate: return "Up to date"
        case .failed: return "Having trouble, see below"
        }
    }

    private var behindText: String {
        guard let behind else { return "…" }
        if behind == 0 { return "Nothing" }
        let minutes = SyncMath.minutesLeft(behind: behind, samples: engine.heightSamples)
        return "\(n(behind)) blocks" + (minutes.map { ", about \($0) min" } ?? "")
    }

    private var ring: some View {
        let progress = upToDate ? 1 : engine.syncFraction
        return ZStack {
            Circle().stroke(Theme.line, lineWidth: 10)
            Circle().trim(from: 0, to: progress)
                .stroke(Theme.gold, style: StrokeStyle(lineWidth: 10, lineCap: .round))
                .rotationEffect(.degrees(-90))
                .animation(.easeOut(duration: 0.4), value: progress)
            VStack(spacing: 2) {
                Text("\(Int((progress * 100).rounded(.down)))%").font(Theme.serif(30, weight: .medium)).foregroundStyle(Theme.text)
                Text(upToDate ? "up to date" : "checked").font(Theme.text(12)).foregroundStyle(Theme.muted)
            }
        }
        .frame(width: 150, height: 150)
        .padding(.vertical, 6)
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
