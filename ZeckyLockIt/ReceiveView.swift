import AppKit
import CoreImage.CIFilterBuiltins
import SwiftUI

/// Lock more: one private address, its QR code with the Z, and Copy.
struct ReceiveView: View {
    @ObservedObject var engine: WalletEngine
    let onClose: () -> Void

    @State private var address: String?
    @State private var problem: String?
    @State private var copied = false

    var body: some View {
        SheetScaffold(title: "Lock more",
                      subtitle: "Send Zcash to this private address. It locks in by itself.",
                      height: 500,
                      onClose: onClose) {
            if let address {
                HStack(alignment: .top, spacing: 20) {
                    qrCard(address)
                    VStack(alignment: .leading, spacing: 12) {
                        Text("PRIVATE ADDRESS").font(Theme.text(11, weight: .semibold)).tracking(1.4).foregroundStyle(Theme.muted)
                        Text(grouped(address))
                            .font(.system(size: 12.5, design: .monospaced))
                            .lineSpacing(4)
                            .textSelection(.enabled)
                            .fixedSize(horizontal: false, vertical: true)
                        PrimaryButton(title: copied ? "Copied ✓" : "Copy address") {
                            NSPasteboard.general.clearContents()
                            NSPasteboard.general.setString(address, forType: .string)
                            withAnimation { copied = true }
                            DispatchQueue.main.asyncAfter(deadline: .now() + 2) { withAnimation { copied = false } }
                        }
                        .padding(.top, 4)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }

                HStack(alignment: .top, spacing: 10) {
                    Image(systemName: "shield.lefthalf.filled").foregroundStyle(Theme.gold)
                    Text("Shielded: amounts, sender and this address stay private on the blockchain. Once this address has been paid, a fresh one appears here, so payments can't be linked.")
                        .font(Theme.text(12)).foregroundStyle(Theme.muted)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .card(padding: 14)
                .padding(.top, 20)
            } else if let problem {
                Text(problem).foregroundStyle(Theme.red)
                Spacer()
            } else {
                HStack { Spacer(); ProgressView(); Spacer() }.padding(.top, 80)
                Spacer()
            }
        }
        .task {
            do { address = try await AddressBook.addressToShow(engine: engine) }
            catch { problem = "No address could be shown. \(error)" }
        }
    }

    private func qrCard(_ address: String) -> some View {
        ZStack {
            if let qr = QRCode.image(for: address) {
                Image(nsImage: qr).interpolation(.none).resizable()
                    .frame(width: 208, height: 208)
            }
            // The Z in the middle; the code is made with high error
            // correction so it still scans.
            RoundedRectangle(cornerRadius: 9, style: .continuous)
                .fill(Theme.plateInk)
                .frame(width: 46, height: 46)
                .overlay(Text("Z").font(Theme.serif(30, weight: .medium)).foregroundStyle(Theme.metalGold).offset(y: -1))
                .overlay(RoundedRectangle(cornerRadius: 9).stroke(Color.white, lineWidth: 3))
        }
        .padding(14)
        .background(Color.white, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous).stroke(Theme.gold.opacity(0.8), lineWidth: 1.5))
        .padding(3)
        .overlay(RoundedRectangle(cornerRadius: 17, style: .continuous).stroke(Theme.gold.opacity(0.25), lineWidth: 1))
        .accessibilityLabel("QR code of your private address")
    }

    /// "u1ab cdef …": groups of four, easier to compare by eye.
    private func grouped(_ a: String) -> String {
        stride(from: 0, to: a.count, by: 4).map { i -> String in
            let start = a.index(a.startIndex, offsetBy: i)
            let end = a.index(start, offsetBy: min(4, a.count - i))
            return String(a[start..<end])
        }.joined(separator: " ")
    }
}

enum QRCode {
    static func image(for text: String) -> NSImage? {
        let filter = CIFilter.qrCodeGenerator()
        filter.message = Data(text.utf8)
        filter.correctionLevel = "H"
        guard let output = filter.outputImage?.transformed(by: CGAffineTransform(scaleX: 8, y: 8)) else { return nil }
        let rep = NSCIImageRep(ciImage: output)
        let image = NSImage(size: rep.size)
        image.addRepresentation(rep)
        return image
    }
}
