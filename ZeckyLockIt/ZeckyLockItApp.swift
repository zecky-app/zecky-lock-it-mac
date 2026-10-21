import AppKit
import SwiftUI

@main
struct ZeckyLockItApp: App {
    @StateObject private var model = AppModel()

    init() {
        Theme.registerFonts()
        DispatchQueue.main.async { Theme.apply(Theme.mode) }
    }

    var body: some Scene {
        // One wallet, one window.
        Window("Zecky Lock it", id: "main") {
            ContentView(model: model)
        }
        .defaultSize(width: 880, height: 820)
        .commands {
            CommandGroup(replacing: .appInfo) {
                Button("About Zecky Lock it") { About.show() }
            }
            CommandGroup(replacing: .appSettings) {
                Button("Settings…") { model.sheet = .settings }
                    .keyboardShortcut(",", modifiers: .command)
                    .disabled(!model.hasWallet)
            }
            CommandGroup(replacing: .newItem) {}
            CommandMenu("Lock") {
                Button("Lock more") { model.sheet = .receive }
                    .keyboardShortcut("l", modifiers: .command)
                    .disabled(!model.hasWallet)
                Button("Open the lock…") { model.askToOpen() }
                    .keyboardShortcut("o", modifiers: [.command, .shift])
                    .disabled(!model.hasWallet)
                Divider()
                Button("Activity") { model.sheet = .activity }
                    .keyboardShortcut("y", modifiers: .command)
                    .disabled(!model.hasWallet)
            }
        }
    }
}

enum About {
    static func show() {
        let credits = NSAttributedString(
            string: "Self-custody Zcash, kept on this Mac.\nzecky.app\n\nNewsreader and Inter fonts: SIL Open Font License 1.1.",
            attributes: [.font: NSFont.systemFont(ofSize: 11), .foregroundColor: NSColor.secondaryLabelColor])
        NSApp.orderFrontStandardAboutPanel(options: [.credits: credits, .applicationName: "Zecky Lock it"])
        NSApp.activate(ignoringOtherApps: true)
    }
}
