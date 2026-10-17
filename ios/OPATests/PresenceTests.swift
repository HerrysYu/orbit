import XCTest
@testable import OPA

@MainActor
final class PresenceTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1_760_000_000)

    private func resolve(_ connection: ConnectionState = .connected(.lan), seen: Date? = nil, approvals: Int = 0, streaming: Bool = false,
                         state: ButlerState = .idle, running: Bool = false, demo: Bool = false) -> Presence {
        Presence.resolve(.init(connection: connection, isDemo: demo, lastSeenOnlineAt: seen, pendingApprovalCount: approvals,
                               isStreaming: streaming, butlerState: state, hasRunningWork: running, now: now))
    }

    // MARK: Priority

    func testIdleIsStandingBy() {
        let p = resolve()
        XCTAssertEqual(p.text, "待命中")
        XCTAssertEqual(p.tone, .neutral)
        XCTAssertEqual(p.mood, .wave)
    }

    func testThinking() {
        let p = resolve(state: .thinking)
        XCTAssertEqual(p.text, "正在想办法…")
        XCTAssertEqual(p.tone, .live)
        XCTAssertEqual(p.mood, .thinking)
    }

    func testExecutingIsAFixedPhrase() {
        let p = resolve(state: .acting, running: true)
        XCTAssertEqual(p.text, "正在处理…")
        XCTAssertEqual(p.tone, .live)
        XCTAssertEqual(p.mood, .focused)
        XCTAssertEqual(resolve(state: .acting).text, "正在处理…")
    }

    func testARunningSessionSaysTheSameThingEvenWhenTheBotIsIdle() {
        let p = resolve(state: .idle, running: true)
        XCTAssertEqual(p.text, "正在处理…")
        XCTAssertEqual(p.tone, .live)
    }

    func testExecutingBeatsThinking() {
        XCTAssertEqual(resolve(state: .thinking, running: true).text, "正在处理…")
    }

    func testStreamingBeatsExecutingAndThinking() {
        let p = resolve(streaming: true, state: .acting, running: true)
        XCTAssertEqual(p.text, "正在回复…")
        XCTAssertEqual(p.tone, .live)
        XCTAssertEqual(resolve(streaming: true, state: .thinking).text, "正在回复…")
    }

    func testPendingApprovalsBeatStreamingAndExecuting() {
        let p = resolve(approvals: 2, streaming: true, state: .acting, running: true)
        XCTAssertEqual(p.text, "等你确认 2 件事")
        XCTAssertEqual(p.tone, .warn)
        XCTAssertEqual(p.mood, .attentive)
        XCTAssertEqual(resolve(approvals: 1).text, "等你确认 1 件事")
    }

    func testMacOfflineBeatsEverything() {
        for c: ConnectionState in [.hostOffline, .failed("x")] {
            let p = resolve(c, approvals: 3, streaming: true, state: .acting, running: true)
            XCTAssertTrue(p.text.hasPrefix("Mac 离线"), "\(c): \(p.text)")
            XCTAssertEqual(p.tone, .warn)
        }
    }

    func testReconnectingIsNotReportedAsOffline() {
        // Same split as `ConnectionIndicator`: these show "恢复中", only host-offline / failed show "Mac 离线".
        for c: ConnectionState in [.idle, .connecting, .handshaking(.lan), .waitingRetry(seconds: 3, reason: "")] {
            let p = resolve(c, approvals: 3)
            XCTAssertEqual(p.text, "正在恢复连接…", "\(c)")
            XCTAssertEqual(p.tone, .neutral)
        }
    }

    func testOfflineShowsWhenTheMacWasLastSeen() {
        XCTAssertEqual(resolve(.hostOffline, seen: now.addingTimeInterval(-20)).text, "Mac 离线 · 刚刚在线")
        XCTAssertEqual(resolve(.hostOffline, seen: now.addingTimeInterval(-120)).text, "Mac 离线 · 2 分钟前在线")
        XCTAssertEqual(resolve(.hostOffline, seen: now.addingTimeInterval(-3 * 3600)).text, "Mac 离线 · 3 小时前在线")
        XCTAssertEqual(resolve(.hostOffline, seen: now.addingTimeInterval(-2 * 86_400)).text, "Mac 离线 · 2 天前在线")
        XCTAssertEqual(resolve(.hostOffline, seen: nil).text, "Mac 离线")
    }

    func testDemoModeIsNeverOffline() {
        XCTAssertEqual(resolve(.idle, demo: true).text, "待命中")
    }

    func testWaitingForYouWithoutApprovals() {
        let p = resolve(state: .waiting)
        XCTAssertEqual(p.text, "等你回复")
        XCTAssertEqual(p.mood, .attentive)
    }

    // MARK: On the model

    func testModelPresenceFollowsTheSameOrder() {
        let h = Harness()
        XCTAssertEqual(h.model.presence.text, "待命中")

        h.model.live("butler.status", ["state": "thinking"])
        XCTAssertEqual(h.model.presence.text, "正在想办法…")

        h.model.ev(1, "session.upsert", Payload.session(id: "s1", taskId: "t1"))
        h.model.ev(2, "task.upsert", Payload.task(id: "t1", status: "running"))
        h.model.live("session.progress", ["sessionId": "s1", "text": "正在比较退改政策"])
        XCTAssertEqual(h.model.presence.text, "正在处理…", "executing wins over thinking, and says only that")

        h.model.live("butler.status", ["state": "acting", "detail": "派出任务", "tool": "codex_session_create"])
        XCTAssertEqual(h.model.presence.text, "正在处理…", "the bot's own phrase and the tool behind it are never shown")

        h.model.live("msg.start", ["id": "X"])
        XCTAssertEqual(h.model.presence.text, "正在回复…")

        h.model.ev(3, "approval.request", Payload.approval(id: "ap1"))
        XCTAssertEqual(h.model.presence.text, "等你确认 1 件事")

        h.model.connection = .hostOffline
        XCTAssertTrue(h.model.presence.text.hasPrefix("Mac 离线"))
    }

    func testNothingTheModelOrASessionReportsReachesThePresence() {
        let h = Harness()
        h.model.ev(1, "task.upsert", Payload.task(id: "t1", status: "running"))
        h.model.ev(2, "session.upsert", Payload.session(id: "s1", taskId: "t1", status: "running"))
        h.model.live("session.progress", ["sessionId": "s1", "text": "调用 orbit_phone.phone_tap"])
        h.model.live("butler.status", ["state": "acting", "detail": "在手机上操作", "tool": "orbit_phone.phone_tap"])
        let text = h.model.presence.text
        XCTAssertEqual(text, "正在处理…")
        for leak in ["orbit_phone", "phone_tap", "在手机上操作", "调用"] {
            XCTAssertFalse(text.contains(leak), "\(leak) must not show: \(text)")
        }
    }

    func testOnlyRunningSessionsOfActiveTasksCountAsExecuting() {
        let h = Harness()
        h.model.ev(1, "task.upsert", Payload.task(id: "t1", status: "done"))
        h.model.ev(2, "session.upsert", Payload.session(id: "s1", taskId: "t1", status: "running"))
        h.model.live("session.progress", ["sessionId": "s1", "text": "stale"])
        XCTAssertFalse(h.model.hasRunningExecution, "the task is finished; its session is not really running")
        XCTAssertEqual(h.model.presence.text, "待命中")

        h.model.ev(3, "task.upsert", Payload.task(id: "t2", status: "running"))
        h.model.ev(4, "session.upsert", Payload.session(id: "s2", taskId: "t2", status: "running"))
        XCTAssertTrue(h.model.hasRunningExecution)
        XCTAssertEqual(h.model.presence.text, "正在处理…")
    }

    func testASessionWithoutATaskCountsWhileItRuns() {
        let h = Harness()
        h.model.ev(1, "session.upsert", Payload.session(id: "lone", taskId: nil, status: "running"))
        XCTAssertTrue(h.model.hasRunningExecution)
        h.model.ev(2, "session.upsert", Payload.session(id: "lone", taskId: nil, status: "idle"))
        XCTAssertFalse(h.model.hasRunningExecution)
    }

    // MARK: Connection info

    func testConnectionInfoTracksTheLastConnectionAndTheLastSign() {
        let h = Harness(connected: false)
        XCTAssertNil(h.model.connectionInfo.lastConnectedAt)
        h.model.hostName = "Herry 的 Mac"
        h.model.connectionStateChanged(.connected(.relay))
        var info = h.model.connectionInfo
        XCTAssertEqual(info.hostName, "Herry 的 Mac")
        XCTAssertEqual(info.path, .relay)
        XCTAssertEqual(info.state, .connected(.relay))
        XCTAssertNotNil(info.lastConnectedAt)
        XCTAssertNotNil(info.lastSeenOnlineAt)

        let connectedAt = info.lastConnectedAt
        h.model.connectionStateChanged(.hostOffline)
        info = h.model.connectionInfo
        XCTAssertNil(info.path, "no path while offline")
        XCTAssertEqual(info.lastConnectedAt, connectedAt, "the last connection time survives going offline")
        XCTAssertNotNil(info.lastSeenOnlineAt)

        // It is remembered across launches.
        XCTAssertNotNil(h.defaults.object(forKey: AppModel.DefaultsKey.lastSeenOnlineAt))
        XCTAssertNotNil(h.defaults.object(forKey: AppModel.DefaultsKey.lastConnectedAt))
    }

    func testLastSeenOnlineIsNotUpdatedWhileOffline() {
        let h = Harness(connected: false)
        h.model.connectionStateChanged(.connected(.lan))
        let seen = h.model.lastSeenOnlineAt
        h.model.connectionStateChanged(.hostOffline)
        h.model.touchOnline()
        XCTAssertEqual(h.model.lastSeenOnlineAt, seen)
    }

    func testPathOfStates() {
        XCTAssertEqual(ConnectionState.connected(.lan).path, .lan)
        XCTAssertEqual(ConnectionState.handshaking(.relay).path, .relay)
        XCTAssertEqual(ConnectionState.awaitingPairConfirm(sas: "123456", path: .lan).path, .lan)
        XCTAssertNil(ConnectionState.hostOffline.path)
        XCTAssertNil(ConnectionState.connecting.path)
    }
}
