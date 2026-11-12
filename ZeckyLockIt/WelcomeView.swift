import SwiftUI

struct WelcomeView: View {
    @ObservedObject var model: AppModel

    var body: some View {
        VStack(spacing: 28) {
            Spacer()
            VStack(spacing: 10) {
                Text("Zecky Lock it").font(Theme.serif(40, weight: .medium))
                Text("Quiet money. Your Zcash, kept on this Mac.")
                    .foregroundStyle(Theme.muted)
            }
            VStack(spacing: 12) {
                PrimaryButton(title: model.busy ? "Creating…" : "Create a new wallet", enabled: !model.busy) {
                    Entropy.noteEvent()
                    Task { await model.create() }
                }
                SecondaryButton(title: "Restore with 24 words") {
                    model.message = nil
                    model.screen = .restore
                }
            }
            .frame(width: 300)
            if let message = model.message {
                Text(message).foregroundStyle(Theme.red).multilineTextAlignment(.center).frame(maxWidth: 420)
            }
            Spacer()
        }
        .padding(40)
        .onContinuousHover { _ in Entropy.noteEvent() }
    }
}

/// The terms Lock it asks to accept before a wallet is made. The accepted
/// version and the moment are kept on this Mac only (UserDefaults); raise
/// `version` when the terms change, and the screen comes once more.
enum Terms {
    static let version = 1
    static let termsURL = URL(string: "https://zecky.app/terms.html")!
    static let privacyURL = URL(string: "https://zecky.app/privacy.html")!
    private static let versionKey = "terms.acceptedVersion"
    private static let dateKey = "terms.acceptedAt"

    static var accepted: Bool { UserDefaults.standard.integer(forKey: versionKey) >= version }

    static func accept() {
        UserDefaults.standard.set(version, forKey: versionKey)
        UserDefaults.standard.set(Date(), forKey: dateKey)
    }
}

/// Before you start: one quiet screen, shown once, before creating or
/// restoring a wallet, and again only when the terms version changes.
struct TermsView: View {
    let onAccept: () -> Void

    private let points: [(icon: String, text: String)] = [
        ("doc.text", "Your 24 words are your wallet. Nobody can recover them, not even Zecky."),
        ("checkmark.seal", "Payments are final. Check before you send."),
        ("testtube.2", "Zecky is in testing. Use amounts you can afford to lose."),
        ("lock", "Zecky never holds your keys or your money."),
    ]

    var body: some View {
        VStack(spacing: 28) {
            Spacer()
            VStack(spacing: 10) {
                PadlockView(open: false, size: 64)
                Text("Before you start").font(Theme.serif(34, weight: .medium))
            }
            VStack(alignment: .leading, spacing: 16) {
                ForEach(points, id: \.text) { point in
                    HStack(alignment: .firstTextBaseline, spacing: 14) {
                        Image(systemName: point.icon).font(.system(size: 13)).foregroundStyle(Theme.gold).frame(width: 18)
                        Text(point.text).font(Theme.text(14)).foregroundStyle(Theme.text)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
            }
            .frame(maxWidth: 440, alignment: .leading)
            .padding(22)
            .background(Theme.surface, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous).stroke(Theme.line))
            HStack(spacing: 22) {
                Link("Read the terms ›", destination: Terms.termsURL)
                Link("Privacy ›", destination: Terms.privacyURL)
            }
            .font(Theme.text(13, weight: .medium))
            .foregroundStyle(Theme.gold)
            PrimaryButton(title: "I understand") {
                Terms.accept()
                onAccept()
            }
            .frame(width: 300)
            .keyboardShortcut(.defaultAction)
            Spacer()
        }
        .padding(40)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}
