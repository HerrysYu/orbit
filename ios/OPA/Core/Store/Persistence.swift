import Foundation
import SwiftData

/// A persisted `ev` frame. The app state is rebuilt by replaying these in seq order.
@Model
final class StoredEvent {
    @Attribute(.unique) var seq: Int64
    var ts: Int64
    var k: String
    var payload: Data

    init(seq: Int64, ts: Int64, k: String, payload: Data) {
        self.seq = seq; self.ts = ts; self.k = k; self.payload = payload
    }
}

/// `chat.send` waiting to be delivered.
@Model
final class OutboxItem {
    @Attribute(.unique) var clientId: String
    var text: String
    var attachments: Data
    var createdAt: Int64

    init(clientId: String, text: String, attachments: Data, createdAt: Int64) {
        self.clientId = clientId; self.text = text; self.attachments = attachments; self.createdAt = createdAt
    }
}

/// Local record of what the user has imported (inbox history).
@Model
final class ImportRecord {
    var id: String
    var kind: String
    var title: String
    var detail: String
    var createdAt: Int64
    var delivered: Bool

    init(id: String, kind: String, title: String, detail: String, createdAt: Int64, delivered: Bool) {
        self.id = id; self.kind = kind; self.title = title; self.detail = detail
        self.createdAt = createdAt; self.delivered = delivered
    }
}

@MainActor
final class Persistence {
    let container: ModelContainer
    var context: ModelContext { container.mainContext }

    init(inMemory: Bool) {
        let schema = Schema([StoredEvent.self, OutboxItem.self, ImportRecord.self])
        if !inMemory { Self.ensureStoreDirectory() }
        let config = ModelConfiguration("OPA", schema: schema, isStoredInMemoryOnly: inMemory)
        do {
            container = try ModelContainer(for: schema, configurations: [config])
        } catch {
            // A corrupt store must never brick the app: fall back to an in-memory store.
            container = try! ModelContainer(for: schema, configurations: [ModelConfiguration(isStoredInMemoryOnly: true)])
        }
    }

    /// SwiftData puts the store in the app group's `Library/Application Support`, which doesn't exist on a fresh
    /// install; CoreData then logs a failed open and recovers. Creating the folder first avoids that.
    /// (The store stays in the group container so existing installs keep their history.)
    private static func ensureStoreDirectory() {
        let fm = FileManager.default
        let base = fm.containerURL(forSecurityApplicationGroupIdentifier: "group.com.haoyuanyu.orbit")
            ?? fm.urls(for: .applicationSupportDirectory, in: .userDomainMask).first?.deletingLastPathComponent().deletingLastPathComponent()
        guard let base else { return }
        let dir = base.appending(path: "Library/Application Support", directoryHint: .isDirectory)
        try? fm.createDirectory(at: dir, withIntermediateDirectories: true)
    }

    // MARK: Events

    func allEvents() -> [StoredEvent] {
        (try? context.fetch(FetchDescriptor<StoredEvent>(sortBy: [SortDescriptor(\.seq)]))) ?? []
    }

    func append(seq: Int64, ts: Int64, k: String, d: JSONValue) {
        guard let data = try? d.data() else { return }
        context.insert(StoredEvent(seq: seq, ts: ts, k: k, payload: data))
        scheduleSave()
    }

    func clearEvents() {
        try? context.delete(model: StoredEvent.self)
        try? context.save()
    }

    // MARK: Outbox

    func outbox() -> [OutboxItem] {
        (try? context.fetch(FetchDescriptor<OutboxItem>(sortBy: [SortDescriptor(\.createdAt)]))) ?? []
    }

    func outboxItem(clientId: String) -> OutboxItem? {
        let d = FetchDescriptor<OutboxItem>(predicate: #Predicate { $0.clientId == clientId })
        return (try? context.fetch(d))?.first
    }

    func enqueue(clientId: String, text: String, attachments: [Attachment]) {
        let data = (try? JSONEncoder().encode(attachments)) ?? Data("[]".utf8)
        context.insert(OutboxItem(clientId: clientId, text: text, attachments: data, createdAt: Clock.nowMs))
        try? context.save()
    }

    func removeOutbox(clientId: String) {
        let d = FetchDescriptor<OutboxItem>(predicate: #Predicate { $0.clientId == clientId })
        for item in (try? context.fetch(d)) ?? [] { context.delete(item) }
        try? context.save()
    }

    // MARK: Imports

    func imports() -> [ImportRecord] {
        (try? context.fetch(FetchDescriptor<ImportRecord>(sortBy: [SortDescriptor(\.createdAt, order: .reverse)]))) ?? []
    }

    func addImport(_ r: ImportRecord) {
        context.insert(r)
        try? context.save()
    }

    func wipe() {
        try? context.delete(model: StoredEvent.self)
        try? context.delete(model: OutboxItem.self)
        try? context.delete(model: ImportRecord.self)
        try? context.save()
    }

    // MARK: Coalesced saves (events arrive in bursts during sync)

    private var saveTask: Task<Void, Never>?
    private func scheduleSave() {
        saveTask?.cancel()
        saveTask = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(300))
            guard !Task.isCancelled else { return }
            try? self?.context.save()
        }
    }

    func saveNow() { try? context.save() }
}
