import SwiftUI

/// Seal it's mark: a gold envelope outline with a wax seal on the flap,
/// pressed with the family serif Z. Drawn in code so it stays sharp at
/// any size and follows the theme.
struct SealMark: View {
    var size: CGFloat = 120
    /// 0 = open (no seal yet), 1 = sealed. Animate it to press the seal.
    var sealed: CGFloat = 1

    var body: some View {
        let s = size / 512
        ZStack {
            EnvelopeShape()
                .stroke(Theme.gold, style: StrokeStyle(lineWidth: 12 * s, lineCap: .round, lineJoin: .round))
            ZStack {
                WaxShape()
                    .fill(RadialGradient(colors: [Self.c(0xF6E2B0), Self.c(0xD9AE5F), Self.c(0x8A6224)],
                                         center: UnitPoint(x: 0.4, y: 0.35), startRadius: 0, endRadius: 80 * s))
                    .overlay(WaxShape().stroke(Theme.ink, lineWidth: 10 * s))
                    .frame(width: 176 * s, height: 176 * s)
                Text("Z")
                    .font(Theme.serif(92 * s, weight: .medium))
                    .foregroundStyle(Self.c(0x5E4519))
                    .offset(y: 2 * s)
            }
            .offset(y: 32 * s)
            .scaleEffect(0.6 + 0.4 * sealed)
            .opacity(Double(sealed))
        }
        .frame(width: size, height: size)
        .accessibilityLabel("Seal it")
    }

    private static func c(_ hex: Int) -> Color {
        Color(red: Double((hex >> 16) & 0xFF) / 255, green: Double((hex >> 8) & 0xFF) / 255, blue: Double(hex & 0xFF) / 255)
    }
}

/// Envelope body and flap in a 512-unit square.
private struct EnvelopeShape: Shape {
    func path(in rect: CGRect) -> Path {
        let k = rect.width / 512
        var p = Path()
        p.addRoundedRect(in: CGRect(x: 78 * k, y: 150 * k, width: 356 * k, height: 232 * k),
                         cornerSize: CGSize(width: 18 * k, height: 18 * k))
        p.move(to: CGPoint(x: 88 * k, y: 166 * k))
        p.addLine(to: CGPoint(x: 256 * k, y: 286 * k))
        p.addLine(to: CGPoint(x: 424 * k, y: 166 * k))
        return p
    }
}

/// A wax blob: a circle with a soft, uneven edge.
private struct WaxShape: Shape {
    func path(in rect: CGRect) -> Path {
        let c = CGPoint(x: rect.midX, y: rect.midY)
        let r = min(rect.width, rect.height) / 2 * 0.92
        var p = Path()
        let n = 120
        for i in 0...n {
            let t = Double(i) / Double(n) * 2 * .pi
            let wobble = 0.55 * sin(7 * t + 1.1) + 0.3 * sin(10 * t + 2.3) + 0.15 * sin(2 * t + 0.4)
            let rr = r * (1 + 0.07 * wobble)
            let pt = CGPoint(x: c.x + rr * cos(t), y: c.y + rr * sin(t))
            if i == 0 { p.move(to: pt) } else { p.addLine(to: pt) }
        }
        p.closeSubpath()
        return p
    }
}

/// "Write it · Seal it · Send it", with the current step in gold.
struct SealSteps: View {
    enum Step: Int { case write, seal, send }
    let current: Step

    var body: some View {
        HStack(spacing: 10) {
            label("Write it", .write)
            dot
            label("Seal it", .seal)
            dot
            label("Send it", .send)
        }
        .frame(maxWidth: .infinity)
    }

    private var dot: some View {
        Text("·").font(Theme.text(13)).foregroundStyle(Theme.muted.opacity(0.6))
    }

    private func label(_ text: String, _ step: Step) -> some View {
        Text(text)
            .font(Theme.text(13, weight: step == current ? .semibold : .regular))
            .foregroundStyle(step == current ? Theme.gold : (step.rawValue < current.rawValue ? Theme.text : Theme.muted))
    }
}
