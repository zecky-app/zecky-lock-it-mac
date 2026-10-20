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
                case .home(let wallet): HomeView(model: model, engine: model.engine, wallet: wallet)
                case .problem(let text):
                    Text(text).foregroundStyle(Theme.red).padding(40)
                }
            }
            .foregroundStyle(Theme.text)

            // Like the iPhone's app-switcher cover: when Zecky is not the app
            // in front, the window shows only the name, not balance or words.
            if covered {
                Theme.ink.ignoresSafeArea()
                Text("Zecky Lock it").font(Theme.serif(32, weight: .medium)).foregroundStyle(Theme.muted)
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didResignActiveNotification)) { _ in covered = true }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in covered = false }
        .frame(minWidth: 620, minHeight: 560)
        .font(Theme.text(14))
        .preferredColorScheme(.dark)
        .onAppear { model.launch() }
    }
}
