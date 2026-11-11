import AppKit
import SwiftUI

struct SettingsView: View {
    @ObservedObject var model: AppModel
    @ObservedObject var prices: PriceFeed
    @ObservedObject private var goMax = GoMaxNode.shared
    let onClose: () -> Void

    /// The opened phrase, only while it is on screen.
    @State private var revealed: StoredWallet?
    private var showingPhrase: Bool { revealed != nil }
    /// A code step in place of the settings list.
    private enum CodeStep { case phrase, setUp, change, remove, erase, guarded }
    @State private var codeStep: CodeStep?
    @State private var pendingPhrase: StoredWallet?
    /// The viewing key while it is on screen, and for which wallet.
    @State private var viewKey: String?
    @State private var viewKeyNote: String?
    @State private var codeNote: String?
    @State private var timeLockHours = TimeLock.hours
    @State private var confirmTimeLock: Int?
    @State private var askZecky = Keys.askOpeningZecky
    @State private var askLock = Keys.askOpeningLock
    @State private var wait = Keys.wait
    /// An address-book change waiting for the owner's code and Touch ID.
    @State private var guardAction: (() -> Void)?
    @State private var guardReason = ""
    @State private var problem: String?
    @State private var confirmErase = false
    @State private var erasing = false

    @State private var serverChoice = Server.presets.firstIndex { $0.host == Server.host } ?? -1
    @State private var customServer = Server.presets.contains { $0.host == Server.host } ? (Server.ownServer ?? "") : "\(Server.host):\(Server.port)"
    @State private var serverNote: String?
    @State private var sendOverTor = TorSending.isOn

    var body: some View {
        SheetScaffold(title: sheetTitle,
                      subtitle: sheetSubtitle,
                      closeLabel: showingPhrase ? "Hide" : (codeStep != nil || page != nil ? "Back" : "Done"),
                      height: 740,
                      onClose: { if showingPhrase { revealed = nil } else if codeStep != nil { codeStep = nil } else if keyPage != nil { keyPage = nil } else if page != nil { withAnimation(.easeOut(duration: 0.2)) { page = nil } } else { onClose() } }) {
            if let revealed {
                PhraseView(wallet: revealed)
            } else if let codeStep {
                codeView(codeStep)
            } else {
                ScrollView { settings.padding(.bottom, 4).padding(.trailing, 6) }
                    .scrollIndicators(.visible)
            }
        }
        // The words leave the screen as soon as Zecky is not the app in front.
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didResignActiveNotification)) { _ in
            revealed = nil
        }
        .onAppear { if let p = model.settingsPage { page = p; model.settingsPage = nil } }
        .alert(timeLockQuestion, isPresented: Binding(get: { confirmTimeLock != nil }, set: { if !$0 { confirmTimeLock = nil } })) {
            Button("Cancel", role: .cancel) { confirmTimeLock = nil }
            Button(timeLockAction) {
                if let hours = confirmTimeLock {
                    TimeLock.choose(hours)
                    timeLockHours = TimeLock.hours
                    model.timeLockChanged += 1
                }
                confirmTimeLock = nil
            }
        } message: {
            Text(timeLockMessage)
        }
        .alert("Erase everything on this Mac?", isPresented: $confirmErase) {
            Button("Cancel", role: .cancel) {}
            Button("Erase everything", role: .destructive) { Task { await erase() } }
        } message: {
            Text("Every wallet's 24 words, every Seal it pairing, the history, address book and settings are removed from this Mac. Without the 24 words on paper, the Zcash in those wallets cannot be recovered.")
        }
    }

    // MARK: Pages

    /// Settings is a calm list; each topic opens its own page.
    enum Page: Hashable { case keys, timeLock, phrase, addressBook, display, network, goMax, how, about }
    @State private var page: Page?

    private var settings: some View {
        VStack(alignment: .leading, spacing: 12) {
            Group {
            switch page {
            case nil: overview
            case .keys?: pageBody { keysPage }
            case .timeLock?: pageBody { timeLockPage }
            case .phrase?: pageBody { phrasePage }
            case .addressBook?: pageBody { addressBookPage }
            case .display?: pageBody { displayPage }
            case .network?: pageBody { networkPage }
            case .goMax?: pageBody { GoMaxPage(node: goMax) }
            case .how?: pageBody { HowItWorks { model.sheet = nil; model.tourShown = true } }
            case .about?: pageBody { aboutPage }
            }
            }
            .id(page)
            .transition(.opacity.combined(with: .move(edge: page == nil ? .leading : .trailing)))
            if let problem { Text(problem).font(Theme.text(12)).foregroundStyle(Theme.red) }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func pageBody<Content: View>(@ViewBuilder _ content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 12) { content() }
    }

    private var overview: some View {
        let _ = model.timeLockChanged
        return VStack(alignment: .leading, spacing: 18) {
            // The current block and how fast blocks come, as on the iPhone.
            NetworkCard(engine: model.engine)
            group("Security") {
                row(.keys, "Keys to the lock", "key.fill", keysSummary)
                row(.timeLock, "Time lock", "clock", TimeLock.isOn ? TimeLock.label(TimeLock.hours) : "Off")
                row(.phrase, "Recovery phrase and viewing key", "doc.text.magnifyingglass", WalletVault.kind == .secureEnclave ? "Sealed in the Secure Enclave" : "In the Keychain")
                row(.addressBook, "Address book", "person.crop.circle", addressSummary)
            }
            group("This Mac") {
                row(.display, "Display", "circle.lefthalf.filled", "\(model.themeMode.label) · Value \(prices.currency.short)")
                row(.network, "Network", "server.rack", Server.nodeLabel ?? Server.host)
                row(.goMax, "Go Max", "point.3.connected.trianglepath.dotted", GoMaxWords.short(goMax.phase, goMax.info))
            }
            group("Lock it") {
                row(.how, "How Zecky works", "book.closed", "The lock, the keys, your privacy")
                row(.about, "About", "info.circle", "Version \(version) · your Zcash by pool")
            }
            // Erase, on its own, with a red edge.
            VStack(alignment: .leading, spacing: 10) {
                Label("Erase everything", systemImage: "trash").font(Theme.text(13, weight: .semibold)).foregroundStyle(Theme.red)
                Text("Removes every wallet, its words, the history and settings from this Mac. To erase one wallet, use its menu on the key ring (two-finger click on its name). Make sure the 24 words are on paper first.")
                    .font(Theme.text(12)).foregroundStyle(Theme.muted)
                    .fixedSize(horizontal: false, vertical: true)
                Button { Task { await askErase() } } label: {
                    Text(erasing ? "Erasing…" : "Erase everything on this Mac…")
                        .font(Theme.text(13, weight: .medium)).foregroundStyle(Theme.red)
                        .padding(.horizontal, 14).frame(height: 32)
                        .overlay(RoundedRectangle(cornerRadius: 8).stroke(Theme.red.opacity(0.6)))
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .disabled(erasing)
            }
            .padding(16)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Theme.red.opacity(0.06), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).stroke(Theme.red.opacity(0.45), lineWidth: 1))

        }
    }

    /// What the chosen server can and cannot prove, in plain words.
    private var networkNote: String {
        switch Server.nodeKind(Server.host) {
        case .homeNetwork?:
            return "Rock it on your home network, without TLS: the traffic stays inside your home. Lock it cannot check that this address is really your node. On another Wi-Fi, a stranger's device with the same numbers could answer: it cannot take anything, but it could hide or delay payments. Away from home, use Rock it's Tailscale address."
        case .tailscaleIP?:
            return "Rock it through Tailscale: the connection is encrypted by Tailscale and only reaches your tailnet. A 100.x address is a Tailscale IP; Lock it cannot prove it is your node, so only use the one Rock it shows you."
        case .thisMac?:
            return "A node on this Mac itself (Go Max, or one you started), without TLS: the traffic never leaves this Mac."
        case nil:
            return "Encrypted (TLS). The server sees this Mac's internet address, never your phrase or balance. Your own node on a home or Tailscale address is used as Rock it."
        }
    }

    private var keysSummary: String {
        var parts: [String] = []
        if Keys.askOpeningZecky { parts.append("① Opening Zecky") }
        if Keys.askOpeningLock || WalletVault.hasCode { parts.append("② Opening the lock") }
        if Keys.wait > 0 { parts.append("③ \(Keys.wait) s") }
        if SecurityKeys.hasKeys { parts.append("④ Security key") }
        return parts.isEmpty ? "Touch ID once per session" : parts.joined(separator: " · ")
    }

    private var addressSummary: String {
        let n = Contacts.all.count
        let saved = n == 0 ? "None saved" : "\(n) saved"
        return Contacts.onlySaved ? saved + " · only these" : saved
    }

    private func group<Content: View>(_ title: String, @ViewBuilder _ rows: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title.uppercased()).font(Theme.text(11, weight: .semibold)).tracking(2).foregroundStyle(Theme.gold)
                .padding(.leading, 4)
            VStack(spacing: 0) { rows() }
                .background(Theme.surface, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
                .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).stroke(Theme.line))
        }
    }

    private func row(_ target: Page, _ title: String, _ icon: String, _ detail: String) -> some View {
        Button { withAnimation(.easeOut(duration: 0.2)) { page = target } } label: {
            HStack(spacing: 12) {
                Image(systemName: icon).font(.system(size: 14)).foregroundStyle(Theme.gold).frame(width: 22)
                Text(title).font(Theme.text(14, weight: .medium)).foregroundStyle(Theme.text)
                Spacer(minLength: 12)
                Text(detail).font(Theme.text(12)).foregroundStyle(Theme.muted).lineLimit(1)
                Image(systemName: "chevron.right").font(.system(size: 11, weight: .semibold)).foregroundStyle(Theme.muted)
            }
            .padding(.horizontal, 14).frame(height: 46)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .overlay(alignment: .bottom) { Rectangle().fill(Theme.line).frame(height: 1).padding(.leading, 48) }
    }

    /// Keys to the lock: an overview of the numbered keys, each with its
    /// state; a key opens its own page. Same order as on the iPhone.
    enum KeyPage: Hashable { case openingZecky, openingLock, pause, securityKey }
    @State private var keyPage: KeyPage?

    @ViewBuilder private var keysPage: some View {
        switch keyPage {
        case nil: keysOverview
        case .openingZecky?: openingZeckyPage
        case .openingLock?: openingLockPage
        case .pause?: pausePage
        case .securityKey?: securityKeyPage
        }
    }

    private var keysOverview: some View {
        let _ = model.timeLockChanged
        return VStack(alignment: .leading, spacing: 12) {
            Text("Up to four keys: you choose. Each one has to be passed before the lock opens.")
                .font(Theme.text(13)).foregroundStyle(Theme.muted)
                .fixedSize(horizontal: false, vertical: true)
            VStack(spacing: 0) {
                keyLink(1, "Opening Zecky", askZecky ? "Touch ID or Mac password" : "Off", on: askZecky) { keyPage = .openingZecky }
                keyLink(2, "Opening the lock", openingLockState, on: askLock || WalletVault.hasCode) { keyPage = .openingLock }
                keyLink(3, "Really open the lock?", wait == 0 ? "Don't ask" : "Wait \(wait) seconds", on: wait > 0) { keyPage = .pause }
                keyLink(4, "Security key", securityKeyState, on: SecurityKeys.hasKeys) { keyPage = .securityKey }
            }
            .background(Theme.surface, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).stroke(Theme.line))
            Text("Always asked, whatever you choose: showing the recovery phrase and erasing. Making a key stricter needs nothing; weakening one asks you first. The time lock is its own setting under Security.")
                .font(Theme.text(11)).foregroundStyle(Theme.muted)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private var openingLockState: String {
        var parts: [String] = []
        parts.append(askLock ? "Touch ID again" : "Touch ID once per session")
        if WalletVault.hasCode { parts.append("Zecky code") }
        return parts.joined(separator: " + ")
    }

    private func keyLink(_ n: Int, _ title: String, _ state: String, on: Bool, _ open: @escaping () -> Void) -> some View {
        Button(action: open) {
            HStack(spacing: 12) {
                Text("\(n)").font(Theme.serif(16, weight: .medium)).foregroundStyle(on ? Theme.gold : Theme.muted)
                    .frame(width: 26, height: 26)
                    .overlay(Circle().stroke((on ? Theme.gold : Theme.muted).opacity(0.5)))
                Text(title).font(Theme.text(14, weight: .medium)).foregroundStyle(Theme.text)
                Spacer(minLength: 12)
                Text(state).font(Theme.text(12)).foregroundStyle(on ? Theme.green : Theme.muted).lineLimit(1)
                Image(systemName: "chevron.right").font(.system(size: 11, weight: .semibold)).foregroundStyle(Theme.muted)
            }
            .padding(.horizontal, 14).frame(height: 50)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .overlay(alignment: .bottom) { Rectangle().fill(Theme.line).frame(height: 1).padding(.leading, 52) }
    }

    private var openingZeckyPage: some View {
        card("1 · Opening Zecky", icon: "key.fill") {
            HStack(alignment: .top, spacing: 14) {
                Text("Touch ID or your Mac password when Lock it starts, and after it locked itself (sleep, screen lock, 5 minutes away). Why: your balance and history stay private on a shared or unattended Mac.")
                    .font(Theme.text(12)).foregroundStyle(Theme.muted)
                    .fixedSize(horizontal: false, vertical: true)
                Spacer()
                Toggle("Ask", isOn: Binding(get: { askZecky }, set: { changeAskZecky($0) }))
                    .toggleStyle(.switch).labelsHidden()
            }
        }
    }

    @ViewBuilder private var openingLockPage: some View {
        card("2 · Opening the lock", icon: "lock.open") {
            HStack(alignment: .top, spacing: 14) {
                Text("Touch ID or your Mac password again when you open the lock, even right after opening Zecky. Off: the confirmation from opening Zecky counts, once per session. Why: someone at your unlocked Mac still cannot take anything out.")
                    .font(Theme.text(12)).foregroundStyle(Theme.muted)
                    .fixedSize(horizontal: false, vertical: true)
                Spacer()
                Toggle("Ask", isOn: Binding(get: { askLock }, set: { changeAskLock($0) }))
                    .toggleStyle(.switch).labelsHidden()
            }
        }
        if WalletVault.canUseCode {
            card("Zecky code", icon: "lock.rotation") {
                HStack {
                    Text("Six digits on the brass dials, asked together with Touch ID. Why: anyone who knows your Mac password passes Touch ID too; the code is a secret only you know. This Mac's Secure Enclave checks it itself.")
                        .font(Theme.text(12)).foregroundStyle(Theme.muted)
                        .fixedSize(horizontal: false, vertical: true)
                    Spacer()
                    Text(WalletVault.hasCode ? "On" : "Off")
                        .font(Theme.text(12, weight: .semibold))
                        .foregroundStyle(WalletVault.hasCode ? Theme.green : Theme.muted)
                }
                if let codeNote { Text(codeNote).font(Theme.text(12)).foregroundStyle(Theme.green) }
                HStack(spacing: 10) {
                    Spacer()
                    if WalletVault.hasCode {
                        SecondaryButton(title: "Remove code") { codeNote = nil; codeStep = .remove }.frame(width: 150)
                        SecondaryButton(title: "Change code") { codeNote = nil; codeStep = .change }.frame(width: 150)
                    } else {
                        SecondaryButton(title: "Set a Zecky code") { codeNote = nil; codeStep = .setUp }.frame(width: 190)
                    }
                }
            }
        }
    }

    private var pausePage: some View {
        card("3 · Really open the lock?", icon: "hourglass") {
            Text("A short pause with a question before the lock opens. Why: scams work by rushing you; a few seconds is often enough to notice.")
                .font(Theme.text(12)).foregroundStyle(Theme.muted)
                .fixedSize(horizontal: false, vertical: true)
            HStack(spacing: 6) {
                ForEach(Keys.waits, id: \.self) { w in
                    Chip(title: Keys.waitLabel(w), on: wait == w) { changeWait(w) }
                }
            }
        }
    }

    // MARK: ④ Security key

    @State private var keyNote: String?
    @State private var keyProblem: String?
    @State private var keyBusy = false
    @State private var keysVersion = 0

    private var securityKeyState: String {
        let _ = keysVersion
        let n = SecurityKeys.keys.count
        if n == 0 { return SecurityKeys.hasKeys ? "Can't read" : "Off" }
        return n == 1 ? "1 key" : "\(n) keys"
    }

    private var securityKeyPage: some View {
        let _ = keysVersion
        let keys = SecurityKeys.keys
        return card("4 · Security key", icon: "key.horizontal") {
            Text("A hardware key, such as a YubiKey, plugged into this Mac or held to it, touched before each payment you send. Why: Touch ID, your Mac password and the Zecky code all live on this Mac; a key you carry is something a thief of the Mac does not have.")
                .font(Theme.text(12)).foregroundStyle(Theme.muted)
                .fixedSize(horizontal: false, vertical: true)
            if keys.isEmpty {
                Text("No key added. Adding one asks you first.").font(Theme.text(12)).foregroundStyle(Theme.muted)
            } else {
                VStack(spacing: 0) {
                    ForEach(keys) { key in
                        HStack(spacing: 10) {
                            Image(systemName: "key.horizontal.fill").foregroundStyle(Theme.gold)
                            Text(key.role == .main ? "Security key" : "Backup key").font(Theme.text(13, weight: .medium)).foregroundStyle(Theme.text)
                            Text("added \(key.added.formatted(date: .abbreviated, time: .omitted))").font(Theme.text(11)).foregroundStyle(Theme.muted)
                            Spacer()
                            Button("Remove") { runKey { try await SecurityKeys.remove(key.id); keyNote = "Key removed." } }
                                .buttonStyle(.plain).font(Theme.text(12)).foregroundStyle(Theme.red).disabled(keyBusy)
                        }
                        .padding(.vertical, 8)
                    }
                }
            }
            if let keyNote { Text(keyNote).font(Theme.text(12)).foregroundStyle(Theme.green) }
            if let keyProblem { Text(keyProblem).font(Theme.text(12)).foregroundStyle(Theme.red).fixedSize(horizontal: false, vertical: true) }
            HStack(spacing: 10) {
                Spacer()
                if !keys.isEmpty {
                    SecondaryButton(title: "Test my key") { runKey { try await SecurityKeys.check(); keyNote = "Your key answered correctly." } }
                        .frame(width: 150).disabled(keyBusy)
                }
                SecondaryButton(title: keys.isEmpty ? "Add a security key" : "Add a backup key") { addKey(first: keys.isEmpty) }
                    .frame(width: 190).disabled(keyBusy)
            }
            if !keys.isEmpty {
                Divider().overlay(Theme.line)
                HStack(alignment: .top, spacing: 14) {
                    VStack(alignment: .leading, spacing: 4) {
                        Text("Ask a key for the recovery phrase").font(Theme.text(13, weight: .medium))
                        Text("Showing your 24 words also needs a key. Needs a backup key first, so one lost key never locks you out.")
                            .font(Theme.text(11)).foregroundStyle(Theme.muted)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    Spacer()
                    Toggle("Ask a key for the recovery phrase", isOn: Binding(
                        get: { SecurityKeys.phraseNeedsKey },
                        set: { on in runKey { try await SecurityKeys.setPhraseNeedsKey(on); keyNote = on ? "The recovery phrase now asks a key." : "The recovery phrase no longer asks a key." } }))
                        .toggleStyle(.switch).labelsHidden()
                        .disabled(keyBusy || (!SecurityKeys.phraseNeedsKey && keys.count < LockRules.phraseKeyMinKeys))
                }
                Divider().overlay(Theme.line)
                lostKeys
            }
        }
        .confirmationDialog("Remove all security keys in 48 hours?", isPresented: $confirmLostKeys) {
            Button("Start the 48 hours", role: .destructive) { startLostKeys() }
        } message: {
            Text("After 48 hours, and 48 hours of Zcash blocks, every security key is removed and sending needs only your other keys again. Any of your keys can cancel it before then. It finishes only on one of the built-in servers.")
        }
    }

    @State private var confirmLostKeys = false

    /// "Lost my keys": the only way around a key, and a slow one on purpose.
    @ViewBuilder private var lostKeys: some View {
        let _ = keysVersion
        let _ = model.engine.keysChanged
        if let removal = SecurityKeys.removal {
            let target = LockRules.removalTargetHeight(from: removal.startHeight)
            let due = removal.startedAt.addingTimeInterval(LockRules.removalSeconds)
            VStack(alignment: .leading, spacing: 6) {
                Text("Removing all security keys").font(Theme.text(13, weight: .medium)).foregroundStyle(Theme.red)
                Text("Not before \(due.formatted(date: .abbreviated, time: .shortened)) and block \(target.formatted(.number.grouping(.automatic).locale(Locale(identifier: "en_US")))). Until then your keys still work. Found them? Cancel with one of them.")
                    .font(Theme.text(11)).foregroundStyle(Theme.muted)
                    .fixedSize(horizontal: false, vertical: true)
                HStack {
                    Spacer()
                    SecondaryButton(title: "Cancel the removal") { runKey { try await SecurityKeys.cancelRemoval(); keyNote = "The removal is cancelled. Your keys stay." } }
                        .frame(width: 190).disabled(keyBusy)
                }
            }
        } else {
            HStack(alignment: .top, spacing: 14) {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Lost your keys?").font(Theme.text(13, weight: .medium))
                    Text("Remove all security keys after 48 hours. Slow on purpose: someone at your Mac cannot simply take the keys away, and you have time to notice and cancel.")
                        .font(Theme.text(11)).foregroundStyle(Theme.muted)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer()
                SecondaryButton(title: "Lost my keys") { confirmLostKeys = true }.frame(width: 150).disabled(keyBusy)
            }
        }
    }

    private func startLostKeys() {
        let height = model.engine.isCurrent ? model.engine.networkHeight : 0
        Task {
            await guarded("start removing all security keys") {
                keyNote = nil; keyProblem = nil
                do {
                    try SecurityKeys.startRemoval(syncedHeight: height)
                    keyNote = "Started. All security keys are removed after 48 hours unless you cancel."
                } catch { keyProblem = String(describing: error) }
                keysVersion += 1
            }
        }
    }

    private func addKey(first: Bool) {
        let role: SecurityKeys.Role = first ? .main : .backup
        let add = { runKey { try await SecurityKeys.add(role: role); keyNote = first ? "Key added. It is asked before each payment you send." : "Backup key added." } }
        // The first key asks the owner; more keys ask an existing key (inside add).
        if LockRules.keyAction(first ? .addFirst : .addMore, keyCount: SecurityKeys.keys.count) == .owner {
            Task { await guarded("add a security key", add) }
        } else { add() }
    }

    private func runKey(_ work: @escaping () async throws -> Void) {
        keyNote = nil; keyProblem = nil; keyBusy = true
        Task { @MainActor in
            defer { keyBusy = false; keysVersion += 1; model.timeLockChanged += 1 }
            do { try await work() }
            catch SecurityKeys.Failure.cancelled { }
            catch { keyProblem = String(describing: error) }
        }
    }

    @ViewBuilder private var timeLockPage: some View {
            card("Time lock", icon: "clock") {
                VStack(alignment: .leading, spacing: 10) {
                    Text("Opening the lock has to be asked for this long ahead. Why: for Zcash you mean to keep, a wait of days protects you against pressure and impulse. Turning it off or shorter waits as long as the current time lock. In an emergency you can break the glass. It does not stop someone who has your 24 words.")
                        .font(Theme.text(12)).foregroundStyle(Theme.muted)
                        .fixedSize(horizontal: false, vertical: true)
                    HStack(spacing: 6) {
                        ForEach(TimeLock.choices, id: \.self) { hours in
                            Chip(title: TimeLock.label(hours), on: timeLockHours == hours) {
                                if hours != timeLockHours { confirmTimeLock = hours }
                            }
                        }
                    }
                    if let broken = TimeLock.lastBroken {
                        Label("Glass last broken on \(TimeLock.when(broken))", systemImage: "hammer")
                            .font(Theme.text(12)).foregroundStyle(Theme.red)
                    }
                    if let pending = TimeLock.pendingHours, let from = TimeLock.pendingFrom {
                        let _ = model.timeLockChanged
                        HStack {
                            Text("Becomes \(TimeLock.label(pending).lowercased()) on \(TimeLock.when(from)).")
                                .font(Theme.text(12)).foregroundStyle(Theme.gold)
                            Spacer()
                            Button("Keep \(TimeLock.label(timeLockHours).lowercased())") {
                                TimeLock.cancelChange()
                                model.timeLockChanged += 1
                            }
                            .buttonStyle(.plain).font(Theme.text(12)).foregroundStyle(Theme.muted).underline()
                        }
                    }
                }
            }

    }

    @ViewBuilder private var phrasePage: some View {
            card("Recovery phrase", icon: "doc.text.magnifyingglass") {
                if model.isSealedSelected {
                    // A Seal it wallet has no words on this Mac: showing the
                    // main wallet's words here would be the wrong wallet's.
                    Text("\(walletWords) is a Seal it wallet. Its 24 words are on the phone that holds it, never on this Mac, so there is nothing to show here.")
                        .font(Theme.text(12)).foregroundStyle(Theme.muted)
                        .fixedSize(horizontal: false, vertical: true)
                } else {
                    HStack(alignment: .center, spacing: 14) {
                        Text("The 24 words of \(walletWords). " + sealNote + " Why: the 24 words are the wallet. Sealed in the chip, they cannot be read from a copy of this Mac's files.")
                            .font(Theme.text(12)).foregroundStyle(Theme.muted)
                            .fixedSize(horizontal: false, vertical: true)
                        Spacer()
                        SecondaryButton(title: "Show recovery phrase") { Task { await showPhrase() } }.frame(width: 200)
                    }
                }
            }

            // As on Lock it iPhone (Settings › Security › Viewing key).
            card("Viewing key", icon: "eye") {
                Text("A viewing key gives read-only access to \(model.engine.currentTag.map { "the wallet \($0.name)" } ?? "this wallet"). Whoever has it can see your balance and every payment in and out, past and future, but cannot spend anything.")
                    .font(Theme.text(12)).foregroundStyle(Theme.muted)
                    .fixedSize(horizontal: false, vertical: true)
                Text("It cannot be taken back once shared. Give it only to someone or something that should see everything, such as your own watch-only device or an accountant.")
                    .font(Theme.text(12)).foregroundStyle(Theme.gold)
                    .fixedSize(horizontal: false, vertical: true)
                if let viewKey {
                    Text(viewKey)
                        .font(.system(size: 12, design: .monospaced))
                        .textSelection(.enabled)
                        .fixedSize(horizontal: false, vertical: true)
                        .padding(10)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .background(Theme.surface, in: RoundedRectangle(cornerRadius: 8))
                        .overlay(RoundedRectangle(cornerRadius: 8).stroke(Theme.line))
                        .hiddenFromCapture()
                    HStack {
                        Text("Select it to copy. Hidden from screenshots while it shows.")
                            .font(Theme.text(12)).foregroundStyle(Theme.muted)
                        Spacer()
                        SecondaryButton(title: "Hide") { self.viewKey = nil }.frame(width: 120)
                    }
                } else {
                    HStack {
                        if let viewKeyNote {
                            Text(viewKeyNote).font(Theme.text(12)).foregroundStyle(Theme.red)
                        }
                        Spacer()
                        SecondaryButton(title: "Show viewing key") {
                            viewKeyNote = nil
                            Task {
                                await guarded("show your viewing key") {
                                    Task {
                                        viewKey = await model.engine.viewingKey()
                                        if viewKey == nil { viewKeyNote = "This wallet's viewing key could not be read." }
                                    }
                                }
                            }
                        }
                        .frame(width: 200)
                    }
                }
            }
            .onDisappear { viewKey = nil; viewKeyNote = nil }

    }

    @ViewBuilder private var addressBookPage: some View {
            card("Saved addresses", icon: "person.crop.circle") {
                ContactsCard(guarded: { reason, action in Task { await guarded(reason, action) } },
                             changed: { model.timeLockChanged += 1 })
            }

    }

    @ViewBuilder private var displayPage: some View {
            card("Appearance", icon: "circle.lefthalf.filled") {
                HStack(spacing: 6) {
                    ForEach(Theme.Mode.allCases) { mode in
                        Chip(title: mode.label, on: model.themeMode == mode) { model.themeMode = mode }
                    }
                }
            }

            card("Value", icon: "chart.line.uptrend.xyaxis") {
                HStack(spacing: 6) {
                    ForEach(PriceFeed.Currency.allCases) { currency in
                        Chip(title: currency.short, on: prices.currency == currency) { prices.currency = currency }
                    }
                }
                Text("Shown on the lock. The price comes from CoinGecko every 5 minutes; CoinGecko sees this Mac's internet address, never anything about your wallet.")
                    .font(Theme.text(12)).foregroundStyle(Theme.muted)
                    .fixedSize(horizontal: false, vertical: true)
            }

    }

    @ViewBuilder private var networkPage: some View {
            card("Server", icon: "server.rack") {
                FlowChips(items: Server.presets.indices.map { ($0, Server.presets[$0].label) } + [(-1, "Your own")],
                          selected: serverChoice) { serverChoice = $0 }
                Text(serverChoice >= 0 ? Server.presets[serverChoice].host + ":443" : "Your own node (Rock it) or server: host:port")
                    .font(.system(size: 12, design: .monospaced)).foregroundStyle(Theme.muted)
                if serverChoice == -1 {
                    TextField("", text: $customServer, prompt: Text("192.168.1.20:9067 or a Tailscale 100.x address").foregroundColor(Theme.muted))
                        .textFieldStyle(.plain)
                        .font(.system(size: 13, design: .monospaced))
                        .autocorrectionDisabled()
                        .padding(10)
                        .background(Theme.ink, in: RoundedRectangle(cornerRadius: 8))
                        .overlay(RoundedRectangle(cornerRadius: 8).stroke(Theme.line))
                }
                HStack(spacing: 12) {
                    SecondaryButton(title: "Use this server") { Task { await applyServer() } }.frame(width: 170)
                    if let serverNote { Text(serverNote).font(Theme.text(12)).foregroundStyle(Theme.muted) }
                }
                Button(showNetworkWhy ? "Less" : "What the server sees") { showNetworkWhy.toggle() }
                    .buttonStyle(.plain).font(Theme.text(12, weight: .medium)).foregroundStyle(Theme.gold)
                if showNetworkWhy {
                    Text(networkNote)
                        .font(Theme.text(12)).foregroundStyle(Theme.muted)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            sendingCard

    }

    private var sendingCard: some View {
        card("Sending", icon: "paperplane") {
            Toggle(isOn: Binding(get: { sendOverTor }, set: { on in
                sendOverTor = on
                Task { await model.engine.setSendsOverTor(on) }
            })) {
                Text("Send payments over Tor").font(Theme.text(13))
            }
            .toggleStyle(.checkbox)
            Text(sendOverTor
                 ? "Your payments leave over Tor, each on its own connection, to a public server that cannot see this Mac's internet address. If Tor cannot connect, the payment waits; it is never sent another way by itself. Reading the chain is not affected."
                 : "Your payments go to the server above, which sees this Mac's internet address. With your own node, other Zcash nodes see the payment coming from your internet address.")
                .font(Theme.text(12)).foregroundStyle(sendOverTor ? Theme.muted : Theme.gold)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    @State private var showAcknowledgements = false
    @State private var showNetworkWhy = false
    @State private var showTechnical = false

    private func aboutLine(_ label: String, _ value: String) -> some View {
        HStack(alignment: .firstTextBaseline) {
            Text(label).font(Theme.text(12)).foregroundStyle(Theme.muted)
            Spacer(minLength: 12)
            Text(value).font(Theme.text(12, weight: .medium)).foregroundStyle(Theme.text).textSelection(.enabled)
                .multilineTextAlignment(.trailing)
        }
    }

    @ViewBuilder private var aboutPage: some View {
            card("About", icon: "info.circle") {
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    Text("ZECKY").font(Theme.text(12, weight: .semibold)).tracking(4).foregroundStyle(Theme.gold)
                    Text("Lock it for Mac \(version)").font(Theme.serif(15))
                }
                Text("Self-custody Zcash. Your keys stay in this Mac's Keychain. zecky.app")
                    .font(Theme.text(12)).foregroundStyle(Theme.muted)
                let engine = model.engine
                let n = { (v: Int) in v > 0 ? v.formatted(.number.grouping(.automatic).locale(Locale(identifier: "en_US"))) : "…" }
                VStack(spacing: 6) {
                    aboutLine("Version", version)
                    aboutLine("Zcash engine", "Zecky engine v4.0.0-zecky.5 + Tor sending")
                    aboutLine("Current block", n(engine.networkHeight))
                    aboutLine("Wallet birthday", n(engine.birthdayHeight))
                    aboutLine("Server", Server.nodeLabel.map { "\($0) (\(Server.host))" } ?? Server.host)
                }
                .padding(.top, 4)
                Button(showTechnical ? "Hide technical details" : "Technical details") { showTechnical.toggle() }
                    .buttonStyle(.plain).font(Theme.text(12, weight: .medium)).foregroundStyle(Theme.gold)
                if showTechnical {
                    VStack(spacing: 6) {
                        aboutLine("Engine", "v4.0.0-zecky.5 + Tor sending · commit 90e877d")
                        aboutLine("Engine fingerprint (Mac)", "ec88e073…3079fa")
                        aboutLine("NU7 check", WalletSelfTest.engineBranch(at: NetworkUpgrade.nu7Height) == 0x7719_0AD9 ? "Signs for NU7 (0x77190AD9)" : "Does not know NU7")
                        aboutLine("Swift SDK", "ZcashLightClientKit 4.0.0")
                    }
                }
                HStack(spacing: 8) {
                    // The same privacy policy as Lock it iPhone (audit C-38).
                    Link("Privacy policy", destination: URL(string: "https://zecky.app/privacy")!)
                        .font(Theme.text(12, weight: .medium)).foregroundStyle(Theme.gold)
                    Text("·").foregroundStyle(Theme.muted)
                    Button("Acknowledgements") { showAcknowledgements = true }
                        .buttonStyle(.plain).font(Theme.text(12, weight: .medium)).foregroundStyle(Theme.gold)
                }
            }
            .sheet(isPresented: $showAcknowledgements) { AcknowledgementsSheet { showAcknowledgements = false } }

        PoolsCard(model: model, engine: model.engine)
    }

    /// A quiet header above a group of cards.
    private func section(_ title: String, _ subtitle: String?) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(title.uppercased()).font(Theme.text(11, weight: .semibold)).tracking(2).foregroundStyle(Theme.gold)
            if let subtitle { Text(subtitle).font(Theme.text(12)).foregroundStyle(Theme.muted) }
        }
        .padding(.top, 14).padding(.leading, 4)
    }

    private func card<Content: View>(_ title: String, icon: String, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Label(title, systemImage: icon)
                .font(Theme.text(13, weight: .semibold))
                .foregroundStyle(Theme.text)
                .labelStyle(GoldIconLabelStyle())
            content()
        }
        .card(padding: 16)
    }

    private var timeLockQuestion: String {
        guard let hours = confirmTimeLock else { return "" }
        if hours == 0 { return "Turn the time lock off?" }
        return hours > timeLockHours ? "Set a \(TimeLock.label(hours).lowercased()) time lock?" : "Shorten the time lock to \(TimeLock.label(hours).lowercased())?"
    }

    private var timeLockAction: String {
        guard let hours = confirmTimeLock else { return "OK" }
        return hours == 0 ? "Turn off" : (hours > timeLockHours ? "Set time lock" : "Shorten")
    }

    private var timeLockMessage: String {
        guard let hours = confirmTimeLock else { return "" }
        if hours > timeLockHours {
            return "From now on, opening the lock has to be asked \(TimeLock.label(hours).lowercased()) ahead. Turning it off or shorter later also takes \(TimeLock.label(hours).lowercased()). In an emergency you can break the glass."
        }
        return "This takes effect on \(TimeLock.when(TimeLock.shorterFrom())), after the current \(TimeLock.label(timeLockHours).lowercased()). Until then the time lock stays as it is."
    }

    private var sheetTitle: String {
        if showingPhrase { return "Recovery phrase" }
        switch codeStep {
        case .phrase: return "Show recovery phrase"
        case .setUp: return "Set a Zecky code"
        case .change: return "Change the code"
        case .remove: return "Remove the code"
        case .erase: return "Erase everything"
        case .guarded: return "Confirm it's you"
        case nil: break
        }
        switch page {
        case .keys?:
            switch keyPage {
            case .openingZecky?: return "Opening Zecky"
            case .openingLock?: return "Opening the lock"
            case .pause?: return "Really open the lock?"
            case .securityKey?: return "Security key"
            case nil: return "Keys to the lock"
            }
        case .timeLock?: return "Time lock"
        case .phrase?: return "Recovery phrase"
        case .addressBook?: return "Address book"
        case .display?: return "Display"
        case .network?: return "Network"
        case .goMax?: return "Go Max"
        case .how?: return "How Zecky works"
        case .about?: return "About"
        case nil: return "Settings"
        }
    }

    private var sheetSubtitle: String {
        if showingPhrase { return "Only for you. Check it against your paper." }
        switch codeStep {
        case .phrase, .remove, .erase, .guarded:
            return WalletVault.usesPassword ? "Your Lock it password first." : "Your code, then Touch ID or your Mac password."
        case .setUp, .change: return "Sealed with your phrase in this Mac's Secure Enclave."
        case nil: break
        }
        switch page {
        case .keys?: return "One, two or three keys: you choose."
        case .timeLock?: return "A wait of days before the lock opens."
        case .phrase?: return "Your 24 words and the viewing key."
        case .addressBook?: return "Addresses you send to often, picked by name."
        case .display?: return "How Lock it looks on this Mac."
        case .network?: return "Where Lock it gets the Zcash chain from."
        case .goMax?: return "Your own Zcash node, on this Mac."
        case .how?: return "Short chapters. Open the one you want."
        case .about?: return "Zecky Lock it for Mac."
        case nil: return "Everything stays on this Mac."
        }
    }

    @ViewBuilder
    private func codeView(_ step: CodeStep) -> some View {
        switch step {
        case .phrase:
            CodePrompt(action: "Show",
                       submit: { code in
                           do {
                               let wallet = try await WalletVault.unseal(reason: "show your recovery phrase", code: code)
                               pendingPhrase = try wordsOfSelected(main: wallet)
                               return nil
                           } catch WalletVault.Failure.cancelled {
                               return "Not confirmed."
                           } catch { return String(describing: error) }
                       },
                       onDone: { revealed = pendingPhrase; pendingPhrase = nil; codeStep = nil },
                       onCancel: { codeStep = nil })
        case .setUp, .change:
            CodeSetupView(changing: step == .change,
                          onDone: { codeStep = nil; codeNote = step == .change ? "The code is changed." : "The lock has a code now." },
                          onCancel: { codeStep = nil })
        case .guarded:
            CodePrompt(action: "Continue",
                       submit: { code in
                           do {
                               _ = try await WalletVault.unseal(reason: guardReason, code: code)
                               return nil
                           } catch WalletVault.Failure.cancelled {
                               return "Not confirmed, so nothing changed."
                           } catch { return String(describing: error) }
                       },
                       onDone: { let action = guardAction; guardAction = nil; codeStep = nil; action?() },
                       onCancel: { guardAction = nil; codeStep = nil })
        case .erase:
            CodePrompt(action: "Continue",
                       submit: { code in
                           do {
                               _ = try await WalletVault.unseal(reason: "erase this wallet", code: code)
                               return nil
                           } catch WalletVault.Failure.cancelled {
                               return "Not confirmed."
                           } catch { return String(describing: error) }
                       },
                       onDone: { codeStep = nil; confirmErase = true },
                       onCancel: { codeStep = nil })
        case .remove:
            CodePrompt(action: "Remove",
                       submit: { code in
                           do {
                               try await WalletVault.setCode(current: code, new: nil)
                               return nil
                           } catch WalletVault.Failure.cancelled {
                               return "Not confirmed, so the code stays."
                           } catch { return String(describing: error) }
                       },
                       onDone: { codeStep = nil; codeNote = "The code is removed. Touch ID or your Mac password opens the lock." },
                       onCancel: { codeStep = nil })
        }
    }

    private var sealNote: String {
        switch WalletVault.kind {
        case .secureEnclave where WalletVault.usesPassword: return "Sealed in this Mac's Secure Enclave. Opens only with your Lock it password."
        case .secureEnclave: return "Sealed in this Mac's Secure Enclave. Opens only with Touch ID or your Mac password."
        default:
            return WalletVault.usesPassword
                ? "Kept in this Mac's Keychain. Opens only with your Lock it password."
                : "Kept in this Mac's Keychain. Opens only with Touch ID or your Mac password."
        }
    }

    private var version: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? ""
    }

    /// "the wallet Savings", as named on the key ring.
    private var walletWords: String { model.engine.currentTag.map { "the wallet \($0.name)" } ?? "this wallet" }

    /// The words of the wallet on screen. An extra wallet on this Mac has
    /// its own, opened with the main ones; a Seal it wallet has none here.
    private func wordsOfSelected(main: StoredWallet) throws -> StoredWallet {
        guard !model.isSealedSelected else { throw WalletVault.Failure.cancelled }
        if let id = model.selectedWallet, KeyRingVault.contains(id) {
            return try KeyRingVault.open(id: id, mainPhrase: main.phrase)
        }
        return main
    }

    private func showPhrase() async {
        problem = nil
        guard !model.isSealedSelected else { return }
        // With "Ask a key for the recovery phrase" on, a security key is
        // touched first. Unreadable key data counts as on.
        if SecurityKeys.phraseNeedsKey {
            do { try await SecurityKeys.check() }
            catch SecurityKeys.Failure.cancelled { return }
            catch { problem = String(describing: error); return }
        }
        if WalletVault.needsSecret { codeStep = .phrase; return }
        do { revealed = try wordsOfSelected(main: try await WalletVault.unseal(reason: "show your recovery phrase")) }
        catch WalletVault.Failure.cancelled { }
        catch { problem = String(describing: error) }
    }

    private func applyServer() async {
        serverNote = nil
        var host: String
        var port = 443
        if serverChoice >= 0 {
            host = Server.presets[serverChoice].host
        } else {
            let parts = customServer.trimmingCharacters(in: .whitespaces).split(separator: ":")
            guard let first = parts.first, !first.isEmpty, parts.count <= 2 else { serverNote = "Enter host or host:port."; return }
            host = String(first).lowercased()
            if parts.count == 2 {
                guard let p = Int(parts[1]), (1...65535).contains(p) else { serverNote = "The port must be a number."; return }
                port = p
            }
        }
        // Leaving your own server for a public one: keep it for later.
        if !Server.presets.contains(where: { $0.host == Server.host }) {
            Server.rememberOwn(Server.port == 443 ? Server.host : "\(Server.host):\(Server.port)")
        }
        Server.set(host: host, port: port)
        if serverChoice < 0 { Server.rememberOwn(port == 443 ? host : "\(host):\(port)") }
        // A running "Lost my keys" removal starts its 48 hours again on a
        // new server (iPhone re-check R1).
        SecurityKeys.restartRemovalIfRunning()
        do {
            try await model.engine.switchServer()
            serverNote = "Now using \(host)"
        } catch {
            serverNote = "Could not connect: \(error)"
        }
    }

    /// One key on the Keys to the lock card: number, name, why, control.
    private func keyRow<Control: View>(_ n: Int, _ title: String, _ why: String, @ViewBuilder control: () -> Control) -> some View {
        HStack(alignment: .top, spacing: 12) {
            Text("\(n)").font(Theme.serif(18, weight: .medium)).foregroundStyle(Theme.gold)
                .frame(width: 26, height: 26)
                .overlay(Circle().stroke(Theme.gold.opacity(0.5)))
            VStack(alignment: .leading, spacing: 4) {
                Text(title).font(Theme.text(13, weight: .semibold))
                Text(why).font(Theme.text(12)).foregroundStyle(Theme.muted)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 12)
            control()
        }
    }

    private func changeAskZecky(_ on: Bool) {
        let apply = { Keys.askOpeningZecky = on; askZecky = on; model.timeLockChanged += 1 }
        if LockRules.check(on: on) == .nothing { apply() } else { Task { await guarded("stop asking when opening Zecky", apply) } }
    }

    private func changeAskLock(_ on: Bool) {
        let apply = { Keys.askOpeningLock = on; askLock = on; model.timeLockChanged += 1 }
        if LockRules.check(on: on) == .nothing { apply() } else { Task { await guarded("stop asking again when opening the lock", apply) } }
    }

    private func changeWait(_ seconds: Int) {
        let apply = { Keys.wait = seconds; wait = seconds; model.timeLockChanged += 1 }
        if LockRules.wait(from: wait, to: seconds) == .nothing { apply() } else { Task { await guarded("shorten the pause before opening the lock", apply) } }
    }

    /// Runs `action` once the owner confirmed: the code (or Lock it
    /// password) and Touch ID when set, otherwise Touch ID.
    private func guarded(_ reason: String, _ action: @escaping () -> Void) async {
        if WalletVault.needsSecret {
            guardReason = reason
            guardAction = action
            codeStep = .guarded
        } else if await OwnerCheck.confirm(reason: reason) {
            action()
        }
    }

    private func askErase() async {
        problem = nil
        if WalletVault.needsSecret { codeStep = .erase; return }
        if await OwnerCheck.confirm(reason: "erase everything on this Mac") { confirmErase = true }
    }

    private func erase() async {
        erasing = true
        defer { erasing = false }
        do {
            try await model.erase()
            onClose()
        } catch {
            problem = "The wallet could not be erased: \(error)"
        }
    }
}

/// The 24 words and birthday, after Touch ID or the Mac password.
struct PhraseView: View {
    let wallet: StoredWallet
    private var words: [String] { wallet.phrase.split(separator: " ").map(String.init) }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 6) {
                Text("Birthday block").foregroundStyle(Theme.muted)
                Text(wallet.birthday.formatted(.number.locale(Locale(identifier: "en_US"))))
                    .font(.system(.body, design: .monospaced))
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
                        .padding(.vertical, 8).padding(.horizontal, 8)
                        .background(Theme.surface, in: RoundedRectangle(cornerRadius: 8))
                        .overlay(RoundedRectangle(cornerRadius: 8).stroke(Theme.line))
                    }
                }
            }
            Text("The words show only after you click Show the words, so a screenshot or someone watching your screen catches nothing by accident. They leave the screen after 2 minutes, when you click Hide, close Settings or switch to another app.")
                .font(.system(size: 12)).foregroundStyle(Theme.muted)
            Spacer()
        }
        .hiddenFromCapture()
    }
}

/// Label with the icon in gold.
struct GoldIconLabelStyle: LabelStyle {
    func makeBody(configuration: Configuration) -> some View {
        HStack(spacing: 8) {
            configuration.icon.foregroundStyle(Theme.gold).frame(width: 18)
            configuration.title
        }
    }
}

/// Chips that wrap onto a second line when needed.
struct FlowChips: View {
    let items: [(Int, String)]
    let selected: Int
    let pick: (Int) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 6) {
                ForEach(items.prefix(3), id: \.0) { item in Chip(title: item.1, on: selected == item.0) { pick(item.0) } }
            }
            HStack(spacing: 6) {
                ForEach(items.dropFirst(3), id: \.0) { item in Chip(title: item.1, on: selected == item.0) { pick(item.0) } }
            }
        }
    }
}

/// Settings › About: your Zcash by pool, from the engine's balance report.
/// Nothing is stored.
struct PoolsCard: View {
    @ObservedObject var model: AppModel
    @ObservedObject var engine: WalletEngine

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Label("Your Zcash by pool", systemImage: "square.stack.3d.up")
                .font(Theme.text(13, weight: .semibold)).labelStyle(GoldIconLabelStyle())
            VStack(spacing: 8) {
                pool("Ironwood", "Current, since NU6.3 (28 July 2026). New Zcash goes here.", engine.pools.ironwood)
                pool("Orchard", "Withdraw-only since NU6.3. Move it to Ironwood from home.", engine.pools.orchard)
                pool("Sapling", "Older shielded pool, still usable.", engine.pools.sapling)
                pool("Transparent", "Visible to everyone, like Bitcoin. Lock it in from home if any arrives.", engine.pools.transparent)
            }
            Text("Sprout, the very first pool, is closed to new Zcash; Lock it does not use it.")
                .font(Theme.text(11)).foregroundStyle(Theme.muted)
                .fixedSize(horizontal: false, vertical: true)
        }
        .card(padding: 16)
    }

    private func pool(_ name: String, _ why: String, _ zats: Int64) -> some View {
        HStack(alignment: .firstTextBaseline) {
            VStack(alignment: .leading, spacing: 2) {
                Text(name).font(Theme.text(13, weight: .medium))
                Text(why).font(Theme.text(11)).foregroundStyle(Theme.muted)
            }
            Spacer()
            Text(model.amountsHidden ? Amount.hiddenText : Amount.text(zats, model.unit))
                .font(Theme.text(13, weight: .semibold))
                .foregroundStyle(zats > 0 ? Theme.text : Theme.muted)
        }
    }
}

/// How Zecky works: short chapters that open and close. Every sentence
/// here has to stay true to what the app does; check it with each change.
struct HowItWorks: View {
    /// Chapters in the order people need them, as on Lock it iPhone: a one-line
    /// summary, the essentials, and the fine print under "More detail".
    private struct Chapter { let title, icon, summary: String; let essentials, more: [String] }

    private let chapters: [Chapter] = [
        Chapter(title: "The lock", icon: "lock.fill", summary: "A place to keep Zcash, not to spend it.", essentials: [
            "Receiving is always one click. Opening the lock to send takes a deliberate moment: the pause, your keys, and then Send.",
            "The lock closes again after a payment, after 2 minutes, or when you hide Lock it.",
            "The line under your balance says how long your Zcash has been in the lock, shielded and transparent alike: \u{201C}Locked for 3 weeks\u{201D}. It is never a date, and nothing unlocks on a date.",
            "The ring around the lock fills towards your next milestone: 1 week, then every month of the first year, then every year. On the day you reach one, the ring glows softly.",
            "Click the line for highlights and milestones, each with its own name, from Locked at 1 week to Legend at 4 years.",
        ], more: [
            "The count starts at your first payment in after the lock was last empty. Sending, of any size, and receiving more do not reset it; only an empty lock does, and then the line is gone until Zcash comes in again.",
            "Moves inside the lock (locking in transparent Zcash, the Ironwood move, a payment to your own address) count as nothing.",
            "It is worked out on this Mac from your own payment history, with no timer stored. After a restore it waits for the first full sync, and it needs the history from before your first payment in; without it the line says \u{201C}Locked on this Mac\u{201D}.",
            "Every wallet on the key ring has its own count. 1 week, 1 year and every year after also engrave a fine line into the medallion. With every new Zcash block a light runs once around it.",
            "Milestones bring no notifications, badges or pop-ups.",
        ]),
        Chapter(title: "Receive and send", icon: "arrow.left.arrow.right", summary: "Waiting times, fees and what can't be undone.", essentials: [
            "Receive gives you a shielded address: amount, sender and receiver are encrypted on the blockchain. It is safe to share; only your 24 words must stay secret.",
            "Nothing leaves without a receipt first: who receives what, the network fee and what stays locked. A payment cannot be reversed once sent.",
        ], more: [
            "Zcash you receive can be used after 10 confirmations, your own change after 3. A block comes about every 25 seconds since the NU7 upgrade.",
            "A payment that could not be delivered is tried again for about 50 minutes (120 blocks), while Lock it is open and this Mac is awake; if the network still has not accepted it, it is cancelled and nothing leaves the lock. Do not send it again meanwhile.",
            "Include the network fee in the amount, and the receiver gets the amount minus the fee. Max sends everything that can be used, minus exactly the fee.",
            "Sending to a transparent address is public: its amount and destination. A private note only goes to a shielded address.",
        ]),
        Chapter(title: "Your 24 words", icon: "doc.text.magnifyingglass", summary: "They are your Zcash. Keep them on paper.", essentials: [
            "Your 24 words and birthday block restore the wallet in Lock it or any Zcash wallet. Whoever has them has your Zcash.",
            "They are sealed by this Mac's Secure Enclave and shown only when you click to show them, for at most 2 minutes, so a screenshot does not catch them by accident.",
            "A viewing key shows everything in a wallet but can't spend. Showing it asks first, and sharing it can't be undone.",
        ], more: [
            "They are made on this Mac from the system's secure random generator (256 bits), checked, and mixed with a second source. After you write them down, Lock it asks for three of them back.",
            "Every wallet on the key ring has its own 24 words and restores on its own in any Zcash wallet. One lock opens them all: the first wallet's words are sealed by the Secure Enclave, and the other wallets' words are encrypted with a key that comes from them.",
            "Erase this wallet, in a wallet's menu on the key ring, removes only that wallet after you type its name. Erasing the wallet that holds the lock passes the lock to the next wallet with words, with the same code and keys; each step is checked before anything old is removed. Only the last wallet with words takes everything with it.",
            "Only Touch ID or your Mac password (and your Zecky code, if set) opens the seal. They are never synced, never in a backup, never written to a log and never sent anywhere. They are opened only to sign a payment or to show them to you, and let go straight after.",
            "Moving Lock it to the Trash does not remove the wallets. To remove everything, use Settings › Erase everything first. The Zecky code, time lock, keys, address book and settings live on this Mac only and do not come back with a restore.",
        ]),
        Chapter(title: "Keys to the lock", icon: "key.fill", summary: "Up to four checks before Zcash leaves. You choose.", essentials: [
            "1 Opening Zecky, 2 Opening the lock (with an optional six-digit Zecky code), 3 Really open the lock?, 4 Security key.",
            "Showing your 24 words and erasing always ask, whatever you choose. Making a key stricter goes straight through; weakening one asks you first.",
        ], more: [
            "Touch ID always falls back to your Mac password, so anyone who knows that password passes Touch ID too. The Zecky code is the secret only you know; this Mac's Secure Enclave checks it itself.",
            "Key 4 is a security key, such as a YubiKey, touched before each payment you send. Lock it checks its signature itself; nothing goes over the internet. Pair a key on each device.",
            "With a backup key you can also ask a key before your 24 words are shown. Lost every key? \"Lost my keys\" removes them after 48 hours and 48 hours of Zcash blocks, only on a built-in server; any of your keys can cancel it before then.",
            "With a time lock, opening has to be asked for 24 hours, 3 or 7 days ahead. In an emergency, Break the glass opens straight away and stays on record. A time lock does not stop someone who has your 24 words.",
            "Every change is listed in Activity › The lock.",
        ]),
        Chapter(title: "Private by default", icon: "shield.lefthalf.filled", summary: "Amounts, senders and addresses stay hidden.", essentials: [
            "Lock it only hands out shielded addresses. Once an address has been paid, a fresh one appears, so payments cannot be linked to each other.",
        ], more: [
            "Zcash that arrives on a transparent address (only possible after restoring) can be locked in with one step. A transparent address works like Bitcoin: its payments are visible to everyone until you lock them in.",
        ]),
        Chapter(title: "Go Max", icon: "point.3.connected.trianglepath.dotted", summary: "Your own Zcash node, inside Lock it.", essentials: [
            "Go Max runs a Zcash node in Lock it on this Mac. It checks every block since the Canopy upgrade itself and keeps only recent blocks in full. When it is up to date, Lock it reads the chain from it instead of a server.",
            "It takes about 20 GB of disk. The first check takes most of a day and downloads the whole chain once, about 250 GB, deleting older blocks as it goes. It is off until you switch it on: the Go Max button on the home screen opens it.",
        ], more: [
            "Until the node is up to date, Lock it keeps using your server. Switching Go Max off, or a problem with the node, switches back, and the Go Max page says so.",
            "The node connects to other Zcash nodes on the internet, like every node: they see this Mac's internet address, never your wallets, addresses or balance. Lock it talks to the node on this Mac only, and the node accepts no connections from outside.",
            "Blocks from before Canopy (2020) are accepted on checkpoints built into the node, as every Zcash node does; every block since is checked here, proofs and all.",
            "It runs while Lock it is open. Its files live in Lock it's own folder, left out of Time Machine; Remove node deletes them. Erase everything removes them too.",
        ]),
        Chapter(title: "What others can see", icon: "server.rack", summary: "The server and the price.", essentials: [
            "Lock it talks to one Zcash server (zec.rocks by default) over an encrypted connection. The server sees this Mac's internet address, never your words or your balance.",
        ], more: [
            "Your own node (Rock it) on a home or Tailscale address is reached without that layer: at home the traffic stays in your network, and Tailscale encrypts it on the way. A home address cannot prove it is your node; away from home use Rock it's Tailscale address.",
            "Value is off unless you choose a currency. Then CoinGecko is asked for the price every 5 minutes and sees only this Mac's internet address.",
            "With Go Max up to date, Lock it uses no server at all: it reads the chain from its own node on this Mac.",
            "Payments you send leave over Tor, each on its own connection, to a public Zcash server: it sees a payment arriving from Tor, not this Mac's internet address. If Tor cannot connect, the payment waits and you are told; it never goes out another way by itself. You can switch this off in Settings › Network.",
            "Everything else (reading the chain from a server, the price) does not use Tor yet.",
        ]),
        Chapter(title: "On this Mac", icon: "laptopcomputer", summary: "Where your data lives.", essentials: [
            "Your history (amounts and dates, never the words) is kept in Lock it's own protected folder and left out of Time Machine. Keep FileVault on so the whole disk is encrypted as well.",
        ], more: [
            "Keys, proofs, signatures and payments are made by librustzcash, the Zcash developers' own core (NU7 releases), not by Lock it. The Zecky engine only connects Lock it to it: release v4.0.0-zecky.5, the same as Lock it for iPhone. Every build checks the engine's commit and fingerprint, and the app checks that it signs for NU7.",
            "The Zcash parameter files (about 50 MB) are inside the app, checked against the Zcash developers' published fingerprints. Lock it never downloads them.",
        ]),
        Chapter(title: "What Zecky never does", icon: "hand.raised", summary: "No account, no tracking.", essentials: [
            "No account, no analytics, no tracking, no ads. Lock it never sends your words, balance or history anywhere.",
        ], more: []),
        Chapter(title: "Where it stands", icon: "flag", summary: "Early software.", essentials: [
            "Lock it for Mac is new and in testing. Start with small amounts, and keep your 24 words on paper.",
        ], more: []),
    ]

    var onTour: (() -> Void)? = nil
    @State private var open: Set<String> = ["The lock"]
    @State private var detail: Set<String> = []

    var body: some View {
        VStack(spacing: 8) {
            if let onTour {
                HStack {
                    Spacer()
                    Button("Show the tour again", action: onTour)
                        .buttonStyle(.plain).font(Theme.text(12, weight: .medium)).foregroundStyle(Theme.gold)
                }
            }
            ForEach(chapters, id: \.title) { c in
                VStack(alignment: .leading, spacing: 10) {
                    Button { if open.contains(c.title) { open.remove(c.title) } else { open.insert(c.title) } } label: {
                        HStack(alignment: .top, spacing: 10) {
                            Image(systemName: c.icon).foregroundStyle(Theme.gold).frame(width: 20)
                            VStack(alignment: .leading, spacing: 2) {
                                Text(c.title).font(Theme.text(14, weight: .semibold)).foregroundStyle(Theme.text)
                                Text(c.summary).font(Theme.text(12)).foregroundStyle(Theme.muted)
                            }
                            Spacer()
                            Image(systemName: open.contains(c.title) ? "chevron.up" : "chevron.down")
                                .font(.system(size: 11, weight: .semibold)).foregroundStyle(Theme.muted)
                        }
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    if open.contains(c.title) {
                        ForEach(c.essentials, id: \.self) { line in
                            Text(line).font(Theme.text(13)).foregroundStyle(Theme.text.opacity(0.9))
                                .fixedSize(horizontal: false, vertical: true)
                        }
                        if !c.more.isEmpty {
                            Button(detail.contains(c.title) ? "Less detail" : "More detail") {
                                if detail.contains(c.title) { detail.remove(c.title) } else { detail.insert(c.title) }
                            }
                            .buttonStyle(.plain).font(Theme.text(12, weight: .medium)).foregroundStyle(Theme.gold)
                            if detail.contains(c.title) {
                                ForEach(c.more, id: \.self) { line in
                                    Text(line).font(Theme.text(12)).foregroundStyle(Theme.muted)
                                        .fixedSize(horizontal: false, vertical: true)
                                }
                            }
                        }
                    }
                }
                .card(padding: 14)
            }
        }
    }
}

/// The open-source software in the app, from Acknowledgements.md
/// (generated by scripts/notices.py from what is actually linked).
struct AcknowledgementsSheet: View {
    let onClose: () -> Void
    private var text: String {
        guard let url = Bundle.main.url(forResource: "Acknowledgements", withExtension: "md"),
              let s = try? String(contentsOf: url, encoding: .utf8) else { return "The list could not be read." }
        return s
    }
    var body: some View {
        SheetScaffold(title: "Acknowledgements", subtitle: "Open-source software in Zecky Lock it for Mac.", width: 640, height: 640, onClose: onClose) {
            ScrollView {
                Text(text)
                    .font(.system(size: 11, design: .monospaced))
                    .foregroundStyle(Theme.muted)
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.bottom, 12)
            }
        }
    }
}

/// "ZCASH NETWORK · Block 3,551,141 · A block every 25 seconds, since NU7",
/// as the iPhone's Settings opens. The number moves with each new block.
private struct NetworkCard: View {
    @ObservedObject var engine: WalletEngine

    var body: some View {
        let height = engine.networkHeight
        VStack(alignment: .leading, spacing: 4) {
            Text("ZCASH NETWORK").font(Theme.text(11, weight: .semibold)).tracking(2).foregroundStyle(Theme.gold)
            Text(height > 0 ? "Block \(height.formatted(.number.grouping(.automatic).locale(Locale(identifier: "en_US"))))" : "Catching up…")
                .font(Theme.serif(28, weight: .medium)).foregroundStyle(Theme.text)
                .monospacedDigit()
            if height > 0 {
                Text(height >= NetworkUpgrade.nu7Height ? "A block every 25 seconds, since NU7" : "A block every 75 seconds")
                    .font(Theme.text(12)).foregroundStyle(Theme.muted)
            }
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Theme.surface, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).stroke(Theme.line))
        .accessibilityElement(children: .combine)
    }
}
