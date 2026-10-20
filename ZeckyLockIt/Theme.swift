import CoreText
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

    /// Newsreader (brand serif) and Inter (text), bundled with the app under
    /// the SIL Open Font License. Registered for this app only.
    static func registerFonts() {
        let names = ["Newsreader-Regular", "Newsreader-Medium", "Inter-Regular", "Inter-Medium", "Inter-SemiBold"]
        for name in names {
            if let url = Bundle.main.url(forResource: name, withExtension: "ttf") {
                CTFontManagerRegisterFontsForURL(url as CFURL, .process, nil)
            }
        }
    }

    /// The serif for balances and titles.
    static func serif(_ size: CGFloat, weight: Font.Weight = .regular) -> Font {
        .custom(weight == .regular ? "Newsreader-Regular" : "Newsreader-Medium", fixedSize: size)
    }

    /// The text face.
    static func text(_ size: CGFloat, weight: Font.Weight = .regular) -> Font {
        switch weight {
        case .semibold, .bold, .heavy, .black: return .custom("Inter-SemiBold", fixedSize: size)
        case .medium: return .custom("Inter-Medium", fixedSize: size)
        default: return .custom("Inter-Regular", fixedSize: size)
        }
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
                .font(Theme.text(14, weight: .semibold))
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
                .font(Theme.text(14, weight: .medium))
                .frame(maxWidth: .infinity)
                .padding(.vertical, 10)
                .foregroundStyle(Theme.text)
                .overlay(RoundedRectangle(cornerRadius: 8).stroke(Theme.muted.opacity(0.5)))
        }
        .buttonStyle(.plain)
    }
}
