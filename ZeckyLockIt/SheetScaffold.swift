import SwiftUI

/// The shared frame for every sheet: ink background with a corner of
/// banknote line work, a small gold ZECKY label, a serif title with one
/// line of explanation, and a Done button.
struct SheetScaffold<Content: View>: View {
    let title: String
    var subtitle: String? = nil
    var closeLabel: String = "Done"
    var showsClose = true
    var width: CGFloat = 560
    var height: CGFloat = 620
    /// The wallet this screen works on, shown under the title so the right
    /// one is chosen (Receive and Send). nil shows nothing.
    var wallet: WalletTag? = nil
    let onClose: () -> Void
    @ViewBuilder var content: () -> Content

    var body: some View {
        ZStack(alignment: .topTrailing) {
            Theme.ink
            CornerLines()
                .frame(width: 320, height: 320)
                .offset(x: 120, y: -120)
            VStack(alignment: .leading, spacing: 0) {
                HStack(alignment: .top) {
                    VStack(alignment: .leading, spacing: 6) {
                        Text("ZECKY").font(Theme.text(11, weight: .semibold)).tracking(4).foregroundStyle(Theme.gold)
                        Text(title).font(Theme.serif(30, weight: .medium))
                        if let wallet {
                            HStack(spacing: 6) {
                                Image(systemName: wallet.sealed ? "envelope.fill" : "lock.fill").font(.system(size: 10))
                                Text(wallet.name).font(Theme.text(12, weight: .semibold)).lineLimit(1)
                            }
                            .foregroundStyle(Theme.gold)
                            .padding(.horizontal, 10).frame(height: 24)
                            .overlay(Capsule().stroke(Theme.gold.opacity(0.6)))
                            .accessibilityElement(children: .combine)
                            .accessibilityLabel("Wallet: \(wallet.name)")
                        }
                        if let subtitle {
                            Text(subtitle).font(Theme.text(13)).foregroundStyle(Theme.muted)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                    }
                    Spacer(minLength: 16)
                    if showsClose {
                        Button(closeLabel, action: onClose)
                            .buttonStyle(HeaderButtonStyle())
                            .keyboardShortcut(.cancelAction)
                    }
                }
                .padding(.bottom, 20)
                content()
            }
            .padding(.horizontal, 32)
            .padding(.top, 28)
            .padding(.bottom, 24)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        }
        .frame(width: width, height: height)
        .clipped()
        .foregroundStyle(Theme.text)
    }
}

/// A quarter of the medallion, peeking in from a sheet's corner.
private struct CornerLines: View {
    var body: some View {
        Canvas { context, size in
            let c = CGPoint(x: size.width / 2, y: size.height / 2)
            for k in 0..<7 {
                let base = 60.0 + Double(k) * 18
                for copy in 0..<3 {
                    let phase = Double(copy) / 3 * 2 * .pi / 40
                    var path = Path()
                    for i in 0...720 {
                        let t = Double(i) / 720 * 2 * .pi
                        let r = base + 6 * sin(40 * (t + phase))
                        let p = CGPoint(x: c.x + r * cos(t), y: c.y + r * sin(t))
                        if i == 0 { path.move(to: p) } else { path.addLine(to: p) }
                    }
                    path.closeSubpath()
                    context.stroke(path, with: .color(Theme.gold.opacity(0.07)), lineWidth: 0.6)
                }
            }
        }
        .mask(RadialGradient(colors: [.black, .clear], center: .center, startRadius: 40, endRadius: 170))
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }
}

/// A calm card for grouped content.
struct CardModifier: ViewModifier {
    var padding: CGFloat = 16
    func body(content: Content) -> some View {
        content
            .padding(padding)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Theme.surface, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).stroke(Theme.line, lineWidth: 1))
    }
}

extension View {
    func card(padding: CGFloat = 16) -> some View { modifier(CardModifier(padding: padding)) }
}

/// A wallet's name on a screen, and whether it is a Seal it wallet.
struct WalletTag: Equatable {
    let name: String
    var sealed = false
}
