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
            Text("An earlier year finds everything but takes longer to scan.")
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
                birthday = (try? await ChainTip.latest()) ?? Birthday.estimatedTip()
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
