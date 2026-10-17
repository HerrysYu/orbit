import CoreGraphics
import Foundation
import UniformTypeIdentifiers

/// One item waiting in the composer tray before it is sent with the message.
struct DraftItem: Identifiable, Hashable {
    enum Content: Hashable {
        /// JPEG already downscaled to ≤ 2048 px long edge.
        case image(jpeg: Data)
        case file(name: String, mime: String, data: Data)
        case link(url: String)
        /// Reminders / pasted notes: appended to the message body as text.
        case note(title: String, body: String, symbol: String)
    }

    let id = UUID()
    var content: Content
    /// Small decoded preview for image chips.
    var preview: CGImage?

    static func == (a: Self, b: Self) -> Bool { a.id == b.id }
    func hash(into h: inout Hasher) { h.combine(id) }

    static let maxFileBytes = 10 * 1024 * 1024
    static let maxImagePixel = 2048

    /// Builds an image item from arbitrary image bytes (downscaled, re-encoded as JPEG 0.8).
    static func image(from data: Data) -> DraftItem? {
        guard let jpeg = ImageTools.downscaledJPEG(data, maxPixel: maxImagePixel, quality: 0.8) else { return nil }
        let preview = ImageTools.downscaledJPEG(jpeg, maxPixel: 240).flatMap(ImageTools.cgImage(from:))
        return DraftItem(content: .image(jpeg: jpeg), preview: preview)
    }

    /// Builds a file item; images picked as files are treated as photos. Nil when too large / unreadable.
    static func file(at url: URL) -> Result<DraftItem, DraftError> {
        let scoped = url.startAccessingSecurityScopedResource()
        defer { if scoped { url.stopAccessingSecurityScopedResource() } }
        let size = (try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
        let type = UTType(filenameExtension: url.pathExtension)
        if type?.conforms(to: .image) == true, let d = try? Data(contentsOf: url), let item = image(from: d) {
            return .success(item)
        }
        guard size <= maxFileBytes else { return .failure(.tooLarge(url.lastPathComponent)) }
        guard let data = try? Data(contentsOf: url), data.count <= maxFileBytes else { return .failure(.unreadable(url.lastPathComponent)) }
        let mime = type?.preferredMIMEType ?? "application/octet-stream"
        return .success(DraftItem(content: .file(name: url.lastPathComponent, mime: mime, data: data)))
    }

    /// Splits pasted text into link items (bare http(s) URLs) or a single note.
    static func fromPasted(_ raw: String) -> [DraftItem] {
        let t = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !t.isEmpty else { return [] }
        let lines = t.split(whereSeparator: \.isNewline).map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
        let links = lines.compactMap { line -> String? in
            guard !line.contains(" "), let u = URL(string: line), let s = u.scheme, ["http", "https"].contains(s), u.host() != nil else { return nil }
            return line
        }
        if links.count == lines.count { return links.map { DraftItem(content: .link(url: $0)) } }
        return [DraftItem(content: .note(title: String(t.prefix(24)), body: t, symbol: "text.alignleft"))]
    }

    var isImage: Bool { if case .image = content { true } else { false } }
}

enum DraftError: Error, LocalizedError {
    case tooLarge(String), unreadable(String)
    var errorDescription: String? {
        switch self {
        case .tooLarge(let n): "“\(n)”超过 10 MB，无法发送"
        case .unreadable(let n): "无法读取“\(n)”"
        }
    }
}

extension Attachment {
    /// Short display label for a link attachment.
    var linkHost: String? { url.flatMap(URL.init(string:))?.host() }
}
