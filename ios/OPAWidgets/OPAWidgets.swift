import ActivityKit
import SwiftUI
import WidgetKit

@main
struct OPAWidgetsBundle: WidgetBundle {
    var body: some Widget {
        TaskLiveActivity()
    }
}

/// The task Live Activity. The lock screen shows `TaskLockScreenView`; the island pieces live in `LiveActivityViews.swift`.
/// The Mac pushes `{title, status, done, total, detail}` (see `TaskActivityAttributes`).
struct TaskLiveActivity: Widget {
    var body: some WidgetConfiguration {
        ActivityConfiguration(for: TaskActivityAttributes.self) { context in
            TaskLockScreenView(state: context.state)
                .activityBackgroundTint(LivePalette.cardTint)
                .activitySystemActionForegroundColor(LivePalette.apricot)
                .widgetURL(LiveLink.url(taskId: context.attributes.taskId))
        } dynamicIsland: { context in
            let state = context.state
            return DynamicIsland {
                DynamicIslandExpandedRegion(.leading) {
                    LiveAvatar(size: 44)
                }
                DynamicIslandExpandedRegion(.trailing) {
                    IslandStatusGlyph(phase: state.phase)
                }
                DynamicIslandExpandedRegion(.center) {
                    IslandTitleBlock(state: state)
                }
                DynamicIslandExpandedRegion(.bottom) {
                    VStack(spacing: 12) {
                        IslandProgressRow(state: state)
                        if state.phase.needsYou {
                            IslandOpenButton(taskId: context.attributes.taskId)
                        }
                    }
                    .padding(.top, 4)
                }
            } compactLeading: {
                OrbitMark(size: 24)
            } compactTrailing: {
                IslandCompactTrailing(state: state)
            } minimal: {
                IslandMinimal(state: state)
            }
            .keylineTint(LivePalette.tint(for: state.phase))
            .widgetURL(LiveLink.url(taskId: context.attributes.taskId))
        }
    }
}

// MARK: - Previews (lock screen and island presentations)

private extension TaskActivityAttributes {
    static let sample = TaskActivityAttributes(taskId: "t8")
}

private extension ActivityState {
    static let running = ActivityState(title: "订周六晚的日料", status: "running", done: 2, total: 4, detail: "核对周六 19:00 的空位")
    static let waiting = ActivityState(title: "订周六晚的日料", status: "waiting_user", done: 3, total: 4, detail: "提交预订")
    static let blocked = ActivityState(title: "整理 9 月发票做报销表", status: "blocked", done: 1, total: 4, detail: "邮箱需要重新登录")
    static let done = ActivityState(title: "预订上海出差酒店", status: "done", done: 4, total: 4, detail: "已预订外滩华尔道夫，10/20–10/24")
    static let failed = ActivityState(title: "预订上海出差酒店", status: "failed", done: 2, total: 4, detail: nil)
    static let planning = ActivityState(title: "整理旅行清单", status: "planning", done: 0, total: 0, detail: nil)
}

#Preview("锁屏", as: .content, using: TaskActivityAttributes.sample) {
    TaskLiveActivity()
} contentStates: {
    ActivityState.running
    ActivityState.waiting
    ActivityState.blocked
    ActivityState.done
    ActivityState.failed
    ActivityState.planning
}

#Preview("灵动岛 · 展开", as: .dynamicIsland(.expanded), using: TaskActivityAttributes.sample) {
    TaskLiveActivity()
} contentStates: {
    ActivityState.waiting
    ActivityState.running
    ActivityState.done
}

#Preview("灵动岛 · 紧凑", as: .dynamicIsland(.compact), using: TaskActivityAttributes.sample) {
    TaskLiveActivity()
} contentStates: {
    ActivityState.running
    ActivityState.waiting
    ActivityState.done
}

#Preview("灵动岛 · 最小", as: .dynamicIsland(.minimal), using: TaskActivityAttributes.sample) {
    TaskLiveActivity()
} contentStates: {
    ActivityState.running
    ActivityState.waiting
}
