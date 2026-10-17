import ImageIO
import SwiftUI
import UIKit

// MARK: - Pictures in cards
//
// Every picture a card shows (link preview, video poster, gallery, commerce and comparison thumbnails) goes through
// `CardImage`. The string a card carries can be one of three things:
//   - `data:image/jpeg;base64,…`: how the Mac sends its local screenshots and plain-http pictures. Decoded here,
//     off the main thread, and kept by string so scrolling does not decode it again;
//   - an https address: `AsyncImage`;
//   - anything else (a local path that was never converted, a malformed string): a quiet placeholder.

// MARK: - Source

/// What the string behind a card's `imageUrl` / `posterUrl` / gallery `url` points at.
enum CardImageSource: Equatable, Sendable {
    /// `data:…;base64,…`, decoded by the app (see `CardImageCodec`).
    case embedded(String)
    /// A web address. https is what the Mac passes through; http is tried as well (App Transport Security may refuse it).
    case remote(URL)
    /// Anything else: a leftover local path, a blank or malformed string.
    case unusable

    init(_ raw: String?) {
        guard let raw else {
            self = .unusable
            return
        }
        // `drop(while:)` slices instead of copying: a data URL can be megabytes long.
        let text = raw.drop(while: \.isWhitespace)
        if text.prefix(5).lowercased() == "data:" {
            self = .embedded(raw)
        } else if let url = URL(string: text.trimmingCharacters(in: .whitespacesAndNewlines)),
                  let scheme = url.scheme?.lowercased(), scheme == "http" || scheme == "https",
                  let host = url.host(), !host.isEmpty {
            self = .remote(url)
        } else {
            self = .unusable
        }
    }
}

extension JSONValue {
    /// The picture string a card carries here, nil when it is missing or blank (the card then draws no picture at all).
    var pictureString: String? {
        guard let string, !string.allSatisfy(\.isWhitespace) else { return nil }
        return string
    }
}

// MARK: - Decoding

/// Turns a `data:` URL into a picture. Touches no UI state, so it can run on any thread.
enum CardImageCodec {
    /// Longest side, in pixels, a decoded picture keeps. Larger ones are shrunk while decoding: a 12-megapixel
    /// screenshot would otherwise sit in memory as a 48 MB bitmap, to be drawn into a phone-wide card.
    static let maxPixel = 2048

    /// The bytes inside a `data:<type>;base64,<payload>` string.
    /// Nil when the string is not a base64 data URL, or the payload is empty or not valid base64.
    static func bytes(ofDataURL raw: String) -> Data? {
        let text = raw.drop(while: \.isWhitespace)
        guard text.prefix(5).lowercased() == "data:",
              let comma = text.prefix(256).firstIndex(of: ",") else { return nil }
        let header = text[text.index(text.startIndex, offsetBy: 5)..<comma]
        guard header.trimmingCharacters(in: .whitespaces).lowercased().hasSuffix(";base64") else { return nil }

        let payload = String(text[text.index(after: comma)...])
        if let data = Data(base64Encoded: payload), !data.isEmpty { return data }

        // A payload wrapped into lines carries white space that the strict decoder refuses: take it out, try once more.
        let squeezed = payload.utf8.filter { $0 != 0x20 && !(0x09...0x0D).contains($0) }
        guard squeezed.count != payload.utf8.count,
              let data = Data(base64Encoded: Data(squeezed)), !data.isEmpty else { return nil }
        return data
    }

    /// A picture from encoded image bytes (JPEG, PNG, HEIC, WebP, GIF), already decoded and shrunk to `maxPixel`,
    /// so drawing it later costs no further decoding. Nil when the bytes are not a picture.
    static func image(from data: Data) -> UIImage? {
        guard let source = CGImageSourceCreateWithData(data as CFData, [kCGImageSourceShouldCache: false] as CFDictionary) else {
            return nil
        }
        let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any]
        let width = properties?[kCGImagePropertyPixelWidth] as? Int ?? 0
        let height = properties?[kCGImagePropertyPixelHeight] as? Int ?? 0
        // Never ask for more pixels than the picture has: the thumbnail call would scale a small picture up.
        let limit = width > 0 && height > 0 ? min(maxPixel, max(width, height)) : maxPixel
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,   // applies the EXIF orientation
            kCGImageSourceShouldCacheImmediately: true,         // decode now, on this thread, not at the first draw
            kCGImageSourceThumbnailMaxPixelSize: limit,
        ]
        guard let cg = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary) else { return nil }
        return UIImage(cgImage: cg)
    }

    /// The picture inside a `data:` URL; nil when the string or the picture in it is broken.
    static func image(fromDataURL raw: String) -> UIImage? {
        bytes(ofDataURL: raw).flatMap(image(from:))
    }

    static func result(forDataURL raw: String) -> CardImageResult {
        image(fromDataURL: raw).map(CardImageResult.picture) ?? .failed
    }
}

/// How decoding one `data:` URL ended.
enum CardImageResult: Sendable {
    case picture(UIImage)
    case failed
}

/// Decoded `data:` pictures, kept by their full string. A card that scrolls out of the chat and back finds its
/// picture here instead of decoding it again, so it can draw it in the very first frame; strings that do not decode
/// are remembered too. Under memory pressure the system empties the cache by itself.
@MainActor
enum CardImageStore {
    private final class Entry {
        let result: CardImageResult
        init(_ result: CardImageResult) { self.result = result }
    }

    private static let cache: NSCache<NSString, Entry> = {
        let cache = NSCache<NSString, Entry>()
        cache.totalCostLimit = 96 * 1024 * 1024   // bytes of decoded bitmaps
        cache.countLimit = 64
        return cache
    }()

    /// Decodes in flight, so two cards showing the same picture (or one card re-created) decode it once.
    private static var decoding: [String: Task<CardImageResult, Never>] = [:]

    /// The finished result for `dataURL`, nil when it has not been decoded yet (or was evicted).
    static func cached(for dataURL: String) -> CardImageResult? {
        cache.object(forKey: dataURL as NSString)?.result
    }

    /// The picture for `dataURL`: from the cache, or decoded on a background thread (the main thread stays free).
    static func load(_ dataURL: String) async -> CardImageResult {
        if let hit = cached(for: dataURL) { return hit }
        if let running = decoding[dataURL] { return await running.value }
        let task = Task.detached(priority: .userInitiated) { CardImageCodec.result(forDataURL: dataURL) }
        decoding[dataURL] = task
        let result = await task.value
        decoding[dataURL] = nil
        store(result, for: dataURL)
        return result
    }

    private static func store(_ result: CardImageResult, for dataURL: String) {
        var cost = 1
        if case .picture(let image) = result, let cg = image.cgImage { cost = cg.bytesPerRow * cg.height }
        cache.setObject(Entry(result), forKey: dataURL as NSString, cost: cost)
    }
}

// MARK: - View

/// A card picture cropped to a fixed width : height ratio. The frame is the same whether the picture is still
/// loading (a plain Hairline-colored field, no spinner), loaded, or cannot be shown (the field with a photo glyph), so
/// a card never changes size or shoves its neighbours around.
///
/// `source` is the raw string from the card (see the notes at the top of this file). VoiceOver reads `caption`, or
/// "图片" when there is none.
struct CardImage: View {
    var source: String?
    /// Width / height of the frame the picture is cropped to (16:9 for hero images, 1 for thumbnails).
    var ratio: CGFloat = 16.0 / 9.0
    var caption: String?

    var body: some View {
        Color.hairline
            .aspectRatio(ratio, contentMode: .fit)
            .overlay { picture }
            .clipped()
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(label)
            .accessibilityAddTraits(.isImage)
    }

    @ViewBuilder
    private var picture: some View {
        switch CardImageSource(source) {
        case .embedded(let dataURL): EmbeddedPicture(dataURL: dataURL)
        case .remote(let url): RemotePicture(url: url)
        case .unusable: PictureMark()
        }
    }

    private var label: String {
        guard let caption, !caption.isEmpty else { return "图片" }
        return caption
    }
}

/// The photo glyph that stands in for a picture that cannot be shown.
private struct PictureMark: View {
    var body: some View {
        Image(systemName: "photo")
            .font(.system(size: 20, weight: .medium))
            .foregroundStyle(Color.inkSecondary)
    }
}

/// A picture the Mac sent inline (`data:` URL), decoded off the main thread.
private struct EmbeddedPicture: View {
    var dataURL: String

    /// The outcome together with the string it belongs to, so a card whose picture was replaced never shows the old one.
    private struct Finished {
        var dataURL: String
        var result: CardImageResult
    }

    @State private var finished: Finished?

    var body: some View {
        // The cache answers at once for a picture seen before, so it is there in the first frame.
        let result = finished.flatMap { $0.dataURL == dataURL ? $0.result : nil } ?? CardImageStore.cached(for: dataURL)
        Group {
            switch result {
            case .picture(let image)?:
                Image(uiImage: image)
                    .resizable()
                    .scaledToFill()
                    .transition(.opacity)
            case .failed?:
                PictureMark().transition(.opacity)
            case nil:
                Color.clear
            }
        }
        .task(id: dataURL) {
            if finished?.dataURL == dataURL { return }
            let result = await CardImageStore.load(dataURL)
            guard !Task.isCancelled else { return }
            withAnimation(.easeOut(duration: 0.25)) {
                finished = Finished(dataURL: dataURL, result: result)
            }
        }
    }
}

/// A picture behind a web address, fetched by `AsyncImage`.
private struct RemotePicture: View {
    var url: URL

    var body: some View {
        AsyncImage(url: url, transaction: Transaction(animation: .easeOut(duration: 0.25))) { phase in
            switch phase {
            case .success(let image):
                image.resizable().scaledToFill()
            case .failure:
                PictureMark()
            default:
                Color.clear
            }
        }
    }
}
