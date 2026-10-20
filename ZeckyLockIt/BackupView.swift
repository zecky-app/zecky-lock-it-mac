import SwiftUI

/// The 24 words and the birthday, shown once after creating a wallet.
struct BackupView: View {
    let wallet: StoredWallet
    let onNext: () -> Void

    private var words: [String] { wallet.phrase.split(separator: " ").map(String.init) }

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            Text("Write these words down").font(Theme.serif(26, weight: .medium))
            Text("On paper, in this order. Whoever has these words has your money. Zecky never sends them anywhere, and nobody can recover them for you.")
                .foregroundStyle(Theme.muted)
                .fixedSize(horizontal: false, vertical: true)
            HStack(spacing: 6) {
                Text("Birthday block").foregroundStyle(Theme.muted)
                Text(wallet.birthday.formatted(.number.locale(Locale(identifier: "en_US"))))
                    .font(.system(.body, design: .monospaced))
                Text("· write it under the words").foregroundStyle(Theme.muted)
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
            Spacer()
            HStack { Spacer(); PrimaryButton(title: "I wrote them down", action: onNext).frame(width: 220) }
        }
        .padding(32)
    }
}
