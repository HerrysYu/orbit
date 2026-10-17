import Foundation

// Small value types the views read from `AppModel`.

// MARK: - Navigation

/// The three tabs. `AppModel.selectedTab` drives the root `TabView`.
enum AppTab: String, Hashable, Sendable, CaseIterable {
    case chat, tasks, settings
}

// MARK: - Presence

/// The one-line "what is Orbit doing" shown under the avatar (chat header), plus the pose for the mascot.
///
/// The line is a fixed phrase per state ("正在想办法…", "正在处理…", "正在回复…", "等你确认 N 件事", "Mac 离线"). What the
/// model is calling, what an execution session reports (`butler.status` detail / tool, `session.progress`) is never
/// part of it: those are implementation details, not something to show the owner.
struct Presence: Equatable, Sendable {
    enum Tone: Sendable { case neutral, live, warn }

    var text: String
    var tone: Tone
    var mood: MascotPose

    /// Everything `presence` is derived from, so the priority rules can be tested without a model.
    struct Inputs: Sendable {
        var connection: ConnectionState
        var isDemo = false
        var lastSeenOnlineAt: Date?
        var pendingApprovalCount = 0
        var isStreaming = false
        var butlerState: ButlerState = .idle
        /// An execution session of a task that is still going is running. Only the fact counts; what it says does not.
        var hasRunningWork = false
        var now = Date()
    }

    /// Priority: Mac offline → approvals waiting → streaming a reply → executing → thinking → idle.
    ///
    /// Connection problems come in two flavours that mirror `ConnectionIndicator`: while we are (re)connecting
    /// (idle / connecting / handshaking / waiting to retry) the line says "正在恢复连接…"; when the Mac is known to be
    /// unreachable (host offline, connection refused) it says "Mac 离线", with when it was last seen.
    static func resolve(_ i: Inputs) -> Presence {
        if !i.isDemo, !i.connection.isConnected {
            switch i.connection {
            case .idle, .connecting, .handshaking, .awaitingPairConfirm, .waitingRetry:
                return Presence(text: "正在恢复连接…", tone: .neutral, mood: .focused)
            case .hostOffline, .failed, .connected:
                var text = "Mac 离线"
                if let seen = i.lastSeenOnlineAt { text += " · " + Self.ago(seen, now: i.now) + "在线" }
                return Presence(text: text, tone: .warn, mood: .focused)
            }
        }
        if i.pendingApprovalCount > 0 {
            return Presence(text: "等你确认 \(i.pendingApprovalCount) 件事", tone: .warn, mood: .attentive)
        }
        if i.isStreaming {
            return Presence(text: "正在回复…", tone: .live, mood: .focused)
        }
        if i.butlerState == .acting || i.hasRunningWork {
            return Presence(text: "正在处理…", tone: .live, mood: .focused)
        }
        if i.butlerState == .thinking {
            return Presence(text: "正在想办法…", tone: .live, mood: .thinking)
        }
        if i.butlerState == .waiting {
            return Presence(text: "等你回复", tone: .warn, mood: .attentive)
        }
        return Presence(text: "待命中", tone: .neutral, mood: .wave)
    }

    /// 刚刚 / N 分钟前 / N 小时前 / N 天前.
    static func ago(_ date: Date, now: Date) -> String {
        let s = max(0, Int(now.timeIntervalSince(date)))
        switch s {
        case ..<60: return "刚刚"
        case ..<3600: return "\(s / 60) 分钟前"
        case ..<86_400: return "\(s / 3600) 小时前"
        default: return "\(s / 86_400) 天前"
        }
    }
}

// MARK: - Connection

/// What the connection sheet shows.
struct ConnectionInfo: Equatable, Sendable {
    var hostName: String?
    /// `.lan` / `.relay` while connected (or handshaking); nil otherwise.
    var path: TransportPath?
    /// When the current/last connection to the Mac was established.
    var lastConnectedAt: Date?
    /// The last time anything arrived from the Mac while connected (so "Mac 离线 · 2 分钟前在线" is honest).
    var lastSeenOnlineAt: Date?
    var state: ConnectionState
}

extension ConnectionState {
    /// The transport path this state is using, if any.
    var path: TransportPath? {
        switch self {
        case .connected(let p), .handshaking(let p): p
        case .awaitingPairConfirm(_, let p): p
        case .idle, .connecting, .hostOffline, .waitingRetry, .failed: nil
        }
    }
}

// MARK: - Tasks tab

/// A row in "需要你处理": a pending approval or a task waiting for your input.
enum AttentionItem: Identifiable, Hashable, Sendable {
    case approval(Approval)
    case task(OPATask)

    var id: String {
        switch self {
        case .approval(let a): "approval:" + a.id
        case .task(let t): "task:" + t.id
        }
    }

    /// Unix ms used to sort newest first: when the approval was requested / the task last changed.
    var date: Int64 {
        switch self {
        case .approval(let a): a.createdAt
        case .task(let t): t.updatedAt
        }
    }
}

// MARK: - Settings

enum SettingsSyncState: Equatable, Sendable {
    case idle
    case saving
    case saved
    case failed(String)
}
