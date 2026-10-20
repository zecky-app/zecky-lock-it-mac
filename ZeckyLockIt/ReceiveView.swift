import AppKit
import CoreImage.CIFilterBuiltins
import SwiftUI

/// Receive: one private address, its QR code and a Copy button.
struct ReceiveView: View {
    @ObservedObject var engine: WalletEngine
    let onClose: () -> Void

    @State private var address: String?
    @State private var problem: String?
    @State private var copied = false
    @State private var showFull = false

    var body: some View {
        VStack(spacing: 18) {
            HStack {
                Text("Lock more").font(Theme.serif(24, weight: .medium))
                Spacer()
                Button("Done", action: onClose).keyboardShortcut(.cancelAction)
            }
            if let address {
                if let qr = QRCode.image(for: address) {
                    Image(nsImage: qr)
                        .interpolation(.none)
                        .resizable()
                        .frame(width: 220, height: 220)
                        .padding(12)
                        .background(Color.white)
                        .clipShape(RoundedRectangle(cornerRadius: 10))
                }
                Text("Private address").font(.system(size: 12, weight: .semibold)).foregroundStyle(Theme.muted)
                Text(showFull ? address : short(address))
                    .font(.system(size: 13, design: .monospaced))
                    .multilineTextAlignment(.center)
                    .textSelection(.enabled)
                    .frame(maxWidth: 460)
                Button(showFull ? "Show less" : "Show the full address") { showFull.toggle() }.buttonStyle(.link)
                PrimaryButton(title: copied ? "Copied" : "Copy address") {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(address, forType: .string)
                    copied = true
                }
                .frame(width: 220)
                Text("Zcash sent here is locked in. A fresh address appears once this one has been paid.")
                    .font(.system(size: 12)).foregroundStyle(Theme.muted)
            } else if let problem {
                Text(problem).foregroundStyle(Theme.red).multilineTextAlignment(.center)
            } else {
                ProgressView().padding(60)
            }
            Spacer(minLength: 0)
        }
        .padding(28)
        .frame(width: 540, height: 560)
        .background(Theme.ink)
        .foregroundStyle(Theme.text)
        .task {
            do { address = try await AddressBook.addressToShow(engine: engine) }
            catch { problem = "No address could be shown. \(error)" }
        }
    }

    private func short(_ a: String) -> String {
        a.count > 40 ? String(a.prefix(20)) + "…" + String(a.suffix(20)) : a
    }
}

enum QRCode {
    static func image(for text: String) -> NSImage? {
        let filter = CIFilter.qrCodeGenerator()
        filter.message = Data(text.utf8)
        filter.correctionLevel = "M"
        guard let output = filter.outputImage?.transformed(by: CGAffineTransform(scaleX: 8, y: 8)) else { return nil }
        let rep = NSCIImageRep(ciImage: output)
        let image = NSImage(size: rep.size)
        image.addRepresentation(rep)
        return image
    }
}
