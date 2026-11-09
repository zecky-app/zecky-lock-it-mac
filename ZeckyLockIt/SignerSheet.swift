import AppKit
import SwiftUI
import ZcashLightClientKit

/// Seal it: a watch-only account whose keys live on an offline phone running
/// Zecky Seal it . Lock it writes the payment
/// and makes the proofs; the phone seals (signs) it; Lock it sends it.
/// Everything passes through QR codes, so the keys never touch this Mac.
/// Kept apart from the lock: its balance is shown here only.
struct SignerSheet: View {
    @ObservedObject var model: AppModel
    @ObservedObject var engine: WalletEngine
    let onClose: () -> Void

    @State private var flow: SealItFlow?
    /// Opened with Send Zcash (the Send form) or Receive (address and QR).
    @State private var sending = false
    /// Opened from "Pair Seal it".
    @State private var pairingAtOpen = false

    init(model: AppModel, engine: WalletEngine, onClose: @escaping () -> Void) {
        self.model = model
        self.engine = engine
        self.onClose = onClose
        _sending = State(initialValue: model.sealItSending && !model.sealItPairing)
        _pairingAtOpen = State(initialValue: model.sealItPairing)
    }

    var body: some View {
        SheetScaffold(title: pairingAtOpen ? "Seal it" : (sending ? "Send Zcash" : "Receive"),
                      subtitle: pairingAtOpen ? "Pair the offline phone that holds the keys."
                                : (sending ? "Written here, sealed on your offline phone, sent from here."
                                           : "Zcash sent here is kept in this sealed wallet."),
                      width: 560, height: 760,
                      wallet: pairingAtOpen ? nil : model.selectedWallet.map { WalletTag(name: engine.walletName($0), sealed: true) },
                      onClose: onClose) {
            if let flow {
                // Scrolls inside the sheet, so the title and Done stay in view
                // when the QR code is shown.
                ScrollView(showsIndicators: false) {
                    SealContent(model: model, engine: engine, flow: flow, sending: sending).padding(.bottom, 8)
                }
            } else {
                Text("The wallet is still starting. Try again in a moment.")
                    .font(Theme.text(13)).foregroundStyle(Theme.muted)
            }
        }
        .task {
            if flow == nil, let sdk = engine.sdk {
                flow = SealItFlow(synchronizer: sdk, network: .mainnet)
            }
        }
    }
}

private struct SealContent: View {
    @ObservedObject var model: AppModel
    @ObservedObject var engine: WalletEngine
    @ObservedObject var flow: SealItFlow
    let sending: Bool

    @State private var account: AccountUUID?
    @State private var accounts: [Account] = []
    @State private var confirmRemove = false
    @State private var checked = false
    @State private var pairing = false
    @State private var pairNote: String?
    @State private var address: String?
    @State private var copied = false
    @State private var showQR = true
    @State private var pressed: CGFloat = 0

    /// The Send screen's receipt, while it is shown.
    @State private var sealPlan: WalletEngine.SendPlan?
    @State private var sealProblem: String?
    /// Where the last sealed payment went, to offer saving it as a contact.
    @State private var sealedTo: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            if !checked {
                ProgressView().frame(maxWidth: .infinity, minHeight: 200)
            } else if pairing {
                pair
            } else if let account {
                paired(account)
            } else {
                pair
            }
        }
        .task { await load() }
        .onChange(of: failureText) { text in
            if let text { sealPlan = nil; sealProblem = text }
        }
        .onDisappear { flow.reset() }
    }

    private func load() async {
        accounts = await flow.sealItAccounts()
        if account == nil, let chosen = model.selectedWallet { account = chosen }
        if account == nil || !accounts.contains(where: { $0.id == account }) {
            account = accounts.first?.id
        }
        if model.sealItPairing {
            model.sealItPairing = false
            pairing = true
        }
        checked = true
        await loadAddress()
    }

    private func select(_ id: AccountUUID) {
        guard id != account else { return }
        flow.reset()
        account = id
        model.selectedWallet = id
        sealPlan = nil
        sealProblem = nil
        address = nil
        copied = false
        Task { await loadAddress() }
    }

    private func remove() async {
        guard let account else { return }
        do {
            try await flow.removeAccount(account)
            self.account = nil
            model.selectedWallet = nil
            await engine.refreshSealedWallets()
            await load()
        } catch {
            pairNote = (error as? LocalizedError)?.errorDescription ?? String(describing: error)
        }
    }

    /// The sealed wallets in Lock it, one tab each, plus "Add".
    private var walletBar: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                ForEach(accounts, id: \.id) { item in
                    let isOn = item.id == account
                    Button { select(item.id) } label: {
                        Text(WalletNames.name(for: item, fallback: "Seal it"))
                            .font(Theme.text(12, weight: isOn ? .semibold : .regular))
                            .foregroundStyle(isOn ? Theme.onGold : Theme.text)
                            .padding(.horizontal, 12).padding(.vertical, 6)
                            .background(isOn ? Theme.gold : Theme.surface, in: Capsule())
                            .overlay(Capsule().stroke(Theme.line, lineWidth: isOn ? 0 : 1))
                    }
                    .buttonStyle(.plain)
                }
                Button { pairNote = nil; pairing = true } label: {
                    Label("Add", systemImage: "plus")
                        .font(Theme.text(12, weight: .medium))
                        .foregroundStyle(Theme.gold)
                        .padding(.horizontal, 12).padding(.vertical, 6)
                        .overlay(Capsule().stroke(Theme.gold.opacity(0.5), lineWidth: 1))
                }
                .buttonStyle(.plain)
                .help("Pair another Seal it wallet")
            }
        }
    }

    private func loadAddress() async {
        guard let account, let sdk = engine.sdk else { return }
        address = try? await sdk.getCustomUnifiedAddress(accountUUID: account, receivers: [.orchard]).stringEncoded
    }

    private func mark(_ sealed: CGFloat = 1, size: CGFloat = 132) -> some View {
        HStack { Spacer(); SealMark(size: size, sealed: sealed); Spacer() }
    }

    // MARK: Pair

    @ViewBuilder private var pair: some View {
        if pairing {
            Text("On your offline phone, open Seal it and show the account QR code. Hold the phone up to this Mac's camera.")
                .font(Theme.text(13)).foregroundStyle(Theme.muted)
                .fixedSize(horizontal: false, vertical: true)
            URScannerView(expectedType: SealItURType.accounts) { message in
                Task { await importAccount(message) }
            }
            if let pairNote { Text(pairNote).font(Theme.text(12)).foregroundStyle(Theme.muted) }
            Spacer()
            QuietButton(title: "Cancel") { pairing = false; pairNote = nil }
        } else {
            mark()
            VStack(alignment: .leading, spacing: 10) {
                step(1, "Write it", "Lock it writes the payment here, on this Mac.")
                step(2, "Seal it", "Your offline phone holds the keys and seals the payment.")
                step(3, "Send it", "Lock it scans the sealed payment back and sends it.")
                Text("Seal it is an early prototype. Use small amounts only.")
                    .font(Theme.text(12)).foregroundStyle(Theme.muted).padding(.top, 4)
            }
            .card()
            if let pairNote { Text(pairNote).font(Theme.text(12)).foregroundStyle(Theme.red) }
            Spacer()
            PrimaryButton(title: "Pair Seal it") { pairNote = nil; pairing = true }
        }
    }

    private func step(_ n: Int, _ title: String, _ text: String) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 10) {
            Text("\(n)").font(Theme.text(12, weight: .semibold)).foregroundStyle(Theme.gold).frame(width: 14)
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(Theme.text(13, weight: .semibold))
                Text(text).font(Theme.text(13)).foregroundStyle(Theme.muted)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private func importAccount(_ message: Data) async {
        pairNote = "Adding the Seal it account…"
        do {
            let birthday = await flow.recentBirthday()
            let id = try await flow.importAccount(fromAccountsUR: message, birthday: birthday)
            pairing = false
            pairNote = nil
            account = id
            model.selectedWallet = id
            await engine.refreshSealedWallets()
            await load()
        } catch {
            pairing = false
            pairNote = (error as? LocalizedError)?.errorDescription ?? String(describing: error)
        }
    }

    // MARK: Paired: write it, seal it, send it

    @ViewBuilder private func paired(_ account: AccountUUID) -> some View {
        switch flow.step {
        case .idle, .failed:
            if !sending {
                walletBar
                balanceCard(showAddress: true)
            } else {
                if sealPlan == nil {
                    walletBar
                    SealSteps(current: .write)
                    balanceCard(showAddress: false)
                } else {
                    SealSteps(current: .write)
                }
                composer(account)
            }

        case .preparing(let text):
            SealSteps(current: flowIsSending ? .send : .write)
            busy(text)

        case .showUnsigned(let encoder):
            SealSteps(current: .seal)
            Text("On your phone, open Seal it and scan this. Check the address and amount there, then seal it.")
                .font(Theme.text(13)).foregroundStyle(Theme.muted)
                .fixedSize(horizontal: false, vertical: true)
            HStack { Spacer(); AnimatedURQRView(encoder: encoder).frame(width: 320, height: 320); Spacer() }
            Spacer()
            PrimaryButton(title: "Sealed on the phone: scan it back") { flow.readyToScanSigned() }
            QuietButton(title: "Cancel") { flow.reset() }

        case .scanSigned:
            SealSteps(current: .seal)
            Text("Hold the sealed QR code from your phone up to this Mac's camera.")
                .font(Theme.text(13)).foregroundStyle(Theme.muted)
            URScannerView(expectedType: SealItURType.pczt) { message in
                Task { await flow.receivedSigned(message: message) }
            }
            Spacer()
            QuietButton(title: "Cancel") { flow.reset() }

        case .broadcasting:
            SealSteps(current: .send)
            busy("Sending…")

        case .sent(let txId):
            SealSteps(current: .send)
            VStack(spacing: 12) {
                SealMark(size: 132, sealed: pressed)
                    .onAppear { withAnimation(.spring(response: 0.45, dampingFraction: 0.55)) { pressed = 1 } }
                    .onDisappear { pressed = 0 }
                Text("Sealed and sent").font(Theme.serif(28, weight: .medium))
                Text("Sealed on your offline phone. The keys never touched this Mac.")
                    .font(Theme.text(13)).foregroundStyle(Theme.muted)
                if !txId.isEmpty {
                    Text(txId).font(.system(size: 11, design: .monospaced)).foregroundStyle(Theme.muted)
                        .textSelection(.enabled).lineLimit(2).multilineTextAlignment(.center)
                }
            }
            .frame(maxWidth: .infinity).padding(.top, 24)
            if let sealedTo { HStack { Spacer(); SaveContactRow(address: sealedTo); Spacer() } }
            Spacer()
            PrimaryButton(title: "Done") { flow.reset(); sealPlan = nil; sealedTo = nil }
        }
    }

    private var failureText: String? {
        if case .failed(let reason) = flow.step { return reason }
        return nil
    }

    /// "Finishing the proofs…" happens after the phone sealed it.
    private var flowIsSending: Bool {
        if case .preparing(let text) = flow.step { return text.lowercased().contains("proof") }
        return false
    }

    private func composer(_ account: AccountUUID) -> some View {
        SendComposer(engine: engine, prices: model.prices, purpose: .sealIt, account: account,
                     plan: $sealPlan, problem: $sealProblem) { plan in
            sealProblem = nil
            sealedTo = plan.toSelf ? nil : plan.to
            Task { await flow.startSend(from: account, proposal: plan.proposal) }
        }
        .id(account)
    }

    private func balanceCard(showAddress: Bool) -> some View {
        HStack(alignment: .center, spacing: 16) {
            SealMark(size: 64)
            VStack(alignment: .leading, spacing: 6) {
                HStack {
                    Text("SEALED BALANCE").font(Theme.text(11, weight: .semibold)).tracking(2).foregroundStyle(Theme.muted)
                    Spacer()
                    Button("Remove") { confirmRemove = true }
                        .buttonStyle(.plain).font(Theme.text(11, weight: .medium)).foregroundStyle(Theme.muted)
                        .help("Remove this sealed wallet from Lock it")
                }
                Text(model.amountsHidden ? Amount.hiddenText : Amount.number(selectedBalance.total, model.unit))
                    .font(Theme.serif(28, weight: .medium))
                if selectedBalance.total != selectedBalance.spendable && !model.amountsHidden {
                    Text("\(Amount.number(selectedBalance.spendable, model.unit)) usable now, the rest is confirming")
                        .font(Theme.text(12)).foregroundStyle(Theme.muted)
                }
                if showAddress, let address {
                    HStack(spacing: 8) {
                        Text(address).font(.system(size: 11, design: .monospaced)).foregroundStyle(Theme.muted)
                            .lineLimit(1).truncationMode(.middle)
                        Button(copied ? "Copied" : "Copy") {
                            ReceiveAddress.copy(address)
                            copied = true
                        }
                        .buttonStyle(.plain).font(Theme.text(12, weight: .medium)).foregroundStyle(Theme.gold)
                        Button(showQR ? "Hide QR" : "QR code") { withAnimation(.easeOut(duration: 0.15)) { showQR.toggle() } }
                            .buttonStyle(.plain).font(Theme.text(12, weight: .medium)).foregroundStyle(Theme.gold)
                    }
                    Text("Send Zcash here to fill Seal it.")
                        .font(Theme.text(11)).foregroundStyle(Theme.muted)
                    if showQR, let qr = QRCode.image(for: address) {
                        Image(nsImage: qr).interpolation(.none).resizable()
                            .frame(width: 200, height: 200)
                            .padding(12)
                            .background(QRCode.paper, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
                            .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).stroke(Theme.gold.opacity(0.8), lineWidth: 1.5))
                            .accessibilityLabel("QR code of this sealed wallet's address")
                            .padding(.top, 4)
                    }
                }
            }
        }
        .card()
        .confirmationDialog("Remove this sealed wallet from Lock it?", isPresented: $confirmRemove) {
            Button("Remove", role: .destructive) { Task { await remove() } }
            Button("Keep it", role: .cancel) {}
        } message: {
            Text("Its keys and Zcash stay on your offline phone. You can pair it again at any time.")
        }
    }

    private var selectedBalance: (spendable: Int64, total: Int64) {
        guard let account else { return (0, 0) }
        return engine.signerBalances[account] ?? (0, 0)
    }

    private func busy(_ text: String) -> some View {
        VStack(spacing: 12) {
            ProgressView()
            Text(text).font(Theme.text(13)).foregroundStyle(Theme.muted)
        }
        .frame(maxWidth: .infinity, minHeight: 240)
    }
}
