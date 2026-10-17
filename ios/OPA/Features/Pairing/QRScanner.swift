import AVFoundation
import Observation
import SwiftUI

/// The scan page's view of the camera: permission state, the latest picture, and the QR codes it reads.
///
/// All AVFoundation, CoreImage and Vision work lives in `CameraEngine` on its own queue; this class only owns the
/// permission flow and republishes what the engine produces on the main actor. Start and stop follow the page's
/// lifecycle and the scene phase; every `start()` / `stop()` bumps `generation`, so a start that was overtaken by a
/// stop (permission prompt still open, session still warming up) quietly does nothing when it finally returns.
@MainActor
@Observable
final class QRScanner {
    enum Availability: Equatable {
        /// Checking permission, waiting for the answer to the system prompt, or warming the session up.
        case starting
        case running
        /// The user said no (or has not been asked and refused): the page offers the system settings.
        case denied
        /// Screen Time / device management forbids the camera.
        case restricted
        /// No camera at all: the Simulator.
        case noCamera
        /// The session could not be set up or kept running.
        case failed
    }

    private(set) var availability: Availability = .starting
    /// The newest camera picture (about 720 px on its long edge); nil until the first one arrives.
    private(set) var frame: CGImage?

    /// Called on the main actor for every QR payload the camera reads (the same code again and again while it stays
    /// in view: the receiver debounces).
    @ObservationIgnored var onCode: (String) -> Void = { _ in }

    @ObservationIgnored private var engine: CameraEngine?
    @ObservationIgnored private var generation = 0
    @ObservationIgnored private var consumers: [Task<Void, Never>] = []

    /// Checks permission (asking the first time) and starts the camera.
    func start() async {
        generation &+= 1
        let mine = generation
        cancelConsumers()

        #if DEBUG
        if await startDebugSource(generation: mine) { return }
        #endif

        guard CameraEngine.hasCamera else {
            availability = .noCamera
            return
        }
        availability = .starting
        switch AVCaptureDevice.authorizationStatus(for: .video) {
        case .authorized:
            break
        case .notDetermined:
            let granted = await AVCaptureDevice.requestAccess(for: .video)
            guard mine == generation else { return }
            guard granted else { availability = .denied; return }
        case .restricted:
            availability = .restricted
            return
        case .denied:
            availability = .denied
            return
        @unknown default:
            availability = .denied
            return
        }

        let engine = self.engine ?? CameraEngine()
        self.engine = engine
        do {
            let streams = try await engine.start()
            // Overtaken by a later stop() or start(): whichever came later already owns the engine (a stop here would
            // kill a session the newer start has just brought up), so just drop these streams.
            guard mine == generation else { return }
            availability = .running
            consume(streams, generation: mine)
        } catch {
            guard mine == generation else { return }
            availability = .failed
        }
    }

    /// Stops the camera. `keepFrame` leaves the last picture on screen (a code was just recognised).
    func stop(keepFrame: Bool = false) {
        generation &+= 1
        cancelConsumers()
        engine?.stop()
        if !keepFrame { frame = nil }
    }

    /// Stops the camera and releases the capture session (the pairing pages are being replaced).
    func shutdown() {
        stop()
        engine?.shutdown()
        engine = nil
    }

    // MARK: Private

    private func consume(_ streams: CameraStreams, generation mine: Int) {
        consumers = [
            Task { [weak self] in
                for await next in streams.frames {
                    guard let self, self.generation == mine else { return }
                    self.frame = next.image
                }
            },
            Task { [weak self] in
                for await code in streams.codes {
                    guard let self, self.generation == mine else { return }
                    self.onCode(code)
                }
            },
        ]
    }

    private func cancelConsumers() {
        consumers.forEach { $0.cancel() }
        consumers = []
    }

    #if DEBUG
    /// Launch arguments for Simulator runs (the Simulator has no camera):
    /// - `-OPAScanState denied|restricted|noCamera|failed`: show that panel instead of the camera;
    /// - `-OPAFakeScan <opa://pair?d=…>`: a still "camera picture" that shows that link as a QR code, read by the same
    ///   Vision detector the camera uses, so frame → detection → parsing → pairing can run end to end.
    private func startDebugSource(generation mine: Int) async -> Bool {
        let defaults = UserDefaults.standard
        if let state = defaults.string(forKey: "OPAScanState") {
            switch state {
            case "denied": availability = .denied
            case "restricted": availability = .restricted
            case "failed": availability = .failed
            default: availability = .noCamera
            }
            return true
        }
        guard let link = defaults.string(forKey: "OPAFakeScan"), let still = PairingDebug.syntheticCameraImage(showing: link) else {
            return false
        }
        availability = .running
        frame = PairingDebug.displayCopy(of: still)
        consumers = [
            Task { [weak self] in
                while !Task.isCancelled {
                    try? await Task.sleep(for: .milliseconds(450))
                    let code = await Task.detached { var detector = QRDetector(); return detector.firstCode(in: still) }.value
                    guard let self, self.generation == mine else { return }
                    if let code { self.onCode(code) }
                }
            },
        ]
        return true
    }
    #endif
}
