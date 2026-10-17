import ActivityKit
import Foundation

/// Shared between the app and the widget extension. Field names must match the host's
/// APNs liveactivity payload: `"content-state": {title,status,done,total,detail}`,
/// push-to-start `"attributes-type": "TaskActivityAttributes", "attributes": {"taskId": …}`.
/// (Only optional fields may be added to `ContentState`: the Mac pushes these keys and knows no others.)
struct TaskActivityAttributes: ActivityAttributes {
    var taskId: String

    struct ContentState: Codable, Hashable {
        var title: String
        /// Task.status raw value (planning/running/waiting_user/blocked/done/failed/cancelled)
        var status: String
        var done: Int
        var total: Int
        var detail: String?
    }
}

extension TaskActivityAttributes.ContentState {
    /// What the Live Activity shows for a task state. A `status` this build does not know presents as running.
    enum Phase: Sendable, Hashable {
        case planning, running, waiting, blocked, done, failed, cancelled

        init(status: String) {
            switch status {
            case "planning": self = .planning
            case "waiting_user": self = .waiting
            case "blocked": self = .blocked
            case "done": self = .done
            case "failed": self = .failed
            case "cancelled": self = .cancelled
            default: self = .running
            }
        }

        /// Status chip text. `.waiting` is shown with the raised-hand icon (the app's tab says 等你补充 / 待确认; here the
        /// task is waiting for your confirmation).
        var label: String {
            switch self {
            case .planning: "规划中"
            case .running: "进行中"
            case .waiting: "需要你确认"
            case .blocked: "遇到阻碍"
            case .done: "已完成"
            case .failed: "未完成"
            case .cancelled: "已取消"
            }
        }

        /// The short form for the compact Dynamic Island, where there is room for one word.
        var shortLabel: String { self == .waiting ? "待确认" : label }

        /// The task cannot go on without you (shown with the raised-hand icon, never by color alone).
        var needsYou: Bool { self == .waiting }
    }

    var phase: Phase { Phase(status: status) }

    var progress: Double { total > 0 ? min(1, max(0, Double(done) / Double(total))) : 0 }

    var statusLabel: String { phase.label }

    var statusSymbol: String {
        switch phase {
        case .done: "checkmark.circle.fill"
        case .failed: "xmark.octagon.fill"
        case .cancelled: "minus.circle.fill"
        case .waiting: "hand.raised.fill"
        case .blocked: "exclamationmark.triangle.fill"
        case .planning, .running: "sparkles"
        }
    }

    var isFinal: Bool { ["done", "failed", "cancelled"].contains(status) }
}

// MARK: - Live Activity copy (shared so it can be unit-tested from the app target)

extension TaskActivityAttributes.ContentState {
    /// The task name, never empty.
    var displayTitle: String {
        let trimmed = title.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? "Orbit 的任务" : trimmed
    }

    /// Where a line of text is shown: the lock-screen card has a status chip, the island has only the hand.
    enum Surface: Sendable { case lockScreen, island }

    /// The second line: the current step or result the Mac sends (`detail`), or a plain sentence for the state.
    func subtitle(on surface: Surface) -> String {
        let text = (detail ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        switch phase {
        case .waiting:
            switch surface {
            case .lockScreen: return text.isEmpty ? "等你确认后继续" : text
            case .island:
                if text.isEmpty { return "需要你确认" }
                // The Mac may already word it as a request ("需要你确认…", "等你批准后提交"): do not say it twice.
                return text.hasPrefix("需要你") || text.hasPrefix("等你") ? text : "需要你确认：" + text
            }
        case .running: return text.isEmpty ? "正在处理…" : text
        case .planning: return text.isEmpty ? "正在规划…" : text
        case .blocked: return text.isEmpty ? "遇到阻碍，需要你看看" : text
        case .done: return text.isEmpty ? "任务已完成" : text
        case .failed: return text.isEmpty ? "这个任务没有完成" : text
        case .cancelled: return text.isEmpty ? "任务已取消" : text
        }
    }

    private var clampedDone: Int { min(max(done, 0), max(total, 0)) }

    /// 已完成 2 / 4 步 (lock screen).
    var stepsText: String { "已完成 \(clampedDone) / \(max(total, 0)) 步" }

    /// 3 / 4 步 (island).
    var shortStepsText: String { "\(clampedDone) / \(max(total, 0)) 步" }

    /// 2/4 (compact island).
    var compactStepsText: String { "\(clampedDone)/\(max(total, 0))" }

    /// The step being worked on (0-based), drawn half filled; nil when nothing is in progress.
    var currentIndex: Int? {
        switch phase {
        case .running, .waiting, .blocked: clampedDone < total ? clampedDone : nil
        case .planning, .done, .failed, .cancelled: nil
        }
    }

    /// One sentence for VoiceOver.
    var spokenSummary: String {
        var parts = [displayTitle, phase.label, subtitle(on: .lockScreen)]
        if total > 0 { parts.append(stepsText) }
        return parts.joined(separator: "，")
    }
}

/// `opa://task?id=…`: where tapping the activity or its button points the app (the app opens in any case).
enum LiveLink {
    static func url(taskId: String) -> URL? {
        var components = URLComponents()
        components.scheme = "opa"
        components.host = "task"
        components.queryItems = [URLQueryItem(name: "id", value: taskId)]
        return components.url
    }
}
