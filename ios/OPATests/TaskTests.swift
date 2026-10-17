import XCTest
@testable import OPA

@MainActor
final class TaskTests: XCTestCase {
    private func seed(_ h: Harness) {
        let m = h.model
        m.ev(1, "task.upsert", Payload.task(id: "run1", status: "running", updatedAt: 5_000))
        m.ev(2, "task.upsert", Payload.task(id: "plan1", status: "planning", updatedAt: 6_000))
        m.ev(3, "task.upsert", Payload.task(id: "wait1", status: "waiting_user", updatedAt: 4_000))
        m.ev(4, "task.upsert", Payload.task(id: "block1", status: "blocked", updatedAt: 3_000))
        m.ev(5, "task.upsert", Payload.task(id: "done1", status: "done", updatedAt: 2_000))
        m.ev(6, "task.upsert", Payload.task(id: "fail1", status: "failed", updatedAt: 9_000))
        m.ev(7, "task.upsert", Payload.task(id: "canc1", status: "cancelled", updatedAt: 1_000))
    }

    // MARK: Groups

    func testEveryTaskLandsInExactlyOneGroup() {
        let h = Harness()
        seed(h)
        XCTAssertEqual(h.model.activeTasks.map(\.id), ["plan1", "run1"], "planning + running, newest first")
        XCTAssertEqual(h.model.blockedTasks.map(\.id), ["block1"])
        XCTAssertEqual(h.model.finishedTasks.map(\.id), ["fail1", "done1", "canc1"], "done + failed + cancelled, newest first")
        let attentionTasks = h.model.attentionItems.compactMap { item -> String? in
            if case .task(let t) = item { return t.id } else { return nil }
        }
        XCTAssertEqual(attentionTasks, ["wait1", "block1"], "等你处理 holds the questions and the blocked tasks, newest first")
        let all = h.model.activeTasks + h.model.finishedTasks
        XCTAssertEqual(all.count + attentionTasks.count, h.model.tasks.count)
    }

    func testAttentionItemsAreApprovalsPlusWaitingAndBlockedTasksNewestFirst() {
        let h = Harness()
        h.model.nowMs = { 50_000 }
        h.model.ev(1, "task.upsert", Payload.task(id: "wait-old", status: "waiting_user", updatedAt: 2_000))
        h.model.ev(2, "task.upsert", Payload.task(id: "wait-new", status: "waiting_user", updatedAt: 8_000))
        h.model.ev(3, "approval.request", Payload.approval(id: "ap-mid", createdAt: 5_000))
        h.model.ev(4, "approval.request", Payload.approval(id: "ap-expired", createdAt: 9_000, expiresAt: 40_000))
        h.model.ev(5, "approval.request", Payload.approval(id: "ap-answered", createdAt: 9_500))
        h.model.ev(6, "approval.resolved", ["id": "ap-answered", "decision": "approve", "by": "user"])
        h.model.ev(7, "task.upsert", Payload.task(id: "block-mid", status: "blocked", updatedAt: 6_000))
        XCTAssertEqual(h.model.attentionItems.map(\.id), ["task:wait-new", "task:block-mid", "approval:ap-mid", "task:wait-old"])
        XCTAssertEqual(h.model.attentionItems.count, 4, "the group title and the tasks-tab badge say the same number")
    }

    func testWaitingTasksHelperListsOnlyWaitingTasksNewestFirst() {
        let h = Harness()
        seed(h)
        h.model.ev(20, "task.upsert", Payload.task(id: "wait2", status: "waiting_user", updatedAt: 7_000))
        XCTAssertEqual(h.model.waitingTasks.map(\.id), ["wait2", "wait1"])
        XCTAssertFalse(h.model.activeTasks.contains { $0.status == .waiting_user }, "the groups never overlap")
    }

    func testAttentionShrinksWhenATaskStopsWaiting() {
        let h = Harness()
        h.model.ev(1, "task.upsert", Payload.task(id: "t", status: "waiting_user"))
        XCTAssertEqual(h.model.attentionItems.count, 1)
        h.model.ev(2, "task.upsert", Payload.task(id: "t", status: "running"))
        XCTAssertEqual(h.model.attentionItems.count, 0)
        XCTAssertEqual(h.model.activeTasks.map(\.id), ["t"])
    }

    func testTaskSessionsOldestFirst() {
        let h = Harness()
        h.model.ev(1, "session.upsert", ["id": "b", "taskId": "t", "title": "B", "status": "running", "permission": "manual", "createdAt": 20, "updatedAt": 20])
        h.model.ev(2, "session.upsert", ["id": "a", "taskId": "t", "title": "A", "status": "idle", "permission": "manual", "createdAt": 10, "updatedAt": 30])
        h.model.ev(3, "session.upsert", ["id": "other", "taskId": "x", "title": "O", "status": "idle", "permission": "manual", "createdAt": 5, "updatedAt": 5])
        XCTAssertEqual(h.model.taskSessions("t").map(\.id), ["a", "b"])
        XCTAssertTrue(h.model.taskSessions("none").isEmpty)
    }

    func testStatusLabels() {
        let expected: [OPATask.Status: String] = [.planning: "规划中", .running: "进行中", .waiting_user: "等你补充", .blocked: "遇到阻碍",
                                                  .done: "已完成", .failed: "未完成", .cancelled: "已取消"]
        for (s, label) in expected { XCTAssertEqual(s.label, label) }
        XCTAssertEqual(TaskStep.Status.pending.label, "待开始")
        XCTAssertEqual(TaskStep.Status.running.label, "进行中")
        XCTAssertEqual(TaskStep.Status.done.label, "完成")
        XCTAssertEqual(TaskStep.Status.failed.label, "失败")
        XCTAssertEqual(TaskStep.Status.skipped.label, "跳过")
        XCTAssertTrue(OPATask.Status.done.isFinished)
        XCTAssertFalse(OPATask.Status.blocked.isFinished)
    }

    // MARK: task.remove

    func testTaskRemoveEventDropsTheTasksTheirSessionsAndProgress() {
        let h = Harness()
        seed(h)
        h.model.ev(10, "session.upsert", Payload.session(id: "s-done", taskId: "done1", status: "idle"))
        h.model.ev(11, "session.upsert", Payload.session(id: "s-run", taskId: "run1"))
        h.model.live("session.progress", ["sessionId": "s-done", "text": "x"])
        h.model.live("session.progress", ["sessionId": "s-run", "text": "y"])
        h.model.ev(12, "task.remove", ["ids": ["done1", "canc1"]])
        XCTAssertNil(h.model.tasks["done1"])
        XCTAssertNil(h.model.tasks["canc1"])
        XCTAssertNotNil(h.model.tasks["fail1"])
        XCTAssertNil(h.model.sessions["s-done"])
        XCTAssertNil(h.model.sessionProgress["s-done"])
        XCTAssertNotNil(h.model.sessions["s-run"])
        XCTAssertEqual(h.model.sessionProgress["s-run"], "y")
        XCTAssertEqual(h.model.finishedTasks.map(\.id), ["fail1"])
    }

    func testTaskRemoveEndsTheirLiveActivitiesImmediately() {
        let h = Harness()
        seed(h)
        h.model.ev(10, "task.remove", ["ids": ["done1", "run1"]])
        XCTAssertEqual(Set(h.activities.ended.map(\.taskId)), ["done1", "run1"])
        XCTAssertTrue(h.activities.ended.allSatisfy(\.immediately), "a removed task leaves the lock screen at once")
        XCTAssertEqual(h.activities.endCalls, 1, "one batch, not one call per task")
    }

    func testReplayedRemovalsEndTheirLiveActivitiesInOneBatchAfterwards() {
        // A task was removed while the app was not running: its activity may still be on the lock screen.
        let h = Harness()
        h.model.persistence.append(seq: 1, ts: 1, k: "task.upsert", d: Payload.task(id: "gone1", status: "done"))
        h.model.persistence.append(seq: 2, ts: 2, k: "task.upsert", d: Payload.task(id: "gone2", status: "cancelled"))
        h.model.persistence.append(seq: 3, ts: 3, k: "task.upsert", d: Payload.task(id: "keep", status: "running"))
        h.model.persistence.append(seq: 4, ts: 4, k: "task.remove", d: ["ids": ["gone1"]])
        h.model.persistence.append(seq: 5, ts: 5, k: "task.remove", d: ["ids": ["gone2"]])
        h.defaults.set(5, forKey: AppModel.DefaultsKey.lastSeq)
        h.model.bootstrap()
        XCTAssertEqual(h.model.tasks.keys.sorted(), ["keep"])
        XCTAssertEqual(Set(h.activities.ended.map(\.taskId)), ["gone1", "gone2"])
        XCTAssertEqual(h.activities.endCalls, 1)
        XCTAssertTrue(h.activities.updated.isEmpty, "replaying must not start or move activities")
    }

    func testTaskRemoveIsIdempotentAndIgnoresUnknownIds() {
        let h = Harness()
        seed(h)
        h.model.ev(10, "task.remove", ["ids": ["done1", "nope"]])
        h.model.ev(11, "task.remove", ["ids": ["done1"]])
        h.model.ev(12, "task.remove", [:])   // malformed: no ids
        XCTAssertEqual(h.model.tasks.count, 6)
    }

    func testARemovedTaskStaysRemoved() {
        let h = Harness()
        h.model.ev(1, "task.upsert", Payload.task(id: "t", status: "done"))
        h.model.ev(2, "task.remove", ["ids": ["t"]])
        h.model.ev(3, "task.upsert", Payload.task(id: "t", status: "done"))              // late echo
        h.model.ev(4, "session.upsert", Payload.session(id: "s", taskId: "t", status: "archived"))   // the archived session
        XCTAssertNil(h.model.tasks["t"])
        XCTAssertNil(h.model.sessions["s"])
    }

    func testTaskRemoveAppliesOnReplayToo() {
        let h = Harness()
        h.model.apply(k: "task.upsert", d: Payload.task(id: "t", status: "done"), ts: 1, seq: 1, animated: false)
        h.model.apply(k: "task.upsert", d: Payload.task(id: "keep", status: "done"), ts: 2, seq: 2, animated: false)
        h.model.apply(k: "task.remove", d: ["ids": ["t"]], ts: 3, seq: 3, animated: false)
        XCTAssertEqual(h.model.tasks.keys.sorted(), ["keep"])
    }

    func testRemovingATaskPopsItsDetailPage() {
        let h = Harness()
        h.model.ev(1, "task.upsert", Payload.task(id: "t", status: "done"))
        h.model.openTask("t")
        XCTAssertEqual(h.model.tasksPath, ["t"])
        h.model.ev(2, "task.remove", ["ids": ["t"]])
        XCTAssertTrue(h.model.tasksPath.isEmpty)
    }

    // MARK: Live Activities

    func testLiveActivitiesFollowLiveTaskUpdatesButNotReplay() {
        let h = Harness()
        h.model.apply(k: "task.upsert", d: Payload.task(id: "old", status: "running"), ts: 1, seq: 1, animated: false)
        XCTAssertTrue(h.activities.updated.isEmpty, "replaying history must not start or move activities")
        h.model.ev(2, "task.upsert", Payload.task(id: "t", status: "running"))
        h.model.ev(3, "task.upsert", Payload.task(id: "t", status: "done"))
        XCTAssertEqual(h.activities.updated.map(\.status), [.running, .done], "the finished update is what ends the activity")
    }

    func testUnpairEndsAllLiveActivities() {
        let h = Harness()
        h.model.unpair()
        XCTAssertEqual(h.activities.endAllCount, 1)
    }

    // MARK: Clearing

    func testClearFinishedTasksAsksTheHostForTheVisibleOnesAndAppliesTheAnswer() async {
        let h = Harness()
        seed(h)
        h.host.handler = { m, d in
            guard m == "tasks.clear" else { return [:] }
            return ["removed": d["ids"] ?? []]
        }
        let n = await h.model.clearFinishedTasks()
        XCTAssertEqual(n, 3)
        let sent = h.host.calls("tasks.clear").first?.params["ids"]?.items.compactMap(\.string)
        XCTAssertEqual(Set(sent ?? []), ["done1", "fail1", "canc1"], "only finished tasks, explicit ids")
        XCTAssertTrue(h.model.finishedTasks.isEmpty)
        XCTAssertEqual(h.model.tasks.count, 4, "active, waiting and blocked tasks stay")
        // The broadcast that follows is harmless.
        h.model.ev(20, "task.remove", ["ids": ["done1", "fail1", "canc1"]])
        XCTAssertEqual(h.model.tasks.count, 4)
    }

    func testClearTaskRemovesOnlyWhatTheHostReportsRemoved() async {
        let h = Harness()
        seed(h)
        h.host.handler = { _, _ in ["removed": []] }   // the host refused (e.g. it is not finished there)
        await h.model.clearTask(id: "done1")
        XCTAssertNotNil(h.model.tasks["done1"])
        h.host.handler = { _, _ in ["removed": ["done1"]] }
        await h.model.clearTask(id: "done1")
        XCTAssertNil(h.model.tasks["done1"])
    }

    func testClearTaskRefusesUnfinishedTasksWithoutAskingTheHost() async {
        let h = Harness()
        seed(h)
        await h.model.clearTask(id: "run1")
        XCTAssertTrue(h.host.calls("tasks.clear").isEmpty)
        XCTAssertNotNil(h.model.toast)
        XCTAssertNotNil(h.model.tasks["run1"])
    }

    func testClearFailureKeepsTheTasksAndSaysSo() async {
        let h = Harness()
        seed(h)
        h.host.handler = { _, _ in throw OPAError.remote("unknown method tasks.clear") }
        let n = await h.model.clearFinishedTasks()
        XCTAssertEqual(n, 0)
        XCTAssertEqual(h.model.finishedTasks.count, 3)
        XCTAssertNotNil(h.model.toast)
    }

    func testClearWithNothingFinishedDoesNothing() async {
        let h = Harness()
        h.model.ev(1, "task.upsert", Payload.task(id: "t", status: "running"))
        let n = await h.model.clearFinishedTasks()
        XCTAssertEqual(n, 0)
        XCTAssertTrue(h.host.calls.isEmpty)
    }

    // MARK: Cancel

    func testCancelTaskSendsTheCommandAndShowsCancellingUntilTheHostConfirms() async {
        let h = Harness()
        h.model.ev(1, "task.upsert", Payload.task(id: "t", status: "running"))
        await h.model.cancelTask(id: "t")
        let call = h.host.calls("task.cmd").first
        XCTAssertEqual(call?.params["cmd"]?.string, "cancel")
        XCTAssertEqual(call?.params["taskId"]?.string, "t")
        XCTAssertTrue(h.model.isCancelling("t"))
        XCTAssertEqual(h.model.tasks["t"]?.status, .running, "not cancelled until the Mac says so")
        h.model.ev(2, "task.upsert", Payload.task(id: "t", status: "cancelled"))
        XCTAssertFalse(h.model.isCancelling("t"))
        XCTAssertEqual(h.model.tasks["t"]?.status, .cancelled)
    }

    func testCancelFailureClearsTheCancellingState() async {
        let h = Harness()
        h.model.ev(1, "task.upsert", Payload.task(id: "t", status: "running"))
        h.host.handler = { _, _ in throw OPAError.notConnected }
        await h.model.cancelTask(id: "t")
        XCTAssertFalse(h.model.isCancelling("t"))
        XCTAssertNotNil(h.model.toast)
    }

    func testCancelTwiceSendsOnce() async {
        let h = Harness()
        h.model.ev(1, "task.upsert", Payload.task(id: "t", status: "running"))
        await h.model.cancelTask(id: "t")
        await h.model.cancelTask(id: "t")
        XCTAssertEqual(h.host.calls("task.cmd").count, 1)
    }

    // MARK: Navigation

    func testOpenTaskSelectsTheTasksTabAndPushesTheTask() {
        let h = Harness()
        h.model.selectedTab = .chat
        h.model.showActivity = true
        h.model.openTask("t1")
        XCTAssertEqual(h.model.selectedTab, .tasks)
        XCTAssertEqual(h.model.tasksPath, ["t1"])
        XCTAssertFalse(h.model.showActivity, "the page must not stay hidden behind a sheet")
        h.model.openTask("t2")
        XCTAssertEqual(h.model.tasksPath, ["t2"], "a different task replaces the stack instead of piling up")
    }

    func testClearStateForgetsNavigationAndPresentation() {
        let h = Harness()
        h.model.openTask("t1")
        h.model.openApproval("a1")
        h.model.clearState()
        XCTAssertTrue(h.model.tasksPath.isEmpty)
        XCTAssertNil(h.model.presentedApprovalId)
    }
}
