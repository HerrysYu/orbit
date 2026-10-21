import CoreGraphics
import Foundation

/// Local copy of image bytes the user sent, keyed by the message clientId and the attachment's index.
/// The host strips `dataB64` from the `msg.user` echo, so without this a sent photo would vanish from the
/// bubble after the echo (or after a relaunch replays stored events).
@MainActor
final class AttachmentCache {
    private let root: URL
    private var memory: [String: CGImage] = [:]

    init(inMemory: Bool = false) {
        let base = inMemory ? FileManager.default.temporaryDirectory : (FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first
            ?? FileManager.default.temporaryDirectory)
        root = base.appending(path: inMemory ? "opa-attachments-\(UUID().uuidString)" : "opa-attachments", directoryHint: .isDirectory)
        try? FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }

    private func key(_ clientId: String, _ index: Int) -> String {
        // clientIds are base64url ids; keep the path component safe regardless.
        "\(safeClientId(clientId))-\(index)"
    }

    private func safeClientId(_ clientId: String) -> String {
        clientId.filter { $0.isLetter || $0.isNumber || $0 == "-" || $0 == "_" }
    }

    private func url(_ key: String) -> URL { root.appending(path: key + ".jpg") }

    func store(_ data: Data, clientId: String, index: Int) {
        try? data.write(to: url(key(clientId, index)), options: .atomic)
    }

    func data(clientId: String, index: Int) -> Data? {
        try? Data(contentsOf: url(key(clientId, index)))
    }

    /// Decoded image, memoized so scrolling doesn't re-decode.
    func image(clientId: String, index: Int) -> CGImage? {
        let k = key(clientId, index)
        if let cg = memory[k] { return cg }
        guard let d = try? Data(contentsOf: url(k)), let cg = ImageTools.cgImage(from: d) else { return nil }
        memory[k] = cg
        return cg
    }

    /// Removes cached images for selected chat messages without disturbing attachments sent after a clear barrier.
    @discardableResult
    func remove(clientIds: Set<String>) -> Bool {
        guard !clientIds.isEmpty else { return true }
        let safeIds = Set(clientIds.map(safeClientId))
        do {
            let files = try FileManager.default.contentsOfDirectory(at: root, includingPropertiesForKeys: nil)
            for file in files where safeIds.contains(Self.clientId(inCacheFile: file.lastPathComponent)) {
                try FileManager.default.removeItem(at: file)
            }
            memory = memory.filter { entry in !safeIds.contains(Self.clientId(inCacheFile: entry.key)) }
            return true
        } catch {
            return false
        }
    }

    private static func clientId(inCacheFile name: String) -> String {
        let withoutExtension = name.hasSuffix(".jpg") ? String(name.dropLast(4)) : name
        guard let separator = withoutExtension.lastIndex(of: "-"),
              Int(withoutExtension[withoutExtension.index(after: separator)...]) != nil else { return "" }
        return String(withoutExtension[..<separator])
    }

    @discardableResult
    func wipe() -> Bool {
        memory = [:]
        do {
            if FileManager.default.fileExists(atPath: root.path) { try FileManager.default.removeItem(at: root) }
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
            return true
        } catch {
            return false
        }
    }
}
