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
