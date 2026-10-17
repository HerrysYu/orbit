#if DEBUG
import CoreImage
import CoreImage.CIFilterBuiltins
import SwiftUI

/// Debug-only helpers for Simulator runs and screenshots (none of this exists in release builds).
///
/// Launch arguments read by the pairing feature:
/// - `-OPAFakeScan <opa://pair?d=…>`: opens the scan page with a still "camera picture" showing that link as a QR code.
///   The real detector reads it, so scan → parse → pair → verify runs end to end without a camera.
/// - `-OPAScanState denied|restricted|noCamera|failed`: opens the scan page in that camera state.
/// - `-OPAOpenScanner YES`: opens the scan page as a tap on "连接我的 Mac" would (in the Simulator: no camera).
/// - `-OPAPasteSheet YES`: opens the paste-link sheet. With `-OPAPasteText <text>` the field starts filled, and with
///   `-OPAPasteSubmit YES` it is submitted at once (to see how a refused link is shown).
/// - `-OPAFakePhoto <path>`: opens the scan page and reads that image file as if it had been picked from the photo library.
/// - `-OPARecognitionDwell <seconds>`: how long "识别到 …" stays on the scan page (default 0.9 s).
/// - `-OPAPairLink <link>` (handled by `OPAApp`): starts pairing straight away, which shows the connecting / verify pages.
/// - `-OPAAutoContinue <seconds>` / `-OPAAutoCancel <seconds>` / `-OPAAutoRetry <seconds>`: press "开始和 Orbit 聊聊" /
///   "取消连接" / "重试" that long after the success / connecting-or-verify / failure page appears (the Simulator cannot tap).
enum PairingDebug {
    /// A 1080 x 1920 portrait picture in the style of the board's scan screen: dark backdrop, a slightly tilted card
    /// with the QR code on it. Nil when the link cannot be encoded.
    static func syntheticCameraImage(showing link: String) -> CGImage? {
        let width = 1080, height = 1920
        let filter = CIFilter.qrCodeGenerator()
        filter.message = Data(link.utf8)
        filter.correctionLevel = "L"
        guard let output = filter.outputImage,
              let space = CGColorSpace(name: CGColorSpace.sRGB),
              let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0, space: space,
                                      bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue)
        else { return nil }

        // The QR: whole pixels per module, nearest neighbour, about 55 % of the picture's width.
        let modules = output.extent.width
        let scale = max(3, (CGFloat(width) * 0.55 / modules).rounded(.down))
        let qrCIImage = output.samplingNearest().transformed(by: CGAffineTransform(scaleX: scale, y: scale))
        guard let qr = CIContext().createCGImage(qrCIImage, from: qrCIImage.extent) else { return nil }

        // Backdrop (the mock's `.camera`).
        let colors = [CGColor(red: 0.227, green: 0.200, blue: 0.176, alpha: 1), CGColor(red: 0.078, green: 0.071, blue: 0.063, alpha: 1)]
        if let gradient = CGGradient(colorsSpace: space, colors: colors as CFArray, locations: [0, 0.75]) {
            let center = CGPoint(x: CGFloat(width) / 2, y: CGFloat(height) * 0.58)
            context.drawRadialGradient(gradient, startCenter: center, startRadius: 0, endCenter: center,
                                       endRadius: CGFloat(height) * 0.6, options: [.drawsAfterEndLocation])
        }

        // The card, tilted 4 degrees counter-clockwise, at 41 % from the top.
        let side = CGFloat(qr.width) * 1.15
        context.saveGState()
        context.translateBy(x: CGFloat(width) / 2, y: CGFloat(height) * 0.59)
        context.rotate(by: 4 * .pi / 180)
        context.setFillColor(CGColor(red: 0.929, green: 0.902, blue: 0.867, alpha: 1))
        context.addPath(CGPath(roundedRect: CGRect(x: -side / 2, y: -side / 2, width: side, height: side),
                               cornerWidth: 28, cornerHeight: 28, transform: nil))
        context.fillPath()
        context.interpolationQuality = .none
        context.draw(qr, in: CGRect(x: -CGFloat(qr.width) / 2, y: -CGFloat(qr.height) / 2, width: CGFloat(qr.width), height: CGFloat(qr.height)))
        context.restoreGState()
        return context.makeImage()
    }

    /// The same downscale the camera path applies before an image is shown.
    static func displayCopy(of image: CGImage) -> CGImage? {
        FrameProcessor().displayImage(from: CIImage(cgImage: image))
    }
}

extension PairingFlow {
    /// Presses the page's button after a delay when the matching `-OPAAuto…` argument is set (see `PairingDebug`).
    func debugStageChanged(_ kind: PairingStage.Kind) {
        let defaults = UserDefaults.standard
        func after(_ key: String, _ action: @escaping @MainActor (PairingFlow) -> Void) {
            let seconds = defaults.double(forKey: key)
            guard seconds > 0 else { return }
            Task {
                try? await Task.sleep(for: .seconds(seconds))
                action(self)
            }
        }
        switch kind {
        case .paired: after("OPAAutoContinue") { $0.finish() }
        case .connecting, .verify: after("OPAAutoCancel") { $0.cancel() }
        case .failed: after("OPAAutoRetry") { $0.retry() }
        case .welcome: break
        }
    }

    /// Applies the debug launch arguments (see `PairingDebug`).
    func applyLaunchArguments() {
        let defaults = UserDefaults.standard
        if defaults.string(forKey: "OPAFakeScan") != nil || defaults.string(forKey: "OPAScanState") != nil
            || defaults.string(forKey: "OPAFakePhoto") != nil || defaults.bool(forKey: "OPAOpenScanner") {
            scannerPresented = true
        }
        if let path = defaults.string(forKey: "OPAFakePhoto") {
            Task {
                try? await Task.sleep(for: .milliseconds(600))   // let the scan page come up first
                await scanned(imageData: try? Data(contentsOf: URL(fileURLWithPath: path)))
            }
        }
        if defaults.bool(forKey: "OPAPasteSheet") { pastePresented = true }
    }
}
#endif
