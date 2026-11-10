import Foundation

/// Go Max: a Zcash node inside Lock it on this Mac.
///
/// Two programs run under Lock it: Zakura (the Zcash node, a fork of Zebra)
/// and Zaino (the light-wallet server in front of it). This file holds the
/// parts that touch neither the disk nor the network, so they can be tested
/// on their own: the settings files both programs read, and the words the
/// Go Max page shows. GoMaxNode.swift runs the programs.
///
/// Measured on a MacBook Air (Apple Silicon), 8–9 Nov 2026:
/// - pruned, every proof since Canopy verified: 13.5 hours from genesis,
///   15 GB with the smallest window, about 20 GB with a month of blocks;
/// - with Zakura's checkpoint fast path the node drops the transparent
///   address indexes, and the Zcash wallet engine then cannot use it, so
///   Go Max always syncs with checkpoint_sync = false.
enum GoMaxConfig {
    /// Zakura's JSON-RPC, on this Mac only.
    static let rpcPort = 8232
    /// Zakura's peer-to-peer port. It listens on this Mac only: the node
    /// connects out to its peers and accepts no connections from outside.
    static let p2pPort = 8233
    /// Zaino's light-wallet port, the one Lock it connects to.
    static let zainoPort = 8137
    static let host = "127.0.0.1"

    /// How many recent blocks the node keeps in full. Zakura's minimum is
    /// 10,000. The window is counted in blocks, and blocks are not equal: in
    /// the 2022–23 spam years 100,000 blocks are 100–200 GB. So the first sync
    /// runs with the minimum, and the window is widened once the node is at
    /// the tip, where blocks are small.
    static let retentionSyncing = 10_000
    /// About a month at 25-second blocks: roughly 5 GB of today's blocks.
    static let retentionAtTip = 100_000

    /// Free disk asked for before starting: the node's ~20 GB, the peak of
    /// about 22 GB seen during a sync with the minimum window, and room for
    /// the database to tidy itself.
    static let minFreeBytes: Int64 = 35 * 1024 * 1024 * 1024

    static func retention(widened: Bool) -> Int { widened ? retentionAtTip : retentionSyncing }

    /// Zakura's settings. Everything not written here keeps Zakura's default.
    /// `dataDir` holds the chain state, the peer cache and the node identity.
    static func zakura(dataDir: String, retention: Int) -> String {
        let dir = tomlString(dataDir)
        return """
        # Written by Zecky Lock it (Go Max). Edits are overwritten.

        [network]
        network = "Mainnet"
        # The long-standing Zcash peer-to-peer protocol only (Zakura's default on
        # Mainnet today), stated so a new default cannot open another port.
        p2p_stack = "legacy"
        listen_addr = "\(host):\(p2pPort)"
        cache_dir = \(dir)
        identity_dir = \(tomlString(dataDir + "/identity"))

        [consensus]
        # Every proof since Canopy is checked here. Zakura drops the transparent
        # address indexes under checkpoint sync, and the wallet needs them.
        checkpoint_sync = false

        [rpc]
        listen_addr = "\(host):\(rpcPort)"
        enable_cookie_auth = false
        cookie_dir = \(dir)

        [state]
        cache_dir = \(dir)
        storage_mode = { pruned = { tx_retention = \(retention) } }

        [tracing]
        use_color = false

        """
    }

    /// Zaino's settings, the same shape as Rock it's on Umbrel.
    static func zaino(dataDir: String) -> String {
        """
        # Written by Zecky Lock it (Go Max). Edits are overwritten.

        backend = "rpc"
        network = "Mainnet"
        # No index of its own: every read goes to the node. Lock it can connect
        # as soon as the node is at the tip.
        ephemeral_finalised_state = true

        [grpc_settings]
        listen_address = "\(host):\(zainoPort)"

        [validator_settings]
        validator_jsonrpc_listen_address = "\(host):\(rpcPort)"
        # The node has no password on this Mac; Zaino ignores these.
        validator_user = "xxxxxx"
        validator_password = "xxxxxx"

        [service]
        timeout = 30
        channel_size = 32

        [storage.cache]
        capacity = 10000
        shard_power = 4

        [storage.database]
        path = \(tomlString(dataDir))
        size = 200
        # Memory budgets in GB for building an index; unused in ephemeral mode,
        # kept small so they never surprise a laptop.
        sync_write_batch_size = 2
        accumulator_rebuild_memory_size = 1
        sync_checkpoint_interval = 120

        [mempool]

        """
    }

    /// A TOML basic string: quotes, backslashes and control characters escaped.
    static func tomlString(_ value: String) -> String {
        var out = "\""
        for scalar in value.unicodeScalars {
            switch scalar {
            case "\\": out += "\\\\"
            case "\"": out += "\\\""
            case _ where scalar.value < 0x20 || scalar.value == 0x7F:
                out += String(format: "\\u%04X", scalar.value)
            default: out.unicodeScalars.append(scalar)
            }
        }
        return out + "\""
    }

    /// How much more free space is needed to start; 0 when there is enough.
    static func missingBytes(free: Int64) -> Int64 { max(0, minFreeBytes - free) }

    /// "17.1 GB", "980 MB": US style, no decimal from 10 GB.
    static func formatBytes(_ bytes: Int64) -> String {
        let gb = Double(bytes) / 1e9
        let us = Locale(identifier: "en_US")
        if gb >= 10 { return "\(Int(gb.rounded())) GB" }
        if gb >= 1 { return gb.formatted(.number.precision(.fractionLength(1)).locale(us)) + " GB" }
        return "\(Int((Double(bytes) / 1e6).rounded())) MB"
    }
}

/// The part of Zakura's getblockchaininfo answer Go Max reads.
struct GoMaxChainInfo: Equatable {
    /// Height of the last block the node has verified.
    var blocks: Int
    /// The network's height, as the node estimates it from its peers.
    var estimatedHeight: Int
    /// 0 to 1.
    var verificationProgress: Double
    /// Bytes the state takes on disk, as the node measures it.
    var sizeOnDisk: Int64

    /// Reads the fields Go Max needs; nil when the answer is not what it expects.
    init?(rpcResult: Any?) {
        guard let r = rpcResult as? [String: Any], let blocks = Self.int(r["blocks"]) else { return nil }
        self.blocks = blocks
        estimatedHeight = Self.int(r["estimatedheight"]) ?? blocks
        verificationProgress = min(1, max(0, (r["verificationprogress"] as? NSNumber)?.doubleValue ?? 0))
        sizeOnDisk = Int64(Self.int(r["size_on_disk"]) ?? 0)
    }

    init(blocks: Int, estimatedHeight: Int, verificationProgress: Double, sizeOnDisk: Int64 = 0) {
        self.blocks = blocks
        self.estimatedHeight = estimatedHeight
        self.verificationProgress = verificationProgress
        self.sizeOnDisk = sizeOnDisk
    }

    private static func int(_ value: Any?) -> Int? {
        guard let n = value as? NSNumber, CFGetTypeID(n) != CFBooleanGetTypeID() else { return nil }
        return n.intValue
    }

    /// Whether the node has reached the network's tip.
    var atTip: Bool { verificationProgress >= 0.9999 && blocks >= estimatedHeight - 2 }
    var blocksBehind: Int { max(0, estimatedHeight - blocks) }
}

/// What the node is doing.
enum GoMaxPhase: Equatable {
    /// Go Max was never switched on, or the node was removed.
    case off
    /// Switched on; the programs are starting and the first answer is awaited.
    case starting
    /// First sync: verifying history.
    case syncing
    /// At the tip; Lock it can use this node.
    case ready
    /// Was ready; now behind after sleep or a pause.
    case catchingUp
    /// Zakura restarting to take a new setting (the wider window).
    case updating
    /// Switched off; the data is kept.
    case stopped
    /// A program exited or stopped answering.
    case problem

    /// Behind by more than this many blocks (25 minutes), a ready node is catching up.
    static let catchingUpBlocks = 60

    /// The next phase, from the last one and what the node says now.
    /// `running` is false when either program is not running.
    static func next(after previous: GoMaxPhase, running: Bool, info: GoMaxChainInfo?, wasEverReady: Bool) -> GoMaxPhase {
        switch previous {
        case .off, .stopped: return previous
        case .updating: return running && info != nil ? fromInfo(info!, wasEverReady) : .updating
        default: break
        }
        guard running, let info else { return previous == .starting ? .starting : .problem }
        return fromInfo(info, wasEverReady)
    }

    private static func fromInfo(_ info: GoMaxChainInfo, _ wasEverReady: Bool) -> GoMaxPhase {
        if info.atTip { return .ready }
        if wasEverReady && info.blocksBehind <= catchingUpBlocks { return .ready }
        return wasEverReady ? .catchingUp : .syncing
    }
}

/// The words on the Go Max page, decided once and tested.
enum GoMaxWords {
    /// Seconds per block on Zcash since NU7.
    private static let blockSeconds = 25

    /// "about 3 hours behind", "about 40 minutes behind", "a few minutes behind".
    static func behind(_ blocks: Int) -> String {
        let minutes = Int((Double(blocks * blockSeconds) / 60).rounded())
        if minutes < 10 { return "a few minutes behind" }
        if minutes < 90 { return "about \(Int((Double(minutes) / 5).rounded()) * 5) minutes behind" }
        let hours = Int((Double(minutes) / 60).rounded())
        if hours < 48 { return "about \(hours) hour\(hours == 1 ? "" : "s") behind" }
        return "about \(Int((Double(hours) / 24).rounded())) days behind"
    }

    /// When a block was made, close enough for a date: between the network
    /// upgrades, whose dates are known, the height is spread evenly over
    /// the time; after NU7, one block every 25 seconds.
    static func blockDate(height: Int) -> Date {
        // (height, noon UTC on the day): genesis, Blossom, Canopy, NU7.
        let anchors: [(Int, TimeInterval)] = [
            (0, 1477656000),             // Oct 28, 2016
            (653_600, 1576065600),       // Dec 11, 2019
            (1_046_400, 1605700800),     // Nov 18, 2020
            (3_543_405, 1792929600),     // Oct 25, 2026
        ]
        let h = max(0, height)
        for i in 1..<anchors.count where h < anchors[i].0 {
            let (h0, t0) = anchors[i - 1], (h1, t1) = anchors[i]
            return Date(timeIntervalSince1970: t0 + (t1 - t0) * Double(h - h0) / Double(h1 - h0))
        }
        let (last, time) = anchors[anchors.count - 1]
        return Date(timeIntervalSince1970: time + Double(h - last) * 25)
    }

    /// "Oct 28, 2016": the date of the last verified block.
    static func verifiedDate(_ info: GoMaxChainInfo) -> String {
        blockDate(height: info.blocks).formatted(
            Date.FormatStyle(date: .abbreviated, time: .omitted, locale: Locale(identifier: "en_US"),
                             timeZone: TimeZone(identifier: "UTC")!))
    }

    /// The one line under the switch.
    static func status(_ phase: GoMaxPhase, _ info: GoMaxChainInfo?, now: Date = Date()) -> String {
        switch phase {
        case .off: return "Off"
        case .starting: return "Starting…"
        case .syncing:
            guard let info else { return "Checking history…" }
            let pct = Int((info.verificationProgress * 100).rounded(.down))
            return "Checking history · \(pct)% · verified up to \(verifiedDate(info))"
        case .ready: return "Up to date · every block since Canopy verified on this Mac"
        case .catchingUp: return info.map { "Catching up · \(behind($0.blocksBehind))" } ?? "Catching up…"
        case .updating: return "Updating…"
        case .stopped: return "Stopped · the node's data is kept"
        case .problem: return "Stopped with a problem · switch off and on to try again"
        }
    }

    /// The few words beside "Go Max" in the Settings list.
    static func short(_ phase: GoMaxPhase, _ info: GoMaxChainInfo?) -> String {
        switch phase {
        case .off: return "Off"
        case .starting: return "Starting"
        case .syncing: return info.map { "Checking history · \(Int(($0.verificationProgress * 100).rounded(.down)))%" } ?? "Checking history"
        case .ready: return "Up to date"
        case .catchingUp: return "Catching up"
        case .updating: return "Updating"
        case .stopped: return "Off · data kept"
        case .problem: return "Stopped"
        }
    }

    /// What the node uses on disk and how much recent history it keeps in full.
    static func storage(sizeOnDisk: Int64, retention: Int) -> String {
        let weeks = Int((Double(retention * blockSeconds) / (7 * 24 * 3600)).rounded())
        let keeps = weeks >= 1 ? "about \(weeks) week\(weeks == 1 ? "" : "s")" : "a few days"
        return "Using \(GoMaxConfig.formatBytes(sizeOnDisk)) · keeps \(keeps) of recent blocks"
    }
}
