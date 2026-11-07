import SwiftUI

/// The 24 words and the birthday, shown once after creating a wallet.
struct BackupView: View {
    let wallet: StoredWallet
    let onNext: () -> Void

    private var words: [String] { wallet.phrase.split(separator: " ").map(String.init) }

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            Text("Write these words down").font(Theme.serif(26, weight: .medium))
            Text("On paper, in this order. Whoever has these words has your money. Zecky never sends them anywhere, and nobody can recover them for you.")
                .foregroundStyle(Theme.muted)
                .fixedSize(horizontal: false, vertical: true)
            HStack(spacing: 6) {
                Text("Birthday block").foregroundStyle(Theme.muted)
                Text(wallet.birthday.formatted(.number.locale(Locale(identifier: "en_US"))))
                    .font(.system(.body, design: .monospaced))
                Text("· write it under the words").foregroundStyle(Theme.muted)
            }
            .font(.system(size: 13))
            HoldToReveal {
                LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 10), count: 4), spacing: 10) {
                    ForEach(Array(words.enumerated()), id: \.offset) { index, word in
                        HStack(spacing: 6) {
                            Text("\(index + 1)").foregroundStyle(Theme.muted).frame(width: 20, alignment: .trailing)
                            Text(word).font(.system(size: 15, weight: .medium, design: .monospaced))
                            Spacer(minLength: 0)
                        }
                        .padding(.vertical, 7).padding(.horizontal, 8)
                        .background(Theme.surface)
                        .clipShape(RoundedRectangle(cornerRadius: 6))
                    }
                }
            }
            Spacer()
            HStack { Spacer(); PrimaryButton(title: "I wrote them down", action: onNext).frame(width: 220) }
        }
        .padding(32)
        .hiddenFromCapture()
    }
}

/// The 24 words, shown only while the button below them is held down.
/// macOS lets screenshots and screen recordings capture any window, so the
/// words are not on screen until you ask for them, and gone again the
/// moment you let go: a screenshot by accident or by someone watching
/// your screen catches nothing. The window is also kept out of screen
/// sharing (hiddenFromCapture), where macOS honours that.
struct HoldToReveal<Content: View>: View {
    @ViewBuilder var content: () -> Content
    @State private var showing = false

    var body: some View {
        VStack(spacing: 12) {
            ZStack {
                content()
                    .opacity(showing ? 1 : 0)
                    .accessibilityHidden(!showing)
                if !showing {
                    RoundedRectangle(cornerRadius: 10, style: .continuous)
                        .fill(Theme.surface)
                        .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous).stroke(Theme.line))
                        .overlay(
                            VStack(spacing: 6) {
                                Image(systemName: "eye.slash").font(.system(size: 18)).foregroundStyle(Theme.gold)
                                Text("Hidden until you hold the button below.")
                                    .font(Theme.text(12)).foregroundStyle(Theme.muted)
                            }
                        )
                        .accessibilityHidden(true)
                }
            }
            Text(showing ? "Let go to hide the words" : "Hold to show the words")
                .font(Theme.text(13, weight: .semibold))
                .foregroundStyle(Theme.ink)
                .padding(.horizontal, 18).frame(height: 36)
                .background(Theme.gold, in: Capsule())
                .contentShape(Capsule())
                .onLongPressGesture(minimumDuration: 3600, maximumDistance: 60, pressing: { showing = $0 }, perform: {})
                .accessibilityElement()
                .accessibilityLabel("Show the words")
                .accessibilityHint("Shows the 24 words for 20 seconds")
                .accessibilityAddTraits(.isButton)
                .accessibilityAction {
                    showing = true
                    DispatchQueue.main.asyncAfter(deadline: .now() + 20) { showing = false }
                }
        }
        .onDisappear { showing = false }
    }
}
