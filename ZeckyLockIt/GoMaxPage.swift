import AppKit
import SwiftUI

/// Settings › Go Max: one switch, two lines, and the fine print tucked away.
struct GoMaxPage: View {
    @ObservedObject var node: GoMaxNode
    @State private var confirmRemove = false
    @State private var working = false
    @State private var showMore = false

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
                    if node.disconnected {
                        Text("Not connected to other Zcash nodes · check this Mac's internet connection. Some networks (office, hotel, guest Wi-Fi) block Zcash nodes.")
                            .font(Theme.text(13)).foregroundStyle(Theme.gold)
                            .fixedSize(horizontal: false, vertical: true)
                    } else if let quiet = node.quietMinutes {
                        Text("No new blocks for \(quiet) minutes · check this Mac's internet connection")
                            .font(Theme.text(13)).foregroundStyle(Theme.gold)
                            .fixedSize(horizontal: false, vertical: true)
                    } else {
                        Text(GoMaxWords.status(node.phase, node.info))
                            .font(Theme.text(13)).foregroundStyle(node.phase == .ready ? Theme.green : Theme.text)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    supportNotice
                    if let info = node.info, node.phase != .off {
                        Text(GoMaxWords.storage(sizeOnDisk: info.sizeOnDisk, retention: node.retention))
                            .font(Theme.text(12)).foregroundStyle(Theme.muted)
                    }
                    if let problem = node.problem {
                        Text(problem).font(Theme.text(12)).foregroundStyle(Theme.red)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    if !node.enabled && !node.hasData {
                        Text("15 GB of disk to start, about 22 GB after a month. The first check takes most of a day (about 14 hours on a MacBook Air) and downloads the whole chain once, about 250 GB, deleting older blocks as it goes. Keep Lock it open; the check pauses while the Mac sleeps and carries on after.")
                            .font(Theme.text(12)).foregroundStyle(Theme.muted)
                            .fixedSize(horizontal: false, vertical: true)
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

    private func switchTo(_ on: Bool) {
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
        "Until the node is up to date, Lock it keeps using your server. Then it switches to the node by itself. Switching Go Max off, or a problem with the node, switches back, and this page says so.",
        "The node connects to other Zcash nodes on the internet, like every node: they see this Mac's internet address, never your wallets, addresses or balance. Lock it talks to the node on this Mac only, and the node accepts no connections from outside.",
        "Every block since the Canopy upgrade (2020) is checked here, proofs and all. Older blocks are accepted on checkpoints built into the node, as every Zcash node does.",
        "The node keeps about a month of recent blocks in full, and what every node needs to check new ones. Its files live in Lock it's own folder, left out of Time Machine.",
        "It runs while Lock it is open. While it is checking or catching up, the Mac does not fall asleep on its own; up to date, it sleeps as usual.",
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
        .help("Go Max: your own Zcash node on this Mac")
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
            if let badge {
                Circle().fill(badge).frame(width: 12, height: 12)
                    .overlay(Circle().stroke(Theme.surface, lineWidth: 2))
                    .offset(x: 16, y: 16)
            }
        }
        .frame(width: 44, height: 44)
        .padding(4)
    }

    private var inviting: Bool { node.phase == .off || node.phase == .stopped }
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
        switch node.phase {
        case .off: return "Run your own node"
        case .stopped: return "Off · data kept"
        case .ready: return "Your own node"
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
