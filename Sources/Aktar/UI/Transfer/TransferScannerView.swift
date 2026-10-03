import AVFoundation
import SwiftUI
import Vision

/// Reads a transfer QR code with the Mac's camera (built in, external or
/// Continuity Camera). The camera runs only while the import sheet shows
/// it and stops as soon as a code is read.
@MainActor
@Observable
final class TransferScanner {
    enum State: Equatable {
        case idle
        case starting
        case scanning
        case noCamera
        case denied
    }

    private(set) var state: State = .idle
    let capture = QRCapture()
    /// Gets the text of the first QR code read.
    var onFound: ((String) -> Void)?

    func start() {
        guard state != .starting, state != .scanning else { return }
        switch AVCaptureDevice.authorizationStatus(for: .video) {
        case .authorized:
            begin()
        case .notDetermined:
            state = .starting
            AVCaptureDevice.requestAccess(for: .video) { [weak self] granted in
                Task { @MainActor in
                    guard let self, self.state == .starting else { return }
                    if granted {
                        self.begin()
                    } else {
                        self.state = .denied
                    }
                }
            }
        default:
            state = .denied
        }
    }

    func stop() {
        capture.stop()
        if state == .starting || state == .scanning { state = .idle }
    }

    private func begin() {
        guard let device = Self.camera() else {
            state = .noCamera
            return
        }
        do {
            try capture.start(device: device) { [weak self] text in
                Task { @MainActor in
                    guard let self, self.state == .scanning else { return }
                    self.state = .idle
                    self.onFound?(text)
                }
            }
            state = .scanning
        } catch {
            state = .noCamera
        }
    }

    /// The camera macOS would pick, or any other one there is.
    private static func camera() -> AVCaptureDevice? {
        if let device = AVCaptureDevice.default(for: .video) { return device }
        return AVCaptureDevice.DiscoverySession(
            deviceTypes: [.builtInWideAngleCamera, .external, .continuityCamera],
            mediaType: .video,
            position: .unspecified
        ).devices.first
    }

    static func openPrivacySettings() {
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Camera") {
            NSWorkspace.shared.open(url)
        }
    }
}

/// The capture session and the Vision pass over its frames, off the main
/// thread. Starting and stopping a session blocks, so both run on their
/// own queue; frames arrive on another one.
final class QRCapture: NSObject, AVCaptureVideoDataOutputSampleBufferDelegate, @unchecked Sendable {
    enum CaptureError: Error {
        case unusable
    }

    let session = AVCaptureSession()
    private let sessionQueue = DispatchQueue(label: "com.getaktar.mac.qr-session")
    private let frameQueue = DispatchQueue(label: "com.getaktar.mac.qr-frames")
    private let lock = NSLock()
    /// Guarded by `lock`; nil once a code was read or the camera stopped.
    private var handler: (@Sendable (String) -> Void)?
    /// Only touched on `frameQueue`.
    private var lastScan = Date.distantPast

    func start(device: AVCaptureDevice, onFound: @escaping @Sendable (String) -> Void) throws {
        let input = try AVCaptureDeviceInput(device: device)
        let output = AVCaptureVideoDataOutput()
        output.alwaysDiscardsLateVideoFrames = true
        output.setSampleBufferDelegate(self, queue: frameQueue)

        session.beginConfiguration()
        session.inputs.forEach(session.removeInput)
        session.outputs.forEach(session.removeOutput)
        guard session.canAddInput(input), session.canAddOutput(output) else {
            session.commitConfiguration()
            throw CaptureError.unusable
        }
        session.addInput(input)
        session.addOutput(output)
        session.commitConfiguration()

        lock.withLock { handler = onFound }
        sessionQueue.async { self.session.startRunning() }
    }

    func stop() {
        lock.withLock { handler = nil }
        sessionQueue.async {
            if self.session.isRunning { self.session.stopRunning() }
        }
    }

    func captureOutput(_ output: AVCaptureOutput, didOutput sampleBuffer: CMSampleBuffer, from connection: AVCaptureConnection) {
        // A few looks a second are plenty, and keep the fans quiet.
        let now = Date()
        guard now.timeIntervalSince(lastScan) > 0.2,
              lock.withLock({ handler != nil }),
              let pixelBuffer = CMSampleBufferGetImageBuffer(sampleBuffer) else { return }
        lastScan = now

        let request = VNDetectBarcodesRequest()
        request.symbologies = [.qr]
        try? VNImageRequestHandler(cvPixelBuffer: pixelBuffer).perform([request])
        guard let text = request.results?.lazy.compactMap(\.payloadStringValue).first else { return }

        let found = lock.withLock {
            defer { handler = nil }
            return handler
        }
        guard let found else { return }
        stop()
        found(text)
    }
}

/// The live picture from `session`.
struct CameraPreview: NSViewRepresentable {
    let session: AVCaptureSession

    func makeNSView(context: Context) -> NSView {
        let view = NSView()
        let layer = AVCaptureVideoPreviewLayer(session: session)
        layer.videoGravity = .resizeAspectFill
        view.layer = layer
        view.wantsLayer = true
        return view
    }

    func updateNSView(_ nsView: NSView, context: Context) {}
}
