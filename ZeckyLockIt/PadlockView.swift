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
enum Milestone {
    static let steps: [(days: Int, name: String)] = [
        (7, "1 week"), (30, "1 month"), (100, "100 days"), (365, "1 year"), (730, "2 years"), (1825, "5 years"),
    ]

    /// The next milestone and how far along the way to it (0…1).
    static func next(after days: Int) -> (name: String, inDays: Int, progress: Double)? {
        guard let i = steps.firstIndex(where: { $0.days > days }) else { return nil }
        let start = i == 0 ? 0 : steps[i - 1].days
        let target = steps[i].days
        return (steps[i].name, target - days, Double(days - start) / Double(target - start))
    }
}

/// A thin gold ring around the lock that fills towards the next milestone.
struct MilestoneRing: View {
    var progress: Double
    var diameter: CGFloat = 340

    var body: some View {
        ZStack {
            Circle().stroke(Theme.gold.opacity(0.14), lineWidth: 2)
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

extension Milestone {
    /// How many milestones are reached after `days` held.
    static func reached(after days: Int) -> Int { steps.filter { $0.days <= days }.count }
    /// True on the day a milestone was reached: its line shines brighter.
    static func reachedToday(after days: Int) -> Bool { steps.contains { $0.days == days } }
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
