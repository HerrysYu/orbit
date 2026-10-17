import SwiftUI

// 高级 › 模型: three groups, each with a model and a reasoning effort (推理强度): Orbit itself, the periodic self-check
// (心跳) and the tasks Orbit hands to the Mac. The Mac lists what it can use (`models.list`, with the efforts every model
// supports). An empty id or effort means "auto" (自动 / 默认 / 跟随) and is saved as such.

struct ModelsView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        let choices = ModelChoices(settings: model.settings.models, list: model.models)
        List {
            jobSection(.orbit, choices)
            jobSection(.heartbeat, choices)
            jobSection(.task, choices)
        }
        .settingsListChrome()
        .navigationTitle("模型")
        .navigationBarTitleDisplayMode(.inline)
        .task { await model.loadModels() }
    }

    private func jobSection(_ job: ModelChoices.Job, _ choices: ModelChoices) -> some View {
        Section {
            ModelPickerRow(title: "模型", automaticLabel: job.automaticModelLabel, selection: choices.model(of: job),
                           entries: choices.entries(for: job)) { value in
                model.updateSettings(choices.patch(choosingModel: value, for: job))
            }
            .settingsRowChrome(icon: false)
            EffortPickerRow(title: "推理强度", automaticLabel: job.automaticEffortLabel, selection: choices.effort(of: job),
                            options: choices.efforts(for: job)) { value in
                model.updateSettings(choices.patch(choosingEffort: value, for: job))
            }
            .settingsRowChrome(icon: false)
        } header: {
            SettingsSectionHeader(job.title)
        } footer: {
            SettingsFooter(footer(for: job, choices))
        }
        .textCase(nil)
    }

    private func footer(for job: ModelChoices.Job, _ choices: ModelChoices) -> String {
        switch job {
        case .orbit:
            if model.models == nil { return "连接 Mac 后自动获取可用模型。" }
            let selected = choices.model(of: .orbit)
            if let description = choices.entries(for: .orbit).first(where: { $0.id == selected })?.description, !description.isEmpty {
                return description
            }
            return "Orbit 聊天、规划和做判断时用的模型。选“自动”则使用 Mac 上的默认模型。"
        case .heartbeat:
            return "Orbit 每隔一段时间会自查有没有需要提醒你的事，这时用这里的设置；选更快、更省的档位可以节省额度。"
        case .task:
            return "自动时由 Orbit 按任务难度选择。\n所有模型都通过你在 Mac 上登录的 ChatGPT 账户计费。"
        }
    }
}

// MARK: - Choices

/// What each group of the 模型 page offers and what a choice saves: the pure rules behind `ModelsView`.
struct ModelChoices {
    /// The three things that think: Orbit's chat and judgement, the periodic self-check and the tasks run on the Mac.
    enum Job: CaseIterable, Sendable {
        case orbit, heartbeat, task

        var title: String {
            switch self {
            case .orbit: "Orbit"
            case .heartbeat: "定期自查（心跳）"
            case .task: "执行任务"
            }
        }

        /// The first model row: an empty id.
        var automaticModelLabel: String { self == .heartbeat ? "跟随 Orbit" : "自动（最新）" }

        /// The first effort row: an empty effort.
        var automaticEffortLabel: String {
            switch self {
            case .orbit: "默认（中）"
            case .heartbeat: "跟随 Orbit"
            case .task: "自动"
            }
        }

        /// The keys of `settings.models` this group writes.
        fileprivate var modelKey: String {
            switch self {
            case .orbit: "butler"
            case .heartbeat: "heartbeat"
            case .task: "codexDefault"
            }
        }

        fileprivate var effortKey: String {
            switch self {
            case .orbit: "butlerEffort"
            case .heartbeat: "heartbeatEffort"
            case .task: "codexEffort"
            }
        }
    }

    /// Offered when the Mac does not say which efforts a model supports (an older Mac, an unlisted model).
    static let fallbackEfforts = ["low", "medium", "high", "xhigh"]

    var settings: Settings.Models
    var list: ModelsList?

    // MARK: Reading

    /// The models a group chooses from: Orbit and the heartbeat use the bot models, tasks the Codex ones.
    func entries(for job: Job) -> [ModelsList.Entry] {
        ModelsList.includingGPT61Sol(in: (job == .task ? list?.codex : list?.butler) ?? [])
    }

    /// The model id a group has chosen; empty is auto / follow Orbit / the Mac's default.
    func model(of job: Job) -> String {
        switch job {
        case .orbit: settings.butler
        case .heartbeat: settings.heartbeat
        case .task: settings.codexDefault ?? ""
        }
    }

    /// The effort a group has chosen; empty is auto / follow Orbit / the default (medium).
    func effort(of job: Job) -> String {
        switch job {
        case .orbit: settings.butlerEffort
        case .heartbeat: settings.heartbeatEffort
        case .task: settings.codexEffort
        }
    }

    /// The efforts the model answering for `job` supports. An empty model is the Mac's default model, and the heartbeat
    /// without a model of its own is Orbit's.
    func efforts(for job: Job) -> [String] {
        let id = job == .heartbeat && settings.heartbeat.isEmpty ? settings.butler : model(of: job)
        return Self.efforts(ofModel: id, in: entries(for: job))
    }

    /// What model `id` supports according to `entries`. An empty id is the entry the Mac marks as default; a model that
    /// is not listed, or lists no efforts, gets `fallbackEfforts`. Blank and repeated efforts are dropped.
    static func efforts(ofModel id: String, in entries: [ModelsList.Entry]) -> [String] {
        let entry = id.isEmpty ? entries.first { $0.isDefault == true } : entries.first { $0.id == id }
        var seen = Set<String>()
        let listed = (entry?.efforts ?? [])
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty && seen.insert($0).inserted }
        return listed.isEmpty ? fallbackEfforts : listed
    }

    /// The Chinese name of an effort; one the app does not know is shown as the Mac sent it.
    static func effortLabel(_ effort: String) -> String {
        switch effort {
        case "none": "关闭"
        case "minimal": "极低"
        case "low": "低"
        case "medium": "中"
        case "high": "高"
        case "xhigh": "超高"
        case "max": "最高"
        default: effort
        }
    }

    // MARK: Saving

    /// The `settings.set` patch for choosing model `id` in a group. When the group's current effort is not among what
    /// the new model supports, the same patch puts it back to auto, so a save never leaves a model with an effort it
    /// cannot run. The heartbeat has its effort checked too when Orbit's model changes under it (it follows Orbit).
    func patch(choosingModel id: String, for job: Job) -> JSONValue {
        var next = settings
        switch job {
        case .orbit: next.butler = id
        case .heartbeat: next.heartbeat = id
        case .task: next.codexDefault = id.isEmpty ? nil : id
        }
        var changes: [String: JSONValue] = [job.modelKey: id.isEmpty && job == .task ? .null : .string(id)]
        let after = ModelChoices(settings: next, list: list)
        let affected: [Job] = job == .orbit && settings.heartbeat.isEmpty ? [.orbit, .heartbeat] : [job]
        for affectedJob in affected {
            let current = effort(of: affectedJob)
            if !current.isEmpty, !after.efforts(for: affectedJob).contains(current) { changes[affectedJob.effortKey] = .string("") }
        }
        return ["models": .object(changes)]
    }

    /// The `settings.set` patch for choosing an effort in a group.
    func patch(choosingEffort effort: String, for job: Job) -> JSONValue {
        ["models": .object([job.effortKey: .string(effort)])]
    }
}

// MARK: - Rows

/// A menu picker over the Mac's model list. The automatic row (empty id) always comes first; a model the Mac no longer
/// lists stays visible so the picker never shows a blank value.
private struct ModelPickerRow: View {
    var title: String
    var automaticLabel: String
    var selection: String
    var entries: [ModelsList.Entry]
    var onChange: (String) -> Void

    var body: some View {
        let listed = selection.isEmpty || entries.contains(where: { $0.id == selection })
            ? entries : [ModelsList.Entry(id: selection)] + entries
        Picker(selection: Binding { selection } set: { onChange($0) }) {
            Text(automaticLabel).tag("")
            ForEach(listed) { entry in
                Text(entry.label + (entry.isDefault == true ? "（默认）" : "")).tag(entry.id)
            }
        } label: {
            Text(verbatim: title).font(.orbitBody).foregroundStyle(Color.ink)
        }
    }
}

/// A menu picker over the efforts the chosen model supports. The automatic row (empty effort) always comes first; an
/// effort that is saved but no longer on offer stays visible so the picker never shows a blank value.
private struct EffortPickerRow: View {
    var title: String
    var automaticLabel: String
    var selection: String
    var options: [String]
    var onChange: (String) -> Void

    var body: some View {
        let listed = selection.isEmpty || options.contains(selection) ? options : options + [selection]
        Picker(selection: Binding { selection } set: { onChange($0) }) {
            Text(automaticLabel).tag("")
            ForEach(listed, id: \.self) { effort in
                Text(ModelChoices.effortLabel(effort)).tag(effort)
            }
        } label: {
            Text(verbatim: title).font(.orbitBody).foregroundStyle(Color.ink)
        }
    }
}
