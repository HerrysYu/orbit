import XCTest
@testable import OPA

@MainActor
final class ChatClearTests: XCTestCase {
    private func clearResponse(seq: Int64, clearedAt: Int64) -> JSONValue {
        ["cleared": .bool(true), "seq": .number(Double(seq)), "clearedAt": .number(Double(clearedAt))]
    }

    private func barrierPayload(clearedAt: Int64) -> JSONValue {
        ["clearedAt": .number(Double(clearedAt))]
    }

    private func setOutboxTime(_ h: Harness, clientId: String, createdAt: Int64, text: String = "queued") {
        h.model.persistence.enqueue(clientId: clientId, text: text, attachments: [])
        h.model.persistence.outboxItem(clientId: clientId)?.createdAt = createdAt
        h.model.persistence.saveNow()
        let message = UserMessage(id: nil, clientId: clientId, text: text, attachments: [], ts: createdAt, delivery: .queued)
        h.model.timelineStore.upsert(.user(message), order: Double(createdAt))
        h.model.refreshOutboxCount()
    }

    func testOnlineClearPersistsBarrierAndKeepsTasksMemoriesSettingsAndImports() async throws {
        let h = Harness(connected: false)
        h.model.ev(1, "msg.user", Payload.user(clientId: "old-user", text: "old"))
        h.model.ev(2, "msg.assistant", Payload.assistant(id: "old-reply", text: "old answer"))
        h.model.ev(3, "ui.render", Payload.card(id: "old-card"))
        h.model.ev(4, "task.upsert", Payload.task(id: "task-keep", status: "running"))
        var settings = Settings()
        settings.butler.persona = "preserve this persona"
        h.model.ev(5, "settings.changed", try JSONValue(encoding: settings))
        h.model.ev(6, "memory.changed", [:])
        h.model.persistence.addImport(ImportRecord(id: "import-keep", kind: "text", title: "kept", detail: "kept",
                                                   createdAt: 1, delivered: true))
        h.model.imports = h.model.persistence.imports()
        h.model.live("butler.status", ["state": .string("thinking"), "detail": .string("整理中")])
        h.model.send(text: "unsent", attachments: [], clientId: "queued-old")
        XCTAssertEqual(h.model.persistence.outbox().map(\.clientId), ["queued-old"])
        h.connect()

        let clearAt = Clock.nowMs + 10
        h.host.handler = { method, _ in
            method == "chat.clear" ? self.clearResponse(seq: 10, clearedAt: clearAt) : [:]
        }
        let cleared = await h.model.clearChatHistory()
        XCTAssertTrue(cleared)

        XCTAssertTrue(h.model.timeline.isEmpty)
        XCTAssertEqual(h.model.butlerState, .idle)
        XCTAssertNil(h.model.butlerDetail)
        XCTAssertEqual(h.model.tasks["task-keep"]?.status, .running)
        XCTAssertEqual(h.model.settings.butler.persona, "preserve this persona")
        XCTAssertEqual(h.model.memoryRevision, 1)
        XCTAssertEqual(h.model.persistence.imports().map(\.id), ["import-keep"])
        XCTAssertTrue(h.model.persistence.outbox().isEmpty)
        XCTAssertEqual(h.model.persistence.allEvents().map(\.k), ["task.upsert", "settings.changed", "memory.changed", "chat.cleared"])
        XCTAssertEqual(h.model.lastSeq, 6, "an RPC response is a barrier, not a reason to advance the event cursor")

        h.model.clearState()
        h.model.replayStoredEvents()
        XCTAssertTrue(h.model.timeline.isEmpty, "relaunch replay must not restore cleared chat rows")
        XCTAssertEqual(h.model.tasks["task-keep"]?.status, .running)
        XCTAssertEqual(h.model.settings.butler.persona, "preserve this persona")
        XCTAssertEqual(h.model.persistence.imports().map(\.id), ["import-keep"])
        await h.model.flushOutbox()
        XCTAssertTrue(h.host.calls("chat.send").isEmpty)
    }

    func testOfflineAndRemoteFailureDoNotClearLocalHistory() async {
        let offline = Harness(connected: false)
        offline.model.ev(1, "msg.user", Payload.user(clientId: "offline-user"))
        let offlineClear = await offline.model.clearChatHistory()
        XCTAssertFalse(offlineClear)
        XCTAssertEqual(offline.model.timeline.count, 1)
        XCTAssertTrue(offline.host.calls.isEmpty)

        let failed = Harness()
        failed.model.ev(1, "msg.user", Payload.user(clientId: "kept-user"))
        failed.host.handler = { method, _ in
            if method == "chat.clear" { throw OPAError.remote("clear refused") }
            return [:]
        }
        let failedClear = await failed.model.clearChatHistory()
        XCTAssertFalse(failedClear)
        XCTAssertEqual(failed.model.timelineIds, ["u:kept-user"])
        XCTAssertTrue(failed.model.persistence.allEvents().contains { $0.k == "msg.user" })
    }

    func testDelayedClearAckKeepsNewMessagesStreamsAndAttachmentCache() async {
        let h = Harness()
        h.model.ev(4, "msg.user", Payload.user(clientId: "old-client", text: "before"))
        h.model.live("msg.start", ["id": .string("old-stream")])
        h.model.attachmentCache.store(Data("old-image".utf8), clientId: "old-client", index: 0)
        let clearAt = Clock.nowMs + 20

        h.host.handler = { method, _ in
            guard method == "chat.clear" else { return [:] }
            h.model.ev(6, "msg.user", Payload.user(id: "new-host-id", clientId: "new-client", text: "after", ts: clearAt + 1))
            h.model.attachmentCache.store(Data("new-image".utf8), clientId: "new-client", index: 0)
            h.model.live("msg.start", ["id": .string("new-stream")])
            h.model.live("butler.status", ["state": .string("thinking")])
            return self.clearResponse(seq: 5, clearedAt: clearAt)
        }

        let cleared = await h.model.clearChatHistory()
        XCTAssertTrue(cleared)
        XCTAssertEqual(h.model.timelineIds, ["u:new-client", "a:new-stream"])
        XCTAssertEqual(h.model.streamingIds, ["new-stream"])
        XCTAssertEqual(h.model.butlerState, .thinking)
        XCTAssertNil(h.model.attachmentCache.data(clientId: "old-client", index: 0))
        XCTAssertEqual(h.model.attachmentCache.data(clientId: "new-client", index: 0), Data("new-image".utf8))

        h.model.ev(5, "chat.cleared", barrierPayload(clearedAt: clearAt))
        XCTAssertEqual(h.model.timelineIds, ["u:new-client", "a:new-stream"], "late durable duplicate must be idempotent")
        XCTAssertTrue(h.model.streamingIds.contains("new-stream"))
        XCTAssertEqual(h.model.lastSeq, 6, "a late clear event cannot move the sequence backwards")
    }

    func testClearInvalidatesAnAlreadyRunningSendCompletion() async {
        let h = Harness()
        h.host.handler = { method, _ in
            if method == "chat.send" {
                try? await Task.sleep(for: .milliseconds(120))
                return ["msgId": .string("late-echo")]
            }
            if method == "chat.clear" { return self.clearResponse(seq: 10, clearedAt: Clock.nowMs + 10) }
            return [:]
        }
        h.model.send(text: "in flight", attachments: [], clientId: "in-flight-client")
        let sendStarted = await waitUntil { h.host.calls("chat.send").count == 1 }
        XCTAssertTrue(sendStarted)
        let cleared = await h.model.clearChatHistory()
        XCTAssertTrue(cleared)
        try? await Task.sleep(for: .milliseconds(180))

        XCTAssertNil(h.model.userMessage(clientId: "in-flight-client"))
        XCTAssertTrue(h.model.persistence.outbox().isEmpty)
        XCTAssertEqual(h.model.timeline, [])
    }

    func testSyncBarrierBeyondReplayWindowRunsBeforeOutboxFlush() async {
        let h = Harness()
        h.model.ev(1, "msg.user", Payload.user(clientId: "very-old", text: "old"))
        for seq in 2...610 {
            if seq == 10 { continue } // The clear marker occupies this global event sequence.
            h.model.persistence.append(seq: Int64(seq), ts: Int64(seq), k: "memory.changed", d: [:])
        }
        h.model.lastSeq = 611 // The clear barrier is older than the host's replay window.
        let clearAt = Clock.nowMs
        setOutboxTime(h, clientId: "old-queued", createdAt: clearAt - 1_000)
        setOutboxTime(h, clientId: "new-queued", createdAt: clearAt + 1_000)
        h.model.tasks["keep-task"] = try? Payload.task(id: "keep-task", status: "running").decode(OPATask.self)
        h.host.handler = { method, _ in
            switch method {
            case "sync":
                return ["reset": .bool(true),
                        "chatCleared": ["seq": .number(10), "clearedAt": .number(Double(clearAt))]]
            case "chat.send":
                return ["msgId": .string("sent-new")]
            default:
                return [:]
            }
        }

        await h.model.sync()
        XCTAssertEqual(h.model.lastChatClearSeq, 10)
        XCTAssertEqual(h.model.lastSeq, 0, "the reset cursor must not be advanced to the older clear barrier")
        XCTAssertEqual(h.host.calls("sync").first?.params["lastSeq"]?.int64, 611)
        XCTAssertNil(h.model.userMessage(clientId: "very-old"))
        XCTAssertTrue(h.model.persistence.allEvents().contains { $0.seq == 10 && $0.k == "chat.cleared" })
        XCTAssertFalse(h.model.persistence.allEvents().contains { $0.k == "msg.user" })
        XCTAssertFalse(h.model.persistence.allEvents().contains { $0.k == "memory.changed" })
        XCTAssertEqual(h.model.persistence.outbox().map(\.clientId), ["new-queued"])
        XCTAssertTrue(h.model.tasks.isEmpty, "reset clears derived task state until the host's replay restores it")

        await h.model.flushOutbox()
        XCTAssertEqual(h.host.calls("chat.send").compactMap { $0.params["clientId"]?.string }, ["new-queued"])
    }
}
