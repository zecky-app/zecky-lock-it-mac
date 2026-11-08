import SwiftUI

/// The Zecky lock: gold padlock with the engraved Z and a ZECKY name plate.
/// Drawn in a 300 × 340 space and scaled. The shackle swings open, and the
/// lock tilts a little towards the pointer so it feels solid.
struct PadlockView: View {
    var open: Bool
    var size: CGFloat = 220
    /// -1…1 in each direction, from the pointer.
    var tilt: CGSize = .zero
    /// What the name plate says: the value, or LOCKED / OPEN. nil = no plate.
    var plateText: String? = nil

    @Environment(\.colorScheme) private var scheme

    private static let ink = Color(red: 0x6A / 255, green: 0x4C / 255, blue: 0x1D / 255)
    private static let light = Color(red: 1, green: 0.94, blue: 0.8)

    var body: some View {
        ZStack {
            Ellipse()
                .fill(Color.black.opacity(scheme == .light ? 0.28 : 0.6))
                .frame(width: 224, height: 20)
                .blur(radius: 8)
                .position(x: 150, y: 332)

            Shackle()
                .stroke(
                    LinearGradient(stops: [
                        .init(color: Color(red: 0.54, green: 0.43, blue: 0.23), location: 0),
                        .init(color: Color(red: 0.97, green: 0.90, blue: 0.72), location: 0.33),
                        .init(color: Color(red: 0.79, green: 0.62, blue: 0.31), location: 0.6),
                        .init(color: Color(red: 0.44, green: 0.33, blue: 0.13), location: 1),
                    ], startPoint: .leading, endPoint: .trailing),
                    lineWidth: 26)
                .frame(width: 300, height: 340)
                .offset(y: open ? -36 : 0)
                .rotationEffect(.degrees(open ? -22 : 0), anchor: UnitPoint(x: 216 / 300, y: 160 / 340))

            ZStack {
                RoundedRectangle(cornerRadius: 34, style: .continuous)
                    .fill(LinearGradient(stops: [
                        .init(color: Color(red: 0.96, green: 0.87, blue: 0.64), location: 0),
                        .init(color: Theme.metalGold, location: 0.42),
                        .init(color: Color(red: 0.50, green: 0.36, blue: 0.14), location: 1),
                    ], startPoint: .top, endPoint: .bottom))
                RoundedRectangle(cornerRadius: 34, style: .continuous)
                    .fill(LinearGradient(stops: [
                        .init(color: .white.opacity(0), location: 0),
                        .init(color: .white.opacity(0.32), location: 0.28 + tilt.width * 0.12),
                        .init(color: .white.opacity(0), location: 0.46 + tilt.width * 0.12),
                    ], startPoint: .leading, endPoint: UnitPoint(x: 1, y: 0.25)))
                RoundedRectangle(cornerRadius: 30, style: .continuous)
                    .strokeBorder(Color(red: 1, green: 0.95, blue: 0.82).opacity(0.5), lineWidth: 2)
                    .padding(4)
                RoundedRectangle(cornerRadius: 34, style: .continuous)
                    .strokeBorder(Color(red: 0.35, green: 0.26, blue: 0.09).opacity(0.65), lineWidth: 1.5)

                VStack(spacing: plateText != nil ? 10 : 0) {
                    ZStack {
                        Text("Z").font(Theme.serif(88, weight: .medium))
                            .foregroundStyle(Self.light.opacity(0.45)).offset(y: 3)
                        Text("Z").font(Theme.serif(88, weight: .medium)).foregroundStyle(Self.ink)
                    }
                    .frame(height: 92)
                    if let plateText {
                        let isWord = plateText.allSatisfy { $0.isLetter }
                        Text(plateText)
                            .font(Theme.text(isWord ? 13 : 14, weight: .semibold))
                            .tracking(isWord ? 5 : 0.4)
                            .foregroundStyle(Theme.metalGold)
                            .lineLimit(1)
                            .minimumScaleFactor(0.6)
                            .padding(.leading, isWord ? 5 : 0)
                            .padding(.horizontal, 14)
                            .fixedSize()
                            .frame(minWidth: 116)
                            .frame(height: 30)
                            .background(Theme.plateInk, in: RoundedRectangle(cornerRadius: 6))
                            .overlay(RoundedRectangle(cornerRadius: 6)
                                .stroke(Color(red: 0.95, green: 0.84, blue: 0.59).opacity(0.7), lineWidth: 1.2))
                            .contentTransition(.numericText())
                    }
                }
                .offset(y: plateText != nil ? 2 : -2)
            }
            .frame(width: 228, height: 176)
            .position(x: 150, y: 236)
        }
        .frame(width: 300, height: 340)
        .rotation3DEffect(.degrees(Double(tilt.width) * 10), axis: (x: 0, y: 1, z: 0), perspective: 0.6)
        .rotation3DEffect(.degrees(Double(-tilt.height) * 6), axis: (x: 1, y: 0, z: 0), perspective: 0.6)
        .scaleEffect(size / 300)
        .frame(width: size, height: size * 340 / 300)
        .accessibilityElement()
        .accessibilityLabel(open ? "The Zecky lock, opened" : "The Zecky lock, locked")
    }
}

private struct Shackle: Shape {
    func path(in rect: CGRect) -> Path {
        var p = Path()
        p.move(to: CGPoint(x: 84, y: 160))
        p.addLine(to: CGPoint(x: 84, y: 96))
        p.addArc(center: CGPoint(x: 150, y: 96), radius: 66, startAngle: .degrees(180), endAngle: .degrees(360), clockwise: false)
        p.addLine(to: CGPoint(x: 216, y: 160))
        return p
    }
}

/// Banknote line work: fine gold guilloché rings behind the lock.
/// Very low contrast, and it drifts a little with the lock's tilt.
struct GuillocheBackground: View {
    var tilt: CGSize = .zero

    var body: some View {
        Canvas { context, size in
            let center = CGPoint(x: size.width / 2 + tilt.width * 6, y: size.height * 0.40 + tilt.height * 4)
            for k in 0..<18 {
                let radius = 150.0 + Double(k) * 16
                let amplitude = 10.0 + Double(k) * 0.6
                var path = Path()
                let steps = 540
                for i in 0...steps {
                    let t = Double(i) / Double(steps) * 2 * .pi
                    let r = radius + amplitude * sin(24 * t + Double(k) * 0.35)
                    let point = CGPoint(x: center.x + r * cos(t) * 1.55, y: center.y + r * sin(t))
                    if i == 0 { path.move(to: point) } else { path.addLine(to: point) }
                }
                path.closeSubpath()
                context.stroke(path, with: .color(Theme.gold.opacity(k % 3 == 0 ? 0.11 : 0.06)), lineWidth: 0.8)
            }
        }
        .background(
            RadialGradient(colors: [Theme.gold.opacity(0.10), .clear],
                           center: UnitPoint(x: 0.5, y: 0.38), startRadius: 0, endRadius: 360))
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }
}

/// Banknote medallion: crisp guilloché rosettes centred on the lock,
/// densest near the lock and fading towards the edge, with a warm halo of
/// light right behind the metal. Shifts a hair with the lock's tilt.
struct Medallion: View {
    var tilt: CGSize = .zero
    var diameter: CGFloat = 640

    var body: some View {
        Canvas { context, size in
            let c = CGPoint(x: size.width / 2, y: size.height / 2)
            let maxR = Double(min(size.width, size.height)) / 2
            // Rosette bands: each band is several phase-shifted waves woven together.
            let bands: [(r: Double, a: Double, n: Double, copies: Int)] = [
                (0.40, 0.030, 36, 6), (0.52, 0.035, 42, 6), (0.66, 0.030, 48, 5),
                (0.80, 0.025, 54, 4), (0.93, 0.020, 60, 3),
            ]
            for (bi, band) in bands.enumerated() {
                let baseR = band.r * maxR
                let amp = band.a * maxR
                let fade = 1 - Double(bi) / Double(bands.count)
                for copy in 0..<band.copies {
                    let phase = Double(copy) / Double(band.copies) * 2 * .pi / band.n
                    var path = Path()
                    let steps = 1440
                    for i in 0...steps {
                        let t = Double(i) / Double(steps) * 2 * .pi
                        let r = baseR + amp * sin(band.n * (t + phase)) + amp * 0.35 * sin(3 * t)
                        let p = CGPoint(x: c.x + r * cos(t), y: c.y + r * sin(t))
                        if i == 0 { path.move(to: p) } else { path.addLine(to: p) }
                    }
                    path.closeSubpath()
                    context.stroke(path, with: .color(Theme.gold.opacity(0.05 + 0.10 * fade)), lineWidth: 0.7)
                }
            }
            // Fine outer border rings, like the edge of a medallion.
            for (i, f) in [0.985, 0.995].enumerated() {
                let r = f * maxR
                context.stroke(Path(ellipseIn: CGRect(x: c.x - r, y: c.y - r, width: 2 * r, height: 2 * r)),
                               with: .color(Theme.gold.opacity(i == 0 ? 0.10 : 0.05)), lineWidth: 0.7)
            }
        }
        .frame(width: diameter, height: diameter)
        .drawingGroup()
        .mask(RadialGradient(colors: [.black, .black, .black.opacity(0)], center: .center,
                             startRadius: 0, endRadius: diameter / 2))
        // Fade the lower part so the balance below sits on clean dark.
        .mask(LinearGradient(stops: [.init(color: .black, location: 0), .init(color: .black, location: 0.64),
                                     .init(color: .black.opacity(0), location: 0.76)],
                             startPoint: .top, endPoint: .bottom))
        // Drawn once; the tilt only moves it a hair.
        .offset(x: tilt.width * 3, y: tilt.height * 2)
        .background(
            RadialGradient(colors: [Color(red: 0.96, green: 0.84, blue: 0.56).opacity(0.22), Theme.gold.opacity(0.06), .clear],
                           center: .center, startRadius: 0, endRadius: diameter * 0.32))
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }
}

/// Milestones for holding: one week, one month, 100 days, one year, two
/// years, five years.
// MARK: - Locked for … (as Lock it iPhone: src/lib/lockedSince.ts, milestones.ts, holding.ts)

/// Milestones for holding: 1 week, then every month of the first year (months
/// of 30 days, as in the "Locked for" line), 1 year, then every year (365
/// days), with no end. Each has its own name, rising to Legend at 4 years.
enum Milestone {
    static let year = 365
    static let legend = 4 * year

    /// Every milestone day up to and including `upTo`, plus the first after it.
    static func list(through upTo: Int) -> [Int] {
        var list = [7] + (1...11).map { 30 * $0 }
        var y = 1
        while list.last! <= upTo { list.append(year * y); y += 1 }
        return list
    }

    /// How far along the way from the previous milestone to the next, 0…1.
    /// Full (1) on the day a milestone is reached; it starts over after each.
    static func progress(after days: Int) -> Double {
        let held = max(0, days)
        if reachedToday(after: held) { return 1 }
        let list = Self.list(through: held)
        let next = list.first { $0 > held } ?? list.last!
        let prev = ([0] + list).last { $0 < next } ?? 0
        return Double(held - prev) / Double(next - prev)
    }

    /// True only on the (calendar) day a milestone is reached: the ring glows.
    static func reachedToday(after days: Int) -> Bool {
        days > 0 && list(through: days).contains(days)
    }

    // The Mac's medallion engraves a fine line only for the big ones:
    // 1 week, 1 year and every year after.
    static func engraves(_ days: Int) -> Bool { days == 7 || (days >= year && days % year == 0) }
    /// How many engraved lines a holding of `days` has earned.
    static func engraved(after days: Int) -> Int { list(through: max(0, days)).filter { $0 <= days && engraves($0) }.count }
    /// True on the day an engraved line is added: it shines brighter.
    static func engravedToday(after days: Int) -> Bool { reachedToday(after: days) && engraves(days) }

    private static let names: [Int: String] = [
        7: "Locked", 30: "Sealed", 60: "Bolted", 90: "Steady", 120: "Anchored", 150: "Rooted",
        180: "Unshaken", 210: "Hardened", 240: "Vaulted", 270: "Fortified", 300: "Bedrock",
        330: "Keeper", 365: "Guardian", 730: "Sentinel", 1095: "Stronghold", 1460: "Legend",
    ]

    /// The name of the milestone at `days`; after Legend, Legend with its years.
    static func name(_ days: Int) -> String {
        names[days] ?? "Legend · \(Int((Double(days) / Double(year)).rounded())) years"
    }

    /// The plain length of the milestone at `days`: "1 week", "3 months", "2 years".
    static func length(_ days: Int) -> String {
        if days == 7 { return "1 week" }
        let (n, unit) = days < year ? (Int((Double(days) / 30).rounded()), "month")
                                    : (Int((Double(days) / Double(year)).rounded()), "year")
        return "\(n) \(unit)\(n == 1 ? "" : "s")"
    }

    /// The one line shown when a milestone is reached: "1 month in the lock."
    static func line(_ days: Int) -> String {
        let text = length(days)
        return text.prefix(1).uppercased() + text.dropFirst() + " in the lock."
    }

    struct Step: Equatable {
        let days: Int
        let name: String
        let length: String
        /// When it was (or will be) reached.
        let at: Date
        let reached: Bool
        /// For the next one only: how far along (0…1) and days to go.
        var progress: Double?
        var inDays: Int?
    }

    /// The whole path for a holding of `held` days that began on `since`: up
    /// to Legend at 4 years, and further when already past it, always with
    /// the next two after the one in progress.
    static func path(since: Date, held: Int, calendar: Calendar = .current) -> [Step] {
        func upcoming(_ list: [Int]) -> Int { list.filter { $0 > held }.count }
        let reach = max(held, legend)
        var list = Self.list(through: reach)
        while upcoming(list) < 3 { list = self.list(through: list.last!) }
        let shown = list.filter { d in d <= reach || upcoming(list.filter { $0 < d }) < 3 }
        let day0 = calendar.startOfDay(for: since)
        var prev = 0
        var nextSeen = false
        return shown.map { d in
            var step = Step(days: d, name: name(d), length: length(d),
                            at: calendar.date(byAdding: .day, value: d, to: day0) ?? day0, reached: d <= held)
            if !step.reached && !nextSeen {
                nextSeen = true
                step.progress = Double(held - prev) / Double(d - prev)
                step.inDays = d - held
            }
            prev = d
            return step
        }
    }

    /// The short view: the last milestone reached (if any) and the next two.
    static func shortPath(_ path: [Step]) -> [Step] {
        let next = path.firstIndex { !$0.reached } ?? path.count
        let from = next <= 0 ? 0 : next - 1
        return Array(path[from..<min(path.count, from + 3)])
    }
}

/// One payment, as the holding count needs it.
struct HoldingEntry: Equatable {
    let height: Int
    let date: Date
    /// The engine's signed change to this wallet's balance in zatoshi: + in,
    /// - out. A send's value already includes its fee: never take it twice.
    let change: Int64
    /// Locking in transparent Zcash, the Ironwood move, a payment to an own
    /// address: Zcash stays in the lock. Never starts or ends anything.
    let internalMove: Bool
}

/// One stretch of holding: from a payment in after an empty lock until it was empty again.
struct Stretch: Equatable {
    let start: Date
    /// When the lock was empty again; nil for the stretch going on now.
    var end: Date?
    /// Zatoshi that came in during the stretch (payments in, not internal moves).
    var received: Int64 = 0
    var paymentsIn = 0
    /// The largest single payment in, and when it came.
    var largest: (zatoshi: Int64, at: Date)?

    static func == (a: Stretch, b: Stretch) -> Bool {
        a.start == b.start && a.end == b.end && a.received == b.received && a.paymentsIn == b.paymentsIn
            && a.largest?.zatoshi == b.largest?.zatoshi && a.largest?.at == b.largest?.at
    }
}

/// How long the Zcash in the lock has been there, worked out from the wallet
/// history alone (no stored timer, so it comes back the same after a restore).
enum Holding {
    /// Every stretch, oldest first. A stretch starts at the first confirmed
    /// payment in after the balance was zero; sends of any size and later
    /// payments in do not end it, internal moves count as nothing; only an
    /// empty lock ends it. Also returns the balance the history adds up to.
    static func walk(_ entries: [HoldingEntry]) -> (stretches: [Stretch], balance: Int64) {
        var list: [Stretch] = []
        var balance: Int64 = 0
        var open = false
        for entry in entries.sorted(by: { ($0.height, $0.date) < ($1.height, $1.date) }) {
            let paymentIn = entry.change > 0 && !entry.internalMove
            if !open && balance <= 0 && paymentIn {
                list.append(Stretch(start: entry.date))
                open = true
            }
            if open && paymentIn {
                list[list.count - 1].received += entry.change
                list[list.count - 1].paymentsIn += 1
                if (list[list.count - 1].largest?.zatoshi ?? 0) < entry.change {
                    list[list.count - 1].largest = (entry.change, entry.date)
                }
            }
            balance += entry.change
            if balance <= 0 {
                balance = 0
                if open { list[list.count - 1].end = entry.date }
                open = false
            }
        }
        return (list, balance)
    }

    /// When the current holding began; nil when nothing is in the lock.
    static func since(_ entries: [HoldingEntry]) -> Date? {
        guard let last = walk(entries).stretches.last, last.end == nil else { return nil }
        return last.start
    }

    /// Whether the history reaches back to the start of what is in the lock.
    /// After a restore from a later date the oldest payments in are missing:
    /// then the confirmed history adds up to less than the balance (minus
    /// what is still waiting to come in), and a count would be too short.
    static func historyComplete(_ entries: [HoldingEntry], pendingIn: Int64, balance: Int64) -> Bool {
        walk(entries).balance + max(0, pendingIn) >= balance
    }

    /// Calendar days, so a payment from yesterday evening counts as 1 day.
    static func days(since: Date, now: Date = Date(), calendar: Calendar = .current) -> Int {
        max(0, calendar.dateComponents([.day], from: calendar.startOfDay(for: since),
                                       to: calendar.startOfDay(for: now)).day ?? 0)
    }

    /// The largest whole unit only, never a date (a date was read as an
    /// unlock date): days up to 6, weeks from 7 to 29 days, months (of 30
    /// days, at most 11) up to 364 days, then years of 365 days.
    static func heldFor(days: Int) -> String {
        func unit(_ n: Int, _ one: String) -> String { "\(n) \(one)\(n == 1 ? "" : "s")" }
        let d = max(0, days)
        if d < 1 { return "since today" }
        if d < 7 { return "for " + unit(d, "day") }
        if d < 30 { return "for " + unit(d / 7, "week") }
        if d < 365 { return "for " + unit(min(11, d / 30), "month") }
        return "for " + unit(d / 365, "year")
    }

    struct Summary {
        let since: Date
        let days: Int
        let current: Stretch
        /// The longest earlier stretch, only when it was longer than now.
        let longestBefore: (days: Int, start: Date, end: Date)?
    }

    /// Highlights of the holding going on now; nil for an empty lock.
    static func summary(_ entries: [HoldingEntry], now: Date = Date(), calendar: Calendar = .current) -> Summary? {
        let list = walk(entries).stretches
        guard let current = list.last, current.end == nil else { return nil }
        let days = Self.days(since: current.start, now: now, calendar: calendar)
        var longest: (days: Int, start: Date, end: Date)?
        for s in list.dropLast() {
            guard let end = s.end else { continue }
            let length = self.days(since: s.start, now: end, calendar: calendar)
            if length > days && length > (longest?.days ?? 0) { longest = (length, s.start, end) }
        }
        return Summary(since: current.start, days: days, current: current, longestBefore: longest)
    }

    enum Per: String { case day, week, month }

    /// Stacking pace: what came in since the start, divided by the time held,
    /// in a period that fits that time: per day in the first week, per week
    /// up to 3 months, then per month (30 days). Rounded to 3 significant
    /// digits so it reads calmly. Nil on the first day or with nothing in.
    static func pace(received: Int64, days: Int) -> (zatoshi: Int64, per: Per)? {
        guard days >= 1, received > 0 else { return nil }
        let (per, length): (Per, Int64) = days < 7 ? (.day, 1) : days < 90 ? (.week, 7) : (.month, 30)
        let exact = received * length / Int64(days)
        let digits = String(exact).count
        var step: Int64 = 1
        if digits > 3 { for _ in 0..<(digits - 3) { step *= 10 } }
        return (((exact + step / 2) / step) * step, per)
    }
}

/// The milestone moment is shown once: the first time the holding page opens
/// on the day it is reached. Only which milestone of which holding is kept.
enum MilestoneMoment {
    static let key = "app.zecky.lockit.mac.milestoneSeen"
    private static func id(_ since: Date, _ days: Int) -> String { "\(Int64(since.timeIntervalSince1970 * 1000)):\(days)" }
    static func seen(since: Date, days: Int, defaults: UserDefaults = .standard) -> Bool {
        defaults.string(forKey: key) == id(since, days)
    }
    static func markSeen(since: Date, days: Int, defaults: UserDefaults = .standard) {
        defaults.set(id(since, days), forKey: key)
    }
    /// For Erase wallet.
    static func reset(defaults: UserDefaults = .standard) { defaults.removeObject(forKey: key) }
}

/// A thin gold ring around the lock that fills towards the next milestone.
struct MilestoneRing: View {
    var progress: Double
    var diameter: CGFloat = 340
    /// The day a milestone is reached: a soft glow along the arc. Nothing else.
    var glow = false

    var body: some View {
        ZStack {
            Circle().stroke(Theme.gold.opacity(0.14), lineWidth: 2)
            if glow {
                // A wider, softer copy of the arc.
                Circle()
                    .trim(from: 0, to: max(0.004, min(1, progress)))
                    .stroke(Theme.gold.opacity(0.14), style: StrokeStyle(lineWidth: 16, lineCap: .round))
                    .rotationEffect(.degrees(-90))
                    .blur(radius: 3)
            }
            Circle()
                .trim(from: 0, to: max(0.004, min(1, progress)))
                .stroke(Theme.gold, style: StrokeStyle(lineWidth: 2.5, lineCap: .round))
                .rotationEffect(.degrees(-90))
                .shadow(color: Theme.gold.opacity(0.5), radius: 4)
            // A glowing point at the tip, like the hand of a clock.
            let angle = (max(0.004, min(1, progress)) * 360 - 90) * .pi / 180
            Circle()
                .fill(Theme.gold)
                .frame(width: 8, height: 8)
                .shadow(color: Theme.gold.opacity(0.9), radius: 6)
                .offset(x: diameter / 2 * cos(angle), y: diameter / 2 * sin(angle))
            // Tick marks every 6 degrees, a longer one every 30.
            ForEach(0..<60, id: \.self) { i in
                Rectangle()
                    .fill(Theme.gold.opacity(i % 5 == 0 ? 0.35 : 0.14))
                    .frame(width: 1, height: i % 5 == 0 ? 8 : 4)
                    .offset(y: -diameter / 2 + 10)
                    .rotationEffect(.degrees(Double(i) * 6))
            }
        }
        .frame(width: diameter, height: diameter)
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }
}

/// Fine guilloche lines engraved into the medallion, one per milestone
/// reached, like rings in a tree. They record how long Zcash stayed locked;
/// sending does not erase them. The newest shines brighter on its day.
struct EngravedRings: View {
    var count: Int
    var newestBright: Bool
    var diameter: CGFloat

    // Radius (as part of the diameter), wave amplitude and wave count per line.
    private static let lines: [(r: CGFloat, amp: CGFloat, waves: Double)] = [
        (0.535, 2.0, 48), (0.565, 2.4, 56), (0.505, 1.6, 40), (0.595, 2.0, 64), (0.475, 1.4, 36), (0.625, 1.8, 72),
    ]

    var body: some View {
        Canvas { context, size in
            let c = CGPoint(x: size.width / 2, y: size.height / 2)
            for (k, line) in Self.lines.prefix(count).enumerated() {
                let newest = k == count - 1
                let opacity = newest && newestBright ? 0.6 : 0.26
                for copy in 0..<3 {
                    let phase = Double(copy) / 3 * 2 * .pi / line.waves
                    var path = Path()
                    for i in 0...480 {
                        let t = Double(i) / 480 * 2 * .pi
                        let r = Double(line.r * diameter / 2) + Double(line.amp) * sin(line.waves * (t + phase))
                        let p = CGPoint(x: c.x + r * cos(t), y: c.y + r * sin(t))
                        if i == 0 { path.move(to: p) } else { path.addLine(to: p) }
                    }
                    path.closeSubpath()
                    context.stroke(path, with: .color(Theme.gold.opacity(opacity)), lineWidth: 0.6)
                }
            }
        }
        .frame(width: diameter, height: diameter)
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }
}

/// The chain's heartbeat: with every new Zcash block (about every 25
/// seconds since NU7) a soft gold light runs once around the medallion, and
/// the block number shows for a moment. With Reduce Motion on, only the
/// number shows.
struct ChainHeartbeat: View {
    var height: Int
    var active: Bool
    var diameter: CGFloat
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    // Each beat turns the light one more full round; it never jumps back.
    @State private var beats = 0
    @State private var lit = false
    @State private var labelOn = false
    @State private var shown = 0
    @State private var token = UUID()

    var body: some View {
        ZStack {
            Circle()
                .trim(from: 0, to: 0.075)
                .stroke(AngularGradient(colors: [Theme.gold.opacity(0), Theme.gold], center: .center,
                                        startAngle: .degrees(0), endAngle: .degrees(27)),
                        style: StrokeStyle(lineWidth: 2.5, lineCap: .round))
                .frame(width: diameter, height: diameter)
                .rotationEffect(.degrees(Double(beats) * 360 - 90 - 27))
                .animation(reduceMotion ? nil : .easeInOut(duration: 2.6), value: beats)
                .opacity(lit ? 1 : 0)
                .animation(.easeInOut(duration: 0.5), value: lit)
            Text("BLOCK \(shown.formatted(.number.grouping(.automatic).locale(Locale(identifier: "en_US"))))")
                .font(Theme.text(9, weight: .medium)).tracking(1.5)
                .foregroundStyle(Theme.gold.opacity(0.8))
                .fixedSize()
                // Inside the milestone ring, under its gold dot and above
                // the shackle: clear of the wallet chips and the balance.
                .offset(y: -diameter / 2 + 46)
                .opacity(labelOn ? 1 : 0)
                .animation(.easeInOut(duration: 0.6), value: labelOn)
        }
        // Drawn on its own layer with a fixed size, so nothing around it
        // moves while it runs.
        .frame(width: diameter, height: diameter)
        .drawingGroup()
        .shadow(color: Theme.gold.opacity(lit ? 0.6 : 0), radius: 5)
        .allowsHitTesting(false)
        .accessibilityHidden(true)
        .onChange(of: height) { new in beat(new) }
    }

    private func beat(_ new: Int) {
        guard active, new > 0, new != shown else { shown = new; return }
        shown = new
        let mine = UUID()
        token = mine
        labelOn = true
        if !reduceMotion { beats += 1; lit = true }
        Task { @MainActor in
            try? await Task.sleep(nanoseconds: 2_300_000_000)
            if token == mine { lit = false }
            try? await Task.sleep(nanoseconds: 2_200_000_000)
            if token == mine { labelOn = false }
        }
    }
}
