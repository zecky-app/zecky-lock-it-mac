import AppKit
import SwiftUI

struct SettingsView: View {
    @ObservedObject var model: AppModel
    @ObservedObject var prices: PriceFeed
    let onClose: () -> Void

    /// The opened phrase, only while it is on screen.
    @State private var revealed: StoredWallet?
    private var showingPhrase: Bool { revealed != nil }
    /// A code step in place of the settings list.
    private enum CodeStep { case phrase, setUp, change, remove, erase, guarded }
    @State private var codeStep: CodeStep?
    @State private var pendingPhrase: StoredWallet?
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
    @State private var customServer = Server.presets.contains { $0.host == Server.host } ? "" : "\(Server.host):\(Server.port)"
    @State private var serverNote: String?

    var body: some View {
        SheetScaffold(title: sheetTitle,
                      subtitle: sheetSubtitle,
                      closeLabel: showingPhrase ? "Hide" : (codeStep != nil ? "Back" : "Done"),
                      height: 740,
                      onClose: { if showingPhrase { revealed = nil } else if codeStep != nil { codeStep = nil } else { onClose() } }) {
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
        .alert("Erase this wallet from this Mac?", isPresented: $confirmErase) {
            Button("Cancel", role: .cancel) {}
            Button("Erase", role: .destructive) { Task { await erase() } }
        } message: {
            Text("The recovery phrase, history and settings are removed from this Mac. Without your 24 words on paper, the money in this wallet cannot be recovered.")
        }
    }

    private var settings: some View {
        VStack(alignment: .leading, spacing: 12) {
            section("Security", "One, two or three keys: you choose.")
            card("Keys to the lock", icon: "key.fill") {
                VStack(alignment: .leading, spacing: 14) {
                    keyRow(1, "Opening Zecky",
                           "Touch ID or your Mac password when Lock it starts, and after it locked itself. Why: your balance and history stay private on a shared or unattended Mac.") {
                        Toggle("Ask", isOn: Binding(get: { askZecky }, set: { changeAskZecky($0) }))
                            .toggleStyle(.switch).labelsHidden()
                    }
                    Rectangle().fill(Theme.line).frame(height: 1)
                    keyRow(2, "Really open the lock?",
                           "A short pause with a question before the lock opens. Why: scams work by rushing you; a few seconds is often enough to notice.") {
                        HStack(spacing: 6) {
                            ForEach(Keys.waits, id: \.self) { w in
                                Chip(title: Keys.waitLabel(w), on: wait == w) { changeWait(w) }
                            }
                        }
                    }
                    Rectangle().fill(Theme.line).frame(height: 1)
                    keyRow(3, "It's you",
                           "Touch ID or your Mac password again when you open the lock, even right after opening Zecky. Why: someone at your unlocked Mac still cannot take anything out.") {
                        Toggle("Ask", isOn: Binding(get: { askLock }, set: { changeAskLock($0) }))
                            .toggleStyle(.switch).labelsHidden()
                    }
                    if WalletVault.canUseCode {
                        VStack(alignment: .leading, spacing: 8) {
                            HStack {
                                Label("Zecky code", systemImage: "lock.rotation")
                                    .font(Theme.text(13, weight: .semibold)).labelStyle(GoldIconLabelStyle())
                                Spacer()
                                Text(WalletVault.hasCode ? "On" : "Off")
                                    .font(Theme.text(12, weight: .semibold))
                                    .foregroundStyle(WalletVault.hasCode ? Theme.green : Theme.muted)
                            }
                            Text("Six digits on the brass dials, asked together with Touch ID. Why: someone who knows your Mac password still cannot open the lock. This Mac's Secure Enclave checks the code itself.")
                                .font(Theme.text(12)).foregroundStyle(Theme.muted)
                                .fixedSize(horizontal: false, vertical: true)
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
                        .padding(12)
                        .background(Theme.ink, in: RoundedRectangle(cornerRadius: 10))
                        .overlay(RoundedRectangle(cornerRadius: 10).stroke(Theme.line))
                    }
                    Text("Always asked, whatever you choose: showing the recovery phrase and erasing. Making a key stricter needs nothing; weakening one asks you first.")
                        .font(Theme.text(11)).foregroundStyle(Theme.muted)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }

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

            card("Recovery phrase", icon: "doc.text.magnifyingglass") {
                HStack(alignment: .center, spacing: 14) {
                    Text(sealNote + " Why: the 24 words are the wallet. Sealed in the chip, they cannot be read from a copy of this Mac's files.")
                        .font(Theme.text(12)).foregroundStyle(Theme.muted)
                        .fixedSize(horizontal: false, vertical: true)
                    Spacer()
                    SecondaryButton(title: "Show recovery phrase") { Task { await showPhrase() } }.frame(width: 200)
                }
            }

            section("Address book", "Addresses you trust, to release to by name.")
            card("Saved addresses", icon: "person.crop.circle") {
                ContactsCard(guarded: { reason, action in Task { await guarded(reason, action) } },
                             changed: { model.timeLockChanged += 1 })
            }

            section("Display", "How Lock it looks on this Mac.")
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

            section("Network", "Where Lock it gets the Zcash chain from.")
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
                Text(Server.isRockIt
                     ? "Rock it, your own node. On a home address there is no TLS layer: the traffic stays in your home network, and Tailscale encrypts it on the way."
                     : "Encrypted (TLS). The server sees this Mac's internet address, never your phrase or balance. Your own node on a home or Tailscale address is used as Rock it.")
                    .font(Theme.text(12)).foregroundStyle(Theme.muted)
                    .fixedSize(horizontal: false, vertical: true)
            }

            section("About", nil)
            card("About", icon: "info.circle") {
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    Text("ZECKY").font(Theme.text(12, weight: .semibold)).tracking(4).foregroundStyle(Theme.gold)
                    Text("Lock it for Mac \(version)").font(Theme.serif(15))
                }
                Text("Self-custody Zcash. Your keys stay in this Mac's Keychain. zecky.app")
                    .font(Theme.text(12)).foregroundStyle(Theme.muted)
            }

            section("Erase", nil)
            // Erase, in its own card with a red edge.
            VStack(alignment: .leading, spacing: 10) {
                Label("Erase wallet", systemImage: "trash").font(Theme.text(13, weight: .semibold)).foregroundStyle(Theme.red)
                Text("Removes the phrase, history and settings from this Mac. Make sure your 24 words are on paper first.")
                    .font(Theme.text(12)).foregroundStyle(Theme.muted)
                    .fixedSize(horizontal: false, vertical: true)
                Button { Task { await askErase() } } label: {
                    Text(erasing ? "Erasing…" : "Erase this wallet…")
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

            if let problem { Text(problem).font(Theme.text(12)).foregroundStyle(Theme.red) }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
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
        case .erase: return "Erase this wallet"
        case .guarded: return "Confirm it's you"
        case nil: return "Settings"
        }
    }

    private var sheetSubtitle: String {
        if showingPhrase { return "Only for you. Check it against your paper." }
        switch codeStep {
        case .phrase, .remove, .erase, .guarded:
            return WalletVault.usesPassword ? "Your Lock it password first." : "Your code, then Touch ID or your Mac password."
        case .setUp, .change: return "Sealed with your phrase in this Mac's Secure Enclave."
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
                               pendingPhrase = wallet
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

    private func showPhrase() async {
        problem = nil
        if WalletVault.needsSecret { codeStep = .phrase; return }
        do { revealed = try await WalletVault.unseal(reason: "show your recovery phrase") }
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
        Server.set(host: host, port: port)
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
        if await OwnerCheck.confirm(reason: "erase this wallet") { confirmErase = true }
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
            Text("Screenshots and screen sharing show an empty window. The words leave the screen when you click Hide, close Settings or switch to another app.")
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
