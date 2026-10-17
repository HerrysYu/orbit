import Foundation
import SwiftUI

// Task groups for the tasks tab, clearing, cancelling, navigation.

extension AppModel {
    // MARK: Groups
    //
    // Every task is in exactly one group, decided by its status, so no task is listed twice:
    //   attentionItems  = pending approvals + tasks waiting for you (`waiting_user`)
    //                     + blocked tasks (`blocked`)                                   → 等你处理
    //   activeTasks     = planning / running                                          → 进行中
    //   finishedTasks   = done / failed / cancelled                                   → 已结束
    // A blocked task is held up by something only you can do (a login, a code), so it sits with the questions and the
    // confirmations instead of in a group of its own. `blockedTasks` and `waitingTasks` stay as the two halves of it.
    // Each list is newest-update first. (The mock also lists a task that waits for an approval under 进行中 with a
    // "等你确认" mark; the row reads that from `TaskInfo.awaitingConfirmation`.)

    private static func newestFirst(_ a: OPATask, _ b: OPATask) -> Bool {
        a.updatedAt != b.updatedAt ? a.updatedAt > b.updatedAt : a.id < b.id
    }

    /// 进行中: planning or running.
    var activeTasks: [OPATask] {
        tasks.values.filter { $0.status == .planning || $0.status == .running }.sorted(by: Self.newestFirst)
    }

    /// Tasks waiting for you (`waiting_user`: a question, or a request for confirmation), newest first.
    var waitingTasks: [OPATask] {
        tasks.values.filter { $0.status == .waiting_user }.sorted(by: Self.newestFirst)
    }

    /// Blocked tasks (遇到阻碍), newest first. They are listed under 等你处理 (see `attentionItems`).
    var blockedTasks: [OPATask] {
        tasks.values.filter { $0.status == .blocked }.sorted(by: Self.newestFirst)
    }

    /// 已结束: done, failed (未完成) and cancelled tasks. These are the ones `clearFinishedTasks()` removes.
    var finishedTasks: [OPATask] {
        tasks.values.filter { $0.status.isFinished }.sorted(by: Self.newestFirst)
    }

    /// 等你处理: pending approvals, tasks waiting for your answer and blocked tasks, newest first. Its count is the
    /// tasks-tab badge, so the badge and the group title always say the same number.
    var attentionItems: [AttentionItem] {
        var items = pendingApprovals.map(AttentionItem.approval)
        items += waitingTasks.map(AttentionItem.task)
        items += blockedTasks.map(AttentionItem.task)
        return items.sorted { $0.date != $1.date ? $0.date > $1.date : $0.id < $1.id }
    }

    // MIGRATION: old flat list (active first); the grouped lists above replace it.
    var sortedTasks: [OPATask] {
        tasks.values.sorted { a, b in
            if a.status.isActive != b.status.isActive { return a.status.isActive }
            return a.updatedAt > b.updatedAt
        }
    }

    /// True once the host removed the task (`tasks.clear` / `task.remove`).
    func isTaskRemoved(_ id: String) -> Bool { removedTaskIds.contains(id) }

    /// The execution sessions of a task, oldest first.
    func taskSessions(_ taskId: String) -> [OPASession] {
        sessions.values.filter { $0.taskId == taskId }.sorted { a, b in
            a.createdAt != b.createdAt ? a.createdAt < b.createdAt : a.id < b.id
        }
    }

    // MARK: Clearing

    /// Removes every finished task the user is looking at (done / failed / cancelled) — `tasks.clear` with explicit
    /// ids, so tasks that finished meanwhile are not removed unseen. Returns how many the host removed.
    @discardableResult
    func clearFinishedTasks() async -> Int {
        let ids = finishedTasks.map(\.id)
        guard !ids.isEmpty else { return 0 }
        return await clearTasks(ids)
    }

    /// Removes one finished task. (Unfinished tasks are cancelled first, see `cancelTask`.)
    func clearTask(id: String) async {
        if let t = tasks[id], !t.status.isFinished {
            showToast("这个任务还没结束，先取消它再清除")
            return
        }
        _ = await clearTasks([id])
    }

    private func clearTasks(_ ids: [String]) async -> Int {
        do {
            let res = try await request("tasks.clear", ["ids": .array(ids.map(JSONValue.string))])
            // Only what the host says it removed is removed here (the `task.remove` broadcast says the same).
            let removed = res["removed"]?.array?.compactMap(\.string) ?? []
            withAnimation(spring) { applyTaskRemoval(ids: removed) }
            return removed.count
        } catch {
            showToast("清除失败：\(error.localizedDescription)")
            return 0
        }
    }

    /// `task.remove`: the tasks are gone. Drops them, their execution sessions and live progress, closes their detail
    /// page and ends their Live Activities. Idempotent (it arrives as an event and, for our own clear, as a response).
    func applyTaskRemoval(ids: [String]) {
        guard !ids.isEmpty else { return }
        let removing = Set(ids)
        removedTaskIds.formUnion(removing)
        for id in removing {
            if tasks[id] != nil { tasks[id] = nil }
            if cancellingTaskIds.contains(id) { cancellingTaskIds.remove(id) }
        }
        // A removed task must not keep a Live Activity on the lock screen.
        if isReplaying { replayRemovedTaskIds.formUnion(removing) } else { liveActivities.end(taskIds: Array(removing), immediately: true) }
        if tasksPath.contains(where: removing.contains) { tasksPath.removeAll { removing.contains($0) } }
        let orphaned = sessions.values.filter { $0.taskId.map(removing.contains) ?? false }.map(\.id)
        for sid in orphaned {
            sessions[sid] = nil
            sessionProgress[sid] = nil
        }
    }

    // MARK: Cancelling

    /// Asks the host to cancel a task (`task.cmd cancel`). The task is only `cancelled` once the host says so;
    /// until then `isCancelling(_:)` is true ("正在取消…").
    func cancelTask(id: String) async {
        guard !cancellingTaskIds.contains(id) else { return }
        cancellingTaskIds.insert(id)
        do {
            try await request("task.cmd", ["taskId": .string(id), "cmd": "cancel"])
            // Never leave "正在取消…" on screen forever if the Mac never confirms.
            Task { [weak self, grace = cancelConfirmationGrace] in
                try? await Task.sleep(for: grace)
                guard let self, self.cancellingTaskIds.contains(id) else { return }
                self.cancellingTaskIds.remove(id)
            }
        } catch {
            cancellingTaskIds.remove(id)
            showToast("取消失败：\(error.localizedDescription)")
        }
    }

    func isCancelling(_ taskId: String) -> Bool { cancellingTaskIds.contains(taskId) }

    func taskCommand(taskId: String? = nil, sessionId: String? = nil, cmd: String, text: String? = nil) async {
        var o: [String: JSONValue] = ["cmd": .string(cmd)]
        if let taskId { o["taskId"] = .string(taskId) }
        if let sessionId { o["sessionId"] = .string(sessionId) }
        if let text { o["text"] = .string(text) }
        do {
            try await request("task.cmd", .object(o))
        } catch {
            showToast(error.localizedDescription)
        }
    }

    func sessionDetail(_ id: String) async throws -> (OPASession?, [SessionItem]) {
        let res = try await request("session.detail", ["sessionId": .string(id)])
        let s = try? res["session"]?.decode(OPASession.self)
        let items = (try? res["items"]?.decode([SessionItem].self)) ?? []
        return (s, items)
    }

    // MARK: Navigation

    /// Shows a task's detail page in the tasks tab (from anywhere, including from a sheet).
    func openTask(_ id: String) {
        dismissGlobalSheets()
        selectedTab = .tasks
        if tasksPath != [id] { tasksPath = [id] }
    }

    /// Shows the global confirm sheet for an approval (replacing any other global sheet).
    func openApproval(_ id: String) {
        showActivity = false
        showConnection = false
        if presentedApprovalId != id { presentedApprovalId = id }
    }

    func dismissGlobalSheets() {
        if presentedApprovalId != nil { presentedApprovalId = nil }
        if showActivity { showActivity = false }
        if showConnection { showConnection = false }
    }
}
