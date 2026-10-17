import ActivityKit
import Foundation

/// What `AppModel` needs from the Live Activity layer. A protocol so tests can watch which activities get ended.
@MainActor
protocol TaskActivityControlling: AnyObject {
    /// (kind, tokenHex, activityId, taskId)
    var onPushToken: (String, String, String?, String?) -> Void { get set }
    func observePushToStart()
    /// Starts (running tasks only) or updates the task's activity; a finished task ends it.
    func update(task: OPATask, butlerName: String)
    /// Ends the activities of these tasks. `immediately` removes them from the lock screen at once (the tasks are
    /// gone); otherwise the final state stays visible for a while.
    func end(taskIds: [String], immediately: Bool)
    /// Ends activities whose task is already finished (e.g. it finished while the app was not running).
    func reconcile(tasks: [OPATask])
    func endAll()
}

/// Starts/updates the task Live Activity locally and forwards ActivityKit push tokens to the host.
@MainActor
final class LiveActivityController: TaskActivityControlling {
    /// (kind, tokenHex, activityId, taskId)
    var onPushToken: (String, String, String?, String?) -> Void = { _, _, _, _ in }

    private var tokenTasks: [String: Task<Void, Never>] = [:]
    private var pushToStartTask: Task<Void, Never>?
    private var lastStates: [String: TaskActivityAttributes.ContentState] = [:]

    /// How long a finished task's final state stays on the lock screen.
    nonisolated static let finishedLinger: TimeInterval = 15 * 60

    var isEnabled: Bool { ActivityAuthorizationInfo().areActivitiesEnabled }

    func observePushToStart() {
        guard pushToStartTask == nil else { return }
        pushToStartTask = Task { [weak self] in
            for await token in Activity<TaskActivityAttributes>.pushToStartTokenUpdates {
                self?.onPushToken("pushToStart", token.hexString, nil, nil)
            }
        }
        // Activities started remotely via push-to-start: pick them up so we can forward their tokens.
        Task { [weak self] in
            for await activity in Activity<TaskActivityAttributes>.activityUpdates {
                self?.observeToken(activity)
            }
        }
    }

    func update(task: OPATask, butlerName: String) {
        let state = Self.contentState(for: task)
        guard lastStates[task.id] != state else { return }
        lastStates[task.id] = state

        let taskId = task.id
        let content = ActivityContent(state: state, staleDate: Date().addingTimeInterval(30 * 60))

        if Activity<TaskActivityAttributes>.activities.contains(where: { $0.attributes.taskId == taskId }) {
            Task.detached {
                guard let existing = Activity<TaskActivityAttributes>.activities.first(where: { $0.attributes.taskId == taskId }) else { return }
                if state.isFinal {
                    await existing.end(content, dismissalPolicy: .after(Date().addingTimeInterval(Self.finishedLinger)))
                } else {
                    await existing.update(content)
                }
            }
            return
        }
        guard task.status == .running, isEnabled else { return }
        do {
            let activity = try Activity.request(attributes: TaskActivityAttributes(taskId: task.id), content: content, pushType: .token)
            observeToken(activity)
        } catch {
            // Simulator without Live Activity support or user disabled them: ignore.
        }
    }

    func end(taskIds: [String], immediately: Bool) {
        guard !taskIds.isEmpty else { return }
        let ids = Set(taskIds)
        for id in ids { lastStates[id] = nil }
        for activity in Activity<TaskActivityAttributes>.activities where ids.contains(activity.attributes.taskId) {
            tokenTasks[activity.id]?.cancel()
            tokenTasks[activity.id] = nil
        }
        Task.detached {
            for activity in Activity<TaskActivityAttributes>.activities where ids.contains(activity.attributes.taskId) {
                await activity.end(nil, dismissalPolicy: immediately ? .immediate : .after(Date().addingTimeInterval(Self.finishedLinger)))
            }
        }
    }

    func reconcile(tasks: [OPATask]) {
        let finished = Dictionary(tasks.filter { $0.status.isFinished }.map { ($0.id, Self.contentState(for: $0)) },
                                  uniquingKeysWith: { _, new in new })
        guard !finished.isEmpty else { return }
        Task.detached {
            for activity in Activity<TaskActivityAttributes>.activities {
                guard let state = finished[activity.attributes.taskId] else { continue }
                let content = ActivityContent(state: state, staleDate: nil)
                await activity.end(content, dismissalPolicy: .after(Date().addingTimeInterval(Self.finishedLinger)))
            }
        }
        for id in finished.keys { lastStates[id] = finished[id] }
    }

    func endAll() {
        Task.detached {
            for a in Activity<TaskActivityAttributes>.activities {
                await a.end(nil, dismissalPolicy: .immediate)
            }
        }
        for t in tokenTasks.values { t.cancel() }
        tokenTasks.removeAll()
        lastStates.removeAll()
    }

    static func contentState(for task: OPATask) -> TaskActivityAttributes.ContentState {
        TaskActivityAttributes.ContentState(
            title: task.title,
            status: task.status.rawValue,
            done: task.doneCount,
            total: task.steps.count,
            detail: task.currentStep?.title ?? task.summary
        )
    }

    private func observeToken(_ activity: Activity<TaskActivityAttributes>) {
        guard tokenTasks[activity.id] == nil else { return }
        let taskId = activity.attributes.taskId
        let activityId = activity.id
        tokenTasks[activity.id] = Task { [weak self] in
            for await token in activity.pushTokenUpdates {
                self?.onPushToken("liveactivity", token.hexString, activityId, taskId)
            }
        }
    }
}
