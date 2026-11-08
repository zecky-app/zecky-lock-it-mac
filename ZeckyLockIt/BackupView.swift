import AppKit
import SwiftUI

/// The 24 words and the birthday, shown once after creating a wallet.
struct BackupView: View {
    let wallet: StoredWallet
    let onNext: () -> Void

    private var words: [String] { wallet.phrase.split(separator: " ").map(String.init) }
    /// After "I wrote them down": three words typed back before going on.
    @State private var checking = false

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
            if checking {
                WordCheck(words: words, onShowAgain: { checking = false }, onPassed: onNext)
            } else {
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
            }
            Spacer()
            if !checking {
                HStack { Spacer(); PrimaryButton(title: "I wrote them down") { checking = true }.frame(width: 220) }
            }
        }
        .padding(32)
        .hiddenFromCapture()
    }
}

/// The 24 words, shown only when you ask for them. On the Mac you need your
/// hands to write, so a click shows them and another click hides them (the
/// iPhone uses hold-to-show). They hide by themselves after 2 minutes, when
/// you switch to another app, and when the screen sleeps or locks, so a
/// screenshot by accident or someone at your screen later catches nothing.
/// The window is also kept out of screenshots and screen sharing
/// (hiddenFromCapture), where macOS honours that.
struct HoldToReveal<Content: View>: View {
    @ViewBuilder var content: () -> Content
    @State private var showing = false
    @State private var hideAt = Date.distantFuture
    @State private var now = Date()
    private static var showFor: TimeInterval { 120 }
    private let tick = Timer.publish(every: 1, on: .main, in: .common).autoconnect()

    var body: some View {
        VStack(spacing: 10) {
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
                                Text("Hidden. Click Show the words when nobody can see your screen.")
                                    .font(Theme.text(12)).foregroundStyle(Theme.muted)
                                    .multilineTextAlignment(.center)
                            }
                            .padding(.horizontal, 20)
                        )
                        .accessibilityHidden(true)
                }
            }
            Button { showing ? hide() : show() } label: {
                Text(showing ? "Hide the words" : "Show the words")
                    .font(Theme.text(13, weight: .semibold))
                    .foregroundStyle(Theme.ink)
                    .padding(.horizontal, 18).frame(height: 36)
                    .background(Theme.gold, in: Capsule())
                    .contentShape(Capsule())
            }
            .buttonStyle(.plain)
            .accessibilityHint("Shows the 24 words for up to 2 minutes")
            Text(showing ? "They hide by themselves in \(remaining), or when you switch apps."
                         : "They hide again after 2 minutes, or when you switch apps.")
                .font(Theme.text(11)).foregroundStyle(Theme.muted)
                .monospacedDigit()
        }
        .onReceive(tick) { t in
            now = t
            if showing && t >= hideAt { hide() }
        }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.willResignActiveNotification)) { _ in hide() }
        .onReceive(NSWorkspace.shared.notificationCenter.publisher(for: NSWorkspace.screensDidSleepNotification)) { _ in hide() }
        .onReceive(NSWorkspace.shared.notificationCenter.publisher(for: NSWorkspace.sessionDidResignActiveNotification)) { _ in hide() }
        .onReceive(DistributedNotificationCenter.default().publisher(for: Notification.Name("com.apple.screenIsLocked"))) { _ in hide() }
        .onDisappear { hide() }
    }

    private var remaining: String {
        let left = max(0, Int(hideAt.timeIntervalSince(now).rounded(.up)))
        return "\(left / 60):" + String(format: "%02d", left % 60)
    }

    private func show() {
        now = Date()
        hideAt = now.addingTimeInterval(Self.showFor)
        showing = true
    }

    private func hide() {
        showing = false
        hideAt = .distantFuture
    }
}

/// After "I wrote them down": three random positions to type back from the
/// paper, so a missing or swapped word is found now, not on the day the words
/// are needed. The words themselves are not on screen meanwhile.
struct WordCheck: View {
    let words: [String]
    let onShowAgain: () -> Void
    let onPassed: () -> Void

    @State private var positions: [Int] = WordCheck.pick(24)
    @State private var answers = ["", "", ""]
    @State private var wrong: [Int] = []

    /// Three different positions (0-based), in order.
    static func pick(_ count: Int) -> [Int] {
        Array((0..<count).shuffled().prefix(3)).sorted()
    }

    /// Typed words compare without case or surrounding spaces.
    static func matches(_ typed: String, _ word: String) -> Bool {
        typed.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() == word.lowercased()
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Check your paper").font(Theme.text(15, weight: .semibold))
            Text("Type these three words from what you wrote down.")
                .font(Theme.text(13)).foregroundStyle(Theme.muted)
            ForEach(0..<3, id: \.self) { i in
                HStack(spacing: 12) {
                    Text("Word \(positions[i] + 1)").font(Theme.text(13, weight: .medium))
                        .frame(width: 70, alignment: .leading)
                    TextField("", text: $answers[i])
                        .textFieldStyle(.roundedBorder)
                        .autocorrectionDisabled()
                        .onSubmit(check)
                    if wrong.contains(i) {
                        Image(systemName: "xmark.circle.fill").foregroundStyle(Theme.red)
                            .accessibilityLabel("Not the word at this position")
                    }
                }
            }
            if !wrong.isEmpty {
                Text(wrong.count == 1
                     ? "Word \(positions[wrong[0]] + 1) is not what Lock it made. Check that line on your paper."
                     : "Words \(wrong.map { String(positions[$0] + 1) }.joined(separator: " and ")) are not what Lock it made. Check those lines on your paper.")
                    .font(Theme.text(12)).foregroundStyle(Theme.red)
                    .fixedSize(horizontal: false, vertical: true)
            }
            HStack {
                QuietButton(title: "Show the words again") { answers = ["", "", ""]; wrong = []; onShowAgain() }
                    .frame(width: 200)
                Spacer()
                SecondaryButton(title: "Check") { check() }
                    .frame(width: 120)
                    .disabled(answers.contains { $0.trimmingCharacters(in: .whitespaces).isEmpty })
            }
        }
        .padding(14)
        .background(Theme.surface, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).stroke(Theme.line))
        .onDisappear { answers = ["", "", ""] }
    }

    private func check() {
        guard words.count > (positions.last ?? 0) else { return }
        wrong = (0..<3).filter { !Self.matches(answers[$0], words[positions[$0]]) }
        if wrong.isEmpty {
            answers = ["", "", ""]
            onPassed()
        }
    }
}
