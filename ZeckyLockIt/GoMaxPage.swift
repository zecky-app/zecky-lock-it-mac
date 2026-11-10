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
                    HStack(spacing: 12) {
                        Toggle(isOn: Binding(get: { node.enabled }, set: { on in switchTo(on) })) {
                            Text("Go Max").font(Theme.text(14, weight: .medium))
                        }
                        .toggleStyle(.switch)
                        .disabled(working)
                        Spacer()
                    }
                    Text(GoMaxWords.status(node.phase, node.info))
                        .font(Theme.text(13)).foregroundStyle(node.phase == .ready ? Theme.green : Theme.text)
                        .fixedSize(horizontal: false, vertical: true)
                    if let info = node.info, node.phase != .off {
                        Text(GoMaxWords.storage(sizeOnDisk: info.sizeOnDisk, retention: node.retention))
                            .font(Theme.text(12)).foregroundStyle(Theme.muted)
                    }
                    if let problem = node.problem {
                        Text(problem).font(Theme.text(12)).foregroundStyle(Theme.red)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    if !node.enabled && !node.hasData {
                        Text("About 20 GB of disk. The first check takes most of a day (13.5 hours on a MacBook Air) and downloads the whole chain once, about 250 GB, deleting older blocks as it goes. Keep Lock it open; the check pauses while the Mac sleeps and carries on after.")
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
            Text("Go Max stops and its data (about 20 GB) is deleted from this Mac. Lock it goes back to its server. Your wallets are not touched. Switching Go Max on again starts the check from the beginning.")
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
    ]
}

/// The Go Max button on the home screen, above Settings. Off, it invites;
/// on, it shows where the node is. A click opens Settings › Go Max, where
/// the price (disk, time, download) is read before anything starts.
struct GoMaxButton: View {
    @ObservedObject var node: GoMaxNode
    let open: () -> Void
    @State private var hover = false

    var body: some View {
        Button(action: open) {
            HStack(spacing: 9) {
                indicator.frame(width: 18, height: 18)
                VStack(alignment: .leading, spacing: 1) {
                    Text("GO MAX").font(Theme.text(11, weight: .semibold)).tracking(2.5).foregroundStyle(Theme.gold)
                    Text(subtitle).font(Theme.text(11)).foregroundStyle(Theme.muted).lineLimit(1)
                }
            }
            .padding(.leading, 12).padding(.trailing, 16).frame(height: 42)
            .background(Theme.surface, in: Capsule())
            .overlay(Capsule().stroke(Theme.gold.opacity(hover ? 0.95 : 0.6), lineWidth: 1))
            .shadow(color: Theme.gold.opacity(inviting ? (hover ? 0.4 : 0.2) : 0), radius: 12)
            .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .onHover { hover = $0 }
        .animation(.easeOut(duration: 0.2), value: hover)
        .help("Go Max: your own Zcash node on this Mac")
        .accessibilityLabel("Go Max, \(subtitle)")
    }

    private var inviting: Bool { node.phase == .off || node.phase == .stopped }

    @ViewBuilder private var indicator: some View {
        switch node.phase {
        case .starting, .syncing, .catchingUp, .updating:
            ZStack {
                Circle().stroke(Theme.gold.opacity(0.25), lineWidth: 2.5)
                Circle().trim(from: 0, to: max(0.03, CGFloat(node.info?.verificationProgress ?? 0)))
                    .stroke(Theme.gold, style: StrokeStyle(lineWidth: 2.5, lineCap: .round))
                    .rotationEffect(.degrees(-90))
            }
        case .ready:
            Image(systemName: "checkmark.seal.fill").font(.system(size: 16)).foregroundStyle(Theme.green)
        case .problem:
            Image(systemName: "exclamationmark.circle.fill").font(.system(size: 16)).foregroundStyle(Theme.red)
        case .off, .stopped:
            Image(systemName: "point.3.connected.trianglepath.dotted").font(.system(size: 15, weight: .medium)).foregroundStyle(Theme.gold)
        }
    }

    private var subtitle: String {
        switch node.phase {
        case .off: return "Run your own node"
        case .stopped: return "Off · data kept"
        case .ready: return "Your own node"
        case .problem: return "Stopped · open to see why"
        default: return GoMaxWords.short(node.phase, node.info)
        }
    }
}
