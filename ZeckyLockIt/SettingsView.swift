import AppKit
import SwiftUI

struct SettingsView: View {
    @ObservedObject var model: AppModel
    @ObservedObject var prices: PriceFeed
    let wallet: StoredWallet
    let onClose: () -> Void

    @State private var showingPhrase = false
    @State private var problem: String?
    @State private var confirmErase = false
    @State private var erasing = false

    @State private var serverChoice = Server.presets.firstIndex { $0.host == Server.host } ?? -1
    @State private var customServer = Server.presets.contains { $0.host == Server.host } ? "" : "\(Server.host):\(Server.port)"
    @State private var serverNote: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text(showingPhrase ? "Recovery phrase" : "Settings").font(Theme.serif(24, weight: .medium))
                Spacer()
                Button(showingPhrase ? "Hide" : "Done") {
                    if showingPhrase { showingPhrase = false } else { onClose() }
                }
                .buttonStyle(HeaderButtonStyle())
                .keyboardShortcut(.cancelAction)
            }
            .padding(.bottom, 18)

            if showingPhrase {
                PhraseView(wallet: wallet)
            } else {
                ScrollView { settings }
            }
        }
        .padding(28)
        .frame(width: 560, height: 560)
        .background(Theme.ink)
        .foregroundStyle(Theme.text)
        // The words leave the screen as soon as Zecky is not the app in front.
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didResignActiveNotification)) { _ in
            showingPhrase = false
        }
        .alert("Erase this wallet from this Mac?", isPresented: $confirmErase) {
            Button("Cancel", role: .cancel) {}
            Button("Erase", role: .destructive) { Task { await erase() } }
        } message: {
            Text("The recovery phrase, history and settings are removed from this Mac. Without your 24 words on paper, the money in this wallet cannot be recovered.")
        }
    }

    private var settings: some View {
        VStack(alignment: .leading, spacing: 22) {
            section("Security") {
                Button("Show recovery phrase") { Task { await showPhrase() } }
                Text("Asks for Touch ID or your Mac password first.").font(.system(size: 12)).foregroundStyle(Theme.muted)
            }

            section("Server") {
                Picker("", selection: $serverChoice) {
                    ForEach(Server.presets.indices, id: \.self) { i in
                        Text("\(Server.presets[i].label) · \(Server.presets[i].host)").tag(i)
                    }
                    Text("Your own server").tag(-1)
                }
                .labelsHidden()
                .frame(width: 320)
                if serverChoice == -1 {
                    TextField("host:port", text: $customServer)
                        .textFieldStyle(.roundedBorder).frame(width: 320).autocorrectionDisabled()
                }
                HStack {
                    Button("Use this server") { Task { await applyServer() } }
                    if let serverNote { Text(serverNote).font(.system(size: 12)).foregroundStyle(Theme.muted) }
                }
                Text("Encrypted (TLS). The server sees this Mac's internet address, never your phrase or balance.")
                    .font(.system(size: 12)).foregroundStyle(Theme.muted)
            }

            section("Value") {
                Picker("", selection: $prices.currency) {
                    ForEach(PriceFeed.Currency.allCases) { Text($0.label).tag($0) }
                }
                .labelsHidden()
                .frame(width: 320)
                Text("Shows what your Zcash is worth under the balance. The price comes from CoinGecko every 5 minutes; CoinGecko sees this Mac's internet address, never anything about your wallet.")
                    .font(.system(size: 12)).foregroundStyle(Theme.muted)
                    .fixedSize(horizontal: false, vertical: true)
            }

            section("Erase wallet") {
                Button(erasing ? "Erasing…" : "Erase this wallet…") { Task { await askErase() } }
                    .foregroundStyle(Theme.red)
                    .disabled(erasing)
                Text("Removes the phrase, history and settings from this Mac. Make sure your 24 words are on paper first.")
                    .font(.system(size: 12)).foregroundStyle(Theme.muted)
            }

            section("About") {
                Text("Zecky Lock it for Mac \(version)").font(.system(size: 13)).foregroundStyle(Theme.muted)
            }

            if let problem { Text(problem).foregroundStyle(Theme.red) }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func section<Content: View>(_ title: String, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title.uppercased()).font(.system(size: 11, weight: .semibold)).tracking(1.2).foregroundStyle(Theme.muted)
            content()
        }
    }

    private var version: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? ""
    }

    private func showPhrase() async {
        problem = nil
        if await OwnerCheck.confirm(reason: "show your recovery phrase") { showingPhrase = true }
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
                    .padding(.vertical, 7).padding(.horizontal, 8)
                    .background(Theme.surface)
                    .clipShape(RoundedRectangle(cornerRadius: 6))
                }
            }
            Text("The words leave the screen when you click Hide, close Settings or switch to another app.")
                .font(.system(size: 12)).foregroundStyle(Theme.muted)
            Spacer()
        }
    }
}
