import AppKit
import CoreText
import SwiftUI

/// Zecky's look, the same palettes as the iPhone app: deep ink with warm
/// gold, or warm paper with a deeper gold. Colours follow the appearance.
enum Theme {
    enum Mode: String, CaseIterable, Identifiable {
        case dark, light, auto
        var id: Self { self }
        var label: String {
            switch self {
            case .dark: return "Dark"
            case .light: return "Light"
            case .auto: return "Same as this Mac"
            }
        }
    }

    static var mode: Mode {
        get { Mode(rawValue: UserDefaults.standard.string(forKey: "theme.mode") ?? "dark") ?? .dark }
        set { UserDefaults.standard.set(newValue.rawValue, forKey: "theme.mode"); apply(newValue) }
    }

    /// Sets the whole app's appearance, sheets and menus included.
    static func apply(_ mode: Mode) {
        switch mode {
        case .dark: NSApp.appearance = NSAppearance(named: .darkAqua)
        case .light: NSApp.appearance = NSAppearance(named: .aqua)
        case .auto: NSApp.appearance = nil
        }
    }

    private static func pair(_ dark: UInt32, _ light: UInt32) -> Color {
        func c(_ hex: UInt32) -> NSColor {
            NSColor(srgbRed: CGFloat(hex >> 16 & 0xFF) / 255, green: CGFloat(hex >> 8 & 0xFF) / 255,
                    blue: CGFloat(hex & 0xFF) / 255, alpha: 1)
        }
        return Color(nsColor: NSColor(name: nil) { appearance in
            appearance.bestMatch(from: [.darkAqua, .aqua]) == .aqua ? c(light) : c(dark)
        })
    }

    static let ink = pair(0x14161C, 0xF6F2EA)
    static let surface = pair(0x1C1F27, 0xFFFFFF)
    static let line = pair(0x2A2E39, 0xE0D9CB)
    static let gold = pair(0xD4A657, 0xA9792B)
    static let onGold = pair(0x14161C, 0xFFFFFF)
    static let text = pair(0xF2EFE8, 0x1B1D24)
    static let muted = pair(0x9A9CA5, 0x6A6D78)
    static let green = pair(0x7FB58A, 0x3C7A50)
    static let red = pair(0xD9705F, 0xB4472F)
    /// The dimmed layer behind "Really open the lock?".
    static let scrim = Color(nsColor: NSColor(name: nil) { a in
        a.bestMatch(from: [.darkAqua, .aqua]) == .aqua
            ? NSColor.black.withAlphaComponent(0.35) : NSColor(srgbRed: 0.04, green: 0.04, blue: 0.055, alpha: 0.8)
    })
    /// The lock's metal and name plate stay the same in both themes.
    static let metalGold = Color(red: 0xD4 / 255, green: 0xA6 / 255, blue: 0x57 / 255)
    static let plateInk = Color(red: 0x14 / 255, green: 0x16 / 255, blue: 0x1C / 255)

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
                .foregroundStyle(Theme.onGold)
                .clipShape(RoundedRectangle(cornerRadius: 8))
                .contentShape(RoundedRectangle(cornerRadius: 8))
        }
        .buttonStyle(.plain)
        .disabled(!enabled)
    }
}

/// Done / Close / Hide in sheet headers: small, outlined, in Zecky's colours.
struct HeaderButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(Theme.text(13, weight: .medium))
            .foregroundStyle(Theme.text)
            .padding(.horizontal, 14)
            .frame(height: 30)
            .background(configuration.isPressed ? Theme.surface : Color.clear)
            .overlay(RoundedRectangle(cornerRadius: 7).stroke(Theme.muted.opacity(0.45)))
            .contentShape(RoundedRectangle(cornerRadius: 7))
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
                .contentShape(RoundedRectangle(cornerRadius: 8))
        }
        .buttonStyle(.plain)
    }
}

/// Keeps the app's windows out of screenshots, screen recordings and screen
/// sharing while this view is on screen. Used wherever the 24 words show.
struct HiddenFromCapture: ViewModifier {
    func body(content: Content) -> some View {
        content
            .onAppear { Self.set(.none) }
            .onDisappear { Self.set(.readOnly) }
    }

    private static func set(_ type: NSWindow.SharingType) {
        for window in NSApp.windows { window.sharingType = type }
    }
}

extension View {
    func hiddenFromCapture() -> some View { modifier(HiddenFromCapture()) }
}
