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
                      closeLabel: showingPhrase ? "Hide" : (codeStep != nil || page != nil ? "Back" : "Done"),
                      height: 740,
                      onClose: { if showingPhrase { revealed = nil } else if codeStep != nil { codeStep = nil } else if page != nil { page = nil } else { onClose() } }) {
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

    // MARK: Pages

    /// Settings is a calm list; each topic opens its own page.
    enum Page: Hashable { case keys, timeLock, phrase, addressBook, display, network, how, about }
    @State private var page: Page?

    private var settings: some View {
        VStack(alignment: .leading, spacing: 12) {
            switch page {
            case nil: overview
            case .keys?: pageBody { keysPage }
            case .timeLock?: pageBody { timeLockPage }
            case .phrase?: pageBody { phrasePage }
            case .addressBook?: pageBody { addressBookPage }
            case .display?: pageBody { displayPage }
            case .network?: pageBody { networkPage }
            case .how?: pageBody { HowItWorks() }
            case .about?: pageBody { aboutPage }
            }
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
            group("Security") {
                row(.keys, "Keys to the lock", "key.fill", keysSummary)
                row(.timeLock, "Time lock", "clock", TimeLock.isOn ? TimeLock.label(TimeLock.hours) : "Off")
                row(.phrase, "Recovery phrase", "doc.text.magnifyingglass", WalletVault.kind == .secureEnclave ? "Sealed in the Secure Enclave" : "In the Keychain")
                row(.addressBook, "Address book", "person.crop.circle", addressSummary)
            }
            group("This Mac") {
                row(.display, "Display", "circle.lefthalf.filled", "\(model.themeMode.label) · Value \(prices.currency.short)")
                row(.network, "Network", "server.rack", Server.isRockIt ? "Rock it · \(Server.host)" : Server.host)
            }
            group("Lock it") {
                row(.how, "How Zecky works", "book.closed", "The lock, the keys, your privacy")
                row(.about, "About", "info.circle", "Version \(version) · your Zcash by pool")
            }
            // Erase, on its own, with a red edge.
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

        }
    }

    private var keysSummary: String {
        var parts: [String] = []
        if Keys.askOpeningZecky { parts.append("Opening Zecky") }
        if Keys.wait > 0 { parts.append("\(Keys.wait) s pause") }
        if Keys.askOpeningLock { parts.append("It's you") }
        if WalletVault.hasCode { parts.append("Zecky code") }
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
        Button { page = target } label: {
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

    @ViewBuilder private var keysPage: some View {
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
                HStack(alignment: .center, spacing: 14) {
                    Text(sealNote + " Why: the 24 words are the wallet. Sealed in the chip, they cannot be read from a copy of this Mac's files.")
                        .font(Theme.text(12)).foregroundStyle(Theme.muted)
                        .fixedSize(horizontal: false, vertical: true)
                    Spacer()
                    SecondaryButton(title: "Show recovery phrase") { Task { await showPhrase() } }.frame(width: 200)
                }
            }

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
                Text(Server.isRockIt
                     ? "Rock it, your own node. On a home address there is no TLS layer: the traffic stays in your home network, and Tailscale encrypts it on the way."
                     : "Encrypted (TLS). The server sees this Mac's internet address, never your phrase or balance. Your own node on a home or Tailscale address is used as Rock it.")
                    .font(Theme.text(12)).foregroundStyle(Theme.muted)
                    .fixedSize(horizontal: false, vertical: true)
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
            }

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
        case .erase: return "Erase this wallet"
        case .guarded: return "Confirm it's you"
        case nil: break
        }
        switch page {
        case .keys?: return "Keys to the lock"
        case .timeLock?: return "Time lock"
        case .phrase?: return "Recovery phrase"
        case .addressBook?: return "Address book"
        case .display?: return "Display"
        case .network?: return "Network"
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
        case .phrase?: return "Your 24 words, sealed on this Mac."
        case .addressBook?: return "Addresses you trust, to release to by name."
        case .display?: return "How Lock it looks on this Mac."
        case .network?: return "Where Lock it gets the Zcash chain from."
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
                pool("Sapling", "Older private pool, still usable.", engine.pools.sapling)
                pool("Transparent", "Public. Lock it in from home if any arrives.", engine.pools.transparent)
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
    private let chapters: [(String, String, [String])] = [
        ("The lock", "lock.fill", [
            "Lock more gives you a private address. Zcash sent to it locks in by itself and shows on the lock.",
            "Opening the lock takes a deliberate moment: the pause, your keys, and then Release. The lock closes again after a release, after 2 minutes, or when you hide Lock it.",
            "Nothing ever leaves without a receipt first: who receives what, the network fee, and what stays locked.",
        ]),
        ("Keys to the lock", "key.fill", [
            "One, two or three keys, you choose: 1 Opening Zecky, 2 Really open the lock?, 3 It's you. The Zecky code adds six digits that this Mac's Secure Enclave checks itself.",
            "Showing your 24 words and erasing always ask, whatever you choose.",
            "Making a key stricter goes straight through; weakening one asks you first. Every change is listed in Activity › The lock.",
        ]),
        ("Time lock and Break the glass", "clock", [
            "With a time lock, opening has to be asked for 24 hours, 3 or 7 days ahead. Turning it off or shorter waits as long as the current time lock.",
            "In an emergency, Break the glass opens straight away after a typed sentence, your Zecky code and Touch ID, and switches the time lock off. It stays on record in Activity.",
            "A time lock does not stop someone who has your 24 words.",
        ]),
        ("Your recovery phrase", "doc.text.magnifyingglass", [
            "Your 24 words are made on this Mac from the system's secure random generator (256 bits), checked, and mixed with a second source.",
            "They are sealed with a key inside this Mac's Secure Enclave. Only Touch ID or your Mac password (and your Zecky code, if set) opens the seal. They are never synced, never in a backup, never written to a log, and never sent anywhere.",
            "They are opened only to sign a release or to show them to you, and let go straight after. While they are on screen, screenshots and screen sharing show an empty window.",
            "Your history (amounts and dates, never the words) is kept in Lock it's own protected folder on this Mac and left out of Time Machine. Keep FileVault on (System Settings › Privacy & Security) so the whole disk is encrypted as well.",
        ]),
        ("Privacy", "shield.lefthalf.filled", [
            "Lock it only hands out shielded addresses: amounts, senders and receivers stay private on the blockchain.",
            "Once an address has been paid, a fresh one appears, so payments cannot be linked to each other.",
            "Zcash that arrives on a public address (only possible after restoring) can be locked in with one step.",
        ]),
        ("Network", "server.rack", [
            "Lock it talks to one Zcash server (zec.rocks by default) over an encrypted connection. The server sees this Mac's internet address, never your words or your balance.",
            "Your own node (Rock it) on a home or Tailscale address is reached without that layer: at home the traffic stays in your network, and Tailscale encrypts it on the way.",
            "Value is off unless you choose a currency. Then CoinGecko is asked for the price every 5 minutes and sees only this Mac's internet address. There are no accounts, no analytics and no tracking.",
            "Only a wallet that holds Sapling or public Zcash (usually one restored from another app) needs the Zcash parameter files once, about 50 MB from download.z.cash, the Zcash developers' own download server. It sees this Mac's internet address, nothing about your wallet.",
        ]),
        ("If you lose this Mac", "arrow.counterclockwise", [
            "Your 24 words and birthday block restore the wallet in Lock it or any Zcash wallet.",
            "The Zecky code, time lock, address book and settings live on this Mac only and do not come back with a restore.",
        ]),
    ]

    @State private var open: Set<String> = ["The lock"]

    var body: some View {
        VStack(spacing: 8) {
            ForEach(chapters, id: \.0) { title, icon, lines in
                VStack(alignment: .leading, spacing: 10) {
                    Button { if open.contains(title) { open.remove(title) } else { open.insert(title) } } label: {
                        HStack(spacing: 10) {
                            Image(systemName: icon).foregroundStyle(Theme.gold).frame(width: 20)
                            Text(title).font(Theme.text(14, weight: .semibold)).foregroundStyle(Theme.text)
                            Spacer()
                            Image(systemName: open.contains(title) ? "chevron.up" : "chevron.down")
                                .font(.system(size: 11, weight: .semibold)).foregroundStyle(Theme.muted)
                        }
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    if open.contains(title) {
                        ForEach(lines, id: \.self) { line in
                            Text(line).font(Theme.text(13)).foregroundStyle(Theme.muted)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                    }
                }
                .card(padding: 14)
            }
        }
    }
}
