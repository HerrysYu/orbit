import XCTest
@testable import OPA

@MainActor
final class DeliveryTests: XCTestCase {
    private func delivery(_ h: Harness, _ clientId: String) -> UserMessage.Delivery? {
        h.model.userMessage(clientId: clientId)?.delivery
    }

    // MARK: Happy path

    func testOnlineSendGoesSendingThenSent() async {
        let h = Harness()
        h.host.handler = { m, _ in
            if m == "chat.send" { try? await Task.sleep(for: .milliseconds(60)); return ["msgId": "u_42"] }
            return [:]
        }
        h.model.send(text: "hello", attachments: [], clientId: "c1")
        XCTAssertEqual(delivery(h, "c1"), .sending)
        let sent = await waitUntil { self.delivery(h, "c1") == .sent }
        XCTAssertTrue(sent)
        XCTAssertEqual(h.model.userMessage(clientId: "c1")?.id, "u_42")
        XCTAssertEqual(h.model.persistence.outbox().count, 0, "delivered messages leave the outbox")
        XCTAssertEqual(h.model.outboxCount, 0)
        XCTAssertEqual(h.host.calls("chat.send").count, 1)
        XCTAssertEqual(h.host.calls("chat.send").first?.params["clientId"]?.string, "c1")
    }

    func testEchoArrivingBeforeTheResponseDoesNotGetUndone() async {
        let h = Harness()
        h.host.handler = { m, _ in
            if m == "chat.send" {
                // The host emits the echo before it answers the request.
                h.model.ev(1, "msg.user", Payload.user(id: "u_9", clientId: "c1", text: "hello"))
                return ["msgId": "u_9"]
            }
            return [:]
        }
        h.model.send(text: "hello", attachments: [], clientId: "c1")
        let sent = await waitUntil { self.delivery(h, "c1") == .sent && h.model.persistence.outbox().isEmpty }
        XCTAssertTrue(sent)
        XCTAssertEqual(h.model.timeline.count, 1)
    }

    // MARK: Offline / timeout → queued → flushed after reconnect

    func testSendWhileOfflineIsQueuedAndGoesOutAfterReconnect() async {
        let h = Harness(connected: false)
        h.model.send(text: "later", attachments: [], clientId: "c1")
        XCTAssertEqual(delivery(h, "c1"), .queued)
        XCTAssertEqual(h.model.persistence.outbox().map(\.clientId), ["c1"])
        XCTAssertEqual(h.model.outboxCount, 1)
        XCTAssertEqual(h.model.queuedMessageCount, 1)
        XCTAssertTrue(h.host.calls.isEmpty, "nothing is sent while offline")

        h.host.handler = { m, _ in m == "chat.send" ? ["msgId": "u_1"] : [:] }
        h.connect()
        await h.model.flushOutbox()
        XCTAssertEqual(delivery(h, "c1"), .sent)
        XCTAssertEqual(h.host.calls("chat.send").count, 1)
        XCTAssertEqual(h.model.persistence.outbox().count, 0)
        XCTAssertEqual(h.model.queuedMessageCount, 0)
    }

    func testTimeoutQueuesTheMessageAndTheSameClientIdIsSentAgain() async {
        let h = Harness()
        var attempts = 0
        h.host.handler = { m, _ in
            guard m == "chat.send" else { return [:] }
            attempts += 1
            if attempts == 1 { throw OPAError.timeout }
            return ["msgId": "u_1"]
        }
        h.model.send(text: "hello", attachments: [], clientId: "c1")
        let queued = await waitUntil { self.delivery(h, "c1") == .queued }
        XCTAssertTrue(queued)
        XCTAssertEqual(h.model.persistence.outbox().count, 1, "still in the outbox")

        await h.model.flushOutbox()   // what the next reconnect does
        XCTAssertEqual(delivery(h, "c1"), .sent)
        let ids = h.host.calls("chat.send").compactMap { $0.params["clientId"]?.string }
        XCTAssertEqual(ids, ["c1", "c1"], "a resend must carry the same clientId so the host can de-duplicate")
    }

    func testDroppedConnectionQueuesTheMessage() async {
        let h = Harness()
        h.host.handler = { m, _ in
            if m == "chat.send" { throw OPAError.notConnected }
            return [:]
        }
        h.model.send(text: "hello", attachments: [], clientId: "c1")
        let queued = await waitUntil { self.delivery(h, "c1") == .queued }
        XCTAssertTrue(queued)
    }

    func testQueuedMessagesFlushOldestFirst() async {
        let h = Harness(connected: false)
        h.model.send(text: "1", attachments: [], clientId: "c1")
        h.model.send(text: "2", attachments: [], clientId: "c2")
        h.model.send(text: "3", attachments: [], clientId: "c3")
        h.host.handler = { m, _ in m == "chat.send" ? ["msgId": "x"] : [:] }
        h.connect()
        await h.model.flushOutbox()
        XCTAssertEqual(h.host.calls("chat.send").compactMap { $0.params["clientId"]?.string }, ["c1", "c2", "c3"])
        XCTAssertEqual(h.model.queuedMessageCount, 0)
    }

    // MARK: Remote error → failed → retry

    func testRemoteErrorFailsTheMessageWithTheReasonAndRetryUsesTheSameClientId() async {
        let h = Harness()
        var attempts = 0
        h.host.handler = { m, _ in
            guard m == "chat.send" else { return [:] }
            attempts += 1
            if attempts == 1 { throw OPAError.remote("消息太长") }
            return ["msgId": "u_1"]
        }
        h.model.send(text: "hello", attachments: [], clientId: "c1")
        let failed = await waitUntil { self.delivery(h, "c1") == .failed("消息太长") }
        XCTAssertTrue(failed, "got \(String(describing: delivery(h, "c1")))")
        XCTAssertEqual(h.model.persistence.outbox().count, 1, "a failed message is kept so it can be retried, even after a relaunch")

        // A reconnect must not silently resend a message the host refused.
        await h.model.flushOutbox()
        XCTAssertEqual(h.host.calls("chat.send").count, 1)
        XCTAssertEqual(delivery(h, "c1"), .failed("消息太长"))

        h.model.retry(clientId: "c1")
        XCTAssertEqual(delivery(h, "c1"), .sending)
        let sent = await waitUntil { self.delivery(h, "c1") == .sent }
        XCTAssertTrue(sent)
        XCTAssertEqual(h.host.calls("chat.send").compactMap { $0.params["clientId"]?.string }, ["c1", "c1"])
        XCTAssertEqual(h.model.persistence.outbox().count, 0)
    }

    func testRetryWhileOfflineQueuesTheMessageForTheNextReconnect() async {
        let h = Harness()
        h.host.handler = { m, _ in
            if m == "chat.send" { throw OPAError.remote("no") }
            return [:]
        }
        h.model.send(text: "hello", attachments: [], clientId: "c1")
        _ = await waitUntil { self.delivery(h, "c1") == .failed("no") }
        h.disconnect()
        h.model.retry(clientId: "c1")
        XCTAssertEqual(delivery(h, "c1"), .queued)

        h.host.handler = { m, _ in m == "chat.send" ? ["msgId": "u_1"] : [:] }
        h.connect()
        await h.model.flushOutbox()
        XCTAssertEqual(delivery(h, "c1"), .sent)
    }

    func testRetryIsIgnoredForMessagesThatAreSendingOrSent() async {
        let h = Harness()
        h.model.ev(1, "msg.user", Payload.user(clientId: "c1"))
        h.model.retry(clientId: "c1")
        XCTAssertTrue(h.host.calls.isEmpty)
        XCTAssertEqual(delivery(h, "c1"), .sent)
        h.model.retry(clientId: "unknown")   // no crash
    }

    func testASentMessageNeverGoesBackToQueued() async {
        let h = Harness()
        h.host.handler = { m, _ in
            guard m == "chat.send" else { return [:] }
            h.model.ev(1, "msg.user", Payload.user(clientId: "c1", text: "hello"))
            throw OPAError.timeout   // the answer is lost, but the echo already proved the host has it
        }
        h.model.send(text: "hello", attachments: [], clientId: "c1")
        try? await Task.sleep(for: .milliseconds(100))
        XCTAssertEqual(delivery(h, "c1"), .sent)
    }

    func testDoubleDeliveryOfTheSameClientIdIsSuppressedWhileInFlight() async {
        let h = Harness()
        h.host.handler = { m, _ in
            if m == "chat.send" { try? await Task.sleep(for: .milliseconds(80)); return ["msgId": "u_1"] }
            return [:]
        }
        h.model.send(text: "hello", attachments: [], clientId: "c1")
        async let again: Void = h.model.deliver(clientId: "c1")
        await again
        _ = await waitUntil { self.delivery(h, "c1") == .sent }
        XCTAssertEqual(h.host.calls("chat.send").count, 1)
    }

    // MARK: Outbox survives a relaunch

    func testOutboxMessagesAreShownAsQueuedAfterARelaunch() {
        let h = Harness(connected: false)
        h.model.persistence.enqueue(clientId: "old1", text: "left over", attachments: [])
        h.model.persistence.enqueue(clientId: "old2", text: "also left over", attachments: [])
        XCTAssertTrue(h.model.timeline.isEmpty)
        h.model.showOutboxMessages()
        XCTAssertEqual(h.model.timelineIds, ["u:old1", "u:old2"])
        XCTAssertEqual(delivery(h, "old1"), .queued)
        XCTAssertEqual(h.model.userMessage(clientId: "old2")?.text, "also left over")
    }

    func testEmptyMessagesAreNotSent() {
        let h = Harness()
        h.model.send(text: "   \n ", attachments: [], clientId: "c1")
        XCTAssertTrue(h.model.timeline.isEmpty)
        XCTAssertTrue(h.host.calls.isEmpty)
    }

    // MARK: Error classification

    func testWhichErrorsQueueAndWhichFail() {
        XCTAssertEqual(AppModel.deliveryState(after: OPAError.notConnected), .queued)
        XCTAssertEqual(AppModel.deliveryState(after: OPAError.timeout), .queued)
        XCTAssertEqual(AppModel.deliveryState(after: OPAError.cancelled), .queued)
        XCTAssertEqual(AppModel.deliveryState(after: OPAError.remote("x")), .failed("x"))
        if case .failed(let m) = AppModel.deliveryState(after: OPAError.rejected("nope")) { XCTAssertTrue(m.contains("nope")) } else { XCTFail() }
        if case .failed = AppModel.deliveryState(after: CocoaError(.fileNoSuchFile)) {} else { XCTFail() }
    }

    func testPendingFlagFollowsDelivery() {
        func msg(_ d: UserMessage.Delivery) -> UserMessage {
            UserMessage(id: nil, clientId: "c", text: "t", attachments: [], ts: 0, delivery: d)
        }
        XCTAssertTrue(msg(.sending).pending)
        XCTAssertTrue(msg(.queued).pending)
        XCTAssertFalse(msg(.sent).pending)
        XCTAssertFalse(msg(.failed("x")).pending)
    }
}
