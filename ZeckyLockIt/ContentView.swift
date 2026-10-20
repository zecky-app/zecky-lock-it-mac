import SwiftUI
import ZcashLightClientKit

// First test build: only proves that the official Zcash SDK
// builds and links on macOS. No keys, no network calls yet.
struct ContentView: View {
    var body: some View {
        VStack(spacing: 8) {
            Text("Zecky Lock it")
                .font(.system(size: 28, weight: .medium, design: .serif))
            Text("Mac test build")
                .foregroundStyle(.secondary)
        }
        .frame(minWidth: 420, minHeight: 280)
        .padding()
    }
}
