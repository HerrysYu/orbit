import CoreImage
import CoreImage.CIFilterBuiltins
import Foundation
import ImageIO
import SwiftUI
import UniformTypeIdentifiers

/// UIKit-free image helpers built on CoreImage / ImageIO.
enum ImageTools {
    static let ciContext = CIContext()

    /// Decodes the first QR code payload in an image.
    static func decodeQR(from data: Data) -> String? {
        guard let image = CIImage(data: data, options: [.applyOrientationProperty: true]) else { return nil }
        let detector = CIDetector(ofType: CIDetectorTypeQRCode, context: ciContext,
                                  options: [CIDetectorAccuracy: CIDetectorAccuracyHigh])
        let features = detector?.features(in: image) ?? []
        return features.compactMap { ($0 as? CIQRCodeFeature)?.messageString }.first
    }

    /// Downscales so the longest side is at most `maxPixel`, re-encoding as JPEG.
    static func downscaledJPEG(_ data: Data, maxPixel: Int, quality: Double = 0.8) -> Data? {
        guard let src = CGImageSourceCreateWithData(data as CFData, nil) else { return nil }
        let opts: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: maxPixel,
        ]
        guard let cg = CGImageSourceCreateThumbnailAtIndex(src, 0, opts as CFDictionary) else { return nil }
        return jpeg(cg, quality: quality)
    }

    /// Center-crops to a square then scales to `side` px.
    static func squareAvatarJPEG(_ data: Data, side: Int = 256) -> Data? {
        guard var image = CIImage(data: data, options: [.applyOrientationProperty: true]) else { return nil }
        let e = image.extent
        let s = min(e.width, e.height)
        image = image.cropped(to: CGRect(x: e.midX - s / 2, y: e.midY - s / 2, width: s, height: s))
            .transformed(by: CGAffineTransform(translationX: -(e.midX - s / 2), y: -(e.midY - s / 2)))
        let scale = CGFloat(side) / s
        let f = CIFilter.lanczosScaleTransform()
        f.inputImage = image
        f.scale = Float(scale)
        f.aspectRatio = 1
        guard let out = f.outputImage,
              let cg = ciContext.createCGImage(out, from: CGRect(x: 0, y: 0, width: side, height: side)) else { return nil }
        return jpeg(cg, quality: 0.82)
    }

    static func jpeg(_ cg: CGImage, quality: Double) -> Data? {
        let out = NSMutableData()
        guard let dest = CGImageDestinationCreateWithData(out, UTType.jpeg.identifier as CFString, 1, nil) else { return nil }
        CGImageDestinationAddImage(dest, cg, [kCGImageDestinationLossyCompressionQuality: quality] as CFDictionary)
        guard CGImageDestinationFinalize(dest) else { return nil }
        return out as Data
    }

    static func cgImage(from data: Data) -> CGImage? {
        guard let src = CGImageSourceCreateWithData(data as CFData, nil) else { return nil }
        return CGImageSourceCreateImageAtIndex(src, 0, nil)
    }

    /// Generates a QR image (used by previews / demo).
    static func qrImage(for string: String) -> CGImage? {
        let f = CIFilter.qrCodeGenerator()
        f.message = Data(string.utf8)
        guard let out = f.outputImage?.transformed(by: CGAffineTransform(scaleX: 10, y: 10)) else { return nil }
        return ciContext.createCGImage(out, from: out.extent)
    }
}

/// Avatar string format: `data:image/jpeg;base64,…` or `emoji:🐱`.
enum AvatarValue: Equatable {
    case image(CGImage)
    case emoji(String)
    case none

    static func == (a: AvatarValue, b: AvatarValue) -> Bool {
        switch (a, b) {
        case (.emoji(let x), .emoji(let y)): x == y
        case (.none, .none): true
        case (.image(let x), .image(let y)): x === y
        default: false
        }
    }

    init(_ raw: String?) {
        guard let raw else { self = .none; return }
        if raw.hasPrefix("emoji:") {
            self = .emoji(String(raw.dropFirst(6)))
        } else if raw.hasPrefix("data:"), let comma = raw.firstIndex(of: ","),
                  let data = Data(base64Encoded: String(raw[raw.index(after: comma)...])),
                  let cg = ImageTools.cgImage(from: data) {
            self = .image(cg)
        } else {
            self = .none
        }
    }
}
