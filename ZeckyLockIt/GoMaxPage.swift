import AppKit
import SwiftUI

/// Settings › Go Max: one switch, two lines, and the fine print tucked away.
struct GoMaxPage: View {
    @ObservedObject var node: GoMaxNode
    @ObservedObject private var attest = AttestedStatementMaker.shared
    @State private var confirmRemove = false
    @State private var working = false
    @State private var showMore = false
    @State private var showStillNot = false
    @State private var showCheck = false
    @State private var showWhyPrivate = false
    @State private var computer: GoMaxComputer?
    /// "Before you start Go Max" is shown at the first switch-on only;
    /// afterwards from "Check this computer".
    @AppStorage("goMax.checkShown") private var checkShown = false

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            VStack(alignment: .leading, spacing: 10) {
                Label("Go Max", systemImage: "point.3.connected.trianglepath.dotted")
                    .font(Theme.text(13, weight: .semibold))
                    .foregroundStyle(Theme.text)
                    .labelStyle(GoldIconLabelStyle())
                Text("Your own Zcash node, inside Lock it. It checks every block since Canopy on this Mac, and Lock it reads the chain from it instead of a server.")
                    .font(Theme.text(12)).foregroundStyle(Theme.muted)
                    .fixedSize(horizontal: false, vertical: true)

                if GoMaxNode.isAvailable {
                    GoMaxSwitch(on: node.enabled, busy: working) { switchTo(!node.enabled) }
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 6)
                    HStack(alignment: .firstTextBaseline, spacing: 10) {
                        Text(GoMaxWords.privateLine)
                            .font(Theme.text(12)).foregroundStyle(Theme.muted)
                            .fixedSize(horizontal: false, vertical: true)
                        Button(showWhyPrivate ? "Less" : "What is this?") { showWhyPrivate.toggle() }
                            .buttonStyle(.plain).font(Theme.text(12, weight: .medium)).foregroundStyle(Theme.gold)
                    }
                    if showWhyPrivate {
                        ForEach(GoMaxWords.whyPrivate, id: \.self) { part in
                            Text(part).font(Theme.text(12)).foregroundStyle(Theme.muted)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                    }
                    if node.disconnected {
                        Text("Not connected to other Zcash nodes · check this Mac's internet connection. Some networks (office, hotel, guest Wi-Fi) block Zcash nodes. A second Zcash node on the same internet connection, such as Rock it, may also be taking the peers.")
                            .font(Theme.text(13)).foregroundStyle(Theme.gold)
                            .fixedSize(horizontal: false, vertical: true)
                    } else if let quiet = node.quietMinutes {
                        Text("No new blocks for \(quiet) minutes · check this Mac's internet connection")
                            .font(Theme.text(13)).foregroundStyle(Theme.gold)
                            .fixedSize(horizontal: false, vertical: true)
                    } else if !node.stoppedWhileStarting && !node.retrying {
                        Text(GoMaxWords.status(node.phase, node.info))
                            .font(Theme.text(13)).foregroundStyle(node.phase == .ready && node.info?.shownUpToDate != false ? Theme.green : Theme.text)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    if node.spamLine != nil {
                        HStack(spacing: 8) {
                            Text("Expected finish").font(Theme.text(12)).foregroundStyle(Theme.muted)
                            Text(GoMaxPace.finishText(node.finishAt)).font(Theme.text(12, weight: .medium)).foregroundStyle(Theme.text)
                        }
                    }
                    // Where the wallet reads from, when that is not simply this node.
                    Group {
                        if node.enabled, !node.readsFromNode, let from = node.olderFrom {
                            Text(GoMaxWords.olderBlocks(from: from, server: Server.host))
                                .font(Theme.text(12)).foregroundStyle(Theme.muted)
                                .fixedSize(horizontal: false, vertical: true)
                        } else if node.enabled, node.phase == .ready, !node.readsFromNode {
                            Text("Lock it still reads the chain from \(Server.host). It moves to this node by itself once the node has stayed at the newest block for half a minute.")
                                .font(Theme.text(12)).foregroundStyle(Theme.muted)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                        if node.readsFromNode, let from = node.olderFrom {
                            Text(GoMaxWords.olderBlocksOnNode(from: from))
                                .font(Theme.text(12)).foregroundStyle(Theme.gold)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                        if node.unsettled, !node.readsFromNode {
                            Text(GoMaxWords.unsettled(server: Server.host))
                                .font(Theme.text(12)).foregroundStyle(Theme.gold)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                        if node.phase == .paused {
                            Text("Meanwhile Lock it reads the chain from \(Server.host).")
                                .font(Theme.text(12)).foregroundStyle(Theme.muted)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                        if node.walletQuiet {
                            Text(GoMaxWords.walletQuiet)
                                .font(Theme.text(12)).foregroundStyle(Theme.gold)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                    }
                    if let peers = node.peers, peers > 0, node.phase != .off {
                        Text(GoMaxWords.peers(peers))
                            .font(Theme.text(12)).foregroundStyle(Theme.muted)
                    }
                    supportNotice
                    if let info = node.info, node.phase != .off {
                        Text(GoMaxWords.storage(sizeOnDisk: info.sizeOnDisk, retention: node.retention))
                            .font(Theme.text(12)).foregroundStyle(Theme.muted)
                    }
                    if let spam = node.spamLine {
                        Text(spam).font(Theme.text(12)).foregroundStyle(Theme.muted)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    if node.hasData, node.downloaded.total > 0 {
                        dataOverview
                    }
                    if node.stoppedWhileStarting || node.retrying {
                        // One calm line, one button; the rest only when asked for.
                        Text(node.retrying ? GoMaxWords.tryingAgain : GoMaxWords.stoppedWhileStarting)
                            .font(Theme.text(13)).foregroundStyle(Theme.gold)
                            .fixedSize(horizontal: false, vertical: true)
                        if !node.retrying {
                            HStack(spacing: 14) {
                                SecondaryButton(title: "Try again") { Task { await node.tryAgain() } }
                                    .frame(width: 150)
                                Button(showStillNot ? "Less" : "Still not working?") { showStillNot.toggle() }
                                    .buttonStyle(.plain).font(Theme.text(12, weight: .medium)).foregroundStyle(Theme.gold)
                            }
                            if showStillNot {
                                Text(GoMaxWords.stillNotWorking)
                                    .font(Theme.text(12)).foregroundStyle(Theme.muted)
                                    .fixedSize(horizontal: false, vertical: true)
                            }
                        }
                    } else if let problem = node.problem {
                        Text(problem).font(Theme.text(12)).foregroundStyle(Theme.red)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    if !node.enabled && !node.hasData {
                        Text("15 GB of disk to start, about 22 GB after a month. The first check takes most of a day (about 14 hours on a MacBook Air) and downloads the whole chain once, about 350 GB, deleting older blocks as it goes. Keep Lock it open; the check pauses while the Mac sleeps and carries on after.")
                            .font(Theme.text(12)).foregroundStyle(Theme.muted)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    HStack(spacing: 18) {
                        Button("Check this computer") { openCheck() }
                            .buttonStyle(.plain).font(Theme.text(12, weight: .medium)).foregroundStyle(Theme.gold)
                        Spacer()
                    }
                    if PowerSource.read().hasBattery {
                        Toggle(isOn: Binding(get: { node.onlyWhilePluggedIn }, set: { node.onlyWhilePluggedIn = $0 })) {
                            VStack(alignment: .leading, spacing: 2) {
                                Text("Only sync while plugged in").font(Theme.text(13, weight: .medium)).foregroundStyle(Theme.text)
                                Text("On battery, the first check and catching up wait for the charger. Up to date, the node keeps running: it needs little power then.")
                                    .font(Theme.text(11)).foregroundStyle(Theme.muted)
                                    .fixedSize(horizontal: false, vertical: true)
                            }
                        }
                        .toggleStyle(.switch).controlSize(.small).tint(Theme.gold)
                    }
                } else {
                    Text("This build of Lock it has no node inside.")
                        .font(Theme.text(13)).foregroundStyle(Theme.muted)
                }

                Button(showMore ? "Less" : "How Go Max works") { showMore.toggle() }
                    .buttonStyle(.plain).font(Theme.text(12, weight: .medium)).foregroundStyle(Theme.gold)
                if showMore {
                    ForEach(Self.details, id: \.self) { line in
                        Text(line).font(Theme.text(12)).foregroundStyle(Theme.muted)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    if let logs = node.logsFolder, node.hasData {
                        Button("Show the node's logs") { NSWorkspace.shared.activateFileViewerSelecting([logs]) }
                            .buttonStyle(.plain).font(Theme.text(12, weight: .medium)).foregroundStyle(Theme.gold)
                    }
                }
            }
            .card(padding: 16)

            if node.hasData {
                AdvancedBox(featureOn: attest.serving) { GoMaxAttestCard() }
            }

            if node.hasData {
                Button { confirmRemove = true } label: {
                    Text("Remove node and its data…")
                        .font(Theme.text(13, weight: .medium)).foregroundStyle(Theme.red)
                        .padding(.horizontal, 14).frame(height: 32)
                        .overlay(RoundedRectangle(cornerRadius: 8).stroke(Theme.red.opacity(0.6)))
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .disabled(working)
            }
        }
        .alert("Remove the node?", isPresented: $confirmRemove) {
            Button("Cancel", role: .cancel) {}
            Button("Remove", role: .destructive) { run { await node.remove() } }
        } message: {
            Text("Go Max stops and its data (15 to 22 GB) is deleted from this Mac. Lock it goes back to its server. Your wallets are not touched. Switching Go Max on again starts the check from the beginning.")
        }
        .sheet(isPresented: $showCheck) {
            GoMaxCheckSheet(computer: computer ?? node.computerCheck(), hasData: node.hasData,
                            onlyPluggedIn: node.onlyWhilePluggedIn, starting: !node.enabled) {
                showCheck = false
                checkShown = true
                if !node.enabled { switchTo(true) }
            } onCancel: {
                showCheck = false
            }
        }
    }

    /// What the node downloaded, keeps, removed after checking, and uploaded.
    private var dataOverview: some View {
        VStack(alignment: .leading, spacing: 3) {
            Grid(alignment: .leading, horizontalSpacing: 18, verticalSpacing: 2) {
                dataRow("Downloaded", node.downloaded.total)
                if let kept = node.kept {
                    dataRow("Kept on this Mac", kept)
                    dataRow("Removed after check", GoMaxData.removed(downloaded: node.downloaded.total, kept: kept))
                }
                dataRow("Uploaded", node.uploaded.total)
            }
            Text(GoMaxData.footnote)
                .font(Theme.text(11)).foregroundStyle(Theme.muted)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(.top, 2)
    }

    private func dataRow(_ label: String, _ bytes: Double) -> some View {
        GridRow {
            Text(label).font(Theme.text(12)).foregroundStyle(Theme.muted)
            Text(GoMaxData.format(bytes)).font(Theme.text(12, weight: .medium)).foregroundStyle(Theme.text)
                .monospacedDigit()
                .gridColumnAlignment(.trailing)
        }
    }

    /// The node version's last block: a calm line two weeks ahead, and at
    /// the stop the choice between a public server and waiting.
    @ViewBuilder private var supportNotice: some View {
        if node.phase == .expired {
            Text("This node version follows the Zcash chain up to block \(GoMaxSupport.stopHeightText), and the network is now past it. Go Max carries on after an update of Lock it; the node's data is kept. Your Zcash is not affected.")
                .font(Theme.text(13)).foregroundStyle(Theme.gold)
                .fixedSize(horizontal: false, vertical: true)
            if node.readsFromNode {
                Text(node.expiredChoice == "wait"
                     ? "Waiting for the update. Until then Lock it does not see new blocks, so no new payments."
                     : "Until then, choose: read the chain from a public server (\(node.fallbackServer)), which sees this Mac's internet address, or wait for the update. Nothing is switched without you.")
                    .font(Theme.text(12)).foregroundStyle(Theme.muted)
                    .fixedSize(horizontal: false, vertical: true)
                HStack(spacing: 10) {
                    SecondaryButton(title: "Use \(node.fallbackServer)") { run { await node.useServerWhileExpired() } }
                        .frame(width: 220)
                    if node.expiredChoice == nil {
                        SecondaryButton(title: "Wait for the update") { node.waitWhileExpired() }
                            .frame(width: 200)
                    }
                }
            } else {
                Text("Until the update, Lock it reads the chain from \(Server.host).")
                    .font(Theme.text(12)).foregroundStyle(Theme.muted)
                    .fixedSize(horizontal: false, vertical: true)
            }
        } else if case .soon(let date) = node.support, node.enabled || node.hasData {
            Text("Go Max needs an update before \(GoMaxSupport.dateText(date)). This node version follows the chain up to block \(GoMaxSupport.stopHeightText); a newer Lock it brings the next one.")
                .font(Theme.text(12)).foregroundStyle(Theme.gold)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private func openCheck() {
        computer = node.computerCheck()
        showCheck = true
    }

    private func switchTo(_ on: Bool) {
        // The first switch-on shows this Mac's check first.
        if on, !checkShown, !node.hasData { openCheck(); return }
        run {
            if on { await node.switchOn() } else { await node.switchOff() }
        }
    }

    private func run(_ action: @escaping () async -> Void) {
        working = true
        Task {
            await action()
            working = false
        }
    }

    static let details = [
        "Until the node is up to date, Lock it keeps using your server. Then it switches to the node by itself. Switching Go Max off, or a problem with the node, switches back, and this page says so. The node keeps only recent blocks: when a wallet still has older blocks to check, after adding or restoring a wallet, Lock it reads those from your server and returns to the node afterwards.",
        "The node connects to other Zcash nodes on the internet, like every node: they see this Mac's internet address, never your wallets, addresses or balance. Lock it talks to the node on this Mac only, and the node accepts no connections from outside: it passes new blocks and transactions on to the nodes it connects to, but your address is never announced as a Zcash node.",
        "The first check downloads about 350 GB; afterwards a day of new blocks is small. The page counts what the node downloaded, keeps, removed after checking and uploaded, on this Mac only. Better on a connection without a data limit; Lock it says so when macOS reports Low Data Mode or a costly connection.",
        "Every block since the Canopy upgrade (2020) is checked here, proofs and all. Older blocks are accepted on checkpoints built into the node, as every Zcash node does.",
        "The node keeps about a month of recent blocks in full, and what every node needs to check new ones. Its files live in Lock it's own folder, left out of Time Machine.",
        "It runs while Lock it is open. While it is checking or catching up, the Mac does not fall asleep on its own; up to date, it sleeps as usual. On a MacBook, \"Only sync while plugged in\" (on unless you switch it off) pauses checking and catching up on battery, and Lock it reads from your server meanwhile; up to date, the node keeps running on battery.",
        "Genuine node (experimental, off unless you switch it on): wallets and other nodes that ask over Tor can check that this node is genuine Lock it on a real Mac, signed with Apple's App Attest. Each answer also carries a fingerprint of the chain, which may later help new nodes start faster; nothing uses that yet. Only public chain data is shared. Switching it on contacts Apple once from this Mac's internet address to set up a key; the key is the same in every answer, so answers can be linked to each other, and Apple could link this Mac's internet address to the node's onion address. New address makes a new key (one more contact with Apple).",
        "Each version of the node follows the chain up to a fixed block, about six weeks after it comes out; this one up to block \(GoMaxSupport.stopHeightText). Lock it says so two weeks ahead. At that block the node stops and Lock it asks you: a public server, or wait for the update.",
    ]
}

/// The Go Max button on the home screen, above Settings: a brass coin
/// with the node mark, in the padlock's metal, on a dark capsule (brass
/// stays the main action's: the coin is a mark, not a fill). Off, it
/// breathes a soft glow; checking, a ring fills around the coin; up to
/// date, the coin carries a seal. A click opens Settings › Go Max, where
/// the price (disk, time, download) is read before anything starts.
struct GoMaxButton: View {
    @ObservedObject var node: GoMaxNode
    /// Genuine node: said on the button while the node is up to date and
    /// answers checks. A status of what the node does, not a proof: the
    /// proof is another device's check (an app cannot vouch for itself).
    @ObservedObject private var attest = AttestedStatementMaker.shared
    @ObservedObject private var onion = AttestOnion.shared
    let open: () -> Void
    @State private var hover = false
    @State private var breathe = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private static func c(_ hex: Int) -> Color {
        Color(red: Double((hex >> 16) & 0xFF) / 255, green: Double((hex >> 8) & 0xFF) / 255, blue: Double(hex & 0xFF) / 255)
    }

    var body: some View {
        Button(action: open) {
            HStack(spacing: 12) {
                coin
                VStack(alignment: .leading, spacing: 2) {
                    Text("Go Max").font(Theme.serif(18, weight: .medium)).foregroundStyle(Theme.text)
                    Text(subtitle).font(Theme.text(12)).foregroundStyle(subtitleColor).lineLimit(1)
                }
            }
            .padding(.leading, 8).padding(.trailing, 22).frame(height: 62)
            .background(Theme.surface, in: Capsule())
            .overlay(Capsule().stroke(Theme.gold.opacity(hover ? 0.95 : 0.55), lineWidth: 1))
            .shadow(color: Theme.gold.opacity(glow), radius: inviting ? 18 : 8, y: 3)
            .scaleEffect(hover ? 1.02 : 1)
            .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .onHover { h in withAnimation(.easeOut(duration: 0.18)) { hover = h } }
        .onAppear {
            guard !reduceMotion else { return }
            withAnimation(.easeInOut(duration: 2.4).repeatForever(autoreverses: true)) { breathe = true }
        }
        .help(showsGenuine
              ? "Go Max: your own Zcash node on this Mac. Genuine node is on: other wallets and nodes can check over Tor that it is genuine Lock it. The proof is their check, not this label."
              : "Go Max: your own Zcash node on this Mac")
        .accessibilityLabel("Go Max, \(subtitle)")
    }

    /// The brass coin, engraved with what the node is doing.
    private var coin: some View {
        ZStack {
            Circle().fill(LinearGradient(stops: [
                .init(color: Self.c(0xF6E2B0), location: 0),
                .init(color: Self.c(0xD9AE5F), location: 0.48),
                .init(color: Self.c(0xB88A3E), location: 0.52),
                .init(color: Self.c(0x9C7330), location: 1),
            ], startPoint: .top, endPoint: .bottom))
            Circle().stroke(Self.c(0x5E4519).opacity(0.8), lineWidth: 1)
            Circle().inset(by: 1.5).stroke(Self.c(0xFFF3D1).opacity(0.45), lineWidth: 1)
            Image(systemName: glyph)
                .font(.system(size: 17, weight: .semibold))
                .foregroundStyle(Self.c(0x3A2A0C))
                .shadow(color: Self.c(0xFFF3D1).opacity(0.6), radius: 0, y: 1)
            if checking {
                Circle().stroke(Theme.gold.opacity(0.2), lineWidth: 2.5).frame(width: 52, height: 52)
                Circle().trim(from: 0, to: max(0.03, CGFloat(node.info?.verificationProgress ?? 0)))
                    .stroke(Theme.gold, style: StrokeStyle(lineWidth: 2.5, lineCap: .round))
                    .rotationEffect(.degrees(-90))
                    .frame(width: 52, height: 52)
            }
            if showsGenuine {
                // Up to date and answering checks over Tor: a small check
                // instead of the green dot.
                Image(systemName: "checkmark.circle.fill")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(Theme.surface, Theme.green)
                    .background(Circle().fill(Theme.surface).padding(-1.5))
                    .offset(x: 16, y: 16)
            } else if let badge {
                Circle().fill(badge).frame(width: 12, height: 12)
                    .overlay(Circle().stroke(Theme.surface, lineWidth: 2))
                    .offset(x: 16, y: 16)
            }
        }
        .frame(width: 44, height: 44)
        .padding(4)
    }

    private var inviting: Bool { node.phase == .off || node.phase == .stopped }
    /// Genuine node is answering checks and reachable over Tor: only then
    /// can anyone outside this Mac check it.
    private var genuineOn: Bool { attest.serving && onion.address != nil }
    /// Said on the button only when nothing else needs saying.
    private var showsGenuine: Bool {
        genuineOn && node.phase == .ready && node.info?.shownUpToDate != false
            && !node.disconnected && node.quietMinutes == nil && updateBefore == nil
            && !(node.olderFrom != nil && !node.readsFromNode)
    }
    private var checking: Bool { [.starting, .syncing, .catchingUp, .updating].contains(node.phase) }
    private var glow: Double {
        if inviting { return hover ? 0.5 : (breathe ? 0.38 : 0.14) }
        return node.phase == .ready ? 0.12 : 0
    }

    private var glyph: String {
        switch node.phase {
        case .ready: return "checkmark.seal.fill"
        case .problem, .expired: return "exclamationmark"
        default: return "point.3.connected.trianglepath.dotted"
        }
    }

    /// The stop is near and the node is running: said on the coin too.
    private var updateBefore: String? {
        guard node.phase == .ready, case .soon(let date) = node.support else { return nil }
        return "Update before \(GoMaxSupport.dateText(date))"
    }

    private var badge: Color? {
        if node.disconnected || node.quietMinutes != nil || node.phase == .expired { return Theme.gold }
        switch node.phase {
        case .ready: return Theme.green
        case .problem: return Theme.red
        default: return nil
        }
    }

    private var subtitle: String {
        if node.disconnected { return "Not connected · check connection" }
        if node.quietMinutes != nil { return "No new blocks · check connection" }
        if let updateBefore { return updateBefore }
        if node.olderFrom != nil, !node.readsFromNode, node.phase == .ready { return "Older blocks · from server" }
        switch node.phase {
        case .off: return "Run your own node"
        case .stopped: return "Off · data kept"
        case .ready:
            if node.info?.shownUpToDate == false { return "Catching up" }
            return showsGenuine ? "Your own genuine node" : "Your own node"
        case .problem: return "Stopped · open to see why"
        case .expired: return "Needs an update · open"
        default: return GoMaxWords.short(node.phase, node.info)
        }
    }

    private var subtitleColor: Color {
        if node.disconnected || node.quietMinutes != nil || updateBefore != nil || node.phase == .expired { return Theme.gold }
        switch node.phase {
        case .ready: return Theme.green
        case .problem: return Theme.red
        default: return Theme.muted
        }
    }
}

/// The Go Max switch: the brass coin slides across a wide track and the
/// track lights up when it is on. On a Force Touch trackpad the change is
/// felt as a click. One click (or Space) switches; nothing starts without
/// the price on the same page.
struct GoMaxSwitch: View {
    let on: Bool
    var busy = false
    let action: () -> Void
    @State private var hover = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private static let width: CGFloat = 300
    private static let height: CGFloat = 64
    private static let knob: CGFloat = 54

    private static func c(_ hex: Int) -> Color {
        Color(red: Double((hex >> 16) & 0xFF) / 255, green: Double((hex >> 8) & 0xFF) / 255, blue: Double(hex & 0xFF) / 255)
    }

    var body: some View {
        Button {
            NSHapticFeedbackManager.defaultPerformer.perform(.levelChange, performanceTime: .now)
            action()
        } label: {
            ZStack(alignment: on ? .trailing : .leading) {
                // The track: dark when off, lit gold when on.
                Capsule()
                    .fill(on
                          ? AnyShapeStyle(LinearGradient(colors: [Theme.gold.opacity(0.18), Theme.gold.opacity(0.42)], startPoint: .leading, endPoint: .trailing))
                          : AnyShapeStyle(Theme.ink))
                Capsule().stroke(Theme.gold.opacity(on ? 0.9 : (hover ? 0.7 : 0.45)), lineWidth: 1)
                // The words sit on the side the coin is not.
                Text(on ? "GO MAX IS ON" : "SWITCH ON")
                    .font(Theme.text(12, weight: .semibold)).tracking(2.5)
                    .foregroundStyle(on ? Theme.text : Theme.gold)
                    .frame(maxWidth: .infinity)
                    .padding(on ? .trailing : .leading, Self.knob + 8)
                coin.padding(5)
            }
            .frame(width: Self.width, height: Self.height)
            .shadow(color: Theme.gold.opacity(on ? 0.35 : (hover ? 0.2 : 0)), radius: on ? 16 : 10)
            .opacity(busy ? 0.6 : 1)
            .contentShape(Capsule())
            .animation(reduceMotion ? nil : .spring(response: 0.42, dampingFraction: 0.72), value: on)
        }
        .buttonStyle(.plain)
        .disabled(busy)
        .onHover { h in withAnimation(.easeOut(duration: 0.18)) { hover = h } }
        .help(on ? "Switch Go Max off" : "Switch Go Max on")
        .accessibilityLabel("Go Max")
        .accessibilityValue(on ? "On" : "Off")
    }

    /// The same brass coin as the home screen's button.
    private var coin: some View {
        ZStack {
            Circle().fill(LinearGradient(stops: [
                .init(color: Self.c(0xF6E2B0), location: 0),
                .init(color: Self.c(0xD9AE5F), location: 0.48),
                .init(color: Self.c(0xB88A3E), location: 0.52),
                .init(color: Self.c(0x9C7330), location: 1),
            ], startPoint: .top, endPoint: .bottom))
            Circle().stroke(Self.c(0x5E4519).opacity(0.8), lineWidth: 1)
            Circle().inset(by: 1.5).stroke(Self.c(0xFFF3D1).opacity(0.45), lineWidth: 1)
            Image(systemName: on ? "power" : "point.3.connected.trianglepath.dotted")
                .font(.system(size: 19, weight: .semibold))
                .foregroundStyle(Self.c(0x3A2A0C))
                .shadow(color: Self.c(0xFFF3D1).opacity(0.6), radius: 0, y: 1)
        }
        .frame(width: Self.knob, height: Self.knob)
        .shadow(color: .black.opacity(0.35), radius: 4, y: 2)
    }
}

/// Settings › Go Max: everything beyond the switch, in one thin red box
/// marked Advanced · Experimental, closed until opened. Closed, it still
/// shows what is inside and whether it is on.
struct AdvancedBox<Content: View>: View {
    /// Whether the feature inside is switched on, shown while closed.
    var featureOn: Bool
    @ViewBuilder var content: () -> Content
    @State private var open = false
    @State private var hover = false

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Button { withAnimation(.spring(response: 0.32, dampingFraction: 0.88)) { open.toggle() } } label: {
                HStack(spacing: 8) {
                    Image(systemName: "chevron.right")
                        .font(.system(size: 10, weight: .semibold)).foregroundStyle(Theme.red)
                        .rotationEffect(.degrees(open ? 90 : 0))
                        .frame(width: 12)
                    Text("ADVANCED · EXPERIMENTAL")
                        .font(Theme.text(11, weight: .bold)).tracking(1.4).foregroundStyle(Theme.red)
                    Spacer(minLength: 12)
                    if !open {
                        HStack(spacing: 8) {
                            Image(systemName: "checkmark.seal").font(.system(size: 13)).foregroundStyle(Theme.gold)
                            Text("Genuine node").font(Theme.text(12, weight: .medium)).foregroundStyle(Theme.text)
                            Circle().fill(featureOn ? Theme.green : Theme.muted.opacity(0.6)).frame(width: 6, height: 6)
                            Text(featureOn ? "On" : "Off").font(Theme.text(12)).foregroundStyle(featureOn ? Theme.green : Theme.muted)
                        }
                        .transition(.opacity)
                    }
                    Text(open ? "Hide" : "Show")
                        .font(Theme.text(12, weight: .medium)).foregroundStyle(hover ? Theme.text : Theme.muted)
                        .padding(.leading, 6)
                }
                .padding(.vertical, 2)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .onHover { hover = $0 }
            if open {
                content()
                    .padding(.top, 12)
                    .transition(.opacity.combined(with: .move(edge: .top)))
            }
        }
        .padding(12)
        .background(Theme.red.opacity(hover && !open ? 0.04 : 0), in: RoundedRectangle(cornerRadius: 14, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous).stroke(Theme.red.opacity(0.55), lineWidth: 1))
        .clipped()
        .animation(.easeOut(duration: 0.15), value: hover)
    }
}

/// "Before you start Go Max": free space, memory and power, read on this
/// Mac only, and what to expect. Only too little space stops a start.
struct GoMaxCheckSheet: View {
    let computer: GoMaxComputer
    let hasData: Bool
    let onlyPluggedIn: Bool
    /// From the switch (Start / Not now), or from "Check this computer" (Close).
    let starting: Bool
    let onStart: () -> Void
    let onCancel: () -> Void

    var body: some View {
        SheetScaffold(title: starting ? "Before you start Go Max" : "This computer",
                      subtitle: "Read on this Mac only. Nothing is sent anywhere.",
                      showsClose: false, width: 520, height: 470, onClose: onCancel) {
            VStack(alignment: .leading, spacing: 16) {
                VStack(alignment: .leading, spacing: 10) {
                    ForEach(computer.lines(hasData: hasData, onlyPluggedIn: onlyPluggedIn), id: \.text) { line in
                        HStack(alignment: .firstTextBaseline, spacing: 10) {
                            Image(systemName: line.good ? "checkmark" : "exclamationmark.triangle")
                                .font(.system(size: 11, weight: .semibold))
                                .foregroundStyle(line.good ? Theme.green : Theme.gold)
                                .frame(width: 14)
                            Text(line.text).font(Theme.text(13)).foregroundStyle(Theme.text)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                    }
                }
                Text(GoMaxComputer.expect)
                    .font(Theme.text(12)).foregroundStyle(Theme.muted)
                    .fixedSize(horizontal: false, vertical: true)
                Spacer(minLength: 0)
                HStack(spacing: 12) {
                    if starting {
                        SecondaryButton(title: "Not now", action: onCancel)
                        PrimaryButton(title: "Start Go Max", enabled: hasData || computer.enoughSpace, action: onStart)
                    } else {
                        SecondaryButton(title: "Close", action: onCancel)
                    }
                }
            }
        }
    }
}

