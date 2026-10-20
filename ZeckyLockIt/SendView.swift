import SwiftUI

/// Send: recipient and amount, then a review of every number before
/// anything leaves the wallet.
struct SendView: View {
    @ObservedObject var engine: WalletEngine
    let phrase: String
    let onClose: () -> Void

    private enum Stage { case form, review(WalletEngine.SendPlan), sending, done(WalletEngine.SendOutcome) }

    @State private var stage: Stage = .form
    @State private var to = ""
    @State private var amountText = ""
    @State private var max = false
    @State private var problem: String?
    @State private var working = false
    @State private var waiting = false

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack {
                Text(title).font(Theme.serif(24, weight: .medium))
                Spacer()
                if case .sending = stage {} else { Button("Close", action: onClose).keyboardShortcut(.cancelAction) }
            }
            switch stage {
            case .form: form
            case .review(let plan): review(plan)
            case .sending: VStack { Spacer(); ProgressView("Sending…"); Spacer() }.frame(maxWidth: .infinity)
            case .done(let outcome): done(outcome)
            }
        }
        .padding(28)
        .frame(width: 540, height: 520)
        .background(Theme.ink)
        .foregroundStyle(Theme.text)
        .task { waiting = await engine.hasWaitingPayment() }
    }

    private var title: String {
        switch stage {
        case .form: return "Send"
        case .review: return "Check before sending"
        case .sending: return "Sending"
        case .done(.sent): return "Sent"
        case .done(.saved): return "Payment saved"
        }
    }

    private var form: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("To").font(.system(size: 13, weight: .semibold))
            TextField("Zcash address", text: $to)
                .textFieldStyle(.roundedBorder)
                .font(.system(size: 13, design: .monospaced))
                .autocorrectionDisabled()
            Text("Amount").font(.system(size: 13, weight: .semibold))
            HStack {
                TextField("0.000", text: $amountText)
                    .textFieldStyle(.roundedBorder)
                    .frame(width: 180)
                    .disabled(max)
                Text("ZEC").foregroundStyle(Theme.muted)
                Toggle("Max", isOn: $max).toggleStyle(.button)
                Spacer()
            }
            Text("Available: \(Amount.zec(engine.spendable)) ZEC")
                .font(.system(size: 12)).foregroundStyle(Theme.muted)
            if waiting {
                Text("A payment you made is still on its way. Wait for it to arrive before sending it again.")
                    .font(.system(size: 12)).foregroundStyle(Theme.gold)
            }
            if engine.status != .upToDate {
                Text("Wait until the wallet is up to date. Nothing is created until then.")
                    .font(.system(size: 12)).foregroundStyle(Theme.gold)
            }
            if let problem { Text(problem).foregroundStyle(Theme.red) }
            Spacer()
            HStack {
                Spacer()
                PrimaryButton(title: working ? "Checking…" : "Review",
                              enabled: !working && engine.status == .upToDate && !to.isEmpty && (max || !amountText.isEmpty)) {
                    Task { await makePlan() }
                }
                .frame(width: 180)
            }
        }
    }

    private func review(_ plan: WalletEngine.SendPlan) -> some View {
        let total = plan.amount + plan.fee
        let left = engine.spendable - total
        return VStack(alignment: .leading, spacing: 12) {
            row("To", plan.toSelf ? "Yourself" : short(plan.to), mono: !plan.toSelf)
            row("Amount", "\(Amount.zec(plan.amount)) ZEC")
            row("Fee", "\(Amount.zec(plan.fee)) ZEC")
            Divider()
            row("Total", "\(Amount.zec(total)) ZEC", strong: true)
            row("Left after this", "\(Amount.zec(Swift.max(0, left))) ZEC")
            if plan.toSelf {
                Text("This is one of your own addresses: only the fee leaves your balance.")
                    .font(.system(size: 12)).foregroundStyle(Theme.muted)
            }
            Spacer()
            HStack {
                SecondaryButton(title: "Change") { stage = .form }.frame(width: 140)
                Spacer()
                PrimaryButton(title: "Send \(Amount.zec(plan.amount)) ZEC") { Task { await send(plan) } }.frame(width: 220)
            }
        }
    }

    private func done(_ outcome: WalletEngine.SendOutcome) -> some View {
        VStack(alignment: .leading, spacing: 14) {
            switch outcome {
            case .sent:
                Text("Your payment is on its way. It shows as confirmed once it is in a block.")
                    .foregroundStyle(Theme.muted)
            case .saved:
                Text("The payment was made but could not be delivered yet. Zecky keeps trying until it is in a block or expires (about 40 blocks). Do not send it again.")
                    .foregroundStyle(Theme.gold)
            }
            Spacer()
            HStack { Spacer(); PrimaryButton(title: "Done", action: onClose).frame(width: 160) }
        }
    }

    private func row(_ label: String, _ value: String, mono: Bool = false, strong: Bool = false) -> some View {
        HStack(alignment: .firstTextBaseline) {
            Text(label).foregroundStyle(Theme.muted).frame(width: 130, alignment: .leading)
            Text(value)
                .font(mono ? .system(size: 13, design: .monospaced) : .system(size: 14, weight: strong ? .semibold : .regular))
                .textSelection(.enabled)
            Spacer()
        }
    }

    private func short(_ a: String) -> String {
        a.count > 40 ? String(a.prefix(20)) + "…" + String(a.suffix(20)) : a
    }

    /// "1.25" → 125,000,000 zatoshi. US style; at most 8 decimals.
    private func zatoshi(_ text: String) -> Int64? {
        let cleaned = text.replacingOccurrences(of: ",", with: "").trimmingCharacters(in: .whitespaces)
        guard let value = Decimal(string: cleaned, locale: Locale(identifier: "en_US")), value > 0 else { return nil }
        var scaled = value * 100_000_000
        var rounded = Decimal()
        NSDecimalRound(&rounded, &scaled, 0, .plain)
        guard rounded == scaled else { return nil }
        return NSDecimalNumber(decimal: rounded).int64Value
    }

    private func makePlan() async {
        problem = nil
        working = true
        defer { working = false }
        var amount: Int64?
        if !max {
            guard let parsed = zatoshi(amountText) else { problem = "Enter the amount as a number, like 0.5 (at most 8 decimals)."; return }
            amount = parsed
        }
        do { stage = .review(try await engine.plan(to: to, amount: amount)) }
        catch { problem = String(describing: error) }
    }

    private func send(_ plan: WalletEngine.SendPlan) async {
        stage = .sending
        do { stage = .done(try await engine.send(plan, phrase: phrase)) }
        catch { problem = String(describing: error); stage = .form }
    }
}
