import Foundation

/// String enum that decodes unknown raw values to a fallback instead of failing.
protocol LenientEnum: RawRepresentable, Codable, Sendable, Hashable, CaseIterable where RawValue == String {
    static var fallback: Self { get }
}

extension LenientEnum {
    init(from decoder: any Decoder) throws {
        let raw = try decoder.singleValueContainer().decode(String.self)
        self = Self(rawValue: raw) ?? Self.fallback
    }
}

extension KeyedDecodingContainer {
    func value<T: Decodable>(_ key: Key, default def: @autoclosure () -> T) -> T {
        ((try? decodeIfPresent(T.self, forKey: key)) ?? nil) ?? def()
    }
}

// MARK: - 4.5 Data structures

struct Attachment: Codable, Sendable, Hashable {
    enum Kind: String, LenientEnum { case image, file, link; static let fallback = Kind.file }
    var kind: Kind
    var name: String?
    var mime: String?
    var dataB64: String?
    var url: String?
}

struct ImportItem: Codable, Sendable, Hashable {
    enum Kind: String, LenientEnum { case photo, link, text, file, reminder, note; static let fallback = Kind.text }
    var kind: Kind
    var title: String?
    var text: String?
    var url: String?
    var mime: String?
    var dataB64: String?
    var createdAt: Int64?
}

struct DeviceContext: Codable, Sendable, Hashable {
    struct Location: Codable, Sendable, Hashable { var lat: Double; var lon: Double; var accuracy: Double; var placeName: String? }
    struct Battery: Codable, Sendable, Hashable { var level: Double; var charging: Bool }
    struct Event: Codable, Sendable, Hashable { var title: String; var start: Int64; var end: Int64; var location: String? }
    struct Reminder: Codable, Sendable, Hashable { var title: String; var due: Int64?; var done: Bool }

    var timezone: String
    var locale: String
    var now: Int64
    var location: Location?
    var battery: Battery?
    var network: String?
    var focus: String?
    var upcomingEvents: [Event]?
    var reminders: [Reminder]?
    var deviceName: String
}

struct CardAction: Codable, Sendable, Hashable, Identifiable {
    enum Style: String, LenientEnum { case primary, secondary, destructive; static let fallback = Style.secondary }
    var id: String
    var label: String
    var style: Style?
    var requiresApproval: Bool?
}

struct Card: Codable, Sendable, Hashable, Identifiable {
    var id: String
    var component: String
    var props: JSONValue
    var actions: [CardAction]?
    var msgId: String?
    var ts: Int64

    init(id: String, component: String, props: JSONValue, actions: [CardAction]? = nil, msgId: String? = nil, ts: Int64) {
        self.id = id; self.component = component; self.props = props; self.actions = actions; self.msgId = msgId; self.ts = ts
    }

    init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(String.self, forKey: .id)
        component = try c.decode(String.self, forKey: .component)
        props = c.value(.props, default: JSONValue.object([:]))
        actions = c.value(.actions, default: nil)
        msgId = c.value(.msgId, default: nil)
        ts = c.value(.ts, default: Clock.nowMs)
    }
}

struct TaskStep: Codable, Sendable, Hashable, Identifiable {
    enum Status: String, LenientEnum {
        case pending, running, done, failed, skipped
        static let fallback = Status.pending
        /// 待开始 / 进行中 / 完成 / 失败 / 跳过
        var label: String {
            switch self {
            case .pending: "待开始"
            case .running: "进行中"
            case .done: "完成"
            case .failed: "失败"
            case .skipped: "跳过"
            }
        }
    }
    var id: String
    var title: String
    var status: Status
    var sessionId: String?
}

struct OPATask: Codable, Sendable, Hashable, Identifiable {
    enum Status: String, LenientEnum {
        case planning, running, waiting_user, blocked, done, failed, cancelled
        static let fallback = Status.planning
        /// Still in flight (the host may yet change it): planning, running, waiting on the user, or blocked.
        var isActive: Bool { [.planning, .running, .waiting_user, .blocked].contains(self) }
        /// Ended for good: done, failed or cancelled. Only these can be cleared (`tasks.clear`).
        var isFinished: Bool { [.done, .failed, .cancelled].contains(self) }
        /// 规划中 / 进行中 / 等你补充 / 遇到阻碍 / 已完成 / 未完成 / 已取消
        var label: String {
            switch self {
            case .planning: "规划中"
            case .running: "进行中"
            case .waiting_user: "等你补充"
            case .blocked: "遇到阻碍"
            case .done: "已完成"
            case .failed: "未完成"
            case .cancelled: "已取消"
            }
        }
    }
    var id: String
    var title: String
    var goal: String
    var status: Status
    var steps: [TaskStep]
    var summary: String?
    var createdAt: Int64
    var updatedAt: Int64

    init(id: String, title: String, goal: String, status: Status, steps: [TaskStep], summary: String? = nil, createdAt: Int64, updatedAt: Int64) {
        self.id = id; self.title = title; self.goal = goal; self.status = status; self.steps = steps
        self.summary = summary; self.createdAt = createdAt; self.updatedAt = updatedAt
    }

    init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(String.self, forKey: .id)
        title = c.value(.title, default: "")
        goal = c.value(.goal, default: "")
        status = c.value(.status, default: .planning)
        steps = c.value(.steps, default: [])
        summary = c.value(.summary, default: nil)
        createdAt = c.value(.createdAt, default: 0)
        updatedAt = c.value(.updatedAt, default: createdAt)
    }

    var doneCount: Int { steps.filter { $0.status == .done || $0.status == .skipped }.count }
    var progress: Double { steps.isEmpty ? (status == .done ? 1 : 0) : Double(doneCount) / Double(steps.count) }
    var currentStep: TaskStep? { steps.first { $0.status == .running } ?? steps.first { $0.status == .pending } }
}

struct OPASession: Codable, Sendable, Hashable, Identifiable {
    enum Status: String, LenientEnum {
        case running, idle, waiting_approval, error, archived
        static let fallback = Status.idle
        var label: String {
            switch self {
            case .running: "运行中"
            case .idle: "空闲"
            case .waiting_approval: "等待审批"
            case .error: "出错"
            case .archived: "已归档"
            }
        }
    }
    enum Permission: String, LenientEnum { case manual, auto; static let fallback = Permission.manual }
    var id: String
    var taskId: String?
    var title: String
    var model: String?
    var status: Status
    var permission: Permission
    var lastActivity: String?
    var createdAt: Int64
    var updatedAt: Int64

    init(id: String, taskId: String?, title: String, model: String?, status: Status, permission: Permission,
         lastActivity: String?, createdAt: Int64, updatedAt: Int64) {
        self.id = id; self.taskId = taskId; self.title = title; self.model = model; self.status = status
        self.permission = permission; self.lastActivity = lastActivity; self.createdAt = createdAt; self.updatedAt = updatedAt
    }

    init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(String.self, forKey: .id)
        taskId = c.value(.taskId, default: nil)
        title = c.value(.title, default: "")
        model = c.value(.model, default: nil)
        status = c.value(.status, default: .idle)
        permission = c.value(.permission, default: .manual)
        lastActivity = c.value(.lastActivity, default: nil)
        createdAt = c.value(.createdAt, default: 0)
        updatedAt = c.value(.updatedAt, default: createdAt)
    }
}

struct Approval: Codable, Sendable, Hashable, Identifiable {
    enum Risk: String, LenientEnum { case low, medium, high; static let fallback = Risk.medium }
    enum Kind: String, LenientEnum { case command, fileChange, permissions, elicitation, action; static let fallback = Kind.action }
    var id: String
    var title: String
    var detail: String
    var risk: Risk
    var sessionId: String?
    var kind: Kind
    var requireBiometric: Bool
    var createdAt: Int64
    var expiresAt: Int64?

    init(id: String, title: String, detail: String, risk: Risk, sessionId: String?, kind: Kind,
         requireBiometric: Bool, createdAt: Int64, expiresAt: Int64?) {
        self.id = id; self.title = title; self.detail = detail; self.risk = risk; self.sessionId = sessionId
        self.kind = kind; self.requireBiometric = requireBiometric; self.createdAt = createdAt; self.expiresAt = expiresAt
    }

    init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(String.self, forKey: .id)
        title = c.value(.title, default: "")
        detail = c.value(.detail, default: "")
        risk = c.value(.risk, default: .medium)
        sessionId = c.value(.sessionId, default: nil)
        kind = c.value(.kind, default: .action)
        requireBiometric = c.value(.requireBiometric, default: false)
        createdAt = c.value(.createdAt, default: 0)
        expiresAt = c.value(.expiresAt, default: nil)
    }
}

struct ApprovalResolution: Codable, Sendable, Hashable {
    var id: String
    var decision: String
    var by: String
}

struct Memory: Codable, Sendable, Hashable, Identifiable {
    enum Kind: String, LenientEnum {
        case profile, preference, fact, person, place, date
        static let fallback = Kind.fact
        var label: String {
            switch self {
            case .profile: "个人"
            case .preference: "偏好"
            case .fact: "事实"
            case .person: "人物"
            case .place: "地点"
            case .date: "日期"
            }
        }
        var symbol: String {
            switch self {
            case .profile: "person.text.rectangle"
            case .preference: "heart"
            case .fact: "lightbulb"
            case .person: "person.2"
            case .place: "mappin.and.ellipse"
            case .date: "calendar"
            }
        }
    }
    var id: String
    var text: String
    var kind: Kind
    var source: String
    var confidence: Double
    var createdAt: Int64
    var updatedAt: Int64

    init(id: String, text: String, kind: Kind, source: String, confidence: Double, createdAt: Int64, updatedAt: Int64) {
        self.id = id; self.text = text; self.kind = kind; self.source = source; self.confidence = confidence
        self.createdAt = createdAt; self.updatedAt = updatedAt
    }

    init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(String.self, forKey: .id)
        text = c.value(.text, default: "")
        kind = c.value(.kind, default: .fact)
        source = c.value(.source, default: "explicit")
        confidence = c.value(.confidence, default: 1)
        createdAt = c.value(.createdAt, default: 0)
        updatedAt = c.value(.updatedAt, default: createdAt)
    }
}

struct Settings: Codable, Sendable, Hashable {
    struct Butler: Codable, Sendable, Hashable {
        var name: String = "Orbit"
        var avatar: String?
        var userTitle: String = "你"
        var persona: String = ""

        init() {}
        init(from decoder: any Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            name = c.value(.name, default: "Orbit")
            avatar = c.value(.avatar, default: nil)
            userTitle = c.value(.userTitle, default: "你")
            persona = c.value(.persona, default: "")
        }
    }
    /// The model and the reasoning effort (a Codex effort such as `low` / `high`) of Orbit, the heartbeat and the tasks.
    /// An empty, null or missing value means "auto":
    /// - `butler` / `codexDefault` empty: the Mac's default model; `heartbeat` empty: Orbit's model;
    /// - `butlerEffort` empty: medium; `heartbeatEffort` empty: Orbit's; `codexEffort` empty: Orbit picks per task.
    struct Models: Codable, Sendable, Hashable {
        var butler: String = ""
        var heartbeat: String = ""
        var codexDefault: String?
        var butlerEffort: String = ""
        var heartbeatEffort: String = ""
        var codexEffort: String = ""

        init() {}
        init(from decoder: any Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            butler = c.value(.butler, default: "")
            heartbeat = c.value(.heartbeat, default: "")
            codexDefault = c.value(.codexDefault, default: nil)
            butlerEffort = c.value(.butlerEffort, default: "")
            heartbeatEffort = c.value(.heartbeatEffort, default: "")
            codexEffort = c.value(.codexEffort, default: "")
        }
    }
    struct QuietHours: Codable, Sendable, Hashable {
        var start: String = "23:00"
        var end: String = "08:00"
    }
    enum Proactivity: String, LenientEnum {
        case low, normal, high
        static let fallback = Proactivity.normal
        var label: String { switch self { case .low: "克制"; case .normal: "适中"; case .high: "积极" } }
    }

    var butler = Butler()
    var models = Models()
    var proactivity: Proactivity = .normal
    var heartbeatMinutes: Int = 30
    var quietHours = QuietHours()
    var dailyNotifyBudget: Int = 5
    var defaultPermission: OPASession.Permission = .manual
    var allowAutoFullAccess: Bool = false

    init() {}
    init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        butler = c.value(.butler, default: Butler())
        models = c.value(.models, default: Models())
        proactivity = c.value(.proactivity, default: .normal)
        heartbeatMinutes = c.value(.heartbeatMinutes, default: 30)
        quietHours = c.value(.quietHours, default: QuietHours())
        dailyNotifyBudget = c.value(.dailyNotifyBudget, default: 5)
        defaultPermission = c.value(.defaultPermission, default: .manual)
        allowAutoFullAccess = c.value(.allowAutoFullAccess, default: false)
    }
}

/// `models.list` result. Both arrays carry `{id, displayName?, isDefault?, description?, efforts?, defaultEffort?}`;
/// older hosts sent butler entries as `{id, created}` (and no efforts) and may send bare strings. Decoding tolerates
/// all shapes and skips malformed entries instead of failing the whole list.
struct ModelsList: Codable, Sendable, Hashable {
    struct Entry: Codable, Sendable, Hashable, Identifiable {
        static let gpt61Sol = Entry(id: "gpt-6.1-sol", displayName: "GPT-6.1 Sol")

        var id: String
        var displayName: String?
        var isDefault: Bool?
        var description: String?
        var created: Int64?
        /// The reasoning efforts the model supports (`low`, `high` …); nil or empty when the host did not say.
        var efforts: [String]?
        var defaultEffort: String?

        init(id: String, displayName: String? = nil, isDefault: Bool? = nil, description: String? = nil, created: Int64? = nil,
             efforts: [String]? = nil, defaultEffort: String? = nil) {
            self.id = id; self.displayName = displayName; self.isDefault = isDefault; self.description = description; self.created = created
            self.efforts = efforts; self.defaultEffort = defaultEffort
        }

        init(from decoder: any Decoder) throws {
            if let single = try? decoder.singleValueContainer(), let s = try? single.decode(String.self) {
                self.init(id: s)
                return
            }
            let c = try decoder.container(keyedBy: CodingKeys.self)
            self.init(id: try c.decode(String.self, forKey: .id),
                      displayName: c.value(.displayName, default: nil),
                      isDefault: c.value(.isDefault, default: nil),
                      description: c.value(.description, default: nil),
                      created: c.value(.created, default: nil),
                      efforts: c.value(.efforts, default: nil),
                      defaultEffort: c.value(.defaultEffort, default: nil))
        }

        /// Human label: displayName when present and non-empty, else the raw id.
        var label: String {
            if let d = displayName?.trimmingCharacters(in: .whitespaces), !d.isEmpty { return d }
            return id
        }
    }

    typealias ButlerModel = Entry
    typealias CodexModel = Entry

    var butler: [Entry]
    var codex: [Entry]

    private enum CodingKeys: String, CodingKey { case butler, codex }

    init(butler: [Entry], codex: [Entry]) { self.butler = butler; self.codex = codex }

    static func includingGPT61Sol(in entries: [Entry]) -> [Entry] {
        guard !entries.contains(where: { $0.id == Entry.gpt61Sol.id }) else { return entries }
        return entries + [Entry.gpt61Sol]
    }

    init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        butler = Self.lenientArray(c, .butler)
        codex = Self.lenientArray(c, .codex)
    }

    private struct Lenient: Decodable { var entry: Entry?; init(from d: any Decoder) throws { entry = try? Entry(from: d) } }

    private static func lenientArray(_ c: KeyedDecodingContainer<CodingKeys>, _ key: CodingKeys) -> [Entry] {
        ((try? c.decodeIfPresent([Lenient].self, forKey: key)) ?? nil)?.compactMap(\.entry) ?? []
    }
}

struct PairedDevice: Codable, Sendable, Hashable, Identifiable {
    var id: String
    var name: String
    var pairedAt: Int64?
    var lastSeen: Int64?
}

struct SessionItem: Codable, Sendable, Hashable {
    var kind: String
    var text: String
    var ts: Int64
}

enum ButlerState: String, LenientEnum {
    case idle, thinking, acting, waiting
    static let fallback = ButlerState.idle
    var label: String {
        switch self {
        case .idle: "空闲"
        case .thinking: "思考中"
        case .acting: "执行中"
        case .waiting: "等待中"
        }
    }
}
