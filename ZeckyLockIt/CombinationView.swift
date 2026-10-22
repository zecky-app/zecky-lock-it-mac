import AppKit
import Combine
import SwiftUI

/// Brass for the dials, the same in light and dark: they are metal.
private enum Brass {
    static func c(_ hex: Int) -> Color {
        Color(red: Double((hex >> 16) & 0xFF) / 255, green: Double((hex >> 8) & 0xFF) / 255, blue: Double(hex & 0xFF) / 255)
    }
    static let body = LinearGradient(stops: [
        .init(color: c(0x4A3612), location: 0), .init(color: c(0x8A6629), location: 0.12),
        .init(color: c(0xD4A657), location: 0.34), .init(color: c(0xF6E2B0), location: 0.5),
        .init(color: c(0xD4A657), location: 0.66), .init(color: c(0x8A6629), location: 0.88),
        .init(color: c(0x4A3612), location: 1),
    ], startPoint: .leading, endPoint: .trailing)
    static let digit = c(0x2E200A)
    static let edge = c(0x5E4519)
    static let shine = c(0xFFF0CC)
}

/// One brass dial: the digit in the window, its neighbours above and below.
/// Click the top half to turn back, the bottom half to turn on.
struct Dial: View {
    let digit: Int
    var active = false
    var band: Color = Brass.edge
    let turn: (Int) -> Void

    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 10).fill(Brass.body)
            Canvas { context, size in
                var y: CGFloat = 0
                while y < size.height {
                    context.fill(Path(CGRect(x: 0, y: y, width: size.width, height: 1)), with: .color(.black.opacity(0.10)))
                    y += 4
                }
            }
            VStack(spacing: 0) {
                LinearGradient(colors: [.black.opacity(0.62), .clear], startPoint: .top, endPoint: .bottom).frame(height: 40)
                Spacer()
                LinearGradient(colors: [.clear, .black.opacity(0.62)], startPoint: .top, endPoint: .bottom).frame(height: 40)
            }
            Rectangle()
                .fill(Brass.shine.opacity(0.10))
                .overlay(Rectangle().stroke(band, lineWidth: 1.5))
                .frame(height: 46)
            VStack(spacing: 0) {
                Text("\((digit + 9) % 10)").font(Theme.serif(22, weight: .medium)).opacity(0.45).frame(height: 44)
                Text("\(digit)").font(Theme.serif(34, weight: .medium))
                    .shadow(color: Brass.shine.opacity(0.55), radius: 0, y: 1).frame(height: 46)
                Text("\((digit + 1) % 10)").font(Theme.serif(22, weight: .medium)).opacity(0.45).frame(height: 44)
            }
            .foregroundStyle(Brass.digit)
            .animation(.spring(response: 0.3, dampingFraction: 0.8), value: digit)
            VStack(spacing: 0) {
                Color.clear.contentShape(Rectangle()).onTapGesture { turn(-1) }
                Color.clear.contentShape(Rectangle()).onTapGesture { turn(1) }
            }
        }
        .frame(width: 58, height: 134)
        .clipShape(RoundedRectangle(cornerRadius: 10))
        .overlay(RoundedRectangle(cornerRadius: 10).stroke(active ? Theme.gold : .black.opacity(0.45), lineWidth: active ? 2 : 1))
        .shadow(color: .black.opacity(0.45), radius: 10, y: 8)
        .accessibilityElement()
        .accessibilityLabel("Dial")
        .accessibilityValue("\(digit)")
        .accessibilityAdjustableAction { direction in turn(direction == .increment ? 1 : -1) }
    }
}

/// Six dials in two groups of three. Typing digits fills them from the
/// left; Delete goes back; the arrow keys move and turn; Return submits.
struct Dials: View {
    @Binding var digits: [Int]
    @Binding var active: Int
    var band: Color = Brass.edge
    var enabled = true
    var onReturn: () -> Void = {}

    @State private var monitor: Any?

    var body: some View {
        HStack(spacing: 10) {
            ForEach(0..<6, id: \.self) { i in
                Dial(digit: digits[i], active: enabled && i == active, band: band) { step in
                    guard enabled else { return }
                    active = i
                    digits[i] = (digits[i] + step + 10) % 10
                }
                if i == 2 { Spacer().frame(width: 10) }
            }
        }
        .onAppear {
            monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
                guard enabled else { return event }
                if let ch = event.charactersIgnoringModifiers, let d = Int(ch), ch.count == 1 {
                    digits[active] = d
                    active = min(5, active + 1)
                    return nil
                }
                switch event.keyCode {
                case 51: digits[active] = 0; active = max(0, active - 1); return nil   // delete
                case 123: active = max(0, active - 1); return nil                       // left
                case 124: active = min(5, active + 1); return nil                       // right
                case 126: digits[active] = (digits[active] + 9) % 10; return nil        // up
                case 125: digits[active] = (digits[active] + 1) % 10; return nil        // down
                case 36, 76: onReturn(); return nil                                     // return
                default: return event
                }
            }
        }
        .onDisappear { if let monitor { NSEvent.removeMonitor(monitor) }; monitor = nil }
    }
}

/// "Turn in your code": dials, then Touch ID. `submit` returns nil when the
/// code opened the lock, or the message to show.
struct CodePrompt: View {
    var heading: String? = nil
    var action = "Open"
    var showsCancel = true
    let submit: (String) async -> String?
    let onDone: () -> Void
    let onCancel: () -> Void

    @State private var digits = [0, 0, 0, 0, 0, 0]
    @State private var password = ""
    @State private var active = 0
    @State private var working = false
    @State private var accepted = false
    private let usesPassword = WalletVault.usesPassword
    @State private var note: String?
    @State private var now = Date()
    private let clock = Timer.publish(every: 1, on: .main, in: .common).autoconnect()

    private var waiting: Date? { WalletVault.waitUntil.flatMap { $0 > now ? $0 : nil } }

    var body: some View {
        VStack(spacing: 12) {
            PadlockView(open: accepted, size: 64)
                .animation(.spring(response: 0.55, dampingFraction: 0.62), value: accepted)
            Text(accepted ? (usesPassword ? "PASSWORD ACCEPTED" : "CODE ACCEPTED") : (usesPassword ? "LOCK IT PASSWORD" : "ZECKY CODE"))
                .font(Theme.text(11, weight: .semibold)).tracking(1.8)
                .foregroundStyle(accepted ? Theme.green : Theme.gold)
            Text(heading ?? (usesPassword ? "Enter your Lock it password" : "Turn in your Zecky code")).font(Theme.serif(26, weight: .medium))
            if usesPassword {
                SecureField("Lock it password", text: $password)
                    .textFieldStyle(.plain)
                    .font(Theme.text(16))
                    .padding(.horizontal, 14).frame(width: 340, height: 44)
                    .background(Theme.ink, in: RoundedRectangle(cornerRadius: 10))
                    .overlay(RoundedRectangle(cornerRadius: 10).stroke(band == Brass.edge ? Theme.line : band, lineWidth: 1.5))
                    .disabled(working || accepted || waiting != nil)
                    .onSubmit { Task { await go() } }
                    .padding(.vertical, 20)
            } else {
                Dials(digits: $digits, active: $active, band: band, enabled: !working && !accepted && waiting == nil) {
                    Task { await go() }
                }
                .padding(.top, 4)
            }
            Text(noteText)
                .font(Theme.text(12)).foregroundStyle(noteColor)
                .frame(height: 18)
            HStack(spacing: 12) {
                if showsCancel {
                    QuietButton(title: "Keep it locked", action: onCancel).frame(width: 160)
                        .keyboardShortcut(.cancelAction)
                }
                PrimaryButton(title: working ? "Waiting…" : action, enabled: !working && !accepted && waiting == nil) {
                    Task { await go() }
                }
                .frame(width: 160)
            }
        }
        .frame(maxWidth: .infinity)
        .onReceive(clock) { now = $0 }
    }

    private var band: Color {
        if accepted { return Theme.green }
        if note != nil || waiting != nil { return Theme.red }
        return Brass.edge
    }

    private var noteText: String {
        if accepted { return "Opened." }
        if let waiting { return "Too many wrong tries. Try again in \(WalletVault.waitText(until: waiting))." }
        return note ?? (usesPassword ? "The password you chose for Lock it." : "Six digits only you know. Then Touch ID or your Mac password.")
    }

    private var noteColor: Color {
        if accepted { return Theme.green }
        return (note != nil || waiting != nil) ? Theme.red : Theme.muted
    }

    private func go() async {
        guard !working, !accepted, waiting == nil else { return }
        working = true
        note = nil
        let code = usesPassword ? password : digits.map(String.init).joined()
        let result = await submit(code)
        working = false
        if let result {
            note = usesPassword ? result.replacingOccurrences(of: "not your Zecky code", with: "not your Lock it password") : result
            digits = [0, 0, 0, 0, 0, 0]
            password = ""
            active = 0
        } else {
            accepted = true
            try? await Task.sleep(nanoseconds: 700_000_000)
            onDone()
        }
    }
}

/// Settings: put a code on the lock, or change it. Turn in the current
/// code (when changing), the new one, and the new one again.
struct CodeSetupView: View {
    let changing: Bool
    let onDone: () -> Void
    let onCancel: () -> Void

    private enum Step { case current, new, confirm }
    @State private var step: Step
    @State private var digits = [0, 0, 0, 0, 0, 0]
    @State private var active = 0
    @State private var current: String?
    @State private var first: String?
    @State private var paper = false
    @State private var note: String?
    @State private var working = false

    init(changing: Bool, onDone: @escaping () -> Void, onCancel: @escaping () -> Void) {
        self.changing = changing
        self.onDone = onDone
        self.onCancel = onCancel
        _step = State(initialValue: changing ? .current : .new)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text(explain).font(Theme.text(13)).foregroundStyle(Theme.muted)
                .fixedSize(horizontal: false, vertical: true)
            Dials(digits: $digits, active: $active, enabled: !working) { next() }
                .frame(maxWidth: .infinity)
                .padding(.vertical, 6)
            if step == .new && !changing {
                Toggle(isOn: $paper) {
                    Text("My 24 words are on paper. If I forget my Zecky code, the only way back is Erase and restoring with those words.")
                        .font(Theme.text(13))
                        .fixedSize(horizontal: false, vertical: true)
                }
                .toggleStyle(.checkbox)
                .padding(12)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(Theme.ink, in: RoundedRectangle(cornerRadius: 10))
                .overlay(RoundedRectangle(cornerRadius: 10).stroke(paper ? Theme.gold.opacity(0.6) : Theme.line))
            }
            if let note { Text(note).font(Theme.text(12)).foregroundStyle(Theme.red) }
            Spacer(minLength: 0)
            HStack {
                Text(stepText).font(Theme.text(12)).foregroundStyle(Theme.muted)
                Spacer()
                QuietButton(title: "Cancel", action: onCancel).frame(width: 120)
                PrimaryButton(title: working ? "Waiting…" : (step == .confirm ? "Set code" : "Next"), enabled: canGo) { next() }
                    .frame(width: 140)
            }
        }
    }

    private var explain: String {
        switch step {
        case .current: return "Turn in your current Zecky code."
        case .new: return "Six digits only you know, asked together with Touch ID when opening Zecky, opening the lock, showing your 24 words and erasing. Why: someone who knows your Mac password still cannot open the lock. The Secure Enclave checks the code itself."
        case .confirm: return "Turn in the same six digits once more."
        }
    }

    private var stepText: String {
        let total = changing ? 3 : 2
        let at: Int
        switch step {
        case .current: at = 1
        case .new: at = changing ? 2 : 1
        case .confirm: at = total
        }
        return "Step \(at) of \(total)"
    }

    private var canGo: Bool { !working && (step != .new || changing || paper) }

    private func next() {
        guard canGo else { return }
        note = nil
        let code = digits.map(String.init).joined()
        switch step {
        case .current:
            current = code; step = .new
        case .new:
            if Set(digits).count == 1 { note = "Six of the same digit is too easy to guess."; return }
            if ["012345", "123456", "234567", "345678", "456789", "987654", "876543", "765432", "654321", "543210"].contains(code) {
                note = "A straight run is too easy to guess."; return
            }
            first = code; step = .confirm
        case .confirm:
            guard code == first else {
                note = "The two codes differ. Turn in the new Zecky code again."
                first = nil; step = .new; reset(); return
            }
            Task {
                working = true
                defer { working = false }
                do {
                    try await WalletVault.setCode(current: current, new: code)
                    onDone()
                } catch WalletVault.Failure.cancelled {
                    note = "Not confirmed, so nothing changed."
                } catch {
                    note = "\(error) Nothing changed."
                    if changing { current = nil; step = .current }
                }
            }
            return
        }
        reset()
    }

    private func reset() { digits = [0, 0, 0, 0, 0, 0]; active = 0 }
}

/// This Mac has no login password, so neither Touch ID nor the Mac password
/// can guard the lock. The safe way: set one. The owner's choice: a Lock it
/// password of at least 10 characters as the only key.
struct NoMacPasswordView: View {
    @ObservedObject var model: AppModel
    let hasWallet: Bool

    @State private var choosing = false
    @State private var first = ""
    @State private var second = ""
    @State private var understood = false
    @State private var note: String?

    var body: some View {
        VStack(spacing: 18) {
            PadlockView(open: false, size: 110)
            Text(choosing ? "A Lock it password" : "Set a password on this Mac first")
                .font(Theme.serif(30, weight: .medium))
            if choosing { chooser } else { advice }
        }
        .frame(maxWidth: 480)
        .padding(40)
    }

    private var advice: some View {
        VStack(spacing: 16) {
            Text(hasWallet
                 ? "This Mac has no login password any more, so Touch ID and your Mac password cannot open the lock. Set a login password, and Lock it opens again."
                 : "Lock it is opened with Touch ID or your Mac password. This Mac has no login password, so anyone at it could open everything on it. A login password also lets your Mac encrypt its disk (FileVault).")
                .font(Theme.text(14)).foregroundStyle(Theme.muted)
                .multilineTextAlignment(.center).fixedSize(horizontal: false, vertical: true)
            HStack(spacing: 12) {
                SecondaryButton(title: "Check again") { model.launch() }.frame(width: 150)
                PrimaryButton(title: "Open System Settings") {
                    if let url = URL(string: "x-apple.systempreferences:com.apple.Users-Groups-Settings.extension") {
                        NSWorkspace.shared.open(url)
                    }
                }
                .frame(width: 220)
            }
            if !hasWallet {
                Button("Use a Lock it password instead…") { choosing = true }
                    .buttonStyle(.plain)
                    .font(Theme.text(12)).foregroundStyle(Theme.muted).underline()
                    .padding(.top, 6)
            }
        }
    }

    private var chooser: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("At least \(WalletVault.minimumPassword) characters. It seals your 24 words in this Mac and is asked before releasing, showing the words and unlocking. Less safe than a Mac password: anyone at this Mac can still use everything else on it.")
                .font(Theme.text(13)).foregroundStyle(Theme.muted)
                .fixedSize(horizontal: false, vertical: true)
            field("Lock it password", $first)
            field("The same password again", $second)
            Toggle(isOn: $understood) {
                Text("I understand this is less safe than a Mac password, and that forgetting it means restoring with my 24 words.")
                    .font(Theme.text(13)).fixedSize(horizontal: false, vertical: true)
            }
            .toggleStyle(.checkbox)
            if let note { Text(note).font(Theme.text(12)).foregroundStyle(Theme.red) }
            HStack {
                QuietButton(title: "Back") { choosing = false; first = ""; second = "" }.frame(width: 120)
                Spacer()
                PrimaryButton(title: "Use this password", enabled: understood) { use() }.frame(width: 200)
            }
            .padding(.top, 4)
        }
    }

    private func field(_ prompt: String, _ text: Binding<String>) -> some View {
        SecureField(prompt, text: text)
            .textFieldStyle(.plain)
            .font(Theme.text(15))
            .padding(.horizontal, 14).frame(height: 42)
            .background(Theme.ink, in: RoundedRectangle(cornerRadius: 10))
            .overlay(RoundedRectangle(cornerRadius: 10).stroke(Theme.line))
    }

    private func use() {
        note = nil
        guard first.count >= WalletVault.minimumPassword else {
            note = "Use at least \(WalletVault.minimumPassword) characters."; return
        }
        guard first == second else { note = "The two passwords differ."; return }
        guard Set(first).count >= 4 else { note = "Use more different characters."; return }
        model.useLockItPassword(first)
        first = ""; second = ""
    }
}
