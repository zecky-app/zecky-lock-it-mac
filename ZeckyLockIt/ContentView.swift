import SwiftUI

struct ContentView: View {
    @StateObject private var model = AppModel()

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
                case .home: HomeView(engine: model.engine)
                case .problem(let text):
                    Text(text).foregroundStyle(Theme.red).padding(40)
                }
            }
            .foregroundStyle(Theme.text)
        }
        .frame(minWidth: 560, minHeight: 520)
        .preferredColorScheme(.dark)
        .onAppear { model.launch() }
    }
}
