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
/// - pruned, every proof since Canopy verified: 13.5 hours from genesis
///   run by hand, about 14 hours inside Lock it (11 Nov);
/// - 15 GB at the tip with the smallest window (measured). A month of
///   blocks adds about 7 GB (200 recent blocks sampled on 11 Nov: 73 KB
///   each, times 100,000), so about 22 GB after a month (calculated);
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
    /// Zakura's metrics (Prometheus text), on this Mac only: the byte
    /// counters behind the data overview on the Go Max page.
    static let metricsPort = 8234
    static let host = "127.0.0.1"

    /// How many recent blocks the node keeps in full. Zakura's minimum is
    /// 10,000. The window is counted in blocks, and blocks are not equal: in
    /// the 2022–23 spam years 100,000 blocks are 100–200 GB. So the first sync
    /// runs with the minimum, and the window is widened once the node is at
    /// the tip, where blocks are small.
    static let retentionSyncing = 10_000
    /// About a month at 25-second blocks: about 7 GB of today's blocks.
    static let retentionAtTip = 100_000

    /// Free disk asked for before starting: the node's ~22 GB, the peak of
    /// about 22 GB seen during a sync with the minimum window, and room for
    /// the database to tidy itself.
    static let minFreeBytes: Int64 = 35 * 1024 * 1024 * 1024

    static func retention(widened: Bool) -> Int { widened ? retentionAtTip : retentionSyncing }

    /// Zakura's settings. Everything not written here keeps Zakura's default.
    /// `dataDir` holds the chain state, the peer cache and the node identity.
    /// `metrics`: the byte counters on 127.0.0.1. Left out when their port
    /// is taken: Zakura refuses to start when it cannot open it.
    static func zakura(dataDir: String, retention: Int, metrics: Bool = true) -> String {
        let dir = tomlString(dataDir)
        let metricsSection = metrics ? """
        [metrics]
        # Byte counters for the Go Max page, on this Mac only.
        endpoint_addr = "\(host):\(metricsPort)"

        """ : ""
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

        \(metricsSection)[tracing]
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

/// How long the node inside this build follows the chain.
///
/// Every Zakura release stops at a fixed block, about 45 days after it comes
/// out (its end-of-support height), and refuses to run past it. The height
/// below belongs to the `zakurad` pinned in GoMax/bin.sha256 and is changed
/// together with it (docs/NODE_UPDATES.md). Lock it says so two weeks ahead,
/// and at the stop it asks: a public server, or wait. Never by itself.
enum GoMaxSupport {
    /// `MAINNET_EOS_HEIGHT` of Zakura v1.8.5 to v1.8.9: about Dec 5, 2026.
    static let releaseStopHeight = 3_643_309
    /// The height Lock it goes by. In a debug build only, it can be moved to
    /// see the notice and the stop before the real date:
    ///   open "Zecky Lock it.app" --args -goMax.testStopHeight 3566000
    /// (not remembered; the node itself still stops at the real height).
    static var stopHeight: Int {
        #if DEBUG
        let test = UserDefaults.standard.integer(forKey: "goMax.testStopHeight")
        if test > 0 { return test }
        #endif
        return releaseStopHeight
    }
    /// Seconds per block since NU7.
    static let blockSeconds = 25.0
    /// The notice starts two weeks of blocks before the stop.
    static let noticeBlocks = 14 * 3_456
    /// Without a fresh height (Lock it was closed for days), the stop is only
    /// taken as reached once the clock is a day of blocks past it: blocks do
    /// not come exactly every 25 seconds.
    static let graceBlocks = 3_456

    enum State: Equatable {
        case fine
        /// The stop is near; about when.
        case soon(Date)
        /// The network is past the node's last block.
        case ended
    }

    /// `reported` is the newest network height anything told Lock it (0: none
    /// yet), `seenAt` when that was (nil: just now).
    static func state(reported: Int, seenAt: Date?, now: Date, stopHeight: Int = stopHeight) -> State {
        guard reported > 0 else { return .fine }
        if reported > stopHeight { return .ended }
        let elapsed = seenAt.map { max(0, now.timeIntervalSince($0)) } ?? 0
        let projected = reported + Int(elapsed / blockSeconds)
        if projected > stopHeight + graceBlocks { return .ended }
        let remaining = max(0, stopHeight - projected)
        guard remaining <= noticeBlocks else { return .fine }
        return .soon(now.addingTimeInterval(Double(remaining) * blockSeconds))
    }

    /// The network height the stop is judged by. The node's own estimate of
    /// the network is only trusted once the node is close to the newest
    /// block: during the first check of history it can be far too high (seen
    /// 13 Nov 2026: about 60,000 blocks, which showed "needs an update before
    /// Nov 17" three weeks early and could have stopped Go Max mid-sync).
    /// Then the node's verified blocks and the wallet's server count.
    static func networkHeight(nodeBlocks: Int, nodeEstimate: Int, verificationProgress: Double, walletNetwork: Int,
                              now: Date = Date()) -> Int {
        // An estimate is never trusted above what the clock allows.
        let estimate = min(nodeEstimate, plausibleMax(at: now))
        let node = verificationProgress >= 0.999 ? max(nodeBlocks, estimate) : nodeBlocks
        return max(node, walletNetwork)
    }

    /// The highest network height the clock allows at a moment: NU7's block
    /// plus one every 25 seconds (Birthday.estimatedTip), with room for
    /// blocks coming faster than that. Verified blocks are never capped by it;
    /// guesses and remembered heights are.
    static let plausibleMargin = 5_000
    static func plausibleMax(at date: Date) -> Int { Birthday.estimatedTip(now: date) + plausibleMargin }

    /// A height remembered across restarts, if the clock allows it when it was
    /// seen; 0 otherwise. One remembered from a node's guess during its first
    /// sync (Lock it 0.2.0 build 5 and earlier) can be far too high, and kept
    /// showing "needs an update" weeks early whenever nothing was answering
    /// yet, such as right after a start (seen 14 Nov 2026: "before Nov 27").
    static func trustedRemembered(height: Int, seenAt: Date?, now: Date) -> Int {
        guard height > 0 else { return 0 }
        return height <= plausibleMax(at: seenAt ?? now) ? height : 0
    }

    /// "Dec 5", in this Mac's time zone.
    static func dateText(_ date: Date) -> String {
        date.formatted(Date.FormatStyle(locale: Locale(identifier: "en_US")).month(.abbreviated).day())
    }

    static var stopHeightText: String { stopHeight.formatted(.number.locale(Locale(identifier: "en_US"))) }
}

/// Where the wallet reads the chain while Go Max is on. The node is pruned:
/// it keeps only recent blocks. A wallet that still has older blocks to
/// check (after adding or restoring a wallet) asks the node for blocks it
/// no longer has and then stands still without an error (seen 12 Nov 2026:
/// the node answered "block not found" for a block from January, the wallet
/// stopped at the moment it turned to that stretch). So the wallet reads
/// from the node only when the node has the oldest block it still needs.
enum GoMaxReading {
    /// The block the wallet needs and the node no longer has; nil when the
    /// node can serve the wallet, or when it cannot be told (no answer).
    /// A block above the node's own newest block is not an older one: the
    /// node is a little behind and will have it.
    static func missing(oldestNeeded: Int?, nodeBlocks: Int, nodeHasIt: Bool?) -> Int? {
        guard let oldestNeeded, oldestNeeded <= nodeBlocks, nodeHasIt == false else { return nil }
        return oldestNeeded
    }

    /// This many blocks (five minutes) the node is ahead of what the wallet
    /// last heard: the wallet's connection to the node has gone quiet.
    static let quietBlocks = 12

    static func walletQuiet(nodeBlocks: Int, walletNetwork: Int) -> Bool {
        walletNetwork > 0 && nodeBlocks - walletNetwork >= quietBlocks
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
    /// Up to date for the words on screen. The network's height is the
    /// node's estimate from the clock, and blocks do not come exactly every
    /// 25 seconds, so a node at the real tip often reads 3 or 4 "behind"
    /// (seen 12 Nov). Ten blocks, about four minutes, is called behind.
    var shownUpToDate: Bool { verificationProgress >= 0.9999 && blocksBehind <= 10 }
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
    /// "Only sync while plugged in": on battery while checking or catching
    /// up, the programs are stopped and Lock it reads from its server. Goes
    /// on by itself at the charger.
    case paused
    /// A program exited or stopped answering.
    case problem
    /// The network is past the last block this node version follows. The
    /// programs are stopped; Go Max carries on after an update of Lock it.
    case expired

    /// Behind by more than this many blocks (25 minutes), a ready node is catching up.
    static let catchingUpBlocks = 60

    /// The next phase, from the last one and what the node says now.
    /// `running` is false when either program is not running.
    static func next(after previous: GoMaxPhase, running: Bool, info: GoMaxChainInfo?, wasEverReady: Bool) -> GoMaxPhase {
        switch previous {
        case .off, .stopped, .expired, .paused: return previous
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
        case .ready:
            // Ready covers a node up to 25 minutes behind (it was at the tip
            // and is catching up after a pause). Only at the newest block is
            // it called up to date.
            if let info, !info.shownUpToDate { return "A little behind · \(info.blocksBehind) blocks to catch up" }
            return "Up to date · every block since Canopy verified on this Mac"
        case .catchingUp: return info.map { "Catching up · \(behind($0.blocksBehind))" } ?? "Catching up…"
        case .updating: return "Updating…"
        case .stopped: return "Stopped · the node's data is kept"
        case .paused: return "Paused on battery · carries on when the charger is connected"
        case .problem: return "Stopped with a problem · switch off and on to try again"
        case .expired: return "Stopped · this node version has reached its last block"
        }
    }

    /// The few words beside "Go Max" in the Settings list.
    static func short(_ phase: GoMaxPhase, _ info: GoMaxChainInfo?) -> String {
        switch phase {
        case .off: return "Off"
        case .starting: return "Starting"
        case .syncing: return info.map { "Checking history · \(Int(($0.verificationProgress * 100).rounded(.down)))%" } ?? "Checking history"
        case .ready: return info.map { $0.shownUpToDate } == false ? "Catching up" : "Up to date"
        case .catchingUp: return "Catching up"
        case .updating: return "Updating"
        case .stopped: return "Off · data kept"
        case .paused: return "Paused · plug in to sync"
        case .problem: return "Stopped"
        case .expired: return "Needs an update"
        }
    }

    /// Under the switch: what Go Max shares and what it does not.
    static let privateLine = "Private: your node connects to other Zcash nodes, but nobody can connect to it."
    static let whyPrivate = [
        "Why Go Max is private. Your node checks every block itself and passes new blocks and transactions on to the nodes it connects to. It does not accept incoming connections, so your internet address is never announced as a Zcash node, and a laptop that sleeps, travels or runs on a data limit isn't asked to serve others.",
        "Want to help the network more? Zecky Rock it runs a full node on an Umbrel at home, always on. It will be able to open to other nodes by choice, which is where helping counts most: a full node can serve new nodes during their first sync.",
    ]

    /// "Connected to 14 other Zcash nodes".
    static func peers(_ count: Int) -> String {
        "Connected to \(count) other Zcash node\(count == 1 ? "" : "s")"
    }

    /// Why Lock it reads from a server although the node is up to date.
    static func olderBlocks(from block: Int, server: String) -> String {
        let number = block.formatted(.number.grouping(.automatic).locale(Locale(identifier: "en_US")))
        return "Lock it reads older blocks (from block \(number)) from \(server): this node keeps only recent blocks. It returns to this node by itself once they are checked."
    }

    /// The same, when Lock it was pointed at the node by hand and has no
    /// server to go back to by itself.
    static func olderBlocksOnNode(from block: Int) -> String {
        let number = block.formatted(.number.grouping(.automatic).locale(Locale(identifier: "en_US")))
        return "This node keeps only recent blocks and no longer has the older ones your wallet still has to check (from block \(number)). Pick a server in Settings › Network to check them."
    }

    /// Lock it's server did not answer when Lock it went back to it.
    static func unsettled(server: String) -> String {
        "Lock it could not connect to \(server) yet · trying again."
    }

    /// The node moves on and the wallet does not hear of it.
    /// The node quit before it first answered. Short and calm on the page,
    /// with one button; the rest only when asked for.
    static let stoppedWhileStarting = "The node stopped while starting. Your wallet is fine: Lock it reads from its server meanwhile."
    static let tryingAgain = "Trying again in half a minute…"
    static let stillNotWorking = "Quit Lock it and open it again. If the node still stops, click \"Remove node and its data…\" below and switch Go Max on: it starts over. To help us, send the node's log with your TestFlight feedback (How Go Max works › Show the node's logs)."

    static let walletQuiet = "Lock it is not getting new blocks from this node. It has connected again; if this line stays, switch Go Max off and on."

    /// What the node uses on disk and how much recent history it keeps in full.
    static func storage(sizeOnDisk: Int64, retention: Int) -> String {
        let weeks = Int((Double(retention * blockSeconds) / (7 * 24 * 3600)).rounded())
        let keeps = weeks >= 1 ? "about \(weeks) week\(weeks == 1 ? "" : "s")" : "a few days"
        return "Using \(GoMaxConfig.formatBytes(sizeOnDisk)) · keeps \(keeps) of recent blocks"
    }
}

/// "Before you start Go Max": what this Mac has, read on this Mac only.
/// Nothing is sent anywhere. Only too little disk space stops a start;
/// everything else informs and the owner decides.
struct GoMaxComputer: Equatable {
    let freeBytes: Int64
    let memoryBytes: UInt64
    let hasBattery: Bool
    let onBattery: Bool
    /// macOS reports Low Data Mode, or a connection it treats as costly
    /// (a phone's hotspot, for example).
    var limitedConnection = false

    /// Below 8 GB the Mac may feel slow during the first check. An 8 GB Mac
    /// reports exactly 8 GiB, so it is not warned.
    static let lowMemoryBytes: UInt64 = 8 * 1_073_741_824

    var enoughSpace: Bool { GoMaxConfig.missingBytes(free: freeBytes) == 0 }

    struct Line: Equatable { let good: Bool; let text: String }

    /// The lines of the check. `hasData`: a node that already has its data
    /// needs no new room. `onlyPluggedIn`: the owner's setting.
    func lines(hasData: Bool, onlyPluggedIn: Bool) -> [Line] {
        var out: [Line] = []
        let free = GoMaxConfig.formatBytes(freeBytes)
        let needed = GoMaxConfig.formatBytes(GoMaxConfig.minFreeBytes)
        if hasData {
            out.append(Line(good: true, text: "Free space: \(free). The node's data is already on this Mac."))
        } else if enoughSpace {
            out.append(Line(good: true, text: "Free space: \(free) (Go Max needs about \(needed))"))
        } else {
            let more = GoMaxConfig.formatBytes(GoMaxConfig.missingBytes(free: freeBytes))
            out.append(Line(good: false, text: "Free space: \(free). Go Max needs about \(needed): free up \(more) first."))
        }
        let memory = "\(Int((Double(memoryBytes) / 1_073_741_824).rounded())) GB"
        out.append(memoryBytes < Self.lowMemoryBytes
                   ? Line(good: false, text: "Memory: \(memory). The Mac may feel slow during the first check.")
                   : Line(good: true, text: "Memory: \(memory)"))
        out.append(limitedConnection
                   ? Line(good: false, text: "Data: this connection is limited. The first sync downloads about 350 GB; better to use one without a data limit.")
                   : Line(good: true, text: "Data: the first sync downloads about 350 GB. Use a connection without a data limit."))
        if hasBattery {
            if !onBattery {
                out.append(Line(good: true, text: "Plugged in"))
            } else if hasData {
                // The first check is done: up to date, the node runs on battery too.
                out.append(Line(good: true, text: onlyPluggedIn
                    ? "On battery. Catching up waits for the charger; up to date, the node keeps running."
                    : "On battery. The node keeps running."))
            } else if onlyPluggedIn {
                out.append(Line(good: false, text: "Running on battery. Plug in to sync: the first check waits for the charger."))
            } else {
                out.append(Line(good: false, text: "Running on battery. The first check drains the battery quickly; plug in if you can."))
            }
        }
        return out
    }

    static let expect = "The first check works the Mac hard for about 14 hours to a day or more, so the fan may run and the Mac gets warm. After that it is light: one block about every 25 seconds. Disk use is about 15 to 22 GB. You can switch Go Max off at any time, and your wallet works the same without it."
}


/// How long the first check still takes, with the spam years counted in.
///
/// Speed is measured on this Mac: blocks checked in the last hour. Blocks
/// are not equal, though. From mid-2022 to early 2023 someone filled most
/// blocks with spam (shielded transactions with hundreds of outputs, up to
/// 2 MB a block), and the chain grew from about 30 GB to well over 100 GB.
/// So each stretch of the chain gets a weight, roughly its work per block,
/// and the estimate measures speed in that work rather than in blocks. A
/// node in the spam years then knows the rest will go faster, and a node
/// before them knows they are coming. Only the ratios are guessed (a first
/// guess from block sizes, to be tuned from measured laptop speeds); the
/// speed is this Mac's own, and the estimate corrects itself as it goes.
/// Same rules as Lock it for Windows.
enum GoMaxPace {
    /// The spam years, roughly: from mid-June 2022 (shortly after NU5 at
    /// 1,687,104) until the spam faded in 2023.
    static let spamStart = 1_710_000
    static let spamEnd = 2_100_000
    /// Canopy: before it, blocks are taken on Zakura's built-in checkpoints.
    static let canopy = 1_046_400

    /// From this height on, this much work per block (relative). The one
    /// place the weights live.
    static let stretches: [(from: Int, weight: Double)] = [(0, 1), (canopy, 3), (spamStart, 20), (spamEnd, 4)]

    /// Within this many blocks of the tip the node is up to date: no finish, no line.
    static let upToDateBlocks = 10
    /// Speed is taken over the last hour…
    static let window: TimeInterval = 3_600
    /// …and only once there is a quarter of an hour of it.
    static let minimum: TimeInterval = 900
    /// A sample at most every 15 seconds.
    static let every: TimeInterval = 15

    /// The work to check every block below `height`.
    static func work(_ height: Int) -> Double {
        var total = 0.0
        for (i, stretch) in stretches.enumerated() where height > stretch.from {
            let until = i + 1 < stretches.count ? min(stretches[i + 1].from, height) : height
            total += Double(until - stretch.from) * stretch.weight
        }
        return total
    }

    /// The node's height over the last hour.
    struct Samples {
        private(set) var list: [(at: Date, height: Int)] = []

        /// Note the height now. A lower height than before (the node
        /// started over) begins a fresh measurement.
        mutating func add(_ at: Date, _ height: Int) {
            if let last = list.last, height < last.height { list.removeAll() }
            list.append((at, height))
            list.removeAll { at.timeIntervalSince($0.at) > GoMaxPace.window }
        }

        mutating func clear() { list.removeAll() }

        /// When the node should reach `tip`: nil while there is too little
        /// to go on or nothing moved.
        func finish(tip: Int) -> Date? {
            guard let first = list.first, let last = list.last else { return nil }
            let seconds = last.at.timeIntervalSince(first.at)
            guard seconds >= GoMaxPace.minimum, last.height > first.height, tip > last.height else { return nil }
            let speed = (GoMaxPace.work(last.height) - GoMaxPace.work(first.height)) / seconds
            return last.at.addingTimeInterval((GoMaxPace.work(tip) - GoMaxPace.work(last.height)) / speed)
        }
    }

    /// The line about the spam years, while the first check runs.
    static func spamLine(height: Int) -> String {
        if height < spamStart {
            return "Ahead: the spam years, blocks 1,710,000 to 2,100,000 (2022–23). Most blocks there are full of spam, so this is the slowest stretch. The expected finish already counts it."
        }
        if height < spamEnd {
            let done = (height - spamStart) * 100 / (spamEnd - spamStart)
            return "Now in the spam years, blocks 1,710,000 to 2,100,000 (2022–23): \(done)% of this stretch done. It is the slowest part; after block 2,100,000 it goes much faster."
        }
        return "The spam years are done. The rest goes much faster."
    }

    /// "About Tue, Nov 17 at 2:00 PM": to the hour when more than 3 hours
    /// away, else to 10 minutes. Rounded, because it is an estimate.
    static func finishText(_ finish: Date?, now: Date = Date(), calendar: Calendar = .current) -> String {
        guard let finish else { return "Measuring speed…" }
        let left = finish.timeIntervalSince(now)
        if left < 600 { return "In a few minutes" }
        guard let hour = calendar.dateInterval(of: .hour, for: finish)?.start else { return "Measuring speed…" }
        let minutes = finish.timeIntervalSince(hour) / 60
        let at = left > 3 * 3_600
            ? hour.addingTimeInterval(minutes >= 30 ? 3_600 : 0)
            : hour.addingTimeInterval((minutes / 10).rounded() * 600)
        var style = Date.FormatStyle(locale: Locale(identifier: "en_US")).weekday(.abbreviated).month(.abbreviated).day().hour().minute()
        style.calendar = calendar
        style.timeZone = calendar.timeZone
        return "About " + at.formatted(style)
    }
}

/// The data overview on the Go Max page: what the node downloaded and
/// uploaded, what it keeps, and what it removed after checking. Counted on
/// this Mac only; nothing is sent.
enum GoMaxData {
    /// Zakura's counters of every byte read from and written to its peers.
    /// Go Max runs only the legacy peer-to-peer protocol, and these count
    /// all of its traffic. Prometheus writes the dots as underscores.
    static let inCounter = "zcash_net_in_bytes_total"
    static let outCounter = "zcash_net_out_bytes_total"

    /// The value of one counter in Prometheus text, summed over its labels.
    static func counter(_ name: String, in text: String) -> Double? {
        var total: Double?
        for line in text.split(separator: "\n") where !line.hasPrefix("#") {
            let parts = line.split(separator: " ")
            guard parts.count >= 2 else { continue }
            let key = parts[0]
            guard key == Substring(name) || key.hasPrefix(name + "{"), let value = Double(parts[1]) else { continue }
            total = (total ?? 0) + value
        }
        return total
    }

    /// A running total over Zakura's restarts: Zakura's counters start at
    /// zero at every start, so Lock it keeps what came before.
    struct Total: Codable, Equatable {
        /// What earlier runs of Zakura counted.
        var before: Double = 0
        /// The last value this run of Zakura reported.
        var current: Double = 0
        var total: Double { before + current }

        /// A new reading. A lower one than before means Zakura started over.
        mutating func read(_ value: Double) {
            if value < current { before += current }
            current = value
        }

        /// Zakura is (re)started: what it counted so far is kept.
        mutating func restart() {
            before += current
            current = 0
        }
    }

    /// Never below zero: the overview never claims more removed than downloaded.
    static func removed(downloaded: Double, kept: Double) -> Double { max(0, downloaded - kept) }

    /// "212.4 GB", "980 MB": one decimal for gigabytes, US style.
    static func format(_ bytes: Double) -> String {
        let us = Locale(identifier: "en_US")
        if bytes >= 1e9 { return (bytes / 1e9).formatted(.number.precision(.fractionLength(1)).locale(us)) + " GB" }
        return "\(Int((bytes / 1e6).rounded())) MB"
    }

    static let footnote = "Every block is checked on this Mac first, then old block data is removed. Counted on this Mac only; nothing is sent."
}

