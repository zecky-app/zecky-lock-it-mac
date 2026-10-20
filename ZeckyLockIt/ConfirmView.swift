import SwiftUI

/// Three words from the paper, to make sure the backup is right.
struct ConfirmView: View {
    let wallet: StoredWallet
    let onBack: () -> Void
    let onDone: () -> Void

    @State private var positions: [Int] = Array((0..<24).shuffled().prefix(3)).sorted()
    @State private var answers = ["", "", ""]
    @State private var wrong = false

    private var words: [String] { wallet.phrase.split(separator: " ").map(String.init) }

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            Text("Check your paper").font(Theme.serif(26, weight: .medium))
            Text("Type these words from what you wrote down.").foregroundStyle(Theme.muted)
            ForEach(0..<3, id: \.self) { i in
                HStack {
                    Text("Word \(positions[i] + 1)").frame(width: 80, alignment: .leading).foregroundStyle(Theme.muted)
                    TextField("", text: $answers[i])
                        .textFieldStyle(.roundedBorder)
                        .autocorrectionDisabled()
                        .frame(width: 220)
                }
            }
            if wrong {
                Text("That doesn’t match. Check the paper against the words and try again.").foregroundStyle(Theme.red)
            }
            Spacer()
            HStack {
                SecondaryButton(title: "Show the words again", action: onBack).frame(width: 220)
                Spacer()
                PrimaryButton(title: "Done", enabled: answers.allSatisfy { !$0.isEmpty }) {
                    let ok = (0..<3).allSatisfy { Mnemonic.normalize(answers[$0]) == words[positions[$0]] }
                    if ok { onDone() } else { wrong = true }
                }
                .frame(width: 160)
            }
        }
        .padding(32)
    }
}
