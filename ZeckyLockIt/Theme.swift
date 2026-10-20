import SwiftUI

/// Zecky's look: deep ink, warm gold, a serif for the balance.
enum Theme {
    static let ink = Color(red: 0x14 / 255, green: 0x16 / 255, blue: 0x1C / 255)
    static let surface = Color(red: 0x1C / 255, green: 0x1F / 255, blue: 0x27 / 255)
    static let gold = Color(red: 0xD4 / 255, green: 0xA6 / 255, blue: 0x57 / 255)
    static let text = Color(red: 0xEC / 255, green: 0xE8 / 255, blue: 0xDF / 255)
    static let muted = Color(red: 0x9A / 255, green: 0x9D / 255, blue: 0xA6 / 255)
    static let green = Color(red: 0x8F / 255, green: 0xBF / 255, blue: 0x8A / 255)
    static let red = Color(red: 0xE0 / 255, green: 0x8A / 255, blue: 0x63 / 255)

    /// Newsreader is the brand serif; until it is bundled, the system serif stands in.
    static func serif(_ size: CGFloat, weight: Font.Weight = .regular) -> Font {
        .system(size: size, weight: weight, design: .serif)
    }
}

/// A gold, full-width primary button.
struct PrimaryButton: View {
    let title: String
    var enabled = true
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Text(title)
                .font(.system(size: 14, weight: .semibold))
                .frame(maxWidth: .infinity)
                .padding(.vertical, 10)
                .background(enabled ? Theme.gold : Theme.gold.opacity(0.35))
                .foregroundStyle(Theme.ink)
                .clipShape(RoundedRectangle(cornerRadius: 8))
        }
        .buttonStyle(.plain)
        .disabled(!enabled)
    }
}

/// A quiet, outlined secondary button.
struct SecondaryButton: View {
    let title: String
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Text(title)
                .font(.system(size: 14, weight: .medium))
                .frame(maxWidth: .infinity)
                .padding(.vertical, 10)
                .foregroundStyle(Theme.text)
                .overlay(RoundedRectangle(cornerRadius: 8).stroke(Theme.muted.opacity(0.5)))
        }
        .buttonStyle(.plain)
    }
}
