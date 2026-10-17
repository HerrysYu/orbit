import Foundation
import SwiftUI

// Timeline, streaming, sending.

extension AppModel {
    // MARK: Timeline access

    /// The chat timeline in arrival order. Stored (not re-sorted per read) — see `TimelineStore`.
    var timeline: [TimelineItem] { timelineStore.items }

    func userMessage(clientId: String) -> UserMessage? {
        if case .user(let m)? = timelineStore.item("u:" + clientId) { return m }
        return nil
    }

    func assistantMessage(id: String) -> AssistantMessage? {
        if case .assistant(let m)? = timelineStore.item("a:" + id) { return m }
        return nil
    }

    func card(id: String) -> Card? {
        if case .card(let c)? = timelineStore.item("c:" + id) { return c }
        return nil
    }

    // MIGRATION: id-keyed views of the timeline for call sites written before `timelineStore` existed
    // (ChatView read `assistantMessages.values`). Built on access; use `timeline` / the lookups above.
    var userMessages: [String: UserMessage] {
        var out: [String: UserMessage] = [:]
        for case .user(let m) in timeline { out[m.clientId] = m }
        return out
    }

    var assistantMessages: [String: AssistantMessage] {
        var out: [String: AssistantMessage] = [:]
        for case .assistant(let m) in timeline { out[m.id] = m }
        return out
    }

    var cards: [String: Card] {
        var out: [String: Card] = [:]
        for case .card(let c) in timeline { out[c.id] = c }
        return out
    }

    // MARK: Replying state

    var hasStreamingMessage: Bool { !streamingIds.isEmpty }

    /// Orbit is thinking, executing, or streaming a reply — the composer shows ■ (stop) instead of ↑.
    /// False while the Mac is unreachable: there is nothing to stop, and a dropped connection must not leave
    /// the button stuck on stop.
    var isReplying: Bool {
        guard canUseHost else { return false }
        return hasStreamingMessage || butlerState == .thinking || butlerState == .acting
    }

    // MIGRATION: old name of `isReplying` / `stopReply()`; remove once the chat views use the new ones.
    var isButlerBusy: Bool { isReplying }
    func interrupt() { stopReply() }

    /// Stops the reply Orbit is producing right now (`chat.interrupt`). Tasks and execution sessions keep going.
    func stopReply() {
        Task {
            do {
                try await request("chat.interrupt")
            } catch {
                showToast("无法停止回复：\(error.localizedDescription)")
            }
        }
    }

    // MARK: Streaming

    func beginStreaming(id: String, proactive: Bool, text: String = "") {
        let msg = AssistantMessage(id: id, text: text, proactive: proactive, interrupted: false, streaming: true, ts: nowMs())
        timelineStore.upsert(.assistant(msg), order: nextLocalOrder())
        streamingIds.insert(id)
        streamActivityToken &+= 1
    }

    /// Appends a delta in place (no re-sort, no re-insert). Deltas for a message that already ended are ignored.
    func appendStreamDelta(id: String, text: String) {
        streamActivityToken &+= 1
        guard timelineStore.contains("a:" + id) else {
            beginStreaming(id: id, proactive: false, text: text)
            return
        }
        let reopen = streamsClosedLocally.contains(id)
        timelineStore.update("a:" + id) { item in
            guard case .assistant(var m) = item, m.streaming || reopen else { return }
            m.text += text
            m.streaming = true
            item = .assistant(m)
        }
        if reopen {
            // We closed this reply when the connection dropped, but the Mac is still writing it.
            streamsClosedLocally.remove(id)
            streamingIds.insert(id)
        }
    }

    /// The host's echo of a message (ours, matched by clientId, or another device's).
    func applyUserEcho(_ d: JSONValue, ts: Int64, seq: Int64) {
        let hostId = Self.nonEmpty(d["id"]?.string)
        let clientId = Self.nonEmpty(d["clientId"]?.string) ?? hostId ?? ShortID.make()
        let local = userMessage(clientId: clientId)
        var atts = (try? d["attachments"]?.decode([Attachment].self)) ?? []
        // Keep the local attachment list if the echo dropped it (images still render from the cache).
        if atts.isEmpty, let l = local?.attachments, !l.isEmpty {
            atts = l.map { var a = $0; a.dataB64 = nil; return a }
        }
        let msg = UserMessage(id: hostId ?? local?.id, clientId: clientId, text: d["text"]?.string ?? local?.text ?? "",
                              attachments: atts, ts: d["ts"]?.int64 ?? ts, delivery: .sent)
        // A message you sent keeps the place it had while it was pending; a new one goes where the host put it.
        timelineStore.upsert(.user(msg), order: orderKey(seq: seq))
        if !isDemo, !isReplaying {
            persistence.removeOutbox(clientId: clientId)
            refreshOutboxCount()
        }
    }

    func applyAssistantFinal(_ d: JSONValue, ts: Int64, seq: Int64) {
        guard let id = d["id"]?.string else { return }
        let text = d["text"]?.string ?? ""
        let interrupted = d["interrupted"]?.bool ?? false
        if streamingIds.contains(id) { streamingIds.remove(id) }
        streamsClosedLocally.remove(id)
        if text.isEmpty, !interrupted {
            // Nothing to show (the host sends no final for an empty reply): drop the streaming placeholder.
            timelineStore.remove("a:" + id)
            return
        }
        let msg = AssistantMessage(id: id, text: text, proactive: d["proactive"]?.bool ?? false,
                                   interrupted: interrupted, streaming: false, ts: d["ts"]?.int64 ?? ts)
        // Same id as the streaming placeholder → replaced in place, the position it had while streaming.
        timelineStore.upsert(.assistant(msg), order: orderKey(seq: seq))
    }

    /// Closes every reply that is still marked streaming (connection lost / re-established, or the bot went idle
    /// without a final message). Keeps the text received so far; an empty placeholder is removed.
    func finishAllStreaming() {
        streamIdleTask?.cancel()
        guard !streamingIds.isEmpty else { return }
        let ids = streamingIds
        withAnimation(spring) {
            for id in ids {
                guard let m = assistantMessage(id: id) else { continue }
                if m.text.isEmpty {
                    timelineStore.remove("a:" + id)
                } else {
                    timelineStore.update("a:" + id) { item in
                        guard case .assistant(var m) = item else { return }
                        m.streaming = false
                        item = .assistant(m)
                    }
                    streamsClosedLocally.insert(id)
                }
            }
            streamingIds = []
        }
    }

    /// The bot went idle: if no delta arrives for `streamIdleGrace` the stream is over even without a final message.
    func scheduleStreamIdleCheck() {
        guard hasStreamingMessage else { return }
        streamIdleTask?.cancel()
        let token = streamActivityToken
        let grace = streamIdleGrace
        streamIdleTask = Task { [weak self] in
            try? await Task.sleep(for: grace)
            guard !Task.isCancelled, let self else { return }
            if self.streamActivityToken == token, self.butlerState == .idle { self.finishAllStreaming() }
        }
    }

    // MARK: Sending

    /// Shows the message at once and delivers it. Offline → it waits in the outbox as `.queued`.
    @discardableResult
    func send(text: String, attachments: [Attachment], clientId: String = ShortID.make()) -> String {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty || !attachments.isEmpty else { return clientId }
        let online = canUseHost
        let msg = UserMessage(id: nil, clientId: clientId, text: trimmed, attachments: attachments, ts: nowMs(),
                              delivery: online ? .sending : .queued)
        withAnimation(spring) { timelineStore.upsert(.user(msg), order: nextLocalOrder()) }
        if !isDemo {
            persistence.enqueue(clientId: clientId, text: trimmed, attachments: attachments)
            refreshOutboxCount()
        }
        if online { Task { await deliver(clientId: clientId) } }
        return clientId
    }

    /// Sends a `.failed` (or stuck `.queued`) message again — with the same clientId, so the host can de-duplicate.
    func retry(clientId: String) {
        guard let m = userMessage(clientId: clientId) else { return }
        switch m.delivery {
        case .failed, .queued: break
        case .sending, .sent: return
        }
        guard canUseHost else {
            setDelivery(clientId, .queued)
            return
        }
        setDelivery(clientId, .sending)
        Task { await deliver(clientId: clientId) }
    }

    /// Adds items to the composer tray (deduplicated by content) and brings the chat to the front.
    func addToDraft(_ items: [DraftItem]) {
        guard !items.isEmpty else { return }
        withAnimation(spring) { draftItems.append(contentsOf: items) }
        selectedTab = .chat
        chatFocusRequest += 1
    }

    func removeDraft(_ id: DraftItem.ID) {
        withAnimation(spring) { draftItems.removeAll { $0.id == id } }
    }

    /// Sends the composer text together with the tray. Images/files/links become `chat.send` attachments;
    /// notes (reminders, pasted text) are appended to the message body so they read naturally in chat.
    func sendDraft(text: String) {
        var body = text.trimmingCharacters(in: .whitespacesAndNewlines)
        var attachments: [Attachment] = []
        var images: [(Int, Data)] = []
        var notes: [String] = []
        for item in draftItems {
            switch item.content {
            case .image(let jpeg):
                images.append((attachments.count, jpeg))
                attachments.append(Attachment(kind: .image, name: "photo-\(attachments.count + 1).jpg", mime: "image/jpeg",
                                              dataB64: jpeg.base64EncodedString()))
            case .file(let name, let mime, let data):
                attachments.append(Attachment(kind: .file, name: name, mime: mime, dataB64: data.base64EncodedString()))
            case .link(let url):
                attachments.append(Attachment(kind: .link, url: url))
            case .note(_, let b, _):
                notes.append(b)
            }
        }
        if !notes.isEmpty { body = ([body].filter { !$0.isEmpty } + notes).joined(separator: "\n\n") }
        guard !body.isEmpty || !attachments.isEmpty else { return }
        // Cache images before the message appears so the bubble renders from the cache immediately.
        let clientId = ShortID.make()
        for (i, d) in images { attachmentCache.store(d, clientId: clientId, index: i) }
        send(text: body, attachments: attachments, clientId: clientId)
        withAnimation(spring) { draftItems = [] }
    }

    // MARK: Cards

    /// A button / selection / form submit on a card (`ui.action`). Returns true when the host accepted it.
    func sendAction(cardId: String, actionId: String, value: JSONValue? = nil) async -> Bool {
        var d: JSONValue = ["cardId": .string(cardId), "actionId": .string(actionId)]
        if let value, case .object(var o) = d { o["value"] = value; d = .object(o) }
        do {
            try await request("ui.action", d)
            return true
        } catch {
            showToast(error.localizedDescription)
            return false
        }
    }

    // MARK: Delivery

    func setDelivery(_ clientId: String, _ delivery: UserMessage.Delivery) {
        timelineStore.update("u:" + clientId) { item in
            guard case .user(var m) = item else { return }
            if case .sent = m.delivery { return }   // once the host has it, it never goes back
            guard m.delivery != delivery else { return }
            m.delivery = delivery
            item = .user(m)
        }
    }

    /// The text and attachments to (re)send: the persisted outbox row when there is one (it still has the attachment
    /// bytes after a relaunch), otherwise the message as shown.
    private func outgoingPayload(clientId: String) -> (text: String, attachments: [Attachment])? {
        if !isDemo, let item = persistence.outboxItem(clientId: clientId) {
            let atts = (try? JSONDecoder().decode([Attachment].self, from: item.attachments)) ?? []
            return (item.text, atts)
        }
        if let m = userMessage(clientId: clientId) { return (m.text, m.attachments) }
        return nil
    }

    /// One `chat.send` attempt.
    /// - answered → `.sent` (and out of the outbox);
    /// - not connected / timed out / cancelled → `.queued` (stays in the outbox, flushed after the next reconnect);
    /// - the host refused it → `.failed(reason)` (stays in the outbox, but only `retry(clientId:)` sends it again).
    func deliver(clientId: String) async {
        guard !inFlightDeliveries.contains(clientId), let payload = outgoingPayload(clientId: clientId) else { return }
        if case .sent? = userMessage(clientId: clientId)?.delivery { return }   // the host already has it
        inFlightDeliveries.insert(clientId)
        defer { inFlightDeliveries.remove(clientId) }
        setDelivery(clientId, .sending)
        var d: JSONValue = ["clientId": .string(clientId), "text": .string(payload.text)]
        if !payload.attachments.isEmpty, case .object(var o) = d {
            o["attachments"] = (try? JSONValue(encoding: payload.attachments)) ?? .array([])
            d = .object(o)
        }
        do {
            let res = try await request("chat.send", d, timeout: .seconds(30))
            markSent(clientId: clientId, msgId: res["msgId"]?.string)
            if !isDemo { persistence.removeOutbox(clientId: clientId); refreshOutboxCount() }
        } catch {
            setDelivery(clientId, Self.deliveryState(after: error))
        }
    }

    /// Network-ish errors keep the message queued; anything the host actively refused is a failure.
    static func deliveryState(after error: any Error) -> UserMessage.Delivery {
        if let e = error as? OPAError {
            switch e {
            case .notConnected, .timeout, .cancelled: return .queued
            case .remote, .rejected, .protocolViolation: return .failed(e.localizedDescription)
            }
        }
        return .failed(error.localizedDescription)
    }

    private func markSent(clientId: String, msgId: String?) {
        timelineStore.update("u:" + clientId) { item in
            guard case .user(var m) = item else { return }
            m.delivery = .sent
            m.id = msgId ?? m.id
            item = .user(m)
        }
    }

    /// Sends everything waiting in the outbox, oldest first. Messages that failed (host refusal) wait for `retry`.
    func flushOutbox() async {
        guard canUseHost else { return }
        if isDemo {
            let queued = timeline.compactMap { item -> String? in
                if case .user(let m) = item, m.delivery == .queued { return m.clientId }
                return nil
            }
            for id in queued {
                await deliver(clientId: id)
                if !canUseHost { return }
            }
            return
        }
        for item in persistence.outbox() {
            if case .failed? = userMessage(clientId: item.clientId)?.delivery { continue }
            showOutboxMessage(item)
            await deliver(clientId: item.clientId)
            if !canUseHost { return }
        }
    }

    /// Makes sure every outbox row is on screen as a queued message (after a relaunch or a history reset).
    func showOutboxMessages() {
        guard !isDemo else { return }
        for item in persistence.outbox() { showOutboxMessage(item) }
    }

    private func showOutboxMessage(_ item: OutboxItem) {
        guard !timelineStore.contains("u:" + item.clientId) else { return }
        let atts = (try? JSONDecoder().decode([Attachment].self, from: item.attachments)) ?? []
        let msg = UserMessage(id: nil, clientId: item.clientId, text: item.text, attachments: atts, ts: item.createdAt, delivery: .queued)
        timelineStore.upsert(.user(msg), order: nextLocalOrder())
    }

    func refreshOutboxCount() { outboxCount = persistence.outbox().count }

    /// Messages waiting for the Mac to come back (the "待发送" count).
    var queuedMessageCount: Int {
        timeline.reduce(0) { n, item in
            if case .user(let m) = item, m.delivery == .queued { n + 1 } else { n }
        }
    }
}
