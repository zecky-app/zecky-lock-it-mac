import SwiftUI

/// Release Zcash: recipient and amount, then a receipt of every number
/// before anything leaves the lock.
struct SendView: View {
    @ObservedObject var engine: WalletEngine
    @ObservedObject var prices: PriceFeed
    /// The phrase the owner unsealed when opening the lock. Used once.
    @State private var opened: StoredWallet?
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
    @State private var used = false
    @State private var sentTo: String?
    @State private var showNote = false
    /// The amount is typed in the currency chosen under Settings › Value.
    @State private var fiat = false
    @State private var memo = ""
    @State private var showBook = false
    @State private var newName = ""
    @State private var savedName: String?

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
    @State private var notUpToDate = false

    var body: some View {
        SheetScaffold(title: title, subtitle: subtitle, closeLabel: "Close", showsClose: !isSending,
                      height: 580, onClose: onClose) {
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
        case .done(.saved): return "Release saved"
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
                    TextField("", text: $to, prompt: Text("Zcash address").foregroundColor(Theme.muted))
                        .textFieldStyle(.plain)
                        .font(.system(size: 13, design: .monospaced))
                        .autocorrectionDisabled()
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
                        Text(Amount.number(Swift.max(0, engine.spendable), unit))
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
                    Text("\(Amount.text(engine.spendable, unit)) available" + (prices.value(of: engine.spendable).map { " · \($0)" } ?? ""))
                        .font(Theme.text(12)).foregroundStyle(Theme.muted)
                    Spacer()
                    Chip(title: "Max", on: max) { max.toggle() }
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

            if waiting {
                note("A release is still on its way. Wait for it to arrive before releasing again.", Theme.gold)
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
                receiptRow("Total released", money(total), strong: true)
                if let note = plan.memo {
                    receiptRow("Private note", note.count > 40 ? String(note.prefix(40)) + "…" : note)
                }
                receiptRow("Stays locked", money(left), accent: true)
            }
            .card(padding: 18)
            if plan.toSelf {
                note("This is one of your own addresses: only the network fee leaves the lock.", Theme.muted)
            }
            if let lockNote { note(lockNote, Theme.muted) }
            Spacer(minLength: 0)
            HStack {
                QuietButton(title: "Change") { lockNote = nil; stage = .form }.frame(width: 140)
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
                if let sentTo, Contacts.name(for: sentTo) == nil, !Contacts.onlySaved {
                    saveContact(sentTo)
                }
            case .saved:
                Text("The release was made but could not be delivered yet. Lock it keeps trying until it is in a block or expires (about 40 blocks). Do not release it again.")
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

    /// After paying a new address: offer to save it under a name.
    private func saveContact(_ address: String) -> some View {
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

    private func short(_ a: String) -> String {
        a.count > 40 ? String(a.prefix(18)) + "…" + String(a.suffix(18)) : a
    }

    /// Keeps the typed amount when switching units.
    /// ZEC per one unit of the chosen currency, when a price is known.
    private var rate: Double? {
        guard prices.currency != .none else { return nil }
        return prices.rates[prices.currency.rawValue]
    }

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

    /// "1.25" ZEC → 125,000,000; "1,500" zats → 1,500. US style.
    private func zatoshi(_ text: String) -> Int64? {
        let cleaned = text.replacingOccurrences(of: ",", with: "").trimmingCharacters(in: .whitespaces)
        if fiat {
            guard let rate, rate > 0, let value = Double(cleaned), value > 0 else { return nil }
            let z = (value / rate * 100_000_000).rounded()
            return z >= 1 ? Int64(z) : nil
        }
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
                problem = fiat ? "Enter an amount in \(prices.currency.short), like 25.00." : (unit == .zec ? "Enter the amount as a number, like 0.5 (at most 8 decimals)." : "Enter a whole number of zats.")
                return
            }
            amount = parsed
        }
        if Contacts.onlySaved && Contacts.name(for: to) == nil {
            problem = "Only saved addresses can be used. Pick one above, or change the rule in Settings."
            return
        }
        let note = memo.trimmingCharacters(in: .whitespacesAndNewlines)
        guard note.utf8.count <= 512 else { problem = "The private note is too long (at most 512 bytes)."; return }
        do { stage = .review(try await engine.plan(to: to, amount: amount, memo: note.isEmpty ? nil : note)) }
        catch { problem = String(describing: error) }
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
