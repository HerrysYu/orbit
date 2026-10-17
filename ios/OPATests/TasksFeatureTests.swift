import XCTest
@testable import OPA

/// The rules behind the task screens and the confirm sheet (`Features/Tasks`, `Features/Approval`): wording, which line
/// says what a task is doing, how an approval's detail is split, where a session works.
@MainActor
final class TasksFeatureTests: XCTestCase {
    // MARK: Builders

    private func taskJSON(id: String, status: String, title: String = "任务", goal: String = "目标", summary: String? = nil,
                          steps: [(title: String, status: String, session: String?)] = [],
                          createdAt: Int64 = 1_000, updatedAt: Int64 = 1_000) -> JSONValue {
        var o: [String: JSONValue] = [
            "id": .string(id), "title": .string(title), "goal": .string(goal), "status": .string(status),
            "steps": .array(steps.enumerated().map { i, s in
                var step: [String: JSONValue] = ["id": .string("\(id)-\(i)"), "title": .string(s.title), "status": .string(s.status)]
                if let session = s.session { step["sessionId"] = .string(session) }
                return .object(step)
            }),
            "createdAt": .number(Double(createdAt)), "updatedAt": .number(Double(updatedAt)),
        ]
        if let summary { o["summary"] = .string(summary) }
        return .object(o)
    }

    private func sessionJSON(id: String, taskId: String?, title: String = "会话", status: String = "running", lastActivity: String? = nil,
                             model: String? = nil, permission: String = "manual", createdAt: Int64 = 1_000, updatedAt: Int64 = 1_000) -> JSONValue {
        var o: [String: JSONValue] = ["id": .string(id), "title": .string(title), "status": .string(status), "permission": .string(permission),
                                      "createdAt": .number(Double(createdAt)), "updatedAt": .number(Double(updatedAt))]
        if let taskId { o["taskId"] = .string(taskId) }
        if let lastActivity { o["lastActivity"] = .string(lastActivity) }
        if let model { o["model"] = .string(model) }
        return .object(o)
    }

    private func info(_ h: Harness, _ taskId: String) -> TaskInfo {
        TaskInfo(task: h.model.tasks[taskId]!, model: h.model)
    }

    private func session(_ title: String, status: OPASession.Status = .idle, createdAt: Int64 = 0, updatedAt: Int64 = 0) -> OPASession {
        OPASession(id: "s", taskId: nil, title: title, model: nil, status: status, permission: .manual, lastActivity: nil,
                   createdAt: createdAt, updatedAt: updatedAt)
    }

    // MARK: Text

    func testCleanTrimsAndTreatsBlankAsMissing() {
        XCTAssertEqual(TaskText.clean("  你好 \n"), "你好")
        XCTAssertNil(TaskText.clean("   "))
        XCTAssertNil(TaskText.clean(""))
        XCTAssertNil(TaskText.clean(nil))
    }

    // MARK: Time

    func testAgoIsDeterministicChinese() {
        let now = Date(timeIntervalSince1970: 1_000_000)
        func ago(_ secondsBack: Int) -> String { TaskTime.ago(Clock.ms(now.addingTimeInterval(TimeInterval(-secondsBack))), now: now) }
        XCTAssertEqual(ago(5), "刚刚")
        XCTAssertEqual(ago(59), "刚刚")
        XCTAssertEqual(ago(60), "1 分钟前")
        XCTAssertEqual(ago(3 * 60 + 20), "3 分钟前")
        XCTAssertEqual(ago(2 * 3600), "2 小时前")
        XCTAssertEqual(ago(3 * 86_400), "3 天前")
        XCTAssertEqual(ago(-30), "刚刚", "a Mac clock slightly ahead of the phone never reads negative")
    }

    func testStampShowsTheClockTodayAndYesterdayByName() throws {
        let calendar = Calendar.current
        let now = try XCTUnwrap(calendar.date(from: DateComponents(year: 2026, month: 10, day: 15, hour: 18, minute: 30)))
        let earlierToday = try XCTUnwrap(calendar.date(from: DateComponents(year: 2026, month: 10, day: 15, hour: 9, minute: 5)))
        let yesterday = try XCTUnwrap(calendar.date(from: DateComponents(year: 2026, month: 10, day: 14, hour: 23, minute: 50)))
        let older = try XCTUnwrap(calendar.date(from: DateComponents(year: 2026, month: 10, day: 3, hour: 10)))
        XCTAssertEqual(TaskTime.stamp(Clock.ms(earlierToday), now: now), Fmt.time(Clock.ms(earlierToday)))
        XCTAssertEqual(TaskTime.stamp(Clock.ms(yesterday), now: now), "昨天")
        let other = TaskTime.stamp(Clock.ms(older), now: now)
        XCTAssertNotEqual(other, "昨天")
        XCTAssertTrue(other.contains("3"), "a month/day date: \(other)")
    }

    func testHeaderLineSaysStartAndLastChange() throws {
        let calendar = Calendar.current
        let now = try XCTUnwrap(calendar.date(from: DateComponents(year: 2026, month: 10, day: 15, hour: 18, minute: 30)))
        let created = Clock.ms(try XCTUnwrap(calendar.date(from: DateComponents(year: 2026, month: 10, day: 15, hour: 17, minute: 20))))
        let updated = Clock.ms(now.addingTimeInterval(-20))
        let running = TaskTime.headerLine(createdAt: created, updatedAt: updated, finished: false, now: now)
        XCTAssertEqual(running, "\(Fmt.time(created)) 开始 · 刚刚更新")
        let finished = TaskTime.headerLine(createdAt: created, updatedAt: Clock.ms(now.addingTimeInterval(-5 * 60)), finished: true, now: now)
        XCTAssertEqual(finished, "\(Fmt.time(created)) 开始 · 5 分钟前结束")
        XCTAssertEqual(TaskTime.headerLine(createdAt: 0, updatedAt: 0, finished: false, now: now), "", "unknown times say nothing")
    }

    func testDurationReadsNaturally() {
        XCTAssertNil(TaskTime.duration(ms: 0))
        XCTAssertNil(TaskTime.duration(ms: 999))
        XCTAssertNil(TaskTime.duration(ms: -5_000))
        XCTAssertEqual(TaskTime.duration(ms: 1_000), "1 秒")
        XCTAssertEqual(TaskTime.duration(ms: 59_000), "59 秒")
        XCTAssertEqual(TaskTime.duration(ms: 134_000), "2 分 14 秒")
        XCTAssertEqual(TaskTime.duration(ms: 120_000), "2 分钟")
        XCTAssertEqual(TaskTime.duration(ms: 3_900_000), "1 小时 5 分")
        XCTAssertEqual(TaskTime.duration(ms: 3_600_000), "1 小时")
        XCTAssertEqual(TaskTime.duration(ms: 90_000_000), "1 天 1 小时")
        XCTAssertEqual(TaskTime.duration(ms: 3 * 86_400_000), "3 天")
    }

    // MARK: Chips

    func testChipFollowsTheTaskStatus() {
        let h = Harness()
        h.model.ev(1, "task.upsert", taskJSON(id: "run", status: "running"))
        h.model.ev(2, "task.upsert", taskJSON(id: "ask", status: "waiting_user"))
        h.model.ev(3, "task.upsert", taskJSON(id: "block", status: "blocked"))
        h.model.ev(4, "task.upsert", taskJSON(id: "done", status: "done"))
        h.model.ev(5, "task.upsert", taskJSON(id: "fail", status: "failed"))
        XCTAssertEqual(info(h, "run").chip, TaskChip(kind: .running, text: "进行中", dot: true))
        XCTAssertEqual(info(h, "ask").chip, TaskChip(kind: .waiting, text: "等你补充"))
        XCTAssertEqual(info(h, "block").chip, TaskChip(kind: .blocked, text: "遇到阻碍"))
        XCTAssertEqual(info(h, "done").chip, TaskChip(kind: .done, text: "已完成"))
        XCTAssertEqual(info(h, "fail").chip, TaskChip(kind: .failed, text: "未完成"))
    }

    func testASessionWaitingForAnApprovalMakesTheTaskWaitForYourConfirmation() {
        let h = Harness()
        h.model.ev(1, "task.upsert", taskJSON(id: "t", status: "running"))
        h.model.ev(2, "session.upsert", sessionJSON(id: "s", taskId: "t", status: "waiting_approval"))
        XCTAssertTrue(info(h, "t").awaitingConfirmation)
        XCTAssertEqual(info(h, "t").chip, TaskChip(kind: .waiting, text: "等你确认"))
        h.model.ev(3, "session.upsert", sessionJSON(id: "s", taskId: "t", status: "running"))
        XCTAssertFalse(info(h, "t").awaitingConfirmation)
        XCTAssertEqual(info(h, "t").chip.text, "进行中")
    }

    func testAnEndedTaskNeverWaitsForYou() {
        let h = Harness()
        h.model.ev(1, "task.upsert", taskJSON(id: "t", status: "done"))
        h.model.ev(2, "session.upsert", sessionJSON(id: "s", taskId: "t", status: "waiting_approval"))
        XCTAssertFalse(info(h, "t").awaitingConfirmation)
        XCTAssertEqual(info(h, "t").chip.text, "已完成")
    }

    func testPendingApprovalsAreLinkedThroughTheExecutionSession() {
        let h = Harness()
        h.model.nowMs = { 10_000 }
        h.model.ev(1, "task.upsert", taskJSON(id: "t", status: "running"))
        h.model.ev(2, "session.upsert", sessionJSON(id: "s", taskId: "t"))
        h.model.ev(3, "approval.request", Payload.approval(id: "mine", sessionId: "s"))
        h.model.ev(4, "approval.request", Payload.approval(id: "other-session", sessionId: "elsewhere"))
        h.model.ev(5, "approval.request", Payload.approval(id: "orbits-own"))
        XCTAssertEqual(info(h, "t").pendingApprovals.map(\.id), ["mine"], "nothing is guessed onto a task")
        XCTAssertTrue(info(h, "t").awaitingConfirmation)
        h.model.ev(6, "approval.resolved", ["id": "mine", "decision": "approve", "by": "user"])
        XCTAssertTrue(info(h, "t").pendingApprovals.isEmpty, "answered approvals are not pending any more")
    }

    func testCancellingReplacesTheChipUntilTheHostConfirms() async {
        let h = Harness()
        h.model.ev(1, "task.upsert", taskJSON(id: "t", status: "running"))
        await h.model.cancelTask(id: "t")
        XCTAssertEqual(info(h, "t").chip, TaskChip(kind: .cancelled, text: "正在取消…"))
        h.model.ev(2, "task.upsert", taskJSON(id: "t", status: "cancelled"))
        XCTAssertEqual(info(h, "t").chip, TaskChip(kind: .cancelled, text: "已取消"))
    }

    // MARK: Lines

    func testCurrentActionIsTheStepTitleNeverWhatTheExecutionReports() {
        let h = Harness()
        h.model.ev(1, "task.upsert", taskJSON(id: "t", status: "running", summary: "总结",
                                              steps: [("找文件", "done", nil), ("填表", "running", "s2")]))
        h.model.ev(2, "session.upsert", sessionJSON(id: "s1", taskId: "t", status: "idle", lastActivity: "已结束", updatedAt: 9_000))
        h.model.ev(3, "session.upsert", sessionJSON(id: "s2", taskId: "t", status: "running", lastActivity: "调用 orbit_phone.phone_tap", updatedAt: 5_000))
        XCTAssertEqual(info(h, "t").currentAction, "填表", "the last activity of the session is not shown")
        h.model.live("session.progress", ["sessionId": "s2", "text": "执行：curl -s https://example.com"])
        XCTAssertEqual(info(h, "t").currentAction, "填表", "neither is its live progress line")
    }

    func testCurrentActionFallsBackToTheCurrentStepThenTheSummary() {
        let h = Harness()
        h.model.ev(1, "task.upsert", taskJSON(id: "steps", status: "running", summary: "总结",
                                              steps: [("A", "done", nil), ("正在做的一步", "running", nil), ("C", "pending", nil)]))
        XCTAssertEqual(info(h, "steps").currentAction, "正在做的一步")
        h.model.ev(2, "task.upsert", taskJSON(id: "bare", status: "planning", goal: "目标文字", summary: "只有摘要"))
        XCTAssertEqual(info(h, "bare").currentAction, "只有摘要")
        h.model.ev(3, "task.upsert", taskJSON(id: "empty", status: "planning", goal: "只有目标"))
        XCTAssertEqual(info(h, "empty").currentAction, "只有目标")
    }

    func testAWaitingForConfirmationTaskQuotesTheHostNotAStepTitle() {
        let h = Harness()
        h.model.ev(1, "task.upsert", taskJSON(id: "t", status: "running", summary: "预订已准备好，等你批准后提交",
                                              steps: [("A", "done", nil), ("你选定后提交预订", "running", "s")]))
        h.model.ev(2, "session.upsert", sessionJSON(id: "s", taskId: "t", status: "waiting_approval", lastActivity: "等待你的确认"))
        XCTAssertEqual(info(h, "t").currentAction, "预订已准备好，等你批准后提交")
        h.model.ev(3, "task.upsert", taskJSON(id: "t", status: "running", steps: [("A", "done", nil), ("你选定后提交预订", "running", "s")]))
        XCTAssertEqual(info(h, "t").currentAction, "等你确认后继续", "no summary: say what is true")
    }

    func testBlockedReasonAndQuestionFallBackSensibly() {
        let h = Harness()
        h.model.ev(1, "task.upsert", taskJSON(id: "b1", status: "blocked", goal: "查社保", summary: "需要你完成微信登录"))
        h.model.ev(2, "task.upsert", taskJSON(id: "b2", status: "blocked", goal: "查社保", steps: [("登录", "running", nil)]))
        h.model.ev(3, "task.upsert", taskJSON(id: "b3", status: "blocked", goal: "查社保"))
        XCTAssertEqual(info(h, "b1").blockedReason, "需要你完成微信登录")
        XCTAssertEqual(info(h, "b2").blockedReason, "登录")
        XCTAssertEqual(info(h, "b3").blockedReason, "查社保")
        h.model.ev(4, "task.upsert", taskJSON(id: "q", status: "waiting_user", goal: "想先确认预算：在 ¥2000 以内吗？"))
        XCTAssertEqual(info(h, "q").question, "想先确认预算：在 ¥2000 以内吗？")
    }

    func testDisplayTitleNeverShowsAnEmptyString() {
        let h = Harness()
        h.model.ev(1, "task.upsert", taskJSON(id: "t", status: "running", title: "  "))
        XCTAssertEqual(info(h, "t").displayTitle, "未命名任务")
    }

    // MARK: Progress

    func testProgressCountsDoneAndSkippedStepsAndFindsTheRunningOne() {
        let h = Harness()
        h.model.ev(1, "task.upsert", taskJSON(id: "t", status: "running", steps: [
            ("A", "done", nil), ("B", "skipped", nil), ("C", "running", nil), ("D", "pending", nil)]))
        XCTAssertEqual(info(h, "t").progress, TaskInfo.Progress(total: 4, done: 2, current: 2))
        h.model.ev(2, "task.upsert", taskJSON(id: "none", status: "planning"))
        XCTAssertEqual(info(h, "none").progress, TaskInfo.Progress(total: 0, done: 0, current: nil))
    }

    func testProgressLineCountsStepsNeverPercent() {
        let h = Harness()
        let updated: Int64 = 5_000_000
        h.model.ev(1, "task.upsert", taskJSON(id: "t", status: "running",
                                              steps: [("A", "done", nil), ("B", "done", nil), ("C", "running", nil)], updatedAt: updated))
        let now = Clock.date(ms: updated + 3 * 60_000 + 10_000)
        XCTAssertEqual(info(h, "t").progressLine(now: now), "2/3 步 · 3 分钟前")
        XCTAssertFalse(info(h, "t").progressLine(now: now).contains("%"))
        h.model.ev(2, "task.upsert", taskJSON(id: "bare", status: "planning", updatedAt: updated))
        XCTAssertEqual(info(h, "bare").progressLine(now: now), "3 分钟前更新")
    }

    func testTheRunningStepIsNamedByItsTitleAndCarriesNoProgressText() {
        let h = Harness()
        h.model.ev(1, "task.upsert", taskJSON(id: "t", status: "running", steps: [("A", "done", "s"), ("B", "running", "s"), ("C", "pending", nil)]))
        h.model.ev(2, "session.upsert", sessionJSON(id: "s", taskId: "t", status: "running", lastActivity: "上一步动作"))
        h.model.live("session.progress", ["sessionId": "s", "text": "正在查看详情页"])
        let t = info(h, "t")
        XCTAssertNil(t.stepSubtitle(t.task.steps[0]), "history stays quiet")
        XCTAssertNil(t.stepSubtitle(t.task.steps[1]), "the step title says it; the execution's progress text is not added")
        XCTAssertNil(t.stepSubtitle(t.task.steps[2]))
        XCTAssertEqual(t.highlightedStepId, "t-1")
        h.model.ev(3, "task.upsert", taskJSON(id: "t", status: "done", steps: [("A", "done", "s"), ("B", "done", "s")]))
        XCTAssertNil(info(h, "t").highlightedStepId, "a finished task highlights nothing")
    }

    func testAStepHeldUpForAConfirmationSaysSo() {
        let h = Harness()
        h.model.ev(1, "task.upsert", taskJSON(id: "t", status: "running", steps: [("A", "done", "s"), ("B", "running", "s")]))
        h.model.ev(2, "session.upsert", sessionJSON(id: "s", taskId: "t", status: "waiting_approval", lastActivity: "等待你的确认"))
        let t = info(h, "t")
        XCTAssertNil(t.stepSubtitle(t.task.steps[0]))
        XCTAssertEqual(t.stepSubtitle(t.task.steps[1]), "等你确认后继续")
    }

    func testTheNoteQuotesTheSummaryOnlyWhenNoApprovalSpeaksInsteadOfIt() {
        let h = Harness()
        h.model.nowMs = { 10_000 }
        h.model.ev(1, "task.upsert", taskJSON(id: "ask", status: "waiting_user", summary: "问题"))
        h.model.ev(2, "task.upsert", taskJSON(id: "block", status: "blocked", summary: "原因"))
        h.model.ev(3, "task.upsert", taskJSON(id: "run", status: "running", summary: "进展"))
        h.model.ev(4, "task.upsert", taskJSON(id: "done", status: "done", summary: "结果"))
        XCTAssertTrue(info(h, "ask").noteQuotesSummary)
        XCTAssertTrue(info(h, "block").noteQuotesSummary)
        XCTAssertFalse(info(h, "run").noteQuotesSummary)
        XCTAssertFalse(info(h, "done").noteQuotesSummary, "the result card shows it")
        h.model.ev(5, "session.upsert", sessionJSON(id: "s", taskId: "run"))
        h.model.ev(6, "approval.request", Payload.approval(id: "a", sessionId: "s"))
        XCTAssertFalse(info(h, "run").noteQuotesSummary, "the note quotes the approval, so the summary card stays")
    }

    // MARK: Sessions

    func testSessionKindComesFromTheTitleMarker() {
        XCTAssertEqual(SessionKind.parse(title: "📱 大众点评查询空位").kind, .phone)
        XCTAssertEqual(SessionKind.parse(title: "📱 大众点评查询空位").title, "大众点评查询空位")
        XCTAssertEqual(SessionKind.parse(title: "🖥 填写报销表").kind, .desktop)
        XCTAssertEqual(SessionKind.parse(title: "🖥️ 填写报销表").title, "填写报销表", "with the emoji variation selector")
        XCTAssertEqual(SessionKind.parse(title: "🤵 📱 订票").kind, .phone, "a butler-started phone session")
        XCTAssertEqual(SessionKind.parse(title: "🤵 📱 订票").title, "订票")
        XCTAssertEqual(SessionKind.parse(title: "酒店搜索与预订").kind, .mac)
        XCTAssertEqual(SessionKind.parse(title: "酒店搜索与预订").title, "酒店搜索与预订")
        XCTAssertEqual(SessionKind.parse(title: "📱").title, "📱", "a title that is only a marker is kept")
        XCTAssertEqual(SessionKind.parse(title: "  普通 会话  ").title, "普通 会话")
    }

    func testSessionKindLabelsAndSymbols() {
        XCTAssertEqual(SessionKind.phone.label, "安卓手机")
        XCTAssertEqual(SessionKind.desktop.label, "Mac 图形界面")
        XCTAssertEqual(SessionKind.mac.label, "Mac")
        XCTAssertEqual(Set([SessionKind.phone, .desktop, .mac].map(\.symbol)).count, 3, "three different icons")
    }

    func testSessionChipDependsOnTheTaskForIdleSessions() {
        func chip(_ status: OPASession.Status, _ task: OPATask.Status?) -> TaskChip {
            SessionPresentation.chip(for: session("s", status: status), taskStatus: task)
        }
        XCTAssertEqual(chip(.running, .running), TaskChip(kind: .running, text: "进行中", dot: true))
        XCTAssertEqual(chip(.waiting_approval, .running), TaskChip(kind: .waiting, text: "等你确认"))
        XCTAssertEqual(chip(.error, .failed), TaskChip(kind: .failed, text: "出错"))
        XCTAssertEqual(chip(.archived, nil), TaskChip(kind: .cancelled, text: "已归档"))
        XCTAssertEqual(chip(.idle, .done), TaskChip(kind: .done, text: "已完成"))
        XCTAssertEqual(chip(.idle, .cancelled), TaskChip(kind: .cancelled, text: "已停止"))
        XCTAssertEqual(chip(.idle, .running), TaskChip(kind: .planning, text: "空闲"))
        XCTAssertEqual(chip(.idle, nil), TaskChip(kind: .planning, text: "空闲"))
    }

    func testSessionSubtitleSaysWhereHowAndHowLong() {
        let done = session("📱 查空位", status: .idle, createdAt: 1_000_000, updatedAt: 1_000_000 + 134_000)
        XCTAssertEqual(SessionPresentation.subtitle(for: done, kind: .phone, chipText: "已完成"), "安卓手机 · 已完成 · 用时 2 分 14 秒")
        let instant = session("x", status: .idle, createdAt: 5_000, updatedAt: 5_000)
        XCTAssertEqual(SessionPresentation.subtitle(for: instant, kind: .mac, chipText: "空闲"), "Mac · 空闲", "no duration to speak of")
        let running = session("x", status: .running, createdAt: 1_000_000)
        let now = Clock.date(ms: 1_000_000 + 65_000)
        XCTAssertEqual(SessionPresentation.subtitle(for: running, kind: .mac, chipText: "进行中", now: now), "Mac · 进行中 · 已运行 1 分 5 秒")
    }

    func testPermissionAndModelLabels() {
        XCTAssertEqual(SessionPresentation.permissionLabel(.manual), "逐项确认")
        XCTAssertEqual(SessionPresentation.permissionLabel(.auto), "完全访问")
        let models = ModelsList(butler: [.init(id: "gpt-5", displayName: "GPT-5")], codex: [.init(id: "gpt-5-codex", displayName: "GPT-5 Codex")])
        XCTAssertEqual(SessionPresentation.modelLabel("gpt-5-codex", models: models), "GPT-5 Codex")
        XCTAssertEqual(SessionPresentation.modelLabel("gpt-5", models: models), "GPT-5", "falls back to the bot list")
        XCTAssertEqual(SessionPresentation.modelLabel("unknown-model", models: models), "unknown-model")
        XCTAssertEqual(SessionPresentation.modelLabel("gpt-5-codex", models: nil), "gpt-5-codex")
        XCTAssertNil(SessionPresentation.modelLabel("  ", models: models))
        XCTAssertNil(SessionPresentation.modelLabel(nil, models: models))
    }

    func testActionLogSymbolsCoverTheHostsItemTypesAndTheDemosKinds() {
        for kind in ["command", "commandExecution"] {
            XCTAssertEqual(SessionPresentation.itemSymbol(kind: kind), "terminal")
            XCTAssertTrue(SessionPresentation.isCommand(kind: kind))
        }
        for kind in ["message", "agentMessage"] { XCTAssertEqual(SessionPresentation.itemSymbol(kind: kind), "text.bubble") }
        XCTAssertEqual(SessionPresentation.itemSymbol(kind: "webSearch"), "globe")
        XCTAssertEqual(SessionPresentation.itemSymbol(kind: "fileChange"), "doc.badge.gearshape")
        XCTAssertEqual(SessionPresentation.itemSymbol(kind: "imageView"), "eye")
        XCTAssertEqual(SessionPresentation.itemSymbol(kind: "mcpToolCall"), SessionPresentation.itemSymbol(kind: "dynamicToolCall"))
        XCTAssertEqual(SessionPresentation.itemSymbol(kind: "something-new"), "smallcircle.filled.circle", "unknown kinds still get an icon")
        XCTAssertFalse(SessionPresentation.isCommand(kind: "plan"))
    }

    // MARK: Approval copy

    func testApproveVerbPerKind() {
        XCTAssertEqual(ApprovalCopy.approveVerb(.command), "允许执行")
        XCTAssertEqual(ApprovalCopy.approveVerb(.fileChange), "允许修改")
        XCTAssertEqual(ApprovalCopy.approveVerb(.permissions), "授予权限")
        XCTAssertEqual(ApprovalCopy.approveVerb(.elicitation), "允许")
        XCTAssertEqual(ApprovalCopy.approveVerb(.action), "批准")
    }

    func testExpiryWording() {
        XCTAssertEqual(ApprovalCopy.expiry(remainingMs: 0), "已过期")
        XCTAssertEqual(ApprovalCopy.expiry(remainingMs: -5_000), "已过期")
        XCTAssertEqual(ApprovalCopy.expiry(remainingMs: 30_000), "不到 1 分钟后过期")
        XCTAssertEqual(ApprovalCopy.expiry(remainingMs: 29 * 60_000 + 30_000), "29 分钟后过期")
        XCTAssertEqual(ApprovalCopy.expiry(remainingMs: 60 * 60_000), "1 小时后过期")
        XCTAssertEqual(ApprovalCopy.expiry(remainingMs: 90 * 60_000), "1 小时 30 分钟后过期")
        XCTAssertEqual(ApprovalCopy.expiry(remainingMs: 25 * 3_600_000), "1 天后过期")
    }

    func testOnlyHighRiskCarriesTheIrreversibleWarning() {
        XCTAssertNil(ApprovalCopy.riskNote(.low))
        XCTAssertNil(ApprovalCopy.riskNote(.medium))
        XCTAssertNotNil(ApprovalCopy.riskNote(.high))
    }

    func testAfterTextKeepsTheBeforeApprovingColon() {
        XCTAssertEqual(ApprovalCopy.afterText("批准后：我会下单"), "批准后：我会下单", "the full-width colon stays")
        XCTAssertEqual(ApprovalCopy.afterText("批准后:我会下单"), "批准后：我会下单", "an ASCII colon becomes the full-width one")
        XCTAssertEqual(ApprovalCopy.afterText("批准后：  "), "批准后会继续执行")
        XCTAssertEqual(ApprovalCopy.afterText("别的话"), "别的话")
    }

    // MARK: Approval content

    func testTheHostsFormatSplitsIntoRowsAndAfterText() {
        let c = ApprovalContent(detail: """
        餐厅：鮨 · 静安店（大众点评 4.8）
        时间：10 月 18 日 周六 19:00
        人数：2 人 · 吧台位
        批准后：我会在你的安卓手机上提交预订。
        """)
        XCTAssertEqual(c.rows.map(\.label), ["餐厅", "时间", "人数"])
        XCTAssertEqual(c.rows.first?.value, "鮨 · 静安店（大众点评 4.8）")
        XCTAssertNil(c.body)
        XCTAssertEqual(c.after, "批准后：我会在你的安卓手机上提交预订。")
        XCTAssertEqual(c.summary, "鮨 · 静安店（大众点评 4.8） · 10 月 18 日 周六 19:00 · 2 人 · 吧台位")
        XCTAssertEqual(c.summary(maxRows: 2), "鮨 · 静安店（大众点评 4.8） · 10 月 18 日 周六 19:00")
    }

    func testACommandApprovalKeepsTheCommandAsBodyText() {
        // `init(detail:)` is Orbit's own wording: everything is shown as written.
        let c = ApprovalContent(detail: "npm publish\n原因：发布 v0.3.1 到 npm\n目录：~/code/opa-skill\n批准后：Orbit 会把新版本发布出去。")
        XCTAssertEqual(c.body, "npm publish")
        XCTAssertEqual(c.rows.map(\.label), ["原因", "目录"])
        XCTAssertEqual(c.after, "批准后：Orbit 会把新版本发布出去。")
        XCTAssertNil(c.technical)
        XCTAssertEqual(c.summary, "发布 v0.3.1 到 npm · ~/code/opa-skill")
    }

    // MARK: Approval content from an execution

    private func approval(_ kind: Approval.Kind, _ detail: String) -> Approval {
        Approval(id: "a", title: "t", detail: detail, risk: .medium, sessionId: "s", kind: kind, requireBiometric: false, createdAt: 0, expiresAt: nil)
    }

    func testACommandRequestShowsItsReasonAndFoldsTheCommandAndTheDirectory() {
        let c = ApprovalContent(approval: approval(.command, "npm publish\n原因：发布 v0.3.1 到 npm\n目录：~/code/opa-skill"))
        XCTAssertEqual(c.rows, [.init(label: "原因", value: "发布 v0.3.1 到 npm")])
        XCTAssertNil(c.body, "the raw command is never shown in the open")
        XCTAssertEqual(c.technical, "npm publish\n目录：~/code/opa-skill", "nothing is dropped: it is folded, in order")
        XCTAssertEqual(c.summary, "发布 v0.3.1 到 npm", "compact places only ever get the reason")
    }

    func testARequestWithoutAReasonFoldsEverything() {
        let c = ApprovalContent(approval: approval(.command, "rm -rf ./build\n目录：/tmp/x"))
        XCTAssertTrue(c.rows.isEmpty)
        XCTAssertNil(c.body)
        XCTAssertEqual(c.technical, "rm -rf ./build\n目录：/tmp/x")
        XCTAssertNil(c.summary)
    }

    func testPermissionsFileChangeAndElicitationFoldWhatTheyCarry() {
        let permissions = ApprovalContent(approval: approval(.permissions, "需要联网下载依赖\n{\"network\":{\"enabled\":true}}"))
        XCTAssertTrue(permissions.rows.isEmpty)
        XCTAssertEqual(permissions.technical, "需要联网下载依赖\n{\"network\":{\"enabled\":true}}", "unlabelled text is folded whole")

        let file = ApprovalContent(approval: approval(.fileChange, "申请写入 /Users/herry/project"))
        XCTAssertEqual(file.technical, "申请写入 /Users/herry/project")
        XCTAssertNil(file.summary)

        let elicitation = ApprovalContent(approval: approval(.elicitation, "允许 Chrome 打开这个页面吗？\n操作：open_url\n网址：https://example.com\n原因：需要查资料"))
        XCTAssertEqual(elicitation.rows, [.init(label: "原因", value: "需要查资料")])
        XCTAssertEqual(elicitation.technical, "允许 Chrome 打开这个页面吗？\n操作：open_url\n网址：https://example.com")
    }

    func testAnUnparseableExecutionDetailIsFoldedWholeNotLost() {
        let text = "weird: {\n  \"a\": 1\n}\nhttps://example.com/a:b"
        let c = ApprovalContent(approval: approval(.permissions, text))
        XCTAssertTrue(c.rows.isEmpty)
        XCTAssertEqual(c.technical, text.split(separator: "\n").map { $0.trimmingCharacters(in: .whitespaces) }.joined(separator: "\n"))
    }

    func testOrbitsOwnRequestIsShownAsWrittenWhateverItsFormat() {
        let c = ApprovalContent(approval: approval(.action, "餐厅：鮨\n时间：周六 19:00\n批准后：我会提交预订"))
        XCTAssertEqual(c.rows.map(\.label), ["餐厅", "时间"])
        XCTAssertEqual(c.after, "批准后：我会提交预订")
        XCTAssertNil(c.technical)
        let free = ApprovalContent(approval: approval(.action, "只是一段说明文字"))
        XCTAssertEqual(free.body, "只是一段说明文字")
        XCTAssertNil(free.technical)
    }

    func testAReasonAndTheAfterSentenceStayInTheOpenForAnExecutionRequest() {
        let c = ApprovalContent(approval: approval(.command, "npm publish\n原因：发布\n批准后：Orbit 会发布。"))
        XCTAssertEqual(c.rows.map(\.value), ["发布"])
        XCTAssertEqual(c.after, "批准后：Orbit 会发布。")
        XCTAssertEqual(c.technical, "npm publish")
    }

    func testADetailThatFollowsNoConventionIsShownWhole() {
        let text = "rm -rf ./build && echo \"done: ok\"\nhttps://example.com/a:b"
        let c = ApprovalContent(detail: text)
        XCTAssertTrue(c.rows.isEmpty)
        XCTAssertNil(c.after)
        XCTAssertEqual(c.body, text, "nothing is dropped because parsing found no rows")
        XCTAssertEqual(c.summary, "rm -rf ./build && echo \"done: ok\"", "the first line stands in for the summary")
    }

    func testAnEmptyDetailIsEmpty() {
        let c = ApprovalContent(detail: "")
        XCTAssertTrue(c.rows.isEmpty)
        XCTAssertNil(c.body)
        XCTAssertNil(c.after)
        XCTAssertNil(c.summary)
    }

    func testTheSameApprovalGivesTheSameContentFromTheModel() {
        let a = Payload.approvalValue(id: "a", detail: "餐厅：鮨\n批准后：我会预订")
        XCTAssertEqual(ApprovalContent(approval: a), ApprovalContent(detail: a.detail))
    }

    // MARK: Approval source

    func testSourceIsTheTaskOfTheApprovalsSessionElseTheSessionElseNothing() {
        let task = OPATask(id: "t", title: "订周六晚的日料", goal: "", status: .running, steps: [], createdAt: 0, updatedAt: 0)
        let withTask = OPASession(id: "s1", taskId: "t", title: "📱 查空位", model: nil, status: .running, permission: .manual,
                                  lastActivity: nil, createdAt: 0, updatedAt: 0)
        let orphan = OPASession(id: "s2", taskId: nil, title: "🖥 填表", model: nil, status: .running, permission: .manual,
                                lastActivity: nil, createdAt: 0, updatedAt: 0)
        let sessions = ["s1": withTask, "s2": orphan]
        let tasks = ["t": task]
        func approval(_ sessionId: String?) -> Approval {
            Approval(id: "a", title: "x", detail: "", risk: .low, sessionId: sessionId, kind: .action, requireBiometric: false, createdAt: 0, expiresAt: nil)
        }
        let viaTask = ApprovalSource.resolve(approval: approval("s1"), sessions: sessions, tasks: tasks)
        XCTAssertEqual(viaTask, .task(title: "订周六晚的日料"))
        XCTAssertEqual(viaTask?.text, "来自任务「订周六晚的日料」")
        XCTAssertEqual(viaTask?.taskTitle, "订周六晚的日料")
        let viaSession = ApprovalSource.resolve(approval: approval("s2"), sessions: sessions, tasks: tasks)
        XCTAssertEqual(viaSession, .session(title: "填表"), "the marker is not part of the name")
        XCTAssertEqual(viaSession?.text, "来自任务「填表」")
        XCTAssertNil(viaSession?.taskTitle)
        XCTAssertNil(ApprovalSource.resolve(approval: approval(nil), sessions: sessions, tasks: tasks), "Orbit's own requests have no session")
        XCTAssertNil(ApprovalSource.resolve(approval: approval("gone"), sessions: sessions, tasks: tasks))
        XCTAssertEqual(ApprovalSource.resolve(approval: approval("s1"), sessions: sessions, tasks: [:]), .session(title: "查空位"),
                       "a session whose task is gone still names itself")
    }
}
