import Foundation

/// A row in the chat timeline.
enum TimelineItem: Identifiable, Hashable, Sendable {
    case user(UserMessage)
    case assistant(AssistantMessage)
    case card(Card)

    var id: String {
        switch self {
        case .user(let m): "u:" + m.clientId
        case .assistant(let m): "a:" + m.id
        case .card(let c): "c:" + c.id
        }
    }

    /// Display time only (device clock for local messages, host clock otherwise). Never used for ordering.
    var ts: Int64 {
        switch self {
        case .user(let m): m.ts
        case .assistant(let m): m.ts
        case .card(let c): c.ts
        }
    }
}

struct UserMessage: Hashable, Sendable {
    /// Where a message you sent is on its way to the Mac.
    enum Delivery: Hashable, Sendable {
        /// Handed to the transport, waiting for the host's answer.
        case sending
        /// Not delivered yet (Mac offline, connection dropped, request timed out). It sits in the persisted outbox
        /// and is sent automatically after the next reconnect.
        case queued
        /// The host has it (`chat.send` answered, or the `msg.user` echo arrived).
        case sent
        /// The host refused it; the text says why. Only `AppModel.retry(clientId:)` sends it again.
        case failed(String)
    }

    var id: String?
    var clientId: String
    var text: String
    var attachments: [Attachment]
    var ts: Int64
    var delivery: Delivery

    /// Not yet delivered (sending or queued).
    var pending: Bool {
        switch delivery {
        case .sending, .queued: true
        case .sent, .failed: false
        }
    }
}

struct AssistantMessage: Hashable, Sendable {
    var id: String
    var text: String
    var proactive: Bool
    var interrupted: Bool
    var streaming: Bool
    var ts: Int64
}

/// The chat timeline in *arrival order*, kept sorted as it is built so reading it is free.
///
/// Every item has a sort key:
/// - durable events (`msg.user`, `msg.assistant`, `ui.render`) use their host `seq`, as a `Double`;
/// - items we show before the host has spoken (a message you just sent, a streaming reply) use
///   `Double(lastSeq) + 0.5 + counter · 1e-6`, i.e. just after everything we have seen so far;
/// - an item keeps its key when the durable event for the same id arrives, so nothing jumps.
///
/// Timestamps are deliberately not involved: the phone and the Mac disagree about the time.
/// Items are located by key with a binary search, so an update (a streaming delta) is O(log n) and never re-sorts.
struct TimelineStore: Sendable {
    private(set) var items: [TimelineItem] = []
    private var keys: [Double] = []
    private var keyById: [String: Double] = [:]

    var count: Int { items.count }
    var isEmpty: Bool { items.isEmpty }

    func contains(_ id: String) -> Bool { keyById[id] != nil }

    func item(_ id: String) -> TimelineItem? {
        index(of: id).map { items[$0] }
    }

    /// The sort key of an item, for tests and diagnostics.
    func order(of id: String) -> Double? { keyById[id] }

    /// Replaces the item with the same id in place (its position is kept), or inserts it according to `order`.
    mutating func upsert(_ item: TimelineItem, order: @autoclosure () -> Double) {
        if let i = index(of: item.id) {
            items[i] = item
            return
        }
        var key = order()
        // Keys must be unique for the binary search to be exact.
        while index(forKey: key) != nil { key = key.nextUp }
        let i = insertionIndex(for: key)
        items.insert(item, at: i)
        keys.insert(key, at: i)
        keyById[item.id] = key
    }

    /// Mutates an existing item in place. Returns false when the id is unknown.
    @discardableResult
    mutating func update(_ id: String, _ change: (inout TimelineItem) -> Void) -> Bool {
        guard let i = index(of: id) else { return false }
        change(&items[i])
        return true
    }

    @discardableResult
    mutating func remove(_ id: String) -> Bool {
        guard let i = index(of: id) else { return false }
        items.remove(at: i)
        keys.remove(at: i)
        keyById[id] = nil
        return true
    }

    mutating func removeAll() {
        items = []; keys = []; keyById = [:]
    }

    // MARK: Search

    private func index(of id: String) -> Int? {
        keyById[id].flatMap { index(forKey: $0) }
    }

    /// Exact match by key (lower bound).
    private func index(forKey key: Double) -> Int? {
        var lo = 0, hi = keys.count
        while lo < hi {
            let mid = (lo + hi) / 2
            if keys[mid] < key { lo = mid + 1 } else { hi = mid }
        }
        return lo < keys.count && keys[lo] == key ? lo : nil
    }

    /// First position whose key is greater than `key` (upper bound), so new items go after equal neighbours.
    private func insertionIndex(for key: Double) -> Int {
        var lo = 0, hi = keys.count
        while lo < hi {
            let mid = (lo + hi) / 2
            if keys[mid] <= key { lo = mid + 1 } else { hi = mid }
        }
        return lo
    }
}
