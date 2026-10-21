import AppKit
import SwiftUI

struct ContentView: View {
    @ObservedObject var model: AppModel
    @State private var covered = false

    var body: some View {
        ZStack {
            Theme.ink.ignoresSafeArea()
            Group {
                switch model.screen {
                case .loading: ProgressView()
                case .welcome: WelcomeView(model: model)
                case .backup(let wallet): BackupView(wallet: wallet) { model.screen = .confirm(wallet) }
                case .confirm(let wallet):
                    ConfirmView(wallet: wallet,
                                onBack: { model.screen = .backup(wallet) },
                                onDone: { model.confirmed(wallet) })
                case .restore: RestoreView(model: model)
                case .home: HomeView(model: model, engine: model.engine, prices: model.prices)
                case .unseal(let purpose): UnsealView(model: model, purpose: purpose)
                case .problem(let text):
                    Text(text).foregroundStyle(Theme.red).padding(40)
                }
            }
            .foregroundStyle(Theme.text)

            // Like the iPhone's app-switcher cover: when Zecky is not the app
            // in front, the window shows only the name, not balance or words.
            if covered {
                Theme.ink.ignoresSafeArea()
                VStack(spacing: 14) {
                    PadlockView(open: false, size: 120)
                    Text("Zecky Lock it").font(Theme.serif(28, weight: .medium)).foregroundStyle(Theme.muted)
                }
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didResignActiveNotification)) { _ in covered = true }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in covered = false }
        .frame(minWidth: 680, minHeight: 760)
        .font(Theme.text(14))
        .onAppear { model.launch() }
    }
}

/// The phrase is sealed and the next step needs it.
struct UnsealView: View {
    @ObservedObject var model: AppModel
    let purpose: AppModel.Unseal

    private var title: String {
        switch purpose {
        case .sealOlder: return "Seal your recovery phrase"
        case .finishBackup: return "Finish your backup"
        case .finishStart: return "Finish opening your wallet"
        }
    }

    private var text: String {
        switch purpose {
        case .sealOlder:
            return "Your recovery phrase is about to be sealed inside this Mac. From now on it only opens with Touch ID or your Mac password, and only for releasing or showing the words."
        case .finishBackup:
            return "Your 24 words are sealed. Open them to write them down and finish the backup."
        case .finishStart:
            return "The wallet needs your sealed phrase once to finish setting up. It is let go again straight after."
        }
    }

    var body: some View {
        VStack(spacing: 22) {
            PadlockView(open: false, size: 130)
            Text(title).font(Theme.serif(32, weight: .medium))
            Text(text)
                .font(Theme.text(14)).foregroundStyle(Theme.muted)
                .multilineTextAlignment(.center).frame(maxWidth: 440)
            if let message = model.message {
                Text(message).font(Theme.text(13)).foregroundStyle(Theme.red)
                    .multilineTextAlignment(.center).frame(maxWidth: 440)
            }
            PrimaryButton(title: model.busy ? "Waiting…" : "Continue", enabled: !model.busy) {
                Task { await model.unseal(purpose) }
            }
            .frame(width: 220)
            .keyboardShortcut(.defaultAction)
        }
        .padding(40)
    }
}
