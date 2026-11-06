//
//  SealItQRViews.swift
//  Zecky Lock it (Mac) — Seal it / Keystone air-gapped signing
//
//  - AnimatedURQRView: shows a UR as an animated QR code on the Mac screen.
//  - QRCameraScanner + CameraPreview: reads QR codes with the Mac camera
//    (AVFoundation + Vision; macOS has no AVCaptureMetadataOutput for QR).
//  - URScannerView: camera box + progress that collects one whole UR.
//
//  Needs NSCameraUsageDescription and com.apple.security.device.camera.
//

import AppKit
import AVFoundation
import CoreImage
import CoreImage.CIFilterBuiltins
import SwiftUI
import Vision

// MARK: - Animated QR (Mac -> signer)

struct AnimatedURQRView: View {
    let encoder: SealItUREncoder
    /// Zashi uses 0.2 s with Keystone. A little slower is kinder to phone cameras.
    var frameInterval: TimeInterval = 0.25

    @State private var image: NSImage?
    @State private var timer: Timer?

    var body: some View {
        ZStack {
            Color.white
            if let image {
                Image(nsImage: image)
                    .interpolation(.none)
                    .resizable()
                    .scaledToFit()
                    .padding(16)
            }
        }
        .aspectRatio(1, contentMode: .fit)
        .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
        .onAppear(perform: start)
        .onDisappear(perform: stop)
    }

    private func start() {
        showNext()
        guard !encoder.isSinglePart else { return }
        timer?.invalidate()
        timer = Timer.scheduledTimer(withTimeInterval: frameInterval, repeats: true) { _ in
            showNext()
        }
    }

    private func stop() {
        timer?.invalidate()
        timer = nil
    }

    private func showNext() {
        image = QRRenderer.image(for: encoder.nextPart())
    }
}

enum QRRenderer {
    private static let context = CIContext()

    static func image(for string: String) -> NSImage? {
        let filter = CIFilter.qrCodeGenerator()
        filter.message = Data(string.utf8)
        filter.correctionLevel = "L"
        guard let output = filter.outputImage?
            .transformed(by: CGAffineTransform(scaleX: 10, y: 10)),
              let cg = context.createCGImage(output, from: output.extent) else { return nil }
        return NSImage(cgImage: cg, size: NSSize(width: output.extent.width, height: output.extent.height))
    }
}

// MARK: - Camera scanner (signer -> Mac)

final class QRCameraScanner: NSObject, ObservableObject, AVCaptureVideoDataOutputSampleBufferDelegate {
    enum State: Equatable { case idle, running, denied, noCamera }

    @Published private(set) var state: State = .idle
    let session = AVCaptureSession()

    /// Called on the main thread for every new QR payload seen.
    var onCode: ((String) -> Void)?

    private let queue = DispatchQueue(label: "app.zecky.lockit.qrscanner")
    private var configured = false
    private var busy = false
    private var lastPayload: String?

    @MainActor
    func start() async {
        let status = AVCaptureDevice.authorizationStatus(for: .video)
        if status == .notDetermined {
            let granted = await AVCaptureDevice.requestAccess(for: .video)
            if !granted { state = .denied; return }
        } else if status != .authorized {
            state = .denied
            return
        }
        guard configureIfNeeded() else { state = .noCamera; return }
        queue.async { [weak self] in
            self?.lastPayload = nil
            self?.session.startRunning()
        }
        state = .running
    }

    func stop() {
        queue.async { [session] in
            if session.isRunning { session.stopRunning() }
        }
        DispatchQueue.main.async { self.state = .idle }
    }

    private func configureIfNeeded() -> Bool {
        if configured { return true }
        guard let device = AVCaptureDevice.default(for: .video),
              let input = try? AVCaptureDeviceInput(device: device) else { return false }
        session.beginConfiguration()
        session.sessionPreset = .high
        if session.canAddInput(input) { session.addInput(input) }
        let output = AVCaptureVideoDataOutput()
        output.alwaysDiscardsLateVideoFrames = true
        output.setSampleBufferDelegate(self, queue: queue)
        if session.canAddOutput(output) { session.addOutput(output) }
        session.commitConfiguration()
        configured = true
        return true
    }

    func captureOutput(_ output: AVCaptureOutput,
                       didOutput sampleBuffer: CMSampleBuffer,
                       from connection: AVCaptureConnection) {
        guard !busy, let pixelBuffer = CMSampleBufferGetImageBuffer(sampleBuffer) else { return }
        busy = true
        defer { busy = false }

        let request = VNDetectBarcodesRequest()
        request.symbologies = [.qr]
        request.revision = VNDetectBarcodesRequestRevision3
        let handler = VNImageRequestHandler(cvPixelBuffer: pixelBuffer, options: [:])
        try? handler.perform([request])

        for observation in request.results ?? [] {
            // Binary-mode codes (Seal it's account export) may come without a
            // string; read the raw bytes then.
            // Prefer the raw bytes: Vision can turn a binary-mode code into
            // a garbled string.
            let raw = (observation.barcodeDescriptor as? CIQRCodeDescriptor)?.errorCorrectedPayload
            let payload: String
            if let raw, let text = QRPayload.byteModeText(raw) {
                payload = text
            } else if let text = observation.payloadStringValue {
                payload = text
            } else { continue }
            // Vision sometimes reports half-read codes as empty; skip those.
            guard !payload.trimmingCharacters(in: .whitespacesAndNewlines.union(.controlCharacters)).isEmpty,
                  payload != lastPayload else { continue }
            lastPayload = payload
            DispatchQueue.main.async { [weak self] in self?.onCode?(payload) }
        }
    }
}

/// Extracts the text of a byte-mode QR code from its raw (error-corrected) data.
enum QRPayload {
    static func byteModeText(_ data: Data) -> String? {
        let bytes = [UInt8](data)
        var bits = BitReader(bytes)
        var mode = bits.read(4)
        if mode == 0b0111 { _ = bits.read(8); mode = bits.read(4) } // skip an ECI header
        guard mode == 0b0100 else { return nil }
        // Character-count width depends on the QR version; try the common ones.
        for width in [16, 8] {
            var b = bits
            guard let count = b.read(width) else { continue }
            var out: [UInt8] = []
            for _ in 0..<count {
                guard let byte = b.read(8) else { out = []; break }
                out.append(UInt8(byte))
            }
            if out.count == count, let text = String(bytes: out, encoding: .utf8), text.lowercased().contains("ur:") {
                return text
            }
        }
        return nil
    }

    private struct BitReader {
        let bytes: [UInt8]
        var position = 0
        init(_ bytes: [UInt8]) { self.bytes = bytes }
        mutating func read(_ n: Int) -> Int? {
            guard position + n <= bytes.count * 8 else { return nil }
            var value = 0
            for _ in 0..<n {
                let bit = (bytes[position / 8] >> (7 - UInt8(position % 8))) & 1
                value = (value << 1) | Int(bit)
                position += 1
            }
            return value
        }
    }
}

struct CameraPreview: NSViewRepresentable {
    let session: AVCaptureSession

    func makeNSView(context: Context) -> NSView {
        let view = NSView()
        view.wantsLayer = true
        let layer = AVCaptureVideoPreviewLayer(session: session)
        layer.videoGravity = .resizeAspectFill
        view.layer = layer
        return view
    }

    func updateNSView(_ nsView: NSView, context: Context) {}
}

/// Camera box + progress bar that collects one UR of `expectedType`.
struct URScannerView: View {
    let expectedType: String
    let onComplete: (Data) -> Void

    @StateObject private var scanner = QRCameraScanner()
    @State private var decoder: SealItURDecoder?
    @State private var progress: Double = 0
    @State private var note: String?
    @State private var done = false

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            ZStack {
                Color.black
                switch scanner.state {
                case .denied:
                    Text("Camera access is off. Allow Zecky Lock it in System Settings → Privacy & Security → Camera.")
                        .font(Theme.text(13)).foregroundStyle(.white)
                        .multilineTextAlignment(.center).padding()
                case .noCamera:
                    Text("No camera found.").font(Theme.text(13)).foregroundStyle(.white)
                default:
                    CameraPreview(session: scanner.session)
                }
            }
            .aspectRatio(4 / 3, contentMode: .fit)
            .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous).stroke(Theme.line, lineWidth: 1))

            if progress > 0 && progress < 1 {
                ProgressView(value: progress).tint(Theme.gold)
            }
            if let note {
                Text(note).font(Theme.text(12)).foregroundStyle(Theme.muted)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .task {
            decoder = SealItURDecoder(expectedType: expectedType)
            scanner.onCode = { handle($0) }
            await scanner.start()
        }
        .onDisappear { scanner.stop() }
    }

    private func handle(_ payload: String) {
        guard !done, let decoder else { return }
        do {
            let complete = try decoder.receive(payload)
            progress = decoder.progress
            note = nil
            if complete, let data = decoder.message {
                done = true
                scanner.stop()
                onComplete(data)
            }
        } catch {
            note = error.localizedDescription
        }
    }
}
