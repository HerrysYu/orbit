import XCTest
@testable import OPA

@MainActor
final class StreamingTests: XCTestCase {
    private func streaming(_ h: Harness, _ id: String) -> Bool? { h.model.assistantMessage(id: id)?.streaming }

    // MARK: End conditions

    func testFinalMessageWithTheSameIdEndsStreaming() {
        let h = Harness()
        h.model.live("msg.start", ["id": "X"])
        h.model.live("msg.delta", ["id": "X", "text": "Hi"])
        XCTAssertEqual(streaming(h, "X"), true)
        XCTAssertTrue(h.model.hasStreamingMessage)
        h.model.ev(1, "msg.assistant", Payload.assistant(id: "X", text: "Hi there"))
        XCTAssertEqual(streaming(h, "X"), false)
        XCTAssertFalse(h.model.hasStreamingMessage)
        XCTAssertFalse(h.model.isReplying)
    }

    func testIdleStatusWithNoFurtherDeltaEndsStreamingAfterTheGracePeriod() async {
        let h = Harness()
        h.model.streamIdleGrace = .milliseconds(80)
        h.model.live("butler.status", ["state": "thinking"])
        h.model.live("msg.start", ["id": "X"])
        h.model.live("msg.delta", ["id": "X", "text": "partial"])
        // The host dies / loses the final message: the status goes idle and nothing else ever arrives.
        h.model.live("butler.status", ["state": "idle"])
        XCTAssertEqual(streaming(h, "X"), true, "not immediately: a final message may still be on its way")
        let ended = await waitUntil { self.streaming(h, "X") == false }
        XCTAssertTrue(ended)
        XCTAssertEqual(h.model.assistantMessage(id: "X")?.text, "partial", "the text received so far is kept")
        XCTAssertFalse(h.model.isReplying, "the composer must not be stuck on stop")
    }

    func testADeltaAfterIdleKeepsTheStreamAlive() async {
        let h = Harness()
        h.model.streamIdleGrace = .milliseconds(120)
        h.model.live("msg.start", ["id": "X"])
        h.model.live("msg.delta", ["id": "X", "text": "a"])
        h.model.live("butler.status", ["state": "idle"])
        try? await Task.sleep(for: .milliseconds(40))
        h.model.live("msg.delta", ["id": "X", "text": "b"])   // still producing text
        try? await Task.sleep(for: .milliseconds(200))
        XCTAssertEqual(streaming(h, "X"), true, "a delta resets the quiet period (and no new idle was reported)")
        h.model.live("butler.status", ["state": "idle"])
        let ended = await waitUntil { self.streaming(h, "X") == false }
        XCTAssertTrue(ended)
        XCTAssertEqual(h.model.assistantMessage(id: "X")?.text, "ab")
    }

    func testGoingBusyAgainCancelsTheIdleCheck() async {
        let h = Harness()
        h.model.streamIdleGrace = .milliseconds(60)
        h.model.live("msg.start", ["id": "X"])
        h.model.live("butler.status", ["state": "idle"])
        h.model.live("butler.status", ["state": "thinking"])
        try? await Task.sleep(for: .milliseconds(200))
        XCTAssertEqual(streaming(h, "X"), true)
    }

    func testAnEmptyStreamPlaceholderIsRemovedWhenTheStreamEndsWithoutAFinalMessage() async {
        let h = Harness()
        h.model.streamIdleGrace = .milliseconds(50)
        h.model.live("msg.start", ["id": "X"])
        h.model.live("butler.status", ["state": "idle"])
        let gone = await waitUntil { h.model.timeline.isEmpty }
        XCTAssertTrue(gone)
        XCTAssertFalse(h.model.hasStreamingMessage)
    }

    func testDroppedConnectionEndsTheStreamAndFreesTheComposer() {
        let h = Harness()
        h.model.live("butler.status", ["state": "acting", "detail": "派出任务"])
        h.model.live("msg.start", ["id": "X"])
        h.model.live("msg.delta", ["id": "X", "text": "so far"])
        XCTAssertTrue(h.model.isReplying)
        h.model.connectionStateChanged(.waitingRetry(seconds: 2, reason: ""))
        XCTAssertEqual(streaming(h, "X"), false)
        XCTAssertEqual(h.model.assistantMessage(id: "X")?.text, "so far")
        XCTAssertEqual(h.model.butlerState, .idle, "what the bot was doing is unknown once we lost the connection")
        XCTAssertFalse(h.model.isReplying)
    }

    func testARepliesStillBeingWrittenAfterAReconnectStreamsAgain() {
        // The connection blips; the Mac keeps writing the same reply and its deltas keep coming after the reconnect.
        let h = Harness()
        h.model.live("msg.start", ["id": "X"])
        h.model.live("msg.delta", ["id": "X", "text": "abc"])
        h.model.connectionStateChanged(.waitingRetry(seconds: 1, reason: ""))
        XCTAssertEqual(streaming(h, "X"), false)
        h.model.connectionStateChanged(.connected(.lan))
        h.model.live("msg.delta", ["id": "X", "text": "def"])
        XCTAssertEqual(streaming(h, "X"), true, "more text means it is still being written")
        XCTAssertEqual(h.model.assistantMessage(id: "X")?.text, "abcdef")
        XCTAssertTrue(h.model.isReplying)
        h.model.ev(1, "msg.assistant", Payload.assistant(id: "X", text: "abcdef ghi"))
        XCTAssertEqual(streaming(h, "X"), false)
        XCTAssertEqual(h.model.assistantMessage(id: "X")?.text, "abcdef ghi")
        h.model.live("msg.delta", ["id": "X", "text": "LATE"])
        XCTAssertEqual(streaming(h, "X"), false, "after its final message a reply never streams again")
        XCTAssertEqual(h.model.assistantMessage(id: "X")?.text, "abcdef ghi")
        XCTAssertFalse(h.model.isReplying)
    }

    func testStreamingEndsOnEveryTransitionAwayFromConnected() {
        for lost: ConnectionState in [.hostOffline, .connecting, .handshaking(.relay), .failed("x"), .idle] {
            let h = Harness()
            h.model.live("msg.start", ["id": "X"])
            h.model.live("msg.delta", ["id": "X", "text": "t"])
            h.model.connectionStateChanged(lost)
            XCTAssertEqual(streaming(h, "X"), false, "\(lost)")
        }
    }

    // MARK: isReplying

    func testIsReplyingFollowsTheBotAndTheConnection() {
        let h = Harness()
        XCTAssertFalse(h.model.isReplying)
        h.model.live("butler.status", ["state": "thinking"])
        XCTAssertTrue(h.model.isReplying)
        h.model.live("butler.status", ["state": "acting", "detail": "整理结果"])
        XCTAssertTrue(h.model.isReplying)
        h.model.live("butler.status", ["state": "waiting"])
        XCTAssertFalse(h.model.isReplying, "waiting for you is not replying")
        h.model.live("butler.status", ["state": "idle"])
        XCTAssertFalse(h.model.isReplying)
        h.model.live("msg.start", ["id": "X"])
        XCTAssertTrue(h.model.isReplying, "streaming counts")
        // Offline: nothing can be stopped.
        h.model.connection = .hostOffline
        XCTAssertFalse(h.model.isReplying)
    }

    func testButlerDetailAndToolAreKept() {
        let h = Harness()
        h.model.live("butler.status", ["state": "acting", "detail": "派出任务", "tool": "codex_session_create"])
        XCTAssertEqual(h.model.butlerDetail, "派出任务")
        XCTAssertEqual(h.model.butlerTool, "codex_session_create")
        h.model.live("butler.status", ["state": "idle"])
        XCTAssertNil(h.model.butlerDetail)
        XCTAssertNil(h.model.butlerTool)
    }

    // MARK: stopReply

    func testStopReplySendsChatInterrupt() async {
        let h = Harness()
        h.model.stopReply()
        let sent = await waitUntil { !h.host.calls("chat.interrupt").isEmpty }
        XCTAssertTrue(sent)
        XCTAssertEqual(h.host.calls("chat.interrupt").count, 1)
    }

    func testStopReplyFailureShowsAToast() async {
        let h = Harness()
        h.host.handler = { _, _ in throw OPAError.notConnected }
        h.model.stopReply()
        let toasted = await waitUntil { h.model.toast != nil }
        XCTAssertTrue(toasted)
    }
}
