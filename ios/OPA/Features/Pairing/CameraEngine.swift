import AVFoundation
import CoreImage
import Vision

// The camera, kept entirely off the main actor.
//
// `CameraEngine` owns an `AVCaptureSession` with an `AVCaptureVideoDataOutput`. Every camera callback, every
// CoreImage conversion and every Vision request runs on the engine's one private serial queue, so all of its mutable
// state is confined to that queue (that is what the `@unchecked Sendable` stands on). Frames leave the engine only as
// `Sendable` values through two `AsyncStream`s, which `QRScanner` (main actor) reads. There is no
// `AVCaptureVideoPreviewLayer` and no UIKit: the picture is a `CGImage` that SwiftUI draws as an `Image`.

// MARK: - Output

/// One camera image (about 720 px on its long edge), ready for `Image(decorative:scale:)`.
struct CameraFrame: Sendable {
    let image: CGImage
}

/// What a running camera produces. Both streams finish when the camera stops.
struct CameraStreams: Sendable {
    /// The newest image about 18 times a second. Older images are dropped, never queued, so the picture never lags.
    let frames: AsyncStream<CameraFrame>
    /// QR payloads as they are read. A code that stays in view is reported again on every pass; the reader debounces.
    let codes: AsyncStream<String>
}

enum CameraError: Error {
    case noCamera
    case cannotConfigure
}

// MARK: - Engine

final class CameraEngine: NSObject, AVCaptureVideoDataOutputSampleBufferDelegate, @unchecked Sendable {
    /// Whether this device has a back camera at all (a Simulator does not).
    static var hasCamera: Bool { backCamera() != nil }

    private static func backCamera() -> AVCaptureDevice? {
        AVCaptureDevice.default(.builtInWideAngleCamera, for: .video, position: .back) ?? AVCaptureDevice.default(for: .video)
    }

    private let queue = DispatchQueue(label: "app.orbit.pairing.camera", qos: .userInitiated)

    // Everything below is only touched on `queue`.
    private var session: AVCaptureSession?
    private var frameSink: AsyncStream<CameraFrame>.Continuation?
    private var codeSink: AsyncStream<String>.Continuation?
    private var processor = FrameProcessor()
    private var detector = QRDetector()
    private var wantsRunning = false
    private var restartsLeft = 0
    private var errorObserver: (any NSObjectProtocol)?

    deinit {
        if let errorObserver { NotificationCenter.default.removeObserver(errorObserver) }
    }

    /// Configures the session on first use and starts it. Runs on the camera queue (`startRunning()` blocks).
    func start() async throws -> CameraStreams {
        try await withCheckedThrowingContinuation { continuation in
            queue.async {
                do {
                    continuation.resume(returning: try self.startOnQueue())
                } catch {
                    continuation.resume(throwing: error)
                }
            }
        }
    }

    /// Stops the session and ends both streams. Safe to call at any time, also while `start()` is still in flight
    /// (the queue is serial, so the stop lands after the start).
    func stop() {
        queue.async {
            self.wantsRunning = false
            self.session?.stopRunning()
            self.finishSinks()
        }
    }

    /// Stops the session and takes it apart (inputs, outputs, delegate), for when the pairing pages are gone for good.
    /// A later `start()` builds a new session.
    func shutdown() {
        queue.async {
            self.wantsRunning = false
            if let session = self.session {
                session.stopRunning()
                session.beginConfiguration()
                for output in session.outputs {
                    (output as? AVCaptureVideoDataOutput)?.setSampleBufferDelegate(nil, queue: nil)
                    session.removeOutput(output)
                }
                for input in session.inputs { session.removeInput(input) }
                session.commitConfiguration()
            }
            if let observer = self.errorObserver {
                NotificationCenter.default.removeObserver(observer)
                self.errorObserver = nil
            }
            self.session = nil
            self.finishSinks()
        }
    }

    // MARK: Queue-confined

    private func startOnQueue() throws -> CameraStreams {
        finishSinks()
        let session = try self.session ?? makeSession()
        self.session = session

        let (frames, frameSink) = AsyncStream.makeStream(of: CameraFrame.self, bufferingPolicy: .bufferingNewest(1))
        let (codes, codeSink) = AsyncStream.makeStream(of: String.self, bufferingPolicy: .bufferingNewest(4))
        self.frameSink = frameSink
        self.codeSink = codeSink
        processor.reset()
        wantsRunning = true
        restartsLeft = 3
        if !session.isRunning { session.startRunning() }
        return CameraStreams(frames: frames, codes: codes)
    }

    private func finishSinks() {
        frameSink?.finish()
        codeSink?.finish()
        frameSink = nil
        codeSink = nil
    }

    private func makeSession() throws -> AVCaptureSession {
        guard let device = Self.backCamera() else { throw CameraError.noCamera }
        let input = try AVCaptureDeviceInput(device: device)
        // A QR code on a Mac screen is close to the phone: restricting autofocus to the near range finds it faster.
        if (try? device.lockForConfiguration()) != nil {
            if device.isAutoFocusRangeRestrictionSupported { device.autoFocusRangeRestriction = .near }
            if device.isFocusModeSupported(.continuousAutoFocus) { device.focusMode = .continuousAutoFocus }
            device.unlockForConfiguration()
        }

        let session = AVCaptureSession()
        session.beginConfiguration()
        defer { session.commitConfiguration() }
        // Dense QR codes shown on a Mac screen need pixels: read 1080p, show a 720 px copy.
        session.sessionPreset = session.canSetSessionPreset(.hd1920x1080) ? .hd1920x1080 : .high
        guard session.canAddInput(input) else { throw CameraError.cannotConfigure }
        session.addInput(input)

        let output = AVCaptureVideoDataOutput()
        output.alwaysDiscardsLateVideoFrames = true
        output.setSampleBufferDelegate(self, queue: queue)
        guard session.canAddOutput(output) else { throw CameraError.cannotConfigure }
        session.addOutput(output)
        // The app is portrait only: have the capture pipeline deliver upright buffers (set before `startRunning()`).
        if let connection = output.connection(with: .video), connection.isVideoRotationAngleSupported(90) {
            connection.videoRotationAngle = 90
        }

        errorObserver = NotificationCenter.default.addObserver(forName: AVCaptureSession.runtimeErrorNotification,
                                                               object: session, queue: nil) { [weak self] _ in
            guard let self else { return }
            self.queue.async { self.restartAfterError() }
        }
        return session
    }

    /// A runtime error stops the session; a few automatic restarts cover transient ones (media services reset).
    private func restartAfterError() {
        guard wantsRunning, restartsLeft > 0, let session, !session.isRunning else { return }
        restartsLeft -= 1
        session.startRunning()
    }

    // MARK: AVCaptureVideoDataOutputSampleBufferDelegate (called on `queue`)

    func captureOutput(_ output: AVCaptureOutput, didOutput sampleBuffer: CMSampleBuffer, from connection: AVCaptureConnection) {
        guard let pixelBuffer = CMSampleBufferGetImageBuffer(sampleBuffer) else { return }
        let time = CMSampleBufferGetPresentationTimeStamp(sampleBuffer).seconds
        autoreleasepool {
            if processor.shouldPublish(at: time), let image = processor.displayImage(from: pixelBuffer) {
                frameSink?.yield(CameraFrame(image: image))
            }
            if processor.shouldScan(at: time), let code = detector.firstCode(in: pixelBuffer) {
                codeSink?.yield(code)
            }
        }
    }
}

// MARK: - Per-frame work

/// Throttling and conversion for the camera queue: a downscaled `CGImage` for display (about 18 fps) and a QR pass
/// (about 6 per second), both from the same full-resolution buffer. One reused `CIContext`.
struct FrameProcessor {
    private let context = CIContext(options: [.cacheIntermediates: false])
    private let colorSpace = CGColorSpace(name: CGColorSpace.sRGB)
    private let publishInterval = 1.0 / 18
    private let scanInterval = 0.16
    private let longEdge: CGFloat = 720

    private var lastPublish = -Double.infinity
    private var lastScan = -Double.infinity

    mutating func reset() {
        lastPublish = -.infinity
        lastScan = -.infinity
    }

    mutating func shouldPublish(at time: Double) -> Bool {
        guard time - lastPublish >= publishInterval else { return false }
        lastPublish = time
        return true
    }

    mutating func shouldScan(at time: Double) -> Bool {
        guard time - lastScan >= scanInterval else { return false }
        lastScan = time
        return true
    }

    /// The buffer scaled to about 720 px on its long edge.
    func displayImage(from pixelBuffer: CVPixelBuffer) -> CGImage? {
        displayImage(from: CIImage(cvPixelBuffer: pixelBuffer))
    }

    func displayImage(from image: CIImage) -> CGImage? {
        let extent = image.extent
        guard extent.width > 0, extent.height > 0 else { return nil }
        let scale = min(1, longEdge / max(extent.width, extent.height))
        let scaled = scale < 1 ? image.transformed(by: CGAffineTransform(scaleX: scale, y: scale), highQualityDownsample: true) : image
        return context.createCGImage(scaled, from: scaled.extent, format: .BGRA8, colorSpace: colorSpace)
    }
}

// MARK: - QR detection

/// Reads QR codes: Vision first, CoreImage's detector when Vision cannot run.
///
/// Vision's barcode request needs an on-device inference engine. Devices have one; the Simulator does not and
/// throws "Could not create inference context". A request that throws is retried through `CIDetector`, and after
/// `visionFailureLimit` failures in a row Vision is left out of the loop (a success resets the count). A frame
/// with no code in it is not a failure.
///
/// Not thread safe: each user keeps its own instance on one queue (the camera queue, or a throwaway one).
struct QRDetector {
    private let visionFailureLimit = 3
    private var visionFailures = 0
    private let coreImage = CIDetector(ofType: CIDetectorTypeQRCode, context: nil,
                                       options: [CIDetectorAccuracy: CIDetectorAccuracyHigh])

    /// The text of the first QR code in a camera buffer (already upright), or nil.
    mutating func firstCode(in pixelBuffer: CVPixelBuffer) -> String? {
        if visionFailures < visionFailureLimit {
            switch vision(VNImageRequestHandler(cvPixelBuffer: pixelBuffer, orientation: .up, options: [:])) {
            case .success(let code): return code
            case .failure: break
            }
        }
        return coreImageCode(in: CIImage(cvPixelBuffer: pixelBuffer))
    }

    /// The text of the first QR code in a still image, or nil.
    mutating func firstCode(in image: CGImage) -> String? {
        if visionFailures < visionFailureLimit {
            switch vision(VNImageRequestHandler(cgImage: image, orientation: .up, options: [:])) {
            case .success(let code): return code
            case .failure: break
            }
        }
        return coreImageCode(in: CIImage(cgImage: image))
    }

    /// `.success(nil)`: Vision ran and found no code. `.failure`: Vision could not run.
    private mutating func vision(_ handler: VNImageRequestHandler) -> Result<String?, any Error> {
        let request = VNDetectBarcodesRequest()
        request.symbologies = [.qr]
        do {
            try handler.perform([request])
        } catch {
            visionFailures += 1
            return .failure(error)
        }
        visionFailures = 0
        for observation in request.results ?? [] {
            if let payload = observation.payloadStringValue, !payload.isEmpty { return .success(payload) }
        }
        return .success(nil)
    }

    private func coreImageCode(in image: CIImage) -> String? {
        for feature in coreImage?.features(in: image) ?? [] {
            if let message = (feature as? CIQRCodeFeature)?.messageString, !message.isEmpty { return message }
        }
        return nil
    }
}
