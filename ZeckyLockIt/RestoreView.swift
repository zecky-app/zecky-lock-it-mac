import SwiftUI

/// Restore from 24 words plus a birthday block or month.
struct RestoreView: View {
    @ObservedObject var model: AppModel
    @State private var phrase = ""
    @State private var useBlock = false
    @State private var block = ""
    @State private var year = Calendar.current.component(.year, from: Date())
    @State private var month = 0 // 0 = not sure
    @State private var working = false

    private let years = Array((2018...Calendar.current.component(.year, from: Date())).reversed())
    private let months = ["Not sure"] + Calendar(identifier: .gregorian).monthSymbols

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Restore a wallet").font(Theme.serif(26, weight: .medium))
            Text("Type or paste your 24 words, separated by spaces.").foregroundStyle(Theme.muted)
            TextEditor(text: $phrase)
                .font(.system(size: 14, design: .monospaced))
                .autocorrectionDisabled()
                .scrollContentBackground(.hidden)
                .padding(8)
                .background(Theme.surface)
                .clipShape(RoundedRectangle(cornerRadius: 8))
                .frame(height: 110)

            Text("When was the wallet made?").font(.system(size: 14, weight: .semibold))
            if useBlock {
                TextField("Birthday block", text: $block).textFieldStyle(.roundedBorder).frame(width: 220)
                Text("The birthday block, as written under your words.").font(.system(size: 12)).foregroundStyle(Theme.muted)
            } else {
                HStack {
                    Picker("Year", selection: $year) { ForEach(years, id: \.self) { Text(String($0)).tag($0) } }.frame(width: 160)
                    Picker("Month", selection: $month) { ForEach(0..<months.count, id: \.self) { Text(months[$0]).tag($0) } }.frame(width: 220)
                }
                Text("It makes syncing much faster. If you are not sure of the month, Zecky starts at the beginning of the year.")
                    .font(.system(size: 12)).foregroundStyle(Theme.muted)
            }
            Button(useBlock ? "Pick a date instead" : "Enter a block height instead") { useBlock.toggle() }
                .buttonStyle(.link)

            if let message = model.message { Text(message).foregroundStyle(Theme.red) }
            Spacer()
            HStack {
                SecondaryButton(title: "Back") { model.message = nil; model.screen = .welcome }.frame(width: 140)
                Spacer()
                PrimaryButton(title: working ? "Restoring…" : "Restore", enabled: !working && !phrase.isEmpty) {
                    Task { await submit() }
                }
                .frame(width: 180)
            }
        }
        .padding(32)
    }

    private func submit() async {
        model.message = nil
        working = true
        defer { working = false }
        var birthday = Birthday.earliest
        if useBlock {
            let digits = block.filter { !" ,.'’".contains($0) }
            if !digits.isEmpty {
                guard let parsed = Int(digits), parsed >= Birthday.earliest else {
                    model.message = "The block height must be a whole number of \(Birthday.earliest) or higher. Leave it empty if you are unsure."
                    return
                }
                birthday = parsed
            }
        } else {
            let tip = (try? await ChainTip.latest()) ?? Birthday.estimatedTip()
            birthday = Birthday.estimate(year: year, month: max(month, 1), tip: tip)
        }
        model.restore(phrase: phrase, birthday: birthday)
    }
}
