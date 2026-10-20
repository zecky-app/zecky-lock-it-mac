import SwiftUI

struct WelcomeView: View {
    @ObservedObject var model: AppModel

    var body: some View {
        VStack(spacing: 28) {
            Spacer()
            VStack(spacing: 10) {
                Text("Zecky Lock it").font(Theme.serif(40, weight: .medium))
                Text("Quiet money. Your Zcash, kept on this Mac.")
                    .foregroundStyle(Theme.muted)
            }
            VStack(spacing: 12) {
                PrimaryButton(title: model.busy ? "Creating…" : "Create a new wallet", enabled: !model.busy) {
                    Entropy.noteEvent()
                    Task { await model.create() }
                }
                SecondaryButton(title: "Restore with 24 words") {
                    model.message = nil
                    model.screen = .restore
                }
            }
            .frame(width: 300)
            if let message = model.message {
                Text(message).foregroundStyle(Theme.red).multilineTextAlignment(.center).frame(maxWidth: 420)
            }
            Spacer()
        }
        .padding(40)
        .onContinuousHover { _ in Entropy.noteEvent() }
    }
}
