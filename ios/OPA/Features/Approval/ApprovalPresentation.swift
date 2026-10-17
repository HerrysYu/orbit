import LocalAuthentication
import SwiftUI

// Wording and parsing rules of the global confirm sheet. Plain logic, pinned down by `TasksFeatureTests`.

// MARK: - Copy

enum ApprovalCopy {
    /// The verb on the main button: command「允许执行」, file change「允许修改」, permissions「授予权限」,
    /// elicitation「允许」, Orbit's own request「批准」.
    static func approveVerb(_ kind: Approval.Kind) -> String {
        switch kind {
        case .command: "允许执行"
        case .fileChange: "允许修改"
        case .permissions: "授予权限"
        case .elicitation: "允许"
        case .action: "批准"
        }
    }

    /// "29 分钟后过期", "不到 1 分钟后过期", "已过期". `remainingMs` is judged on the Mac's clock.
    static func expiry(remainingMs: Int64) -> String {
        guard remainingMs > 0 else { return "已过期" }
        let minutes = Int(remainingMs / 60_000)
        if minutes < 1 { return "不到 1 分钟后过期" }
        if minutes < 60 { return "\(minutes) 分钟后过期" }
        let hours = minutes / 60
        if hours < 24 {
            let rest = minutes % 60
            return rest == 0 ? "\(hours) 小时后过期" : "\(hours) 小时 \(rest) 分钟后过期"
        }
        return "\(hours / 24) 天后过期"
    }

    /// The warning that only a high-risk request carries.
    static func riskNote(_ risk: Approval.Risk) -> String? {
        risk == .high ? "高风险：批准后可能无法撤销，请先核对上面的内容。" : nil
    }

    /// 低风险 / 中风险 / 高风险: the word that opens the line under the title ("中风险 · 28 分钟后过期").
    static func riskLabel(_ risk: Approval.Risk) -> String {
        switch risk {
        case .low: "低风险"
        case .medium: "中风险"
        case .high: "高风险"
        }
    }

    /// What the host wrote after "批准后:" or "批准后：", always with the full-width colon: "批准后：我会下单". An empty
    /// promise reads "批准后会继续执行". Any other line is returned as it is.
    static func afterText(_ line: String) -> String {
        for prefix in ["批准后：", "批准后:"] where line.hasPrefix(prefix) {
            let rest = line.dropFirst(prefix.count).trimmingCharacters(in: .whitespaces)
            return rest.isEmpty ? "批准后会继续执行" : "批准后：\(rest)"
        }
        return line
    }
}

// MARK: - Content

/// An approval's `detail`, split for display: the `标签：内容` rows, the `批准后：` sentence, and whatever else it says.
/// Nothing is dropped: a detail that does not follow the convention comes out whole, as `body` for Orbit's own
/// requests and as `technical` for requests that come out of an execution.
///
/// Who wrote the detail decides what is shown in the open:
/// - kind `action`: Orbit wrote it for the owner, in plain language. Rows, sentence and text are shown as written.
/// - command / fileChange / permissions / elicitation: the execution wrote it. Only its reason (the `原因：` row) is
///   shown in the open; the raw command, the directory, JSON parameters and anything the parser cannot make sense of
///   go to `technical`, which the screens put behind a collapsed "技术详情".
struct ApprovalContent: Equatable, Sendable {
    struct Row: Equatable, Sendable {
        var label: String
        var value: String
    }

    var rows: [Row]
    /// Lines that are neither rows nor the `批准后：` sentence, as written, in order (Orbit's own requests only).
    var body: String?
    /// What happens after approving ("批准后：我会…"), or nil.
    var after: String?
    /// The raw material of an execution's request, as written, in order: a shell command, the working directory, JSON
    /// parameters, free text. Never shown in the open; nil when there is none.
    var technical: String?

    /// Orbit's own wording (`action` requests): every line is for the owner.
    init(detail: String) {
        let parsed = ApprovalDetailParser.parse(detail)
        rows = parsed.rows.map { Row(label: $0.0, value: $0.1) }
        var others: [String] = []
        var afters: [String] = []
        for line in (parsed.note ?? "").split(separator: "\n", omittingEmptySubsequences: true).map(String.init) {
            if line.hasPrefix("批准后：") || line.hasPrefix("批准后:") {
                afters.append(ApprovalCopy.afterText(line))
            } else {
                others.append(line)
            }
        }
        body = others.isEmpty ? nil : others.joined(separator: "\n")
        after = afters.isEmpty ? nil : afters.joined(separator: "\n")
        technical = nil
    }

    /// An execution's request (command / fileChange / permissions / elicitation): the `原因：` row stays in the open,
    /// everything else is technical.
    init(execution detail: String) {
        var reasons: [Row] = []
        var afters: [String] = []
        var raw: [String] = []
        for line in detail.split(whereSeparator: \.isNewline).map({ $0.trimmingCharacters(in: .whitespacesAndNewlines) }) where !line.isEmpty {
            if line.hasPrefix("批准后：") || line.hasPrefix("批准后:") {
                afters.append(ApprovalCopy.afterText(line))
            } else if let row = ApprovalDetailParser.parse(line).rows.first, row.0 == Self.reasonLabel {
                reasons.append(Row(label: row.0, value: row.1))
            } else {
                raw.append(line)
            }
        }
        rows = reasons
        body = nil
        after = afters.isEmpty ? nil : afters.joined(separator: "\n")
        technical = raw.isEmpty ? nil : raw.joined(separator: "\n")
    }

    init(approval: Approval) {
        if approval.kind == .action {
            self.init(detail: approval.detail)
        } else {
            self.init(execution: approval.detail)
        }
    }

    /// The label the host puts on the reason of a command request.
    static let reasonLabel = "原因"

    /// One short line for compact places: the row values ("鮨 · 静安店 · 周六 19:00"), else the first line of the text.
    /// `maxRows` keeps only the first few rows. (Technical text is never part of it.)
    func summary(maxRows: Int = .max) -> String? {
        if !rows.isEmpty { return rows.prefix(maxRows).map(\.value).joined(separator: " · ") }
        return body?.split(separator: "\n").first.map(String.init)
    }

    var summary: String? { summary() }
}

extension Approval.Risk {
    /// The color of the risk word: low = Success, medium = Warning, high = Danger. Text only, never a fill.
    var tint: Color {
        switch self {
        case .low: .success
        case .medium: .warning
        case .high: .danger
        }
    }
}

// MARK: - Source

/// Where an approval comes from: the task its execution session belongs to, else just the session. An approval that
/// Orbit raised itself has no session, so it has no source (nothing is guessed).
enum ApprovalSource: Equatable, Sendable {
    case task(title: String)
    case session(title: String)

    var text: String {
        switch self {
        case .task(let title): "来自任务「\(title)」"
        case .session(let title): "来自任务「\(title)」"
        }
    }

    /// The task title alone, when the source is a task (for the one-line summary in the tasks list).
    var taskTitle: String? {
        if case .task(let title) = self { return title }
        return nil
    }

    static func resolve(approval: Approval, sessions: [String: OPASession], tasks: [String: OPATask]) -> ApprovalSource? {
        guard let sessionId = approval.sessionId, let session = sessions[sessionId] else { return nil }
        if let taskId = session.taskId, let task = tasks[taskId], let title = TaskText.clean(task.title) {
            return .task(title: title)
        }
        return .session(title: SessionKind.parse(title: session.title).title)
    }
}

// MARK: - Biometrics

/// What this device authenticates with, for the button icon and its spoken label. Falls back to Face ID (the design's
/// wording) when the device cannot say (a simulator with nothing enrolled).
enum BiometricLabel: Sendable {
    case faceID, touchID

    var name: String { self == .touchID ? "Touch ID" : "Face ID" }
    var symbol: String { self == .touchID ? "touchid" : "faceid" }

    static let current: BiometricLabel = {
        let context = LAContext()
        var error: NSError?
        _ = context.canEvaluatePolicy(.deviceOwnerAuthenticationWithBiometrics, error: &error)
        return context.biometryType == .touchID ? .touchID : .faceID
    }()
}
