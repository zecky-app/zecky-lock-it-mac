import SwiftUI
import ZcashLightClientKit

/// Adds a wallet with its own 24 words to the key ring on this Mac: new, or
/// restored from words. Opened only while the main lock is open; its words
/// are sealed with the main lock (see KeyRingVault).
struct AddWalletSheet: View {
    @ObservedObject var model: AppModel
    @ObservedObject var engine: WalletEngine
    let kind: AppModel.Adding
    let onClose: () -> Void

    @State private var name = ""
    @State private var words: [String] = []
    @State private var restoreText = ""
    @State private var year = Calendar.current.component(.year, from: Date())
    /// "I wrote them down" pressed: the three-word check is shown.
    @State private var checking = false
    /// The three words were typed back correctly.
    @State private var checked = false
    @State private var working = false
    @State private var problem: String?

    private var isNew: Bool { kind == .new }

    var body: some View {
        SheetScaffold(title: isNew ? "New wallet" : "Restore a wallet",
                      subtitle: isNew
                        ? "A second wallet on this Mac, with its own 24 words, behind the same lock."
                        : "Bring in a wallet from its 24 words. It sits behind the same lock.",
                      closeLabel: "Cancel", width: 600, height: 700, onClose: onClose) {
            VStack(alignment: .leading, spacing: 14) {
                TextField("Name, e.g. Savings or Daily", text: $name)
                    .textFieldStyle(.roundedBorder)

                if isNew { newWords } else { restoreForm }

                if let problem {
                    Text(problem).font(Theme.text(12)).foregroundStyle(Theme.red)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer()
                PrimaryButton(title: working ? "Adding…" : (isNew ? "Add to the key ring" : "Restore to the key ring"),
                              enabled: canAdd && !working) {
                    Task { await add() }
                }
            }
        }
        .hiddenFromCapture()
        .task {
            if isNew && words.isEmpty {
                do {
                    words = try Mnemonic.phrase(from: Entropy.secure(32)).split(separator: " ").map(String.init)
                } catch {
                    // Never a weaker fallback: no words, and the reason.
                    problem = String(describing: error)
                }
            }
        }
        .onDisappear { words = []; restoreText = "" }
    }

    // MARK: New

    private var newWords: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Write these 24 words on paper, in order. They are the only way back to this wallet.")
                .font(Theme.text(13)).foregroundStyle(Theme.muted)
                .fixedSize(horizontal: false, vertical: true)
            if checked {
                Label("The 24 words are written down and checked.", systemImage: "checkmark.seal.fill")
                    .font(Theme.text(13, weight: .medium)).foregroundStyle(Theme.green)
            } else if checking {
                WordCheck(words: words, onShowAgain: { checking = false }, onPassed: { checked = true })
            } else {
                HoldToReveal {
                    LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 8), count: 4), spacing: 8) {
                        ForEach(Array(words.enumerated()), id: \.offset) { index, word in
                            HStack(spacing: 6) {
                                Text("\(index + 1)").font(Theme.text(11)).foregroundStyle(Theme.muted).frame(width: 18, alignment: .trailing)
                                Text(word).font(Theme.text(13, weight: .medium))
                                Spacer(minLength: 0)
                            }
                            .padding(.horizontal, 8).frame(height: 28)
                            .background(Theme.surface, in: RoundedRectangle(cornerRadius: 6))
                            .overlay(RoundedRectangle(cornerRadius: 6).stroke(Theme.line, lineWidth: 1))
                        }
                    }
                }
                HStack {
                    Spacer()
                    SecondaryButton(title: "I wrote the 24 words down") { checking = true }
                        .frame(width: 240)
                        .disabled(words.count != 24)
                }
            }
        }
    }

    // MARK: Restore

    private var restoreForm: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("The 24 words, separated by spaces.")
                .font(Theme.text(13)).foregroundStyle(Theme.muted)
            TextEditor(text: $restoreText)
                .font(Theme.text(14))
                .frame(height: 110)
                .padding(6)
                .background(Theme.surface, in: RoundedRectangle(cornerRadius: 8))
                .overlay(RoundedRectangle(cornerRadius: 8).stroke(Theme.line, lineWidth: 1))
            Text("\(restoreWords.count) of 24 words")
                .font(Theme.text(12)).foregroundStyle(restoreWords.count == 24 ? Theme.green : Theme.muted)
            HStack {
                Text("First used in").font(Theme.text(13))
                Stepper("\(String(year))", value: $year, in: 2018...Calendar.current.component(.year, from: Date()))
                    .font(Theme.text(13, weight: .medium))
            }
            Text("An earlier year finds everything but takes longer: Lock it then checks every block from that year again, for all wallets on this Mac. Their Zcash stays safe meanwhile.")
                .font(Theme.text(11)).foregroundStyle(Theme.muted)
        }
    }

    private var restoreWords: [String] {
        restoreText.lowercased().split(whereSeparator: { $0 == " " || $0 == "\n" || $0 == "," }).map(String.init)
    }

    // MARK: Add

    private var trimmedName: String { name.trimmingCharacters(in: .whitespacesAndNewlines) }

    private var canAdd: Bool {
        guard !trimmedName.isEmpty else { return false }
        return isNew ? (checked && words.count == 24) : restoreWords.count == 24
    }

    private func add() async {
        working = true
        problem = nil
        defer { working = false }
        guard let main = model.openedPhrase else {
            problem = "The lock closed. Open it again to add a wallet."
            return
        }
        do {
            let phrase: String
            let birthday: Int
            if isNew {
                phrase = words.joined(separator: " ")
                // Today's block, as the running engine knows it. Adding a wallet
                // makes the engine check every block from its start again for
                // all wallets, so a new wallet must start at today's block.
                if engine.networkHeight > 0 {
                    birthday = engine.networkHeight
                } else {
                    birthday = (try? await ChainTip.latest()) ?? Birthday.estimatedTip()
                }
            } else {
                let joined = restoreWords.joined(separator: " ")
                try Mnemonic.validate(joined)
                phrase = Mnemonic.normalize(joined)
                let tip = (try? await ChainTip.latest()) ?? Birthday.estimatedTip()
                birthday = max(Birthday.earliest, Birthday.estimate(year: year, month: 1, tip: tip))
            }
            if phrase == main { throw AddError.sameAsMain }
            let id = try await engine.addMacWallet(name: trimmedName, phrase: phrase, birthday: birthday)
            do {
                try KeyRingVault.add(id: id, name: trimmedName, phrase: phrase, birthday: birthday, mainPhrase: main)
            } catch {
                try? await engine.removeWallet(id)
                throw error
            }
            LockLog.add(.keys, "Wallet \"\(trimmedName)\" added to the key ring")
            model.selectedWallet = id
            onClose()
        } catch let failure as Mnemonic.Failure {
            problem = failure.description
        } catch {
            problem = String(describing: error)
        }
    }

    enum AddError: Error, CustomStringConvertible {
        case sameAsMain
        var description: String { "These are the words of your main wallet. It is already on the key ring." }
    }
}

/// The 24 words of an extra wallet on this Mac, shown after the main lock opened.
struct WalletWordsSheet: View {
    @ObservedObject var model: AppModel
    @ObservedObject var engine: WalletEngine
    let onClose: () -> Void

    private var title: String {
        guard let id = model.selectedWallet, let wallet = engine.macWallets.first(where: { $0.id == id }) else { return "Wallet" }
        return WalletNames.name(for: wallet, fallback: "Wallet")
    }

    private var words: [String] {
        (model.opened?.phrase ?? "").split(separator: " ").map(String.init)
    }

    var body: some View {
        SheetScaffold(title: "\(title): words",
                      subtitle: "Anyone with these 24 words can take this wallet's Zcash. Keep them offline.",
                      width: 600, height: 520, onClose: onClose) {
            VStack(alignment: .leading, spacing: 14) {
                if words.count == 24 {
                    HoldToReveal {
                        LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 8), count: 4), spacing: 8) {
                            ForEach(Array(words.enumerated()), id: \.offset) { index, word in
                                HStack(spacing: 6) {
                                    Text("\(index + 1)").font(Theme.text(11)).foregroundStyle(Theme.muted)
                                        .frame(width: 18, alignment: .trailing)
                                    Text(word).font(Theme.text(13, weight: .medium))
                                    Spacer(minLength: 0)
                                }
                                .padding(.horizontal, 8).frame(height: 28)
                                .background(Theme.surface, in: RoundedRectangle(cornerRadius: 6))
                                .overlay(RoundedRectangle(cornerRadius: 6).stroke(Theme.line, lineWidth: 1))
                            }
                        }
                    }
                    if let birthday = model.opened?.birthday {
                        Text("Birthday block: \(birthday)").font(Theme.text(12)).foregroundStyle(Theme.muted)
                    }
                } else {
                    Text("The words could not be opened. Close and open the lock again.")
                        .font(Theme.text(13)).foregroundStyle(Theme.red)
                }
                Spacer()
                PrimaryButton(title: "Done", action: onClose)
            }
        }
        .hiddenFromCapture()
    }
}

/// Erasing one wallet: which one, what it holds, and what happens, before
/// anything is removed. Erase stays off until its name is typed.
struct EraseWalletSheet: View {
    @ObservedObject var model: AppModel
    @ObservedObject var engine: WalletEngine
    let onClose: () -> Void

    @State private var typed = ""
    @State private var secret = ""
    @State private var address: String?
    @State private var working = false
    @State private var problem: String?

    private var id: AccountUUID? { model.selectedWallet }
    private var kind: AppModel.EraseKind { model.eraseKind(id) }

    private var account: Account? {
        guard let id else { return engine.leadWallet }
        return (engine.macWallets + engine.sealedWallets).first { $0.id == id } ?? (engine.leadWallet?.id == id ? engine.leadWallet : nil)
    }

    private var name: String { account.map { WalletNames.display($0, lead: $0.id == engine.leadWallet?.id) } ?? "This wallet" }

    private var balance: Int64 {
        guard let account else { return 0 }
        if account.id == engine.leadWallet?.id { return engine.total }
        return engine.signerBalances[account.id]?.total ?? 0
    }

    private var needsSecret: Bool {
        if case .handOver = kind { return WalletVault.needsSecret }
        return false
    }

    private var confirmed: Bool {
        typed.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() == name.lowercased()
            && (!needsSecret || !secret.isEmpty)
    }

    var body: some View {
        SheetScaffold(title: "Erase \(name)?", subtitle: "Check that this is the right wallet.",
                      closeLabel: "Cancel", width: 560, height: 600, onClose: onClose) {
            VStack(alignment: .leading, spacing: 14) {
                VStack(spacing: 0) {
                    line("Wallet", name)
                    line("Balance", model.amountsHidden ? "••••" : Amount.text(balance, model.unit))
                    line("Address", address.map { String($0.prefix(14)) + "…" } ?? "…", last: true)
                }
                .background(Theme.surface, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
                .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).stroke(Theme.line))

                Text(explanation)
                    .font(Theme.text(13)).foregroundStyle(balance > 0 ? Theme.gold : Theme.muted)
                    .fixedSize(horizontal: false, vertical: true)

                if needsSecret {
                    SecureField(WalletVault.usesPassword ? "Your Lock it password" : "Your Zecky code", text: $secret)
                        .textFieldStyle(.roundedBorder)
                    Text("The lock passes to the next wallet with the same code.")
                        .font(Theme.text(11)).foregroundStyle(Theme.muted)
                }
                Text("Type \(name) to confirm").font(Theme.text(12, weight: .medium))
                TextField(name, text: $typed).textFieldStyle(.roundedBorder).autocorrectionDisabled()

                if let problem {
                    Text(problem).font(Theme.text(12)).foregroundStyle(Theme.red)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer()
                HStack {
                    Spacer()
                    Button { Task { await erase() } } label: {
                        Text(working ? "Erasing…" : (isEverything ? "Erase everything" : "Erase \(name)"))
                            .font(Theme.text(13, weight: .semibold)).foregroundStyle(.white)
                            .padding(.horizontal, 18).frame(height: 36)
                            .background(Theme.red.opacity(confirmed && !working ? 1 : 0.35), in: Capsule())
                            .contentShape(Capsule())
                    }
                    .buttonStyle(.plain)
                    .disabled(!confirmed || working)
                }
            }
        }
        .task {
            guard let account, let sdk = engine.sdk else { return }
            address = try? await sdk.getUnifiedAddress(accountUUID: account.id).stringEncoded
        }
        .onDisappear { secret = ""; typed = "" }
    }

    private var isEverything: Bool { if case .everything = kind { return true }; return false }

    private var explanation: String {
        let money = balance > 0 ? " It still holds Zcash: without its 24 words on paper, that Zcash cannot be recovered." : ""
        switch kind {
        case .sealed:
            return "This Seal it wallet is removed from Lock it. Its keys and Zcash stay on your offline phone; you can pair it again at any time."
        case .macWallet:
            return "Its 24 words are deleted from this Mac. The other wallets stay as they are." + money
        case .handOver(let next):
            return "Its 24 words are deleted from this Mac, and the lock passes to \(WalletNames.display(next, lead: false)). Your code, keys, time lock and settings stay. The other wallets stay as they are." + money
        case .everything:
            return "This is the last wallet with words on this Mac, so everything is erased: its words, every Seal it pairing, the address book and the settings. Lock it starts fresh." + money
        }
    }

    private func erase() async {
        working = true
        problem = nil
        defer { working = false }
        do {
            try await model.eraseWallet(id, secret: needsSecret ? secret : nil)
        } catch {
            problem = "Stopped: \(error)"
        }
    }

    private func line(_ label: String, _ value: String, last: Bool = false) -> some View {
        HStack {
            Text(label).font(Theme.text(13)).foregroundStyle(Theme.muted)
            Spacer(minLength: 12)
            Text(value).font(Theme.text(13, weight: .medium)).foregroundStyle(Theme.text)
        }
        .padding(.horizontal, 14).frame(height: 40)
        .overlay(alignment: .bottom) { if !last { Rectangle().fill(Theme.line).frame(height: 1).padding(.leading, 14) } }
    }
}
