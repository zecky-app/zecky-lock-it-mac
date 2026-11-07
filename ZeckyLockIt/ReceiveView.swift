import AppKit
import CoreImage.CIFilterBuiltins
import SwiftUI

/// Lock more: the QR with the Z gets the room; the address as one short
/// line, click to copy; then Request an amount and All addresses.
struct ReceiveView: View {
    @ObservedObject var engine: WalletEngine
    @ObservedObject var prices: PriceFeed
    let onClose: () -> Void

    private enum Mode { case address, request, all }
    @State private var mode: Mode = .address
    @State private var address: String?
    @State private var problem: String?
    @State private var copied = false
    @State private var requestText = ""
    /// Ask in the currency chosen under Settings › Value; the request
    /// itself always carries the ZEC amount.
    @State private var requestFiat = false
    @State private var usage: [String: Int] = [:]
    @State private var copiedOther: String?

    var body: some View {
        SheetScaffold(title: mode == .all ? "All addresses" : "Receive",
                      subtitle: mode == .all ? "Every shielded address this wallet has handed out." : "Your shielded address: amount and sender stay hidden. Zcash sent here locks in by itself.",
                      height: 600,
                      onClose: onClose) {
            if let address {
                switch mode {
                case .address, .request: main(address)
                case .all: allAddresses
                }
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

    // MARK: The address

    private func main(_ address: String) -> some View {
        let payload = requestURI(address)
        return VStack(spacing: 14) {
            qrCard(payload ?? address)
            if mode == .request {
                VStack(spacing: 6) {
                    HStack(spacing: 8) {
                        Text("Ask for").font(Theme.text(13)).foregroundStyle(Theme.muted)
                        TextField("", text: $requestText, prompt: Text(requestFiat ? "0.00" : "0.000").foregroundColor(Theme.muted.opacity(0.6)))
                            .textFieldStyle(.plain).font(Theme.serif(22, weight: .medium))
                            .multilineTextAlignment(.trailing).frame(width: 120)
                        if rate != nil {
                            Chip(title: "ZEC", on: !requestFiat) { requestFiat = false; requestText = "" }
                            Chip(title: prices.currency.short, on: requestFiat) { requestFiat = true; requestText = "" }
                        } else {
                            Text("ZEC").font(Theme.text(13, weight: .medium)).foregroundStyle(Theme.muted)
                        }
                    }
                    .padding(.horizontal, 14).frame(height: 40)
                    .background(Theme.surface, in: RoundedRectangle(cornerRadius: 10))
                    .overlay(RoundedRectangle(cornerRadius: 10).stroke(Theme.line))
                    if requestFiat, let zec = requestZEC {
                        Text("The request asks for \(zec) ZEC, at CoinGecko's price of a few minutes ago.")
                            .font(Theme.text(11)).foregroundStyle(Theme.gold)
                    }
                }
            }
            Button { copy(payload ?? address) } label: {
                VStack(spacing: 4) {
                    Text(shortGrouped(address))
                        .font(.system(size: 13, design: .monospaced)).foregroundStyle(Theme.text)
                    Text(copied ? "Copied ✓" : (payload != nil ? "Click to copy the request" : "Click to copy"))
                        .font(Theme.text(11, weight: .medium)).foregroundStyle(copied ? Theme.green : Theme.gold)
                }
                .padding(.horizontal, 16).padding(.vertical, 8)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help(grouped(address))
            HStack(spacing: 18) {
                link(mode == .request ? "Just the address" : "Request an amount") {
                    mode = mode == .request ? .address : .request; requestText = ""
                }
                Text("·").foregroundStyle(Theme.muted.opacity(0.6))
                link("All addresses") { mode = .all; Task { usage = (try? await engine.addressUsage()) ?? [:] } }
            }
            Spacer(minLength: 0)
            Label("Shielded: amounts, sender and this address stay private. Once it has been paid, a fresh one appears here.", systemImage: "shield.lefthalf.filled")
                .font(Theme.text(11)).foregroundStyle(Theme.muted)
                .labelStyle(GoldIconLabelStyle())
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity)
    }

    private var rate: Double? {
        guard prices.currency != .none else { return nil }
        return prices.rates[prices.currency.rawValue]
    }

    /// The ZEC amount asked for, as text with at most 8 decimals.
    private var requestZEC: String? {
        let text = requestText.trimmingCharacters(in: .whitespaces).replacingOccurrences(of: ",", with: ".")
        if requestFiat {
            guard let rate, rate > 0, let value = Double(text), value > 0 else { return nil }
            let zats = (value / rate * 100_000_000).rounded()
            guard zats >= 1 else { return nil }
            var zec = String(format: "%.8f", zats / 100_000_000)
            while zec.hasSuffix("0") { zec.removeLast() }
            if zec.hasSuffix(".") { zec.removeLast() }
            return zec
        }
        guard let value = Decimal(string: text, locale: Locale(identifier: "en_US")), value > 0, value < 21_000_000,
              text.range(of: #"^\d+(\.\d{1,8})?$"#, options: .regularExpression) != nil else { return nil }
        return text
    }

    /// ZIP-321 request: "zcash:<address>?amount=0.5". Nil without a valid amount.
    private func requestURI(_ address: String) -> String? {
        guard mode == .request, let zec = requestZEC else { return nil }
        return "zcash:\(address)?amount=\(zec)"
    }

    // MARK: All addresses

    private var allAddresses: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("They all lead to the same lock. A fresh one for each payer keeps payments from being linked to each other; an older one still works.")
                .font(Theme.text(12)).foregroundStyle(Theme.muted)
                .fixedSize(horizontal: false, vertical: true)
            ScrollView {
                VStack(spacing: 0) {
                    ForEach(Array(AddressBook.load().enumerated()), id: \.element) { i, a in
                        if i > 0 { Rectangle().fill(Theme.line).frame(height: 1) }
                        Button { copy(a); copiedOther = a } label: {
                            HStack {
                                Text(shortGrouped(a)).font(.system(size: 12, design: .monospaced)).foregroundStyle(Theme.text)
                                Spacer()
                                let paid = usage[a] ?? 0
                                Text(copiedOther == a ? "Copied ✓" : (paid == 0 ? "Not paid yet" : "Paid \(paid)×"))
                                    .font(Theme.text(11, weight: .medium))
                                    .foregroundStyle(copiedOther == a ? Theme.green : Theme.muted)
                            }
                            .padding(.horizontal, 12).padding(.vertical, 10)
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .help(grouped(a))
                    }
                }
                .card(padding: 4)
            }
            link("Back to your shielded address") { mode = .address }
        }
    }

    // MARK: Pieces

    private func link(_ title: String, _ action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(title).font(Theme.text(12, weight: .medium)).foregroundStyle(Theme.gold).contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    private func copy(_ text: String) {
        ReceiveAddress.copy(text)
        withAnimation { copied = true }
        DispatchQueue.main.asyncAfter(deadline: .now() + 2) { withAnimation { copied = false; copiedOther = nil } }
    }

    private func qrCard(_ text: String) -> some View {
        ZStack {
            if let qr = QRCode.image(for: text) {
                Image(nsImage: qr).interpolation(.none).resizable()
                    .frame(width: 250, height: 250)
            }
            // The Z in the middle; the code is made with high error
            // correction so it still scans.
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(Theme.plateInk)
                .frame(width: 54, height: 54)
                .overlay(Text("Z").font(Theme.serif(34, weight: .medium)).foregroundStyle(Theme.metalGold).offset(y: -1))
                .overlay(RoundedRectangle(cornerRadius: 10).stroke(QRCode.paper, lineWidth: 3))
        }
        // About 4 modules of quiet zone, as the QR standard asks.
        .padding(18)
        .background(QRCode.paper, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 16, style: .continuous).stroke(Theme.gold.opacity(0.8), lineWidth: 1.5))
        .padding(3)
        .overlay(RoundedRectangle(cornerRadius: 19, style: .continuous).stroke(Theme.gold.opacity(0.25), lineWidth: 1))
        .accessibilityLabel("QR code of your shielded address")
    }

    /// "u1ab cdef … wxyz": a short line in groups of four.
    private func shortGrouped(_ a: String) -> String {
        guard a.count > 24 else { return grouped(a) }
        return grouped(String(a.prefix(12))) + " … " + grouped(String(a.suffix(8)))
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
    /// Dark ink on a light paper color, whatever the theme, so every scanner
    /// reads it (as Lock it iPhone).
    static let paper = Color(red: 0xEC / 255, green: 0xE8 / 255, blue: 0xDF / 255)

    static func image(for text: String) -> NSImage? {
        let filter = CIFilter.qrCodeGenerator()
        filter.message = Data(text.utf8)
        filter.correctionLevel = "H"
        let colors = CIFilter.falseColor()
        colors.inputImage = filter.outputImage
        colors.color0 = CIColor(red: 0x14 / 255, green: 0x16 / 255, blue: 0x1C / 255)
        colors.color1 = CIColor(red: 0xEC / 255, green: 0xE8 / 255, blue: 0xDF / 255)
        guard let output = colors.outputImage?.transformed(by: CGAffineTransform(scaleX: 8, y: 8)) else { return nil }
        let rep = NSCIImageRep(ciImage: output)
        let image = NSImage(size: rep.size)
        image.addRepresentation(rep)
        return image
    }
}

/// The one place Lock it uses the clipboard: copying a receive address
/// (also for a sealed wallet). Nothing secret is ever copied.
enum ReceiveAddress {
    static func copy(_ address: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(address, forType: .string)
    }
}
