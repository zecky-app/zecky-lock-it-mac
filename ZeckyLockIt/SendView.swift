import SwiftUI

/// Release Zcash: recipient and amount, then a receipt of every number
/// before anything leaves the lock.
struct SendView: View {
    @ObservedObject var engine: WalletEngine
    let onClose: () -> Void

    private enum Stage { case form, review(WalletEngine.SendPlan), sending, done(WalletEngine.SendOutcome) }

    @State private var stage: Stage = .form
    @State private var to = ""
    @State private var amountText = ""
    @State private var max = false
    @State private var unit: Amount.Unit = Amount.unit
    @State private var problem: String?
    @State private var working = false
    @State private var waiting = false
    @State private var closedAgain = false
    @State private var lockNote: String?
    @State private var notUpToDate = false

    var body: some View {
        SheetScaffold(title: title, subtitle: subtitle, closeLabel: "Close", showsClose: !isSending,
                      height: 520, onClose: onClose) {
            switch stage {
            case .form: form
            case .review(let plan): review(plan)
            case .sending:
                VStack(spacing: 14) {
                    Spacer()
                    PadlockView(open: true, size: 90)
                    ProgressView().controlSize(.small)
                    Text("Releasing…").font(Theme.text(13)).foregroundStyle(Theme.muted)
                    Spacer()
                }
                .frame(maxWidth: .infinity)
            case .done(let outcome): done(outcome)
            }
        }
        .task { waiting = await engine.hasWaitingPayment() }
        // The wallet checks for new blocks now and then, which flips the
        // status for a moment. Only warn when it stays behind for a while.
        .task(id: engine.status == .upToDate) {
            guard engine.status != .upToDate else { notUpToDate = false; return }
            try? await Task.sleep(nanoseconds: 1_500_000_000)
            if !Task.isCancelled && engine.status != .upToDate { notUpToDate = true }
        }
    }

    private var isSending: Bool { if case .sending = stage { return true } else { return false } }

    private var title: String {
        switch stage {
        case .form: return "Release Zcash"
        case .review: return "Check before releasing"
        case .sending: return "Releasing"
        case .done(.sent): return "Released"
        case .done(.saved): return "Payment saved"
        }
    }

    private var subtitle: String {
        switch stage {
        case .form: return "Taken out of the lock. Everything else stays locked."
        case .review: return "Nothing has left the lock yet."
        case .sending: return "Signing on this Mac and handing it to the network."
        case .done(.sent): return "The lock closes again."
        case .done(.saved): return "Made, but not delivered yet."
        }
    }

    // MARK: Form

    private var form: some View {
        VStack(alignment: .leading, spacing: 14) {
            VStack(alignment: .leading, spacing: 8) {
                fieldLabel("TO")
                TextField("", text: $to, prompt: Text("Zcash address").foregroundColor(Theme.muted))
                    .textFieldStyle(.plain)
                    .font(.system(size: 13, design: .monospaced))
                    .autocorrectionDisabled()
            }
            .card(padding: 14)

            VStack(alignment: .leading, spacing: 10) {
                HStack {
                    fieldLabel("AMOUNT")
                    Spacer()
                    HStack(spacing: 6) {
                        Chip(title: "ZEC", on: unit == .zec) { switchUnit(.zec) }
                        Chip(title: "zats", on: unit == .zats) { switchUnit(.zats) }
                        Chip(title: "Max", on: max) { max.toggle() }
                    }
                }
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    if max {
                        Text(Amount.number(Swift.max(0, engine.spendable), unit))
                            .font(Theme.serif(30, weight: .medium)).foregroundStyle(Theme.muted)
                        Text("minus the fee").font(Theme.text(12)).foregroundStyle(Theme.muted)
                    } else {
                        TextField("", text: $amountText, prompt: Text(unit == .zec ? "0.000" : "0").foregroundColor(Theme.muted.opacity(0.6)))
                            .textFieldStyle(.plain)
                            .font(Theme.serif(30, weight: .medium))
                    }
                    Spacer()
                    Text(unit.rawValue).font(Theme.text(14, weight: .medium)).foregroundStyle(Theme.muted)
                }
                Rectangle().fill(Theme.line).frame(height: 1)
                Text("In the lock: \(Amount.text(engine.spendable, unit))")
                    .font(Theme.text(12)).foregroundStyle(Theme.muted)
            }
            .card(padding: 14)

            if waiting {
                note("A payment you made is still on its way. Wait for it to arrive before releasing it again.", Theme.gold)
            }
            if notUpToDate {
                note("Wait until the wallet is up to date. Nothing is created until then.", Theme.gold)
            }
            if let problem { note(problem, Theme.red) }

            Spacer(minLength: 0)
            HStack {
                Spacer()
                PrimaryButton(title: working ? "Checking…" : "Check",
                              enabled: !working && engine.status == .upToDate && !to.isEmpty && (max || !amountText.isEmpty)) {
                    Task { await makePlan() }
                }
                .frame(width: 180)
                .keyboardShortcut(.defaultAction)
            }
        }
    }

    // MARK: Receipt

    private func review(_ plan: WalletEngine.SendPlan) -> some View {
        let total = plan.amount + plan.fee
        let left = Swift.max(0, engine.spendable - total)
        return VStack(alignment: .leading, spacing: 14) {
            VStack(spacing: 0) {
                receiptRow("To", plan.toSelf ? "Yourself" : short(plan.to), mono: !plan.toSelf)
                receiptRow("Amount", Amount.text(plan.amount, unit))
                receiptRow("Network fee", Amount.text(plan.fee, unit))
                Rectangle().fill(Theme.line).frame(height: 1).padding(.vertical, 8)
                receiptRow("Total released", Amount.text(total, unit), strong: true)
                receiptRow("Stays locked", Amount.text(left, unit), accent: true)
            }
            .card(padding: 18)
            if plan.toSelf {
                note("This is one of your own addresses: only the network fee leaves the lock.", Theme.muted)
            }
            if let lockNote { note(lockNote, Theme.muted) }
            Spacer(minLength: 0)
            HStack {
                SecondaryButton(title: "Change") { lockNote = nil; stage = .form }.frame(width: 140)
                Spacer()
                PrimaryButton(title: "Release \(Amount.text(plan.amount, unit))") { Task { await send(plan) } }
                    .frame(width: 240)
            }
        }
    }

    private func receiptRow(_ label: String, _ value: String, mono: Bool = false, strong: Bool = false, accent: Bool = false) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Text(label).font(Theme.text(13)).foregroundStyle(Theme.muted)
            DottedLeader()
            Text(value)
                .font(mono ? .system(size: 12.5, design: .monospaced) : Theme.text(14, weight: strong ? .semibold : .regular))
                .foregroundStyle(accent ? Theme.gold : Theme.text)
                .textSelection(.enabled)
        }
        .padding(.vertical, 6)
    }

    // MARK: Done

    private func done(_ outcome: WalletEngine.SendOutcome) -> some View {
        VStack(spacing: 16) {
            Spacer()
            PadlockView(open: !closedAgain, size: 110)
                .animation(.spring(response: 0.55, dampingFraction: 0.62), value: closedAgain)
                .onAppear { DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { closedAgain = true } }
            switch outcome {
            case .sent:
                Text("It shows as confirmed once it is in a block. The rest stays locked.")
                    .font(Theme.text(14)).foregroundStyle(Theme.muted).multilineTextAlignment(.center)
            case .saved:
                Text("The payment was made but could not be delivered yet. Zecky keeps trying until it is in a block or expires (about 40 blocks). Do not send it again.")
                    .font(Theme.text(14)).foregroundStyle(Theme.gold).multilineTextAlignment(.center)
            }
            Spacer()
            PrimaryButton(title: "Done", action: onClose).frame(width: 180)
                .keyboardShortcut(.defaultAction)
        }
        .frame(maxWidth: .infinity)
    }

    // MARK: Helpers

    private func fieldLabel(_ text: String) -> some View {
        Text(text).font(Theme.text(11, weight: .semibold)).tracking(1.4).foregroundStyle(Theme.muted)
    }

    private func note(_ text: String, _ color: Color) -> some View {
        Text(text).font(Theme.text(12)).foregroundStyle(color).fixedSize(horizontal: false, vertical: true)
    }

    private func short(_ a: String) -> String {
        a.count > 40 ? String(a.prefix(18)) + "…" + String(a.suffix(18)) : a
    }

    /// Keeps the typed amount when switching units.
    private func switchUnit(_ next: Amount.Unit) {
        guard next != unit else { return }
        if let z = zatoshi(amountText) { amountText = next == .zec ? Amount.zec(z).replacingOccurrences(of: ",", with: "") : String(z) }
        unit = next
    }

    /// "1.25" ZEC → 125,000,000; "1,500" zats → 1,500. US style.
    private func zatoshi(_ text: String) -> Int64? {
        let cleaned = text.replacingOccurrences(of: ",", with: "").trimmingCharacters(in: .whitespaces)
        if unit == .zats {
            guard let v = Int64(cleaned), v > 0 else { return nil }
            return v
        }
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
            guard let parsed = zatoshi(amountText) else {
                problem = unit == .zec ? "Enter the amount as a number, like 0.5 (at most 8 decimals)." : "Enter a whole number of zats."
                return
            }
            amount = parsed
        }
        do { stage = .review(try await engine.plan(to: to, amount: amount)) }
        catch { problem = String(describing: error) }
    }

    /// Nothing leaves the lock until the owner of this Mac confirms it with
    /// Touch ID or the Mac password. That opens the sealed phrase for this
    /// one payment; the key is made, used, and wiped straight after.
    private func send(_ plan: WalletEngine.SendPlan) async {
        lockNote = nil
        let total = Amount.text(plan.amount + plan.fee, .zec)
        let wallet: StoredWallet
        do {
            wallet = try await WalletVault.unseal(reason: "release \(total) from the lock")
        } catch WalletVault.Failure.cancelled {
            lockNote = "Not confirmed, so nothing left the lock."
            return
        } catch {
            lockNote = "\(error) Nothing left the lock."
            return
        }
        stage = .sending
        do {
            var seed = try Mnemonic.seed(from: wallet.phrase)
            defer { Wipe.bytes(&seed) }
            stage = .done(try await engine.send(plan, seed: seed))
        } catch {
            problem = String(describing: error); stage = .form
        }
    }
}

/// A small rounded toggle in Zecky's gold.
struct Chip: View {
    let title: String
    let on: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Text(title)
                .font(Theme.text(12, weight: .medium))
                .padding(.horizontal, 10).frame(height: 24)
                .foregroundStyle(on ? Theme.onGold : Theme.text)
                .background(on ? Theme.gold : Color.clear, in: Capsule())
                .overlay(Capsule().stroke(on ? Color.clear : Theme.line))
                .contentShape(Capsule())
        }
        .buttonStyle(.plain)
    }
}

/// The dotted line between a label and its value on a receipt.
struct DottedLeader: View {
    var body: some View {
        Line()
            .stroke(Theme.muted.opacity(0.4), style: StrokeStyle(lineWidth: 1, dash: [1, 4]))
            .frame(height: 1)
            .offset(y: -3)
    }

    private struct Line: Shape {
        func path(in rect: CGRect) -> Path {
            var p = Path()
            p.move(to: CGPoint(x: 0, y: rect.midY))
            p.addLine(to: CGPoint(x: rect.maxX, y: rect.midY))
            return p
        }
    }
}
