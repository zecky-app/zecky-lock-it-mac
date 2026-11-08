import SwiftUI

/// The short message that slides down when Zcash arrives, as on Lock it
/// iPhone: "Locked in" with the wallet and the amount. It leaves by itself
/// after a few seconds; a click opens Activity for that wallet.
struct ArrivalToast: View {
    @ObservedObject var model: AppModel
    @ObservedObject var engine: WalletEngine

    @State private var shown: WalletEngine.Arrival?
    @State private var visible = false
    private static let visibleFor: TimeInterval = 4.5

    /// Waits while a sheet is open or Lock it is locked.
    private var free: Bool { model.sheet == nil && !model.locked }

    var body: some View {
        VStack {
            if let shown, visible {
                Button { open(shown) } label: { card(shown) }
                    .buttonStyle(.plain)
                    .accessibilityLabel("\(title(shown)). \(detail(shown))")
                    .accessibilityHint("Opens Activity")
                    .transition(.move(edge: .top).combined(with: .opacity))
            }
            Spacer()
        }
        .padding(.top, 52)
        .animation(.spring(response: 0.4, dampingFraction: 0.85), value: visible)
        .onReceive(engine.$arrivals) { _ in next() }
        .onChange(of: model.sheet == nil) { _ in next() }
        .onChange(of: model.locked) { _ in next() }
    }

    private func card(_ arrival: WalletEngine.Arrival) -> some View {
        HStack(spacing: 12) {
            Image(systemName: "arrow.down")
                .font(.system(size: 14, weight: .semibold))
                .foregroundStyle(Theme.onGold)
                .frame(width: 32, height: 32)
                .background(Theme.green, in: Circle())
            VStack(alignment: .leading, spacing: 2) {
                Text(title(arrival)).font(Theme.text(14, weight: .semibold)).foregroundStyle(Theme.text)
                Text(detail(arrival)).font(Theme.text(12)).foregroundStyle(Theme.muted).monospacedDigit()
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 14).padding(.vertical, 10)
        .frame(width: 340)
        .background(Theme.surface, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous).stroke(Theme.gold.opacity(0.5)))
        .shadow(color: .black.opacity(0.25), radius: 12, y: 4)
        .contentShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
    }

    /// The wallet's name in the title: the Mac holds several wallets.
    private func title(_ arrival: WalletEngine.Arrival) -> String {
        (arrival.kind == .shielded ? "Locked in ✓ · " : "Locked in · ") + engine.walletName(arrival.account)
    }

    private func detail(_ arrival: WalletEngine.Arrival) -> String {
        if arrival.kind == .shielded { return "Your transparent Zcash is shielded now" }
        return model.amountsHidden ? "Amount hidden" : Amount.text(arrival.amount, model.unit)
    }

    /// Shows the next waiting message, one at a time.
    private func next() {
        guard shown == nil, free, let arrival = engine.takeArrival() else { return }
        shown = arrival
        visible = true
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.visibleFor) {
            guard self.shown == arrival else { return }
            dismiss()
        }
    }

    private func dismiss() {
        visible = false
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
            shown = nil
            next()
        }
    }

    private func open(_ arrival: WalletEngine.Arrival) {
        model.selectedWallet = arrival.account == engine.leadWallet?.id || arrival.account == engine.mainAccount ? nil : arrival.account
        dismiss()
        model.sheet = .activity
    }
}
