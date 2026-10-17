import SwiftUI

// Presentation rules for the task screens (list, detail, execution sheet).
//
// Everything here is plain logic: which chip a task shows, which line describes what it is doing right now,
// how times read ("刚刚", "3 分钟前", "用时 2 分 14 秒"), what an execution session is. The views only draw it,
// and `TasksFeatureTests` pins the rules down.

// MARK: - Text helpers

enum TaskText {
    /// Trimmed text, or nil when nothing is left. Hosts send empty strings for "no value".
    static func clean(_ text: String?) -> String? {
        guard let trimmed = text?.trimmingCharacters(in: .whitespacesAndNewlines), !trimmed.isEmpty else { return nil }
        return trimmed
    }
}

// MARK: - Time

/// Chinese time strings for the task screens. The relative phrases are deterministic (they do not depend on the
/// device language); clock times and dates follow the locale.
enum TaskTime {
    /// 刚刚 / N 分钟前 / N 小时前 / N 天前.
    static func ago(_ ms: Int64, now: Date = Date()) -> String {
        Presence.ago(Clock.date(ms: ms), now: now)
    }

    /// The time column of a finished task: "17:05" today, "昨天", otherwise "10月14日".
    static func stamp(_ ms: Int64, now: Date = Date(), calendar: Calendar = .current) -> String {
        let date = Clock.date(ms: ms)
        if calendar.isDate(date, inSameDayAs: now) { return Fmt.time(ms) }
        if let yesterday = calendar.date(byAdding: .day, value: -1, to: now), calendar.isDate(date, inSameDayAs: yesterday) {
            return "昨天"
        }
        return date.formatted(.dateTime.month().day())
    }

    /// When a finished task ended, as the lists read it: "17:05" today, "昨天", the weekday ("周三") within the last
    /// week, otherwise "10月14日". Deterministic Chinese, whatever the device language.
    static func when(_ ms: Int64, now: Date = Date(), calendar: Calendar = .current) -> String {
        let date = Clock.date(ms: ms)
        if calendar.isDate(date, inSameDayAs: now) { return Fmt.time(ms) }
        let days = calendar.dateComponents([.day], from: calendar.startOfDay(for: date), to: calendar.startOfDay(for: now)).day ?? 0
        if days == 1 { return "昨天" }
        if (2...6).contains(days) { return weekdayNames[(calendar.component(.weekday, from: date) - 1) % 7] }
        return date.formatted(.dateTime.month().day())
    }

    private static let weekdayNames = ["周日", "周一", "周二", "周三", "周四", "周五", "周六"]

    /// The second line of a finished task: "昨天 · 已完成", "17:05 · 已完成", "周三 · 未完成", "10月14日 · 已取消".
    static func finishedLine(status: OPATask.Status, updatedAt: Int64, now: Date = Date(), calendar: Calendar = .current) -> String {
        "\(when(updatedAt, now: now, calendar: calendar)) · \(status.label)"
    }

    /// "17:20 开始 · 刚刚更新" (a finished task says "结束" instead of "更新").
    static func headerLine(createdAt: Int64, updatedAt: Int64, finished: Bool, now: Date = Date(), calendar: Calendar = .current) -> String {
        var parts: [String] = []
        if createdAt > 0 {
            let created = Clock.date(ms: createdAt)
            let start = calendar.isDate(created, inSameDayAs: now)
                ? Fmt.time(createdAt)
                : created.formatted(.dateTime.month().day().hour().minute())
            parts.append("\(start) 开始")
        }
        if updatedAt > 0 {
            parts.append(ago(updatedAt, now: now) + (finished ? "结束" : "更新"))
        }
        return parts.joined(separator: " · ")
    }

    /// "2 分 14 秒", "1 小时 5 分", "3 天"; nil for nothing worth saying (under a second, or negative).
    static func duration(ms: Int64) -> String? {
        let total = Int(ms / 1000)
        guard total >= 1 else { return nil }
        switch total {
        case ..<60:
            return "\(total) 秒"
        case ..<3600:
            let minutes = total / 60, seconds = total % 60
            return seconds == 0 ? "\(minutes) 分钟" : "\(minutes) 分 \(seconds) 秒"
        case ..<86_400:
            let hours = total / 3600, minutes = (total % 3600) / 60
            return minutes == 0 ? "\(hours) 小时" : "\(hours) 小时 \(minutes) 分"
        default:
            let days = total / 86_400, hours = (total % 86_400) / 3600
            return hours == 0 ? "\(days) 天" : "\(days) 天 \(hours) 小时"
        }
    }
}

// MARK: - Live clock text

/// Text that re-reads the clock every minute ("3 分钟前" must not go stale while the screen stays open).
struct TaskMinuteText: View {
    var text: @MainActor (Date) -> String

    var body: some View {
        TimelineView(.everyMinute) { context in
            Text(verbatim: text(context.date))
        }
    }
}

// MARK: - Chips

/// What a `StatusChip` shows.
struct TaskChip: Equatable, Sendable {
    var kind: StatusKind
    var text: String
    var dot = false
}

// MARK: - A task, as the screens describe it

/// Everything the task screens derive from one task plus the live state around it (execution sessions, pending
/// approvals, a cancel in flight). Built per render; cheap.
@MainActor
struct TaskInfo {
    let task: OPATask
    let model: AppModel

    /// Execution sessions of this task, oldest first.
    var sessions: [OPASession] { model.taskSessions(task.id) }

    /// Pending approvals raised by one of this task's execution sessions. (An approval that Orbit itself raised has no
    /// session, so nothing links it to a task: those are listed on their own, never guessed onto a task.)
    var pendingApprovals: [Approval] {
        let ids = Set(sessions.map(\.id))
        return model.pendingApprovals.filter { approval in approval.sessionId.map(ids.contains) ?? false }
    }

    /// The task is held up by a confirmation only you can give: one of its sessions waits for an approval.
    var awaitingConfirmation: Bool {
        switch task.status {
        case .planning, .running, .waiting_user:
            return !pendingApprovals.isEmpty || sessions.contains { $0.status == .waiting_approval }
        case .blocked, .done, .failed, .cancelled:
            return false
        }
    }

    var chip: TaskChip {
        if model.isCancelling(task.id) { return TaskChip(kind: .cancelled, text: "正在取消…") }
        if awaitingConfirmation { return TaskChip(kind: .waiting, text: "等你确认") }
        return TaskChip(kind: task.status.chipKind, text: task.status.label, dot: task.status == .running)
    }

    var displayTitle: String { TaskText.clean(task.title) ?? "未命名任务" }

    // MARK: Lines

    /// What a running task is on right now, in the owner's terms: the step being worked on; when a confirmation holds
    /// the task up, the host's own summary; else the summary or the goal. Nothing the execution reports along the way
    /// (progress lines, the last tool call) is ever used: the owner sees steps and results, not how they are made.
    var currentAction: String? {
        if awaitingConfirmation { return TaskText.clean(task.summary) ?? "等你确认后继续" }
        if let step = task.currentStep { return TaskText.clean(step.title) }
        return TaskText.clean(task.summary) ?? TaskText.clean(task.goal)
    }

    /// Why a task is blocked: the host's summary, else the step it is stuck on.
    var blockedReason: String? {
        TaskText.clean(task.summary) ?? task.currentStep.flatMap { TaskText.clean($0.title) } ?? TaskText.clean(task.goal)
    }

    /// What a task that waits for you is asking: the host's summary, else the goal.
    var question: String? {
        TaskText.clean(task.summary) ?? TaskText.clean(task.goal) ?? task.currentStep.flatMap { TaskText.clean($0.title) }
    }

    /// The "现在等你…" note on the detail page already quotes the host's summary, so the page does not show it a second
    /// time as a card. (A note about a linked approval quotes the approval instead.)
    var noteQuotesSummary: Bool {
        pendingApprovals.isEmpty && (awaitingConfirmation || task.status == .waiting_user || task.status == .blocked)
    }

    // MARK: Progress

    struct Progress: Equatable, Sendable {
        var total: Int
        var done: Int
        /// The step being worked on (half filled in the bar), when one is running.
        var current: Int?
    }

    var progress: Progress {
        Progress(total: task.steps.count, done: task.doneCount, current: task.steps.firstIndex { $0.status == .running })
    }

    /// "2/4 步 · 3 分钟前" (steps done out of all steps), or "3 分钟前更新" for a task without steps. Step counts only,
    /// never a percentage.
    func progressLine(now: Date = Date()) -> String {
        let p = progress
        let ago = TaskTime.ago(task.updatedAt, now: now)
        return p.total > 0 ? "\(p.done)/\(p.total) 步 · \(ago)" : "\(ago)更新"
    }

    /// How much of the line under a running task is filled: steps done out of all steps. Nil for a task without steps
    /// (no line is drawn then). Only ever drawn, never written out.
    var progressFraction: Double? {
        let p = progress
        guard p.total > 0 else { return nil }
        return min(max(Double(p.done) / Double(p.total), 0), 1)
    }

    /// The word that goes before the step count in a running task's row when it is not under way yet or is being stopped:
    /// "规划中", "正在取消…". Nil otherwise: a task that waits for a confirmation reads like one that runs, because the
    /// confirmation itself is listed under 等你处理.
    var rowStatusWord: String? {
        let chip = self.chip
        switch chip.kind {
        case .running, .waiting: return nil
        default: return chip.text
        }
    }

    // MARK: Steps

    /// The line under a step. Only the step being worked on can have one, and only when it is held up: the step title
    /// already says what it is doing, so no progress text from the execution is added.
    func stepSubtitle(_ step: TaskStep) -> String? {
        guard step.status == .running else { return nil }
        if awaitingConfirmation, step.id == task.currentStep?.id { return "等你确认后继续" }
        return nil
    }

    /// The step the timeline highlights: only while the task is still going.
    var highlightedStepId: String? {
        task.status.isActive ? task.currentStep?.id : nil
    }
}

// MARK: - Execution sessions

/// Where an execution session works. The host marks phone sessions with a leading 📱 (a butler-started one reads
/// "🤵 📱") and Mac desktop (GUI) sessions with 🖥.
enum SessionKind: Equatable, Sendable {
    case phone, desktop, mac

    var label: String {
        switch self {
        case .phone: "安卓手机"
        case .desktop: "Mac 图形界面"
        case .mac: "Mac"
        }
    }

    var symbol: String {
        switch self {
        case .phone: "iphone"
        case .desktop: "macwindow"
        case .mac: "laptopcomputer"
        }
    }

    /// The kind a title announces, and the title without its markers (the icon says it already).
    static func parse(title raw: String) -> (kind: SessionKind, title: String) {
        var kind = SessionKind.mac
        var rest = Substring(raw)
        while let first = rest.first {
            let scalar = first.unicodeScalars.first?.value
            if scalar == 0x1F4F1 {                                  // 📱
                kind = .phone
            } else if scalar == 0x1F5A5 {                           // 🖥 (with or without the emoji variation selector)
                if kind != .phone { kind = .desktop }
            } else if scalar == 0x1F935 || first.isWhitespace || first == "\u{FE0F}" {   // 🤵 and spacing
                // skipped
            } else {
                break
            }
            rest = rest.dropFirst()
        }
        let title = rest.trimmingCharacters(in: .whitespacesAndNewlines)
        return (kind, title.isEmpty ? raw.trimmingCharacters(in: .whitespacesAndNewlines) : title)
    }
}

/// How an execution session reads on the screens.
enum SessionPresentation {
    /// The status chip. An idle session has finished its turn: "已完成" when its task is done, "已停止" when the task
    /// was cancelled, otherwise "空闲" (it simply waits for the next instruction).
    static func chip(for session: OPASession, taskStatus: OPATask.Status?) -> TaskChip {
        switch session.status {
        case .running: return TaskChip(kind: .running, text: "进行中", dot: true)
        case .waiting_approval: return TaskChip(kind: .waiting, text: "等你确认")
        case .error: return TaskChip(kind: .failed, text: "出错")
        case .archived: return TaskChip(kind: .cancelled, text: "已归档")
        case .idle:
            switch taskStatus {
            case .done: return TaskChip(kind: .done, text: "已完成")
            case .cancelled: return TaskChip(kind: .cancelled, text: "已停止")
            default: return TaskChip(kind: .planning, text: "空闲")
            }
        }
    }

    /// "逐项确认" (manual) / "完全访问" (auto).
    static func permissionLabel(_ permission: OPASession.Permission) -> String {
        permission == .auto ? "完全访问" : "逐项确认"
    }

    /// The model's display name from `models.list`, else the raw id.
    static func modelLabel(_ id: String?, models: ModelsList?) -> String? {
        guard let id = TaskText.clean(id) else { return nil }
        let known = models?.codex.first(where: { $0.id == id }) ?? models?.butler.first(where: { $0.id == id })
        return known?.label ?? id
    }

    /// "安卓手机 · 已完成 · 用时 2 分 14 秒". A running session says how long it has been running instead.
    static func subtitle(for session: OPASession, kind: SessionKind, chipText: String, now: Date = Date()) -> String {
        var parts = [kind.label, chipText]
        if session.status == .running {
            if let running = TaskTime.duration(ms: Clock.ms(now) - session.createdAt) { parts.append("已运行 \(running)") }
        } else if let spent = TaskTime.duration(ms: session.updatedAt - session.createdAt) {
            parts.append("用时 \(spent)")
        }
        return parts.joined(separator: " · ")
    }

    /// SF Symbol for one line of the action log. The host sends Codex item types (`commandExecution`, `agentMessage`,
    /// `webSearch` …); the demo host uses shorter names (`command`, `message`); both spellings are understood.
    static func itemSymbol(kind: String) -> String {
        switch kind {
        case "plan": "list.bullet"
        case "command", "commandExecution": "terminal"
        case "fileChange": "doc.badge.gearshape"
        case "message", "agentMessage": "text.bubble"
        case "userMessage": "bubble.left"
        case "reasoning": "brain"
        case "mcpToolCall", "dynamicToolCall": "wrench.and.screwdriver"
        case "webSearch": "globe"
        case "imageView": "eye"
        case "imageGeneration": "photo"
        case "subAgentActivity", "collabAgentToolCall": "person.2"
        default: "smallcircle.filled.circle"
        }
    }

    /// Command lines read as code.
    static func isCommand(kind: String) -> Bool { kind == "command" || kind == "commandExecution" }
}

// MARK: - Compatibility

// MIGRATION: `OPASession.Status.color` came from the pre-redesign TasksView. Nothing in the task screens uses it any more
// (they use `SessionPresentation.chip`); it stays only so a view that still calls it keeps compiling. WP7 removes it as soon
// as nothing references it.
extension OPASession.Status {
    var color: Color {
        switch self {
        case .running: .accentText
        case .error: .danger
        case .waiting_approval: .warning
        default: .inkSecondary
        }
    }
}
