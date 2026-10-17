import XCTest
@testable import OPA

@MainActor
final class TimelineOrderingTests: XCTestCase {
    // MARK: Arrival order, not timestamps

    func testDurableEventsFollowSeqEvenWhenTimestampsDisagree() {
        let h = Harness()
        // The Mac's clock is far ahead of the phone's, and its timestamps are not monotonic.
        h.model.ev(1, "msg.user", Payload.user(clientId: "c1", ts: 9_999_999_999))
        h.model.ev(2, "msg.assistant", Payload.assistant(id: "a1", ts: 5))
        h.model.ev(3, "ui.render", Payload.card(id: "k1"))
        h.model.ev(4, "msg.assistant", Payload.assistant(id: "a2", ts: 1))
        XCTAssertEqual(h.model.timelineIds, ["u:c1", "a:a1", "c:k1", "a:a2"])
    }

    func testPhoneClockBehindTheMacDoesNotPutNewMessagesBeforeHistory() {
        // Bug: the timeline was sorted by `ts`, mixing the phone's clock (pending messages, streaming replies) with
        // the Mac's. A phone running behind put the message you just sent above the whole history.
        let h = Harness()
        h.model.nowMs = { 1_000 }   // phone clock: 1970
        h.model.ev(1, "msg.assistant", Payload.assistant(id: "a1", ts: 1_760_000_000_000))
        h.model.ev(2, "ui.render", Payload.card(id: "k1"))
        h.model.send(text: "hello", attachments: [], clientId: "c1")
        h.model.live("msg.start", ["id": "a2"])
        XCTAssertEqual(h.model.timelineIds, ["a:a1", "c:k1", "u:c1", "a:a2"])
    }

    func testPhoneClockAheadOfTheMacDoesNotPutNewMessagesAfterLaterEvents() {
        let h = Harness()
        h.model.nowMs = { 9_000_000_000_000 }   // phone clock: far in the future
        h.model.ev(1, "msg.assistant", Payload.assistant(id: "a1", ts: 10))
        h.model.send(text: "hello", attachments: [], clientId: "c1")
        h.model.ev(2, "msg.assistant", Payload.assistant(id: "a2", ts: 20))
        // "hello" was sent after a1 was on screen and before a2 arrived.
        XCTAssertEqual(h.model.timelineIds, ["a:a1", "u:c1", "a:a2"])
    }

    // MARK: Pending → echo keeps its place

    func testPendingMessageKeepsItsPlaceWhenTheEchoArrives() {
        let h = Harness()
        h.model.ev(1, "msg.assistant", Payload.assistant(id: "a1"))
        h.model.send(text: "A", attachments: [], clientId: "cA")
        // A proactive message from the Mac slips in before the Mac gets to our message.
        h.model.ev(2, "msg.assistant", Payload.assistant(id: "a2"))
        XCTAssertEqual(h.model.timelineIds, ["a:a1", "u:cA", "a:a2"])
        h.model.ev(3, "msg.user", Payload.user(id: "u_9", clientId: "cA", text: "A", ts: 3))
        XCTAssertEqual(h.model.timelineIds, ["a:a1", "u:cA", "a:a2"], "the echo must not move the message")
        let m = h.model.userMessage(clientId: "cA")
        XCTAssertEqual(m?.delivery, .sent)
        XCTAssertEqual(m?.id, "u_9")
        XCTAssertEqual(m?.ts, 3, "the displayed time becomes the Mac's")
    }

    func testMessagesSentWhileOfflineStayInSendOrder() {
        let h = Harness(connected: false)
        h.model.send(text: "1", attachments: [], clientId: "c1")
        h.model.send(text: "2", attachments: [], clientId: "c2")
        h.model.send(text: "3", attachments: [], clientId: "c3")
        XCTAssertEqual(h.model.timelineIds, ["u:c1", "u:c2", "u:c3"])
        // Echoes arrive out of order; each message keeps the place it had.
        h.model.ev(1, "msg.user", Payload.user(id: "u1", clientId: "c1"))
        h.model.ev(3, "msg.user", Payload.user(id: "u3", clientId: "c3"))
        h.model.ev(2, "msg.user", Payload.user(id: "u2", clientId: "c2"))   // old seq: ignored (seq must increase)
        XCTAssertEqual(h.model.timelineIds, ["u:c1", "u:c2", "u:c3"])
    }

    func testEchoFromAnotherDeviceGoesWhereTheMacPutIt() {
        let h = Harness()
        h.model.ev(1, "msg.assistant", Payload.assistant(id: "a1"))
        h.model.send(text: "mine", attachments: [], clientId: "mine")
        h.model.ev(2, "msg.user", Payload.user(id: "u_other", clientId: "theirs", text: "theirs"))
        XCTAssertEqual(h.model.timelineIds, ["a:a1", "u:mine", "u:theirs"])
    }

    func testEchoWithoutClientIdFallsBackToTheHostId() {
        let h = Harness()
        h.model.ev(1, "msg.user", ["id": "u_7", "clientId": "", "text": "x", "ts": 1])
        h.model.ev(2, "msg.user", ["id": "u_8", "clientId": "", "text": "y", "ts": 2])
        XCTAssertEqual(h.model.timelineIds, ["u:u_7", "u:u_8"], "an empty clientId must not collapse messages into one")
    }

    // MARK: Streaming → final keeps its place

    func testStreamingMessageKeepsItsPlaceWhenTheFinalMessageArrives() {
        let h = Harness()
        h.model.ev(1, "msg.user", Payload.user(clientId: "c1"))
        h.model.live("msg.start", ["id": "X"])
        h.model.live("msg.delta", ["id": "X", "text": "Hel"])
        h.model.live("msg.delta", ["id": "X", "text": "lo"])
        // A card is rendered while the reply is still streaming.
        h.model.ev(2, "ui.render", Payload.card(id: "k1"))
        XCTAssertEqual(h.model.timelineIds, ["u:c1", "a:X", "c:k1"])
        XCTAssertEqual(h.model.assistantMessage(id: "X")?.text, "Hello")
        XCTAssertEqual(h.model.assistantMessage(id: "X")?.streaming, true)

        h.model.ev(3, "msg.assistant", Payload.assistant(id: "X", text: "Hello there", ts: 3))
        XCTAssertEqual(h.model.timelineIds, ["u:c1", "a:X", "c:k1"], "the final message replaces the placeholder in place")
        let m = h.model.assistantMessage(id: "X")
        XCTAssertEqual(m?.text, "Hello there")
        XCTAssertEqual(m?.streaming, false)
        XCTAssertEqual(m?.ts, 3)
    }

    func testFinalMessageWithoutStreamingIsInsertedBySeq() {
        let h = Harness()
        h.model.ev(1, "msg.user", Payload.user(clientId: "c1"))
        h.model.ev(2, "msg.assistant", Payload.assistant(id: "a1"))
        XCTAssertEqual(h.model.timelineIds, ["u:c1", "a:a1"])
    }

    // MARK: No duplicates

    func testRerenderedCardKeepsItsPositionAndTakesTheNewContent() {
        let h = Harness()
        h.model.ev(1, "ui.render", Payload.card(id: "k1", props: ["markdown": "old"]))
        h.model.ev(2, "msg.assistant", Payload.assistant(id: "a1"))
        h.model.ev(3, "ui.render", Payload.card(id: "k1", props: ["markdown": "new"]))
        XCTAssertEqual(h.model.timelineIds, ["c:k1", "a:a1"])
        XCTAssertEqual(h.model.card(id: "k1")?.props["markdown"]?.string, "new")
    }

    func testPatchUpdatesTheCardInPlace() {
        let h = Harness()
        h.model.ev(1, "ui.render", Payload.card(id: "k1", props: ["status": "draft", "total": 44]))
        h.model.ev(2, "msg.assistant", Payload.assistant(id: "a1"))
        h.model.ev(3, "ui.patch", ["id": "k1", "props": ["status": "placed"]])
        XCTAssertEqual(h.model.timelineIds, ["c:k1", "a:a1"])
        XCTAssertEqual(h.model.card(id: "k1")?.props["status"]?.string, "placed")
        XCTAssertEqual(h.model.card(id: "k1")?.props["total"]?.int, 44)
    }

    func testDuplicateEventsAreIgnored() {
        let h = Harness()
        h.model.ev(1, "msg.assistant", Payload.assistant(id: "a1", text: "first"))
        h.model.ev(1, "msg.assistant", Payload.assistant(id: "a1", text: "again"))   // same seq: dropped
        XCTAssertEqual(h.model.timeline.count, 1)
        XCTAssertEqual(h.model.assistantMessage(id: "a1")?.text, "first")
    }

    // MARK: Streaming deltas are cheap

    func testDeltasAppendInPlaceAndNeverReorder() {
        let h = Harness()
        for i in 1...200 { h.model.ev(Int64(i), "msg.assistant", Payload.assistant(id: "a\(i)")) }
        h.model.live("msg.start", ["id": "S"])
        let before = h.model.timelineIds
        XCTAssertEqual(before.last, "a:S")
        let start = ContinuousClock.now
        for _ in 0..<5_000 { h.model.live("msg.delta", ["id": "S", "text": "x"]) }
        let elapsed = ContinuousClock.now - start
        XCTAssertEqual(h.model.timelineIds, before)
        XCTAssertEqual(h.model.assistantMessage(id: "S")?.text.count, 5_000)
        XCTAssertLessThan(elapsed, .seconds(3), "5 000 deltas on a 200-message timeline should be near-instant")
    }

    func testDeltaForAMessageThatAlreadyEndedIsIgnored() {
        let h = Harness()
        h.model.live("msg.start", ["id": "S"])
        h.model.live("msg.delta", ["id": "S", "text": "abc"])
        h.model.ev(1, "msg.assistant", Payload.assistant(id: "S", text: "abc"))
        h.model.live("msg.delta", ["id": "S", "text": "LATE"])
        XCTAssertEqual(h.model.assistantMessage(id: "S")?.text, "abc")
    }

    // MARK: Replay

    func testReplayAndLiveProduceTheSameOrder() {
        let events: [(Int64, String, JSONValue)] = [
            (1, "msg.assistant", Payload.assistant(id: "a1")),
            (2, "msg.user", Payload.user(clientId: "c1")),
            (3, "ui.render", Payload.card(id: "k1")),
            (4, "msg.assistant", Payload.assistant(id: "a2")),
        ]
        let live = Harness()
        for (s, k, d) in events { live.model.ev(s, k, d) }
        let replayed = Harness()
        for (s, k, d) in events { replayed.model.apply(k: k, d: d, ts: s * 1000, seq: s, animated: false) }
        XCTAssertEqual(live.model.timelineIds, replayed.model.timelineIds)
    }

    // MARK: TimelineStore

    func testStoreKeepsItemsSortedByKeyWhateverTheInsertionOrder() {
        var store = TimelineStore()
        func card(_ id: String) -> TimelineItem { .card(Card(id: id, component: "text_card", props: [:], ts: 0)) }
        store.upsert(card("c"), order: 3)
        store.upsert(card("a"), order: 1)
        store.upsert(card("b"), order: 2.5)
        store.upsert(card("d"), order: 10)
        XCTAssertEqual(store.items.map(\.id), ["c:a", "c:b", "c:c", "c:d"])
        store.upsert(card("a"), order: 99)   // existing: keeps its key
        XCTAssertEqual(store.items.map(\.id), ["c:a", "c:b", "c:c", "c:d"])
        XCTAssertTrue(store.remove("c:b"))
        XCTAssertEqual(store.items.map(\.id), ["c:a", "c:c", "c:d"])
        XCTAssertFalse(store.contains("c:b"))
    }

    func testStoreNudgesCollidingKeys() {
        var store = TimelineStore()
        func card(_ id: String) -> TimelineItem { .card(Card(id: id, component: "text_card", props: [:], ts: 0)) }
        store.upsert(card("a"), order: 5)
        store.upsert(card("b"), order: 5)   // same key: goes after, stays addressable
        XCTAssertEqual(store.items.map(\.id), ["c:a", "c:b"])
        XCTAssertNotNil(store.item("c:a"))
        XCTAssertNotNil(store.item("c:b"))
    }

    func testStoreUpdateMutatesInPlace() {
        var store = TimelineStore()
        store.upsert(.assistant(AssistantMessage(id: "x", text: "a", proactive: false, interrupted: false, streaming: true, ts: 0)), order: 1)
        store.upsert(.assistant(AssistantMessage(id: "y", text: "b", proactive: false, interrupted: false, streaming: false, ts: 0)), order: 2)
        let changed = store.update("a:x") { item in
            guard case .assistant(var m) = item else { return }
            m.text += "bc"
            item = .assistant(m)
        }
        XCTAssertTrue(changed)
        XCTAssertFalse(store.update("a:nope") { _ in })
        XCTAssertEqual(store.items.map(\.id), ["a:x", "a:y"])
        if case .assistant(let m) = store.item("a:x") { XCTAssertEqual(m.text, "abc") } else { XCTFail() }
    }

    func testReadingTheTimelineDoesNotCopyOrSort() {
        // `timeline` is a stored array: reading it twice yields identical contents without any work in between.
        let h = Harness()
        for i in 1...50 { h.model.ev(Int64(i), "msg.assistant", Payload.assistant(id: "a\(i)")) }
        XCTAssertEqual(h.model.timeline, h.model.timeline)
        XCTAssertEqual(h.model.timeline.count, 50)
    }
}
