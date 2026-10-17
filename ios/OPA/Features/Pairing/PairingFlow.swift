import Observation
import SwiftUI

// MARK: - Stage

/// What the pairing UI shows. It is derived from `AppModel.connection`, so a pairing started anywhere (the scanner,
/// pasted text, an `opa://pair` link, a launch argument) lands on the right page.
enum PairingStage: Equatable {
    case welcome
    /// Dialling the Mac (`retrying`: it did not answer yet, the connection manager keeps trying).
    case connecting(hostName: String, retrying: Bool)
    /// The six-digit code both sides must show.
    case verify(code: String, hostName: String, path: TransportPath)
    case failed(reason: String)
    /// Pairing finished; waiting for "开始和 Orbit 聊聊".
    case paired(PairedHost)

    /// Page identity: the transition runs when this changes, not when the digits of the code do.
    enum Kind: Hashable { case welcome, connecting, verify, failed, paired }

    var kind: Kind {
        switch self {
        case .welcome: .welcome
        case .connecting: .connecting
        case .verify: .verify
        case .failed: .failed
        case .paired: .paired
        }
    }
}

/// A short line under the viewfinder ("这不是 Orbit 的配对二维码").
struct ScanHint: Equatable {
    var text: String
}

// MARK: - Flow

/// The pairing flow's state that does not live in `AppModel`: which sheets are up, what the scanner just saw, and
/// the finished pairing that is waiting for the "开始" tap.
///
/// Pairing itself stays in the core: this class only parses what the scanner / paste field / photo produced,
/// hands valid links to `AppModel.pair(with:)`, and reads the result back from `AppModel.connection`.
@MainActor
@Observable
final class PairingFlow {
    // MARK: Presentation

    var scannerPresented = false
    var pastePresented = false

    // MARK: Scanner feedback

    let scanner = QRScanner()
    /// Set when a valid code was just read: the scan page shows "识别到 …" before it gives way to the next page.
    private(set) var recognizedHostName: String?
    private(set) var hint: ScanHint?
    /// Bumped on every accepted code (drives the haptic).
    private(set) var recognitionCount = 0

    // MARK: Finished pairing

    /// The Mac that has just been paired. The core would switch to the main screen at that very moment; the success
    /// page keeps the screen until the user continues (see `attach(to:)`).
    private(set) var completedHost: PairedHost?

    @ObservationIgnored private weak var model: AppModel?
    @ObservationIgnored private var interception: Interception?
    @ObservationIgnored private var hintTask: Task<Void, Never>?
    @ObservationIgnored private var dismissTask: Task<Void, Never>?

    /// How long "识别到 …" stays up before the scan page closes.
    private var recognitionDwell: Duration {
        #if DEBUG
        // `-OPARecognitionDwell <seconds>` holds the page open so it can be screenshotted.
        let override = UserDefaults.standard.double(forKey: "OPARecognitionDwell")
        if override > 0 { return .seconds(override) }
        #endif
        return .milliseconds(900)
    }

    // MARK: - Wiring

    /// Connects the flow to the model and holds back the core's "pairing finished" step.
    ///
    /// `AppModel` shows the main screen the moment `ConnectionManager.onPaired` fires, which would remove the pairing
    /// UI before it can say "连上了". So while the pairing pages are on screen `onPaired` is wrapped: the paired Mac is
    /// kept here, the success page is shown, and the original handler (which sets `AppModel.pairedHost`) runs when the
    /// user taps the button. The host is already saved by then; if the app is closed on the success page the next
    /// launch goes straight to the main screen. If this flow is gone the wrapper forwards immediately.
    func attach(to model: AppModel) {
        self.model = model
        scanner.onCode = { [weak self] code in self?.scanned(code) }
        guard interception == nil else { return }
        let manager = model.connectionManager
        let original = manager.onPaired
        let interception = Interception(manager: manager, forward: original)
        self.interception = interception
        manager.onPaired = { [weak self, weak interception] host in
            guard let self, let interception, self.interception === interception else { original(host); return }
            self.hold(host)
        }
    }

    /// Gives `onPaired` back (the pairing pages are being replaced). A held pairing is never swallowed.
    func detach() {
        scanner.shutdown()
        guard let interception else { return }
        interception.manager.onPaired = interception.forward
        if let host = completedHost, !interception.delivered {
            interception.delivered = true
            interception.forward(host)
        }
        self.interception = nil
    }

    private func hold(_ host: PairedHost) {
        dismissTask?.cancel()
        completedHost = host
        scannerPresented = false
        pastePresented = false
    }

    /// "开始和 Orbit 聊聊": lets the core finish pairing, which swaps the pairing pages for the main screen.
    func finish() {
        guard let host = completedHost, let interception, !interception.delivered else { return }
        interception.delivered = true
        interception.forward(host)
        // The connection normally stays up through the success page. If something stopped it meanwhile (a second pairing
        // that was cancelled), nothing would ever bring it back: the core only starts it at launch.
        if let model, case .idle = model.connection { model.connectionManager.start(host: host) }
    }

    // MARK: - Actions

    func presentScanner() {
        model?.pairingError = nil
        recognizedHostName = nil
        hint = nil
        scannerPresented = true
    }

    func presentPaste() {
        model?.pairingError = nil
        pastePresented = true
    }

    /// Stops a pairing in progress and clears what it left behind.
    func cancel() {
        dismissTask?.cancel()
        model?.cancelPairing()
        model?.pairingError = nil
        recognizedHostName = nil
        hint = nil
    }

    /// "重试" after a failure: the pair token is single use, so the way forward is a fresh code from the Mac.
    func retry() {
        cancel()
        presentScanner()
    }

    /// A pasted link. Returns the reason it was refused, or nil when pairing has started.
    func submit(link: String) -> String? {
        switch Self.evaluate(link) {
        case .invalid(let reason):
            return reason
        case .valid(let payload):
            accept(link: link.trimmingCharacters(in: .whitespacesAndNewlines), payload: payload)
            return nil
        }
    }

    /// A code the camera read (or the photo picker found). Anything that is not a valid, fresh pairing code shows a hint
    /// instead; the same wrong code seen again just keeps the hint up.
    func scanned(_ code: String) {
        guard recognizedHostName == nil, completedHost == nil else { return }
        switch Self.evaluate(code, forScanning: true) {
        case .invalid(let reason):
            show(reason)
        case .valid(let payload):
            accept(link: code.trimmingCharacters(in: .whitespacesAndNewlines), payload: payload)
        }
    }

    /// A photo from the library: find the QR code in it, then treat it like a scanned one.
    func scanned(imageData data: Data?) async {
        guard let data else {
            show("无法读取这张图片")
            return
        }
        let text = await Task.detached(priority: .userInitiated) { ImageTools.decodeQR(from: data) }.value
        guard let text else {
            show("图片里没有找到二维码")
            return
        }
        scanned(text)
    }

    func show(_ text: String) {
        guard hint?.text != text else { restartHintTimer(); return }
        hint = ScanHint(text: text)
        AccessibilityNotification.Announcement(text).post()
        restartHintTimer()
    }

    // MARK: - Internals

    private func accept(link: String, payload: PairingPayload) {
        hintTask?.cancel()
        hint = nil
        recognizedHostName = payload.hostName
        recognitionCount += 1
        scanner.stop(keepFrame: true)
        pastePresented = false
        model?.pairingError = nil
        model?.pair(with: link)
        AccessibilityNotification.Announcement("识别到 \(payload.hostName)，正在连接").post()
        if scannerPresented {
            dismissTask?.cancel()
            let dwell = recognitionDwell
            dismissTask = Task {
                try? await Task.sleep(for: dwell)
                guard !Task.isCancelled else { return }
                self.scannerPresented = false
            }
        }
    }

    private func restartHintTimer() {
        hintTask?.cancel()
        hintTask = Task {
            try? await Task.sleep(for: .seconds(2.6))
            guard !Task.isCancelled else { return }
            self.hint = nil
        }
    }

    enum Verdict {
        case valid(PairingPayload)
        case invalid(String)
    }

    /// Parses a link. `forScanning` words the refusals for a code on a screen ("这不是 Orbit 的配对二维码"); otherwise they
    /// are the core's own sentences about the pasted text.
    static func evaluate(_ text: String, forScanning: Bool = false) -> Verdict {
        do {
            return .valid(try PairingPayload.parse(text))
        } catch let error as PairingPayload.ParseError {
            guard forScanning else { return .invalid(error.localizedDescription) }
            switch error {
            case .expired: return .invalid("二维码已过期，请在 Mac 上重新运行 opa pair")
            case .hostIdMismatch: return .invalid("二维码校验失败，请在 Mac 上重新运行 opa pair")
            case .notOPALink, .badEncoding, .badPayload: return .invalid("这不是 Orbit 的配对二维码")
            }
        } catch {
            return .invalid(error.localizedDescription)
        }
    }

    /// The original `onPaired` handler and where it came from.
    private final class Interception {
        let manager: ConnectionManager
        let forward: (PairedHost) -> Void
        var delivered = false

        init(manager: ConnectionManager, forward: @escaping (PairedHost) -> Void) {
            self.manager = manager
            self.forward = forward
        }
    }
}

// MARK: - Failure wording

/// Turns what the connection layer reports into a sentence for the failure page.
///
/// The reports come from `ConnectionManager`: `PairingFailure` ("配对被拒绝或已失效…": the Mac answered "no" or the
/// pairing channel was cut) and `OPAError.rejected` ("Mac 拒绝了连接：<reason>", the host's own reason string).
func pairingFailureExplanation(_ message: String) -> String {
    // The Mac user chose "n", or the code did not match: one report covers it and the broken-channel case.
    if message.contains("拒绝或已失效") {
        return "Mac 没有接受这次配对：可能是在 Mac 上选了拒绝、校验码对不上，或二维码已过期。"
    }
    if message.contains("not paired") {
        return "二维码已过期或已被使用。每个二维码只能用一次，5 分钟内有效。"
    }
    if message.contains("clock skew") {
        return "手机和 Mac 的时间相差太大。请检查两台设备的日期与时间设置。"
    }
    if message.contains("device key changed") {
        return "Mac 记得这台手机，但它的密钥变了。请在 Mac 上用 opa unpair 移除旧的配对，再重新配对。"
    }
    return message
}
