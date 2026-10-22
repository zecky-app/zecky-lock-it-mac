import SwiftUI

/// The optional time lock: opening the lock has to be asked for ahead of
/// time. Kept in the Keychain (this device only), like everything else.
///
/// A Zcash payment expires on the network within about an hour, so it
/// cannot be signed now and sent days later. The wait therefore sits in
/// front of opening the lock, not in front of a payment.
///
/// Shortening or switching off the time lock waits as long as the current
/// time lock, so nobody can talk the owner into "just turn it off".
enum TimeLock {
    static let choices = [0, 24, 72, 168]

    /// Builds from Xcode run the time lock fast: an hour lasts 5 seconds,
    /// so 24 hours is 2 minutes. The app people download uses real time.
    #if DEBUG
    static let hour: TimeInterval = 5
    #else
    static let hour: TimeInterval = 3600
    #endif

    /// How long the lock can be opened once the wait is over.
    static let window: TimeInterval = 24 * hour

    /// The sentence to type before breaking the glass.
    static let glassSentence = "I am breaking the glass myself"
    private static let service = "app.zecky.lockit.mac.timelock"

    private struct State: Codable {
        var hours = 0
        var pendingHours: Int?
        var pendingFrom: Date?
        var readyAt: Date?
        /// Every time the glass was broken, newest first (the last 10).
        var broken: [Date]?
        /// The home screen still has to say the glass was broken.
        var brokenNotice: Bool?
    }

    private static var state: State {
        get {
            guard let data = (try? KeyStore.read(service: service)) ?? nil,
                  var s = try? JSONDecoder().decode(State.self, from: data) else { return State() }
            // A shorter time lock takes over once its wait has passed.
            if let from = s.pendingFrom, let hours = s.pendingHours, from <= Date() {
                s.hours = hours; s.pendingHours = nil; s.pendingFrom = nil
            }
            // A request that was never used lapses after its window.
            if let ready = s.readyAt, Date() > ready.addingTimeInterval(window) { s.readyAt = nil }
            return s
        }
        set { try? KeyStore.save(try JSONEncoder().encode(newValue), service: service) }
    }

    static var hours: Int { state.hours }
    static var isOn: Bool { hours > 0 }
    static var pendingHours: Int? { state.pendingHours }
    static var pendingFrom: Date? { state.pendingFrom }

    enum Phase: Equatable { case off, notAsked, waiting(until: Date), ready(until: Date) }

    static var phase: Phase {
        let s = state
        guard s.hours > 0 else { return .off }
        guard let ready = s.readyAt else { return .notAsked }
        if Date() < ready { return .waiting(until: ready) }
        return .ready(until: ready.addingTimeInterval(window))
    }

    static func askToOpen() {
        var s = state
        s.readyAt = Date().addingTimeInterval(TimeInterval(s.hours) * hour)
        state = s
    }

    static func cancelRequest() {
        var s = state
        s.readyAt = nil
        state = s
    }

    /// Longer: straight away. Shorter or off: after the current wait.
    static func choose(_ hours: Int) {
        var s = state
        if LockRules.timeLock(from: s.hours, to: hours) == .nothing {
            s.hours = hours; s.pendingHours = nil; s.pendingFrom = nil
            LockLog.add(.timeLock, hours == 0 ? "Time lock off" : "Time lock on · \(label(hours).lowercased())")
        } else {
            s.pendingHours = hours
            let from = Date().addingTimeInterval(TimeInterval(s.hours) * hour)
            s.pendingFrom = from
            LockLog.add(.timeLock, (hours == 0 ? "Time lock off" : "Time lock \(label(hours).lowercased())") + " from \(when(from))")
        }
        state = s
    }

    /// When a shorter time lock would take over, if chosen now.
    static func shorterFrom() -> Date { Date().addingTimeInterval(TimeInterval(hours) * hour) }

    static func cancelChange() {
        var s = state
        s.pendingHours = nil; s.pendingFrom = nil
        state = s
        LockLog.add(.timeLock, "Kept the \(label(s.hours).lowercased()) time lock")
    }

    static func erase() { try? KeyStore.delete(service: service) }

    // MARK: Break the glass

    /// When the glass was last broken, if ever.
    static var lastBroken: Date? { state.broken?.first }
    static var brokenNotice: Bool { state.brokenNotice ?? false }

    /// The lock was opened at once, past the time lock. Remembered, and
    /// said on the home screen until the owner has seen it.
    /// Breaking the glass also switches the time lock off: the owner sets
    /// a new one when they want it back.
    static func recordBroken() {
        var s = state
        let was = s.hours
        s.broken = Array(([Date()] + (s.broken ?? [])).prefix(10))
        s.brokenNotice = true
        s.readyAt = nil
        s.hours = 0
        s.pendingHours = nil
        s.pendingFrom = nil
        state = s
        LockLog.add(.glassBroken, "Opened past a \(label(was).lowercased()) time lock · time lock off")
    }

    static func seenBroken() {
        var s = state
        s.brokenNotice = false
        state = s
    }

    static func label(_ hours: Int) -> String {
        switch hours {
        case 0: return "Off"
        case 24: return "24 hours"
        default: return hours % 24 == 0 ? "\(hours / 24) days" : "\(hours) hours"
        }
    }

    static func when(_ date: Date) -> String {
        date.formatted(.dateTime.weekday(.wide).day().month(.abbreviated).hour().minute())
    }
}

/// Over the home screen when the lock has a time lock: ask, or wait.
struct TimeLockPrompt: View {
    let phase: TimeLock.Phase
    let onAsk: () -> Void
    let onCancelRequest: () -> Void
    let onKeep: () -> Void
    let onBreakGlass: () -> Void

    @State private var breaking = false
    @State private var sentence = ""
    private var sentenceOK: Bool {
        sentence.trimmingCharacters(in: .whitespacesAndNewlines.union(.punctuationCharacters))
            .caseInsensitiveCompare(TimeLock.glassSentence) == .orderedSame
    }

    var body: some View {
        ZStack {
            Theme.scrim.ignoresSafeArea().onTapGesture {}
            VStack(spacing: 16) {
                ZStack {
                    Circle().stroke(Theme.gold.opacity(0.25), lineWidth: 3)
                    PadlockView(open: false, size: 62)
                    Image(systemName: "clock.fill")
                        .font(.system(size: 18)).foregroundStyle(Theme.gold)
                        .background(Circle().fill(Theme.surface).frame(width: 30, height: 30))
                        .offset(x: 34, y: 34)
                }
                .frame(width: 104, height: 104)
                Text("TIME LOCK · \(TimeLock.label(TimeLock.hours).uppercased())")
                    .font(Theme.text(11, weight: .semibold)).tracking(1.8).foregroundStyle(Theme.gold)
                if breaking { glass } else { asking }
            }
            .padding(.horizontal, 40).padding(.top, 30).padding(.bottom, 32)
            .frame(width: 500)
            .background(Theme.surface, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 18, style: .continuous).stroke(Theme.gold.opacity(0.25), lineWidth: 1))
            .shadow(color: .black.opacity(0.35), radius: 30, y: 12)
        }
    }

    private var asking: some View {
        VStack(spacing: 16) {
            Text(title).font(Theme.serif(30, weight: .medium)).multilineTextAlignment(.center)
            Text(text).font(Theme.text(14)).foregroundStyle(Theme.muted)
                .multilineTextAlignment(.center).fixedSize(horizontal: false, vertical: true)
            HStack(spacing: 12) {
                PrimaryButton(title: "Keep it locked", action: onKeep).keyboardShortcut(.cancelAction)
                if case .notAsked = phase {
                    SecondaryButton(title: "Start the wait", action: onAsk)
                } else {
                    SecondaryButton(title: "Cancel the request", action: onCancelRequest)
                }
            }
            .padding(.top, 4)
            Button { breaking = true } label: {
                HStack(spacing: 8) {
                    ZStack {
                        Circle().stroke(Theme.red, lineWidth: 1.5).frame(width: 22, height: 22)
                        Image(systemName: "hammer.fill").font(.system(size: 10)).foregroundStyle(Theme.red)
                    }
                    Text("Break the glass").font(Theme.text(13, weight: .semibold)).foregroundStyle(Theme.red)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .padding(.top, 6)
            .help("Emergency: open the lock now, past the time lock")
        }
    }

    private var glass: some View {
        VStack(spacing: 14) {
            Text("Break the glass").font(Theme.serif(30, weight: .medium)).foregroundStyle(Theme.red)
            Text("Only for an emergency. After your Zecky code and Touch ID the lock opens straight away, and the time lock turns off. It stays on record in Activity.")
                .font(Theme.text(14)).foregroundStyle(Theme.muted)
                .multilineTextAlignment(.center).fixedSize(horizontal: false, vertical: true)
            Text("Nobody legitimate will ever ask you to do this.")
                .font(Theme.text(13, weight: .medium)).foregroundStyle(Theme.text)
            VStack(alignment: .leading, spacing: 6) {
                Text("Type: \(TimeLock.glassSentence)").font(Theme.text(12)).foregroundStyle(Theme.muted)
                TextField("", text: $sentence)
                    .textFieldStyle(.plain)
                    .font(Theme.text(15))
                    .autocorrectionDisabled()
                    .padding(.horizontal, 12).frame(height: 40)
                    .background(Theme.ink, in: RoundedRectangle(cornerRadius: 10))
                    .overlay(RoundedRectangle(cornerRadius: 10).stroke(sentenceOK ? Theme.red : Theme.line, lineWidth: 1.5))
            }
            HStack(spacing: 12) {
                PrimaryButton(title: "Keep it locked") { breaking = false; sentence = ""; onKeep() }
                    .keyboardShortcut(.cancelAction)
                Button { if sentenceOK { onBreakGlass() } } label: {
                    Text("Break the glass")
                        .font(Theme.text(14, weight: .semibold))
                        .frame(maxWidth: .infinity).padding(.vertical, 10)
                        .foregroundStyle(.white)
                        .background(Theme.red.opacity(sentenceOK ? 1 : 0.35), in: RoundedRectangle(cornerRadius: 8))
                        .contentShape(RoundedRectangle(cornerRadius: 8))
                }
                .buttonStyle(.plain)
                .disabled(!sentenceOK)
            }
            .padding(.top, 4)
        }
    }

    private var title: String {
        if case .waiting = phase { return "The lock is waiting" }
        return "Ask to open the lock"
    }

    private var text: String {
        switch phase {
        case .waiting(let until):
            return "It can be opened from \(TimeLock.when(until)), for 24 hours. Nothing can leave before then, whoever asks."
        default:
            let ready = Date().addingTimeInterval(TimeInterval(TimeLock.hours) * TimeLock.hour)
            return "Your time lock asks for \(TimeLock.label(TimeLock.hours)) first. Start the wait now, and the lock can be opened from \(TimeLock.when(ready)), for 24 hours. Nobody legitimate will ever rush you."
        }
    }
}

/// What happened to the lock itself, next to the payments in Activity:
/// the glass broken, the time lock and the code changed. This device only.
enum LockLog {
    enum Kind: String, Codable { case glassBroken, timeLock, code, addressBook, keys }

    struct Entry: Codable, Identifiable {
        var id = UUID()
        let date: Date
        let kind: Kind
        let text: String
    }

    private static let service = "app.zecky.lockit.mac.lock-log"

    static var entries: [Entry] {
        guard let data = (try? KeyStore.read(service: service)) ?? nil,
              let list = try? JSONDecoder().decode([Entry].self, from: data) else { return [] }
        return list
    }

    static func add(_ kind: Kind, _ text: String) {
        let list = Array(([Entry(date: Date(), kind: kind, text: text)] + entries).prefix(100))
        try? KeyStore.save(try JSONEncoder().encode(list), service: service)
    }

    static func erase() { try? KeyStore.delete(service: service) }
}
