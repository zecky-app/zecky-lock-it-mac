import SwiftUI

/// The gold padlock with the Zecky Z: the heart of Lock it.
/// Drawn in a 240 × 280 space and scaled. It opens with a swing of the
/// shackle, and tilts a little towards the pointer so it feels solid.
struct PadlockView: View {
    var open: Bool
    var size: CGFloat = 200
    /// -1…1 in each direction, from the pointer.
    var tilt: CGSize = .zero

    private static let ink = Color(red: 0x6E / 255, green: 0x50 / 255, blue: 0x20 / 255)

    var body: some View {
        ZStack {
            Ellipse()
                .fill(Color.black.opacity(0.55))
                .frame(width: 176, height: 18)
                .blur(radius: 7)
                .position(x: 120, y: 266)

            Shackle()
                .stroke(
                    LinearGradient(stops: [
                        .init(color: Color(red: 0.56, green: 0.45, blue: 0.25), location: 0),
                        .init(color: Color(red: 0.96, green: 0.89, blue: 0.69), location: 0.35),
                        .init(color: Color(red: 0.79, green: 0.63, blue: 0.32), location: 0.6),
                        .init(color: Color(red: 0.48, green: 0.36, blue: 0.15), location: 1),
                    ], startPoint: .leading, endPoint: .trailing),
                    lineWidth: 22)
                .frame(width: 240, height: 280)
                .offset(y: open ? -30 : 0)
                .rotationEffect(.degrees(open ? -22 : 0), anchor: UnitPoint(x: 170 / 240, y: 132 / 280))

            ZStack {
                RoundedRectangle(cornerRadius: 30, style: .continuous)
                    .fill(LinearGradient(stops: [
                        .init(color: Color(red: 0.95, green: 0.84, blue: 0.59), location: 0),
                        .init(color: Theme.gold, location: 0.45),
                        .init(color: Color(red: 0.54, green: 0.40, blue: 0.16), location: 1),
                    ], startPoint: .top, endPoint: .bottom))
                RoundedRectangle(cornerRadius: 30, style: .continuous)
                    .fill(LinearGradient(stops: [
                        .init(color: .white.opacity(0), location: 0),
                        .init(color: .white.opacity(0.28), location: 0.3 + tilt.width * 0.12),
                        .init(color: .white.opacity(0), location: 0.5 + tilt.width * 0.12),
                    ], startPoint: .leading, endPoint: .trailing))
                RoundedRectangle(cornerRadius: 27, style: .continuous)
                    .strokeBorder(Color(red: 1, green: 0.95, blue: 0.82).opacity(0.45), lineWidth: 2)
                    .padding(3)
                RoundedRectangle(cornerRadius: 30, style: .continuous)
                    .strokeBorder(Color(red: 0.37, green: 0.27, blue: 0.10).opacity(0.6), lineWidth: 1.5)
                ZStack {
                    Text("Z").font(Theme.serif(92, weight: .medium))
                        .foregroundStyle(Color(red: 1, green: 0.94, blue: 0.8).opacity(0.45))
                        .offset(y: 3)
                    Text("Z").font(Theme.serif(92, weight: .medium)).foregroundStyle(Self.ink)
                }
                .offset(y: -2)
            }
            .frame(width: 184, height: 142)
            .position(x: 120, y: 189)
        }
        .frame(width: 240, height: 280)
        .rotation3DEffect(.degrees(Double(tilt.width) * 10), axis: (x: 0, y: 1, z: 0), perspective: 0.6)
        .rotation3DEffect(.degrees(Double(-tilt.height) * 6), axis: (x: 1, y: 0, z: 0), perspective: 0.6)
        .scaleEffect(size / 240)
        .frame(width: size, height: size * 280 / 240)
        .accessibilityElement()
        .accessibilityLabel(open ? "Gold padlock with the Zecky Z, opened" : "Gold padlock with the Zecky Z, locked")
    }
}

private struct Shackle: Shape {
    func path(in rect: CGRect) -> Path {
        var p = Path()
        p.move(to: CGPoint(x: 70, y: 132))
        p.addLine(to: CGPoint(x: 70, y: 82))
        p.addArc(center: CGPoint(x: 120, y: 82), radius: 50, startAngle: .degrees(180), endAngle: .degrees(360), clockwise: false)
        p.addLine(to: CGPoint(x: 170, y: 132))
        return p
    }
}
