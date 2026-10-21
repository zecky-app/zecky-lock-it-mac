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
    private enum CodeStep { case phrase, setUp, change, remove, erase }
    @State private var codeStep: CodeStep?
    @State private var pendingPhrase: StoredWallet?
    @State private var codeNote: String?
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
        .alert("Erase this wallet from this Mac?", isPresented: $confirmErase) {
            Button("Cancel", role: .cancel) {}
            Button("Erase", role: .destructive) { Task { await erase() } }
        } message: {
            Text("The recovery phrase, history and settings are removed from this Mac. Without your 24 words on paper, the money in this wallet cannot be recovered.")
        }
    }

    private var settings: some View {
        VStack(alignment: .leading, spacing: 12) {
            card("Security", icon: "key.fill") {
                HStack {
                    Text(sealNote).font(Theme.text(12)).foregroundStyle(Theme.muted)
                    Spacer()
                    SecondaryButton(title: "Show recovery phrase") { Task { await showPhrase() } }.frame(width: 200)
                }
            }

            if WalletVault.canUseCode {
                card("Code on the lock", icon: "lock.rotation") {
                    VStack(alignment: .leading, spacing: 10) {
                        Text(WalletVault.hasCode
                             ? "On. Six digits, asked with Touch ID before releasing, showing your 24 words and unlocking."
                             : "Optional. Six digits on top of Touch ID, so someone who knows your Mac password still cannot open the lock.")
                            .font(Theme.text(12)).foregroundStyle(Theme.muted)
                            .fixedSize(horizontal: false, vertical: true)
                        if let codeNote { Text(codeNote).font(Theme.text(12)).foregroundStyle(Theme.green) }
                        HStack(spacing: 10) {
                            Spacer()
                            if WalletVault.hasCode {
                                SecondaryButton(title: "Remove code") { codeNote = nil; codeStep = .remove }.frame(width: 150)
                                SecondaryButton(title: "Change code") { codeNote = nil; codeStep = .change }.frame(width: 150)
                            } else {
                                SecondaryButton(title: "Put a code on the lock") { codeNote = nil; codeStep = .setUp }.frame(width: 210)
                            }
                        }
                    }
                }
            }

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

            card("Server", icon: "server.rack") {
                FlowChips(items: Server.presets.indices.map { ($0, Server.presets[$0].label) } + [(-1, "Your own")],
                          selected: serverChoice) { serverChoice = $0 }
                Text(serverChoice >= 0 ? Server.presets[serverChoice].host + ":443" : "Your own server, with TLS")
                    .font(.system(size: 12, design: .monospaced)).foregroundStyle(Theme.muted)
                if serverChoice == -1 {
                    TextField("", text: $customServer, prompt: Text("host:port").foregroundColor(Theme.muted))
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
                Text("Encrypted (TLS). The server sees this Mac's internet address, never your phrase or balance.")
                    .font(Theme.text(12)).foregroundStyle(Theme.muted)
            }

            card("About", icon: "info.circle") {
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    Text("ZECKY").font(Theme.text(12, weight: .semibold)).tracking(4).foregroundStyle(Theme.gold)
                    Text("Lock it for Mac \(version)").font(Theme.serif(15))
                }
                Text("Self-custody Zcash. Your keys stay in this Mac's Keychain. zecky.app")
                    .font(Theme.text(12)).foregroundStyle(Theme.muted)
            }

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

    private var sheetTitle: String {
        if showingPhrase { return "Recovery phrase" }
        switch codeStep {
        case .phrase: return "Show recovery phrase"
        case .setUp: return "Put a code on the lock"
        case .change: return "Change the code"
        case .remove: return "Remove the code"
        case .erase: return "Erase this wallet"
        case nil: return "Settings"
        }
    }

    private var sheetSubtitle: String {
        if showingPhrase { return "Only for you. Check it against your paper." }
        switch codeStep {
        case .phrase, .remove, .erase:
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
