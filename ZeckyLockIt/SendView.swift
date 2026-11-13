import SwiftUI
import ZcashLightClientKit

/// Release Zcash: recipient and amount, then a receipt of every number
/// before anything leaves the lock.
struct SendView: View {
    @ObservedObject var engine: WalletEngine
    @ObservedObject var prices: PriceFeed
    /// The phrase the owner unsealed when opening the lock. Used once.
    @State private var opened: StoredWallet?
    let onClose: () -> Void

    private enum Stage { case compose, sending, done(WalletEngine.SendOutcome) }

    @State private var stage: Stage = .compose
    /// Set while the receipt is shown.
    @State private var plan: WalletEngine.SendPlan?
    @State private var problem: String?
    @State private var ownNodeWorking = false
    @State private var ownNodeNote: String?
    @State private var closedAgain = false
    @State private var lockNote: String?
    @State private var used = false
    @State private var sentTo: String?

    /// Tells the app while signing, so the open lock is not closed mid-way.
    let signing: (Bool) -> Void

    let onReleased: () -> Void

    init(engine: WalletEngine, prices: PriceFeed, opened: StoredWallet?, signing: @escaping (Bool) -> Void,
         onReleased: @escaping () -> Void, onClose: @escaping () -> Void) {
        self.engine = engine
        self.prices = prices
        self.signing = signing
        self.onReleased = onReleased
        self.onClose = onClose
        _opened = State(initialValue: opened)
    }

    var body: some View {
        SheetScaffold(title: title, subtitle: subtitle, closeLabel: "Close", showsClose: !isSending,
                      height: 580, wallet: engine.currentTag, onClose: onClose) {
            switch stage {
            case .compose:
                SendComposer(engine: engine, prices: prices, purpose: .lock, account: nil,
                             plan: $plan, problem: $problem, reviewNote: lockNote) { plan in
                    Task { await send(plan) }
                }
            case .sending:
                VStack(spacing: 14) {
                    Spacer()
                    PadlockView(open: true, size: 90)
                    ProgressView().controlSize(.small)
                    Text("Sending…").font(Theme.text(13)).foregroundStyle(Theme.muted)
                    Spacer()
                }
                .frame(maxWidth: .infinity)
            case .done(let outcome): done(outcome)
            }
        }
        .onChange(of: plan == nil) { _ in lockNote = nil }
    }

    private var isSending: Bool { if case .sending = stage { return true } else { return false } }

    private var title: String {
        switch stage {
        case .compose: return plan == nil ? "Send Zcash" : "Check before sending"
        case .sending: return "Sending"
        case .done(.sent): return "Sent"
        case .done(.saved): return "Payment saved"
        case .done(.waitingForTor): return "Not delivered yet"
        }
    }

    private var subtitle: String {
        switch stage {
        case .compose: return plan == nil ? "Taken out of the lock. Everything else stays locked." : "Nothing has left the lock yet."
        case .sending: return TorSending.isOn
            ? "Signing on this Mac and sending it over Tor. This can take a minute."
            : "Signing on this Mac and handing it to the network."
        case .done(.sent): return "The lock closes again."
        case .done(.saved): return "Made, but not delivered yet."
        case .done(.waitingForTor): return "Tor did not get it to a server."
        }
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
                if let sentTo { SaveContactRow(address: sentTo) }
            case .saved:
                Text("Not delivered yet. Lock it keeps trying for \(engine.retryText), while it is open and this Mac is awake. After that the payment expires and nothing leaves the lock. It cannot be cancelled, so do not pay again.")
                    .font(Theme.text(14)).foregroundStyle(Theme.gold).multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
                if let answer = engine.ownNodeAnswer {
                    Text("Your own node did not take it (\(answer)).")
                        .font(Theme.text(12)).foregroundStyle(Theme.muted).multilineTextAlignment(.center)
                        .fixedSize(horizontal: false, vertical: true)
                }
            case .waitingForTor:
                Text("Tor did not reach a server, so this payment has most likely not left this Mac. Lock it keeps trying over Tor for \(engine.retryText), while it is open and this Mac is awake. After that the payment expires and nothing leaves the lock. It cannot be cancelled and is never sent another way by itself, so do not pay again.")
                    .font(Theme.text(14)).foregroundStyle(Theme.gold).multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
                if engine.canSendThroughOwnNode {
                    SecondaryButton(title: ownNodeWorking ? "Sending…" : "Send through my own node") {
                        guard !ownNodeWorking else { return }
                        ownNodeWorking = true
                        Task {
                            defer { ownNodeWorking = false }
                            do { stage = .done(try await engine.sendThroughOwnNode()) }
                            catch { ownNodeNote = String(describing: error) }
                        }
                    }
                    .frame(width: 260)
                    Text(ownNodeNote ?? "Other Zcash nodes then see it coming from your internet address.")
                        .font(Theme.text(12)).foregroundStyle(ownNodeNote == nil ? Theme.muted : Theme.red).multilineTextAlignment(.center)
                }
            }
            Spacer()
            PrimaryButton(title: "Done", action: onClose).frame(width: 180)
                .keyboardShortcut(.defaultAction)
        }
        .frame(maxWidth: .infinity)
    }

    /// The lock was opened with Touch ID (and the code) before this sheet
    /// came up; that unsealed phrase signs this one payment. The key is
    /// made, used, and wiped straight after. A second payment needs the
    /// lock opened again.
    private func send(_ plan: WalletEngine.SendPlan) async {
        lockNote = nil
        guard let wallet = opened, !used else {
            lockNote = "The lock closed again. Close this and open the lock once more."
            return
        }
        used = true
        // Key ④: with a security key added, it must be touched first.
        // Unreadable key data counts as "keys present" and stops here.
        if SecurityKeys.hasKeys {
            do { try await SecurityKeys.check() }
            catch { used = false; self.plan = nil; problem = String(describing: error); return }
        }
        signing(true)
        defer { signing(false) }
        stage = .sending
        do {
            var seed = try Mnemonic.seed(from: wallet.phrase)
            defer { Wipe.bytes(&seed) }
            stage = .done(try await engine.send(plan, seed: seed))
            if !plan.toSelf { sentTo = plan.to }
            opened = nil
            onReleased()
        } catch {
            used = false
            self.plan = nil
            problem = String(describing: error); stage = .compose
        }
    }
}

/// The Send form and its receipt, the same for the lock and for Seal it:
/// who (with the address book), how much (ZEC, zats or money, Max, fee
/// included), an optional private note, then every number before anything
/// happens. `onConfirm` is the last button: sign here, or seal on the phone.
struct SendComposer: View {
    enum Purpose { case lock, sealIt }

    @ObservedObject var engine: WalletEngine
    @ObservedObject var prices: PriceFeed
    let purpose: Purpose
    /// The wallet paying: nil is the one on the key ring.
    let account: AccountUUID?
    /// Set while the receipt is shown; nil shows the form.
    @Binding var plan: WalletEngine.SendPlan?
    @Binding var problem: String?
    var reviewNote: String? = nil
    let onConfirm: (WalletEngine.SendPlan) -> Void

    @State private var to = ""
    @State private var amountText = ""
    @State private var max = false
    @State private var feeIncluded = false
    @State private var unit: Amount.Unit = Amount.unit
    @State private var working = false
    @State private var waiting = false
    @State private var showNote = false
    /// The amount is typed in the currency chosen under Settings › Value.
    @State private var fiat = false
    /// Filled from a pasted zcash: payment request.
    @State private var requestNote: String?
    @State private var memo = ""
    @State private var showBook = false
    @State private var notUpToDate = false

    private var spendable: Int64 { engine.spendable(of: account) }
    /// Zcash already in the wallet but not yet usable: it waits for its
    /// confirmations (10 blocks for a payment in, 3 for own change).
    private var notYetUsable: Int64 { Swift.max(0, engine.balance(of: account) - spendable) }
    private var notYetText: String? {
        guard notYetUsable > 0 else { return nil }
        let wait = WalletEngine.slowestWaiting(engine.activity, networkHeight: engine.networkHeight)
        let when = wait.map { $0.minutes <= 1 ? "in about a minute" : "in about \($0.minutes) minutes" } ?? "shortly"
        return "\(Amount.text(notYetUsable, unit)) more can be sent \(when), once it has enough confirmations."
    }

    var body: some View {
        Group {
            if let plan { review(plan) } else { form }
        }
        // Checked again with every new block, so the note goes away as soon
        // as the earlier payment is in one.
        .task(id: engine.walletHeight) { waiting = await engine.hasWaitingPayment(from: account) }
        // The wallet checks for new blocks now and then, which flips the
        // status for a moment. Only warn when it stays behind for a while.
        .task(id: engine.status == .upToDate) {
            guard engine.status != .upToDate else { notUpToDate = false; return }
            try? await Task.sleep(nanoseconds: 1_500_000_000)
            if !Task.isCancelled && engine.status != .upToDate { notUpToDate = true }
        }
    }

    // MARK: Form

    private var form: some View {
        VStack(alignment: .leading, spacing: 14) {
            // One card: who, how much, and an optional private note.
            VStack(alignment: .leading, spacing: 10) {
                HStack(spacing: 10) {
                    fieldLabel("TO")
                    Spacer()
                    if let name = Contacts.name(for: to) {
                        Label(name, systemImage: "checkmark.seal.fill")
                            .font(Theme.text(11, weight: .semibold)).foregroundStyle(Theme.green)
                    }
                    Button { showBook.toggle() } label: {
                        Image(systemName: "person.crop.circle")
                            .font(.system(size: 15)).foregroundStyle(Theme.gold)
                            .frame(width: 26, height: 26).contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .help("Address book")
                    .popover(isPresented: $showBook, arrowEdge: .bottom) {
                        BookPicker { address in to = address; showBook = false }
                    }
                }
                if !Contacts.onlySaved {
                    TextField("", text: $to, prompt: Text(purpose == .sealIt ? "Zcash address (u1… or t1…) or payment request" : "Zcash address or payment request").foregroundColor(Theme.muted))
                        .textFieldStyle(.plain)
                        .font(.system(size: 13, design: .monospaced))
                        .autocorrectionDisabled()
                        .onChange(of: to) { text in applyRequest(text) }
                    if let requestNote {
                        Label(requestNote, systemImage: "doc.text")
                            .font(Theme.text(11, weight: .medium)).foregroundStyle(Theme.gold)
                    }
                } else if Contacts.all.isEmpty {
                    Text("Only saved addresses can be used, and none are saved yet. Add one in Settings › Address book.")
                        .font(Theme.text(12)).foregroundStyle(Theme.muted)
                }
                if !Contacts.all.isEmpty {
                    FlowChips(items: Contacts.all.indices.map { ($0, Contacts.all[$0].name) },
                              selected: Contacts.all.firstIndex { $0.address == to.trimmingCharacters(in: .whitespacesAndNewlines) } ?? -1) { i in
                        to = Contacts.all[i].address
                    }
                }

                Rectangle().fill(Theme.line).frame(height: 1).padding(.vertical, 4)

                HStack {
                    fieldLabel("AMOUNT")
                    Spacer()
                    HStack(spacing: 6) {
                        Chip(title: "ZEC", on: !fiat && unit == .zec) { switchUnit(.zec) }
                        Chip(title: "zats", on: !fiat && unit == .zats) { switchUnit(.zats) }
                        if rate != nil {
                            Chip(title: prices.currency.short, on: fiat) { switchToFiat() }
                        }
                    }
                }
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    if max {
                        Text(Amount.number(Swift.max(0, spendable), unit))
                            .font(Theme.serif(34, weight: .medium)).foregroundStyle(Theme.muted)
                        Text("minus the fee").font(Theme.text(12)).foregroundStyle(Theme.muted)
                    } else {
                        TextField("", text: $amountText, prompt: Text(unit == .zec ? "0.000" : "0").foregroundColor(Theme.muted.opacity(0.6)))
                            .textFieldStyle(.plain)
                            .font(Theme.serif(34, weight: .medium))
                    }
                    Spacer()
                    Text(fiat && !max ? prices.currency.short : unit.rawValue)
                        .font(Theme.text(14, weight: .medium)).foregroundStyle(Theme.muted)
                }
                if fiat && !max {
                    Text(zatoshi(amountText).map { "= \(Amount.text($0, unit)) at CoinGecko's price of a few minutes ago; the exact amount is on the next screen" }
                         ?? "Type an amount in \(prices.currency.short)")
                        .font(Theme.text(12)).foregroundStyle(Theme.gold)
                        .fixedSize(horizontal: false, vertical: true)
                }
                HStack {
                    Text("\(Amount.text(spendable, unit)) available" + fromWallet.map { " in \($0.name)" }.orEmpty
                         + (prices.value(of: spendable).map { " · \($0)" } ?? ""))
                        .font(Theme.text(12)).foregroundStyle(Theme.muted)
                    Spacer()
                    Chip(title: "Max", on: max) { max.toggle() }
                }
                if let notYetText {
                    Text(notYetText).font(Theme.text(12)).foregroundStyle(Theme.gold)
                        .fixedSize(horizontal: false, vertical: true)
                }
                if !max {
                    Toggle(isOn: $feeIncluded) {
                        Text(feeIncluded ? "Fee included: the receiver gets this minus the fee" : "Include the network fee in this amount")
                            .font(Theme.text(12)).foregroundStyle(feeIncluded ? Theme.gold : Theme.muted)
                    }
                    .toggleStyle(.checkbox)
                }

                Rectangle().fill(Theme.line).frame(height: 1).padding(.vertical, 4)

                if showNote {
                    VStack(alignment: .leading, spacing: 6) {
                        HStack {
                            fieldLabel("PRIVATE NOTE")
                            Spacer()
                            Text("\(memo.utf8.count)/512").font(Theme.text(11))
                                .foregroundStyle(memo.utf8.count > 512 ? Theme.red : Theme.muted)
                            Button { showNote = false; memo = "" } label: {
                                Image(systemName: "xmark").font(.system(size: 10, weight: .semibold)).foregroundStyle(Theme.muted)
                            }
                            .buttonStyle(.plain).help("Remove the note")
                        }
                        TextField("", text: $memo, prompt: Text("Only the receiver can read this").foregroundColor(Theme.muted), axis: .vertical)
                            .textFieldStyle(.plain).font(Theme.text(13)).lineLimit(1...3)
                    }
                } else {
                    Button { showNote = true } label: {
                        Label("Add a private note", systemImage: "plus").font(Theme.text(12, weight: .medium)).foregroundStyle(Theme.gold)
                    }
                    .buttonStyle(.plain)
                    .help("Encrypted with the payment; only the receiver can read it")
                }
            }
            .card(padding: 16)

            if engine.hasUndelivered {
                note("A payment has not been sent yet. Lock it keeps trying; a new payment is possible once that one is sent or has expired.", Theme.gold)
            } else if waiting {
                note("A payment is still on its way. Wait for it to arrive before sending again.", Theme.gold)
            }
            if notUpToDate {
                note("Wait until the wallet is up to date. Nothing is created until then.", Theme.gold)
            }
            if let problem { note(problem, Theme.red) }

            Spacer(minLength: 0)
            HStack {
                Spacer()
                PrimaryButton(title: working ? "Checking…" : "Check",
                              enabled: !working && engine.status == .upToDate && !engine.hasUndelivered && !to.isEmpty && (max || !amountText.isEmpty)) {
                    Task { await makePlan() }
                }
                .frame(width: 180)
                .keyboardShortcut(.defaultAction)
            }
        }
    }

    /// The wallet that pays, named on the screen and the receipt when the
    /// lock holds more than one wallet (with one there is nothing to mix up).
    private var fromWallet: WalletTag? {
        guard engine.hasSeveralWallets else { return nil }
        return account.map(engine.tag) ?? engine.currentTag
    }

    // MARK: Receipt

    private func review(_ plan: WalletEngine.SendPlan) -> some View {
        let total = plan.amount + plan.fee
        let left = Swift.max(0, spendable - total)
        return VStack(alignment: .leading, spacing: 14) {
            VStack(spacing: 0) {
                if let from = fromWallet {
                    // Several wallets share one lock: say which one pays,
                    // before anything else on the receipt.
                    receiptRow("From", from.name, strong: true, accent: true)
                    Rectangle().fill(Theme.line).frame(height: 1).padding(.vertical, 8)
                }
                receiptRow("To", plan.toSelf ? "Yourself" : (Contacts.name(for: plan.to) ?? "New address"), strong: true)
                if !plan.toSelf {
                    Text(Contacts.grouped(plan.to))
                        .font(.system(size: 11, design: .monospaced)).foregroundStyle(Theme.muted)
                        .fixedSize(horizontal: false, vertical: true)
                        .padding(.bottom, 6)
                        .textSelection(.enabled)
                }
                receiptRow(plan.toSelf ? "Arrives at your address" : "They receive", money(plan.amount))
                receiptRow("Network fee", Amount.text(plan.fee, unit))
                Rectangle().fill(Theme.line).frame(height: 1).padding(.vertical, 8)
                receiptRow("Total sent", money(total), strong: true)
                if let note = plan.memo {
                    receiptRow("Private note", note.count > 40 ? String(note.prefix(40)) + "…" : note)
                }
                receiptRow(purpose == .sealIt ? "Stays sealed" : "Stays locked", money(left), accent: true)
            }
            .card(padding: 18)
            if plan.toSelf {
                note(purpose == .sealIt ? "This is one of your own addresses: only the network fee leaves this sealed wallet."
                                        : "This is one of your own addresses: only the network fee leaves the lock.", Theme.muted)
            }
            if purpose == .sealIt {
                note("Next, your offline phone shows the same address and amount. Check them there before you seal it.", Theme.muted)
            }
            if let reviewNote { note(reviewNote, Theme.muted) }
            Spacer(minLength: 0)
            HStack {
                QuietButton(title: "Change") { self.plan = nil }.frame(width: 140)
                Spacer()
                PrimaryButton(title: purpose == .sealIt ? "Seal it on your phone"
                              : "Send \(Amount.text(plan.amount, unit))" + fromWallet.map { " from \($0.name)" }.orEmpty) {
                    onConfirm(plan)
                }
                .frame(width: fromWallet == nil ? 240 : 320)
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

    // MARK: Helpers

    private func fieldLabel(_ text: String) -> some View {
        Text(text).font(Theme.text(11, weight: .semibold)).tracking(1.4).foregroundStyle(Theme.muted)
    }

    private func note(_ text: String, _ color: Color) -> some View {
        Text(text).font(Theme.text(12)).foregroundStyle(color).fixedSize(horizontal: false, vertical: true)
    }

    /// A pasted zcash: request fills the address, amount and note.
    private func applyRequest(_ text: String) {
        guard PaymentRequest.isRequest(text) else { return }
        do {
            let r = try PaymentRequest.parse(text)
            to = r.address
            if let amount = r.amount { fiat = false; unit = .zec; max = false; amountText = amount }
            if let memo = r.memo { self.memo = memo; showNote = true }
            problem = nil
            var parts = ["Payment request"]
            if let label = r.label, !label.isEmpty { parts.append(label) }
            if let amount = r.amount { parts.append("\(amount) ZEC") }
            requestNote = parts.joined(separator: " · ") + ". Check it on the next screen."
        } catch {
            to = ""
            requestNote = nil
            problem = String(describing: error)
        }
    }

    /// ZEC per one unit of the chosen currency, when a price is known.
    private var rate: Double? {
        guard prices.currency != .none else { return nil }
        return prices.rates[prices.currency.rawValue]
    }

    /// Keeps the typed amount when switching units.
    private func switchUnit(_ next: Amount.Unit) {
        guard fiat || next != unit else { return }
        let z = zatoshi(amountText)
        fiat = false
        unit = next
        if let z { amountText = next == .zec ? Amount.zec(z).replacingOccurrences(of: ",", with: "") : String(z) }
    }

    private func switchToFiat() {
        guard !fiat, let rate else { return }
        let z = zatoshi(amountText)
        fiat = true
        if let z {
            let value = Double(z) / 100_000_000 * rate
            amountText = prices.currency == .btc ? String(format: "%.8f", value) : String(format: "%.2f", value)
        }
    }

    /// "0.5 ZEC · ≈ $12.30" when a currency is chosen.
    private func money(_ zatoshi: Int64) -> String {
        Amount.text(zatoshi, unit) + (prices.value(of: zatoshi).map { "  \($0)" } ?? "")
    }

    /// "1.25" or "1,25" ZEC → 125,000,000; "1,500" zats → 1,500. An amount
    /// like "1,500" in ZEC or money is asked about, never guessed.
    private func zatoshi(_ text: String) -> Int64? {
        if fiat {
            guard let rate, rate > 0, let value = AmountInput.fiat(text) else { return nil }
            let z = (value / rate * 100_000_000).rounded()
            return z >= 1 ? Int64(z) : nil
        }
        return unit == .zats ? AmountInput.zats(text) : AmountInput.zec(text)
    }

    private func makePlan() async {
        problem = nil
        working = true
        defer { working = false }
        var amount: Int64?
        if !max {
            guard let parsed = zatoshi(amountText) else {
                if unit == .zec || fiat, AmountInput.ambiguous(amountText) {
                    problem = AmountInput.question(amountText, unit: fiat ? prices.currency.short : "ZEC")
                    return
                }
                problem = fiat ? "Enter an amount in \(prices.currency.short), like 25.00." : (unit == .zec ? "Enter the amount as a number, like 0.5 (at most 8 decimals)." : "Enter a whole number of zats.")
                return
            }
            amount = parsed
        }
        if Contacts.onlySaved && Contacts.name(for: to) == nil {
            problem = "Only saved addresses can be used. Pick one above, or change the rule in Settings."
            return
        }
        // The offline phone cannot sign to a Sapling-only address.
        if purpose == .sealIt, let r = try? Recipient(to.trimmingCharacters(in: .whitespacesAndNewlines), network: .mainnet),
           case .sapling = r {
            problem = SealItFlow.FlowError.saplingRecipient.errorDescription
            return
        }
        let note = memo.trimmingCharacters(in: .whitespacesAndNewlines)
        guard note.utf8.count <= 512 else { problem = "The private note is too long (at most 512 bytes)."; return }
        do {
            plan = try await engine.plan(to: to, amount: amount, memo: note.isEmpty ? nil : note,
                                         feeIncluded: feeIncluded && !max, from: account)
        } catch { problem = WalletEngine.planProblem(error) }
    }
}

/// After paying a new address: offer to save it under a name.
struct SaveContactRow: View {
    let address: String
    @State private var newName = ""
    @State private var savedName: String?

    var body: some View {
        if Contacts.name(for: address) == nil || savedName != nil, !Contacts.onlySaved {
            HStack(spacing: 8) {
                if let savedName {
                    Label("Saved as \(savedName)", systemImage: "checkmark.seal.fill")
                        .font(Theme.text(12, weight: .medium)).foregroundStyle(Theme.green)
                } else {
                    TextField("", text: $newName, prompt: Text("Name, to save this address").foregroundColor(Theme.muted))
                        .textFieldStyle(.plain).font(Theme.text(13))
                        .padding(.horizontal, 10).frame(width: 240, height: 32)
                        .background(Theme.ink, in: RoundedRectangle(cornerRadius: 8))
                        .overlay(RoundedRectangle(cornerRadius: 8).stroke(Theme.line))
                    SecondaryButton(title: "Save") {
                        if (try? Contacts.add(name: newName, address: address)) != nil { savedName = newName }
                    }
                    .frame(width: 80)
                }
            }
            .padding(.top, 6)
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

/// The address book while releasing: pick a name, or save a new one.
struct BookPicker: View {
    let pick: (String) -> Void
    @State private var contacts = Contacts.all
    @State private var search = ""
    @State private var adding = false
    @State private var name = ""
    @State private var address = ""
    @State private var note: String?

    private var shown: [Contacts.Contact] {
        let q = search.trimmingCharacters(in: .whitespaces)
        return q.isEmpty ? contacts : contacts.filter { $0.name.localizedCaseInsensitiveContains(q) }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("ADDRESS BOOK").font(Theme.text(11, weight: .semibold)).tracking(1.8).foregroundStyle(Theme.gold)
            if contacts.count > 5 {
                TextField("Search", text: $search).textFieldStyle(.roundedBorder)
            }
            if contacts.isEmpty && !adding {
                Text("No saved addresses yet.").font(Theme.text(12)).foregroundStyle(Theme.muted)
            }
            ScrollView {
                VStack(spacing: 0) {
                    ForEach(shown) { c in
                        Button { pick(c.address) } label: {
                            HStack(spacing: 10) {
                                ZStack {
                                    Circle().fill(Theme.gold.opacity(0.14))
                                    Text(String(c.name.prefix(1)).uppercased())
                                        .font(Theme.serif(14, weight: .medium)).foregroundStyle(Theme.gold)
                                }
                                .frame(width: 28, height: 28)
                                VStack(alignment: .leading, spacing: 1) {
                                    Text(c.name).font(Theme.text(13, weight: .medium)).foregroundStyle(Theme.text)
                                    Text(Contacts.short(c.address)).font(.system(size: 11, design: .monospaced)).foregroundStyle(Theme.muted)
                                }
                                Spacer()
                            }
                            .padding(.vertical, 6).padding(.horizontal, 6)
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                    }
                }
            }
            .frame(maxHeight: 240)
            if Contacts.onlySaved {
                Text("New addresses are added in Settings › Address book, with your Zecky code and Touch ID.")
                    .font(Theme.text(11)).foregroundStyle(Theme.muted).fixedSize(horizontal: false, vertical: true)
            } else if adding {
                TextField("Name", text: $name).textFieldStyle(.roundedBorder)
                TextField("Zcash address", text: $address).textFieldStyle(.roundedBorder)
                    .font(.system(size: 12, design: .monospaced))
                if let note { Text(note).font(Theme.text(11)).foregroundStyle(Theme.red) }
                HStack {
                    Button("Cancel") { adding = false; note = nil }
                    Spacer()
                    Button("Save and use") {
                        do {
                            try Contacts.add(name: name, address: address)
                            pick(address.trimmingCharacters(in: .whitespacesAndNewlines))
                        } catch { note = String(describing: error) }
                    }
                    .keyboardShortcut(.defaultAction)
                }
            } else {
                Button { adding = true } label: {
                    Label("Add a new address", systemImage: "plus.circle").font(Theme.text(12, weight: .medium))
                }
                .buttonStyle(.plain).foregroundStyle(Theme.gold)
            }
        }
        .padding(16)
        .frame(width: 340)
    }
}

private extension Optional where Wrapped == String {
    var orEmpty: String { self ?? "" }
}
