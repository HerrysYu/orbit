import SwiftUI

/// Where a row of the settings home leads. `String` raw values double as the debug launch argument
/// `-OPASettingsRoute <name>` (screenshots).
enum SettingsRoute: String, Hashable {
    case identity, userTitle, persona
    case phone, devices
    case memory, proactivity, quietHours
    case permission, deviceInfo
    case models
}

/// Settings home. It answers "how does Orbit help me and what can I control": the character, its name and the Mac on
/// top (left aligned), then plain-language groups; technical details live one level down under 高级.
struct SettingsView: View {
    @Environment(AppModel.self) private var model
    @State private var path: [SettingsRoute]
    @State private var phone = AndroidPhoneStatusStore()
    @State private var access = DeviceAccess.current()
    @State private var confirmUnpair = false

    init() {
        #if DEBUG
        _path = State(initialValue: Self.debugInitialPath())
        #else
        _path = State(initialValue: [])
        #endif
    }

    var body: some View {
        NavigationStack(path: $path) {
            List {
                headerSection
                orbitSection
                connectionSection
                memorySection
                privacySection
                advancedSection
            }
            .settingsListChrome()
            .navigationTitle("设置")
            .toolbar(.hidden, for: .navigationBar)
            // Content scrolling under the status bar would collide with the clock: a zero-height top inset whose
            // background reaches up to the screen edge keeps the status bar area clean.
            .safeAreaInset(edge: .top, spacing: 0) {
                Color.clear.frame(height: 0).background(Color.canvas.ignoresSafeArea(edges: .top))
            }
            .navigationDestination(for: SettingsRoute.self) { route in destination(route) }
            .confirmationDialog("解除与 \(model.hostName ?? "Mac") 的配对？", isPresented: $confirmUnpair, titleVisibility: .visible) {
                Button("解除配对", role: .destructive) { model.unpair() }
            } message: {
                Text("会删除本机缓存的对话与任务记录。设备身份密钥保留在钥匙串中。")
            }
            .task {
                async let settings: Void = model.loadSettings()
                async let models: Void = model.loadModels()
                async let memories: Void = model.loadMemories()
                async let devices: Void = model.loadDevices()
                _ = await (settings, models, memories, devices)
            }
            .task(id: model.connection.isConnected) { await phone.refresh(using: model) }
            .onAppear { access = DeviceAccess.current() }
        }
    }

    // MARK: Destinations

    @ViewBuilder
    private func destination(_ route: SettingsRoute) -> some View {
        switch route {
        case .identity: BotIdentityView()
        case .userTitle: UserTitleView()
        case .persona: PersonaView()
        case .phone: AndroidPhoneStatusView(store: phone)
        case .devices: PairedDevicesView()
        case .memory: MemoryView()
        case .proactivity: ProactivityView()
        case .quietHours: QuietHoursView()
        case .permission: ExecutionPermissionView()
        case .deviceInfo: DeviceInfoView()
        case .models: ModelsView()
        }
    }

    // MARK: Header

    private var headerSection: some View {
        Section {
            SettingsHeader { path.append(.identity) }
                .listRowBackground(Color.clear)
                .listRowSeparator(.hidden)
                .listRowInsets(EdgeInsets(top: Space.s, leading: 0, bottom: Space.m, trailing: 0))
        }
    }

    // MARK: 我的 Orbit

    private var orbitSection: some View {
        let butler = model.settings.butler
        return Section {
            SettingsNavRow { path.append(.identity) } label: {
                SettingsRowLabel(systemImage: "person", title: "名字和形象", value: butler.name, showsChevron: true)
            }
            .settingsRowChrome()
            SettingsNavRow { path.append(.userTitle) } label: {
                SettingsRowLabel(systemImage: "bubble.left", title: "怎么称呼你", value: butler.userTitle, showsChevron: true)
            }
            .settingsRowChrome()
            SettingsNavRow { path.append(.persona) } label: {
                SettingsRowLabel(systemImage: "sparkles", title: "性格", value: Self.personaSummary(butler.persona), showsChevron: true)
            }
            .settingsRowChrome()
        } header: {
            SettingsSectionHeader("我的 Orbit")
        }
        .textCase(nil)
    }

    /// "温和、靠谱" from "温和、靠谱，说话简洁，偶尔幽默。": the first phrase of the persona text.
    static func personaSummary(_ persona: String) -> String {
        let separators = CharacterSet(charactersIn: "，,。.；;！!？?\n")
        let first = persona.components(separatedBy: separators)
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .first { !$0.isEmpty }
        return first ?? "未设置"
    }

    // MARK: 连接与设备

    private var connectionSection: some View {
        let line = macLine
        return Section {
            SettingsNavRow { model.showConnection = true } label: {
                SettingsRowLabel(systemImage: "laptopcomputer", title: model.hostName ?? "Mac", subtitle: line.text,
                                 subtitleTone: line.isWarning ? .warning : .normal, showsChevron: true)
            }
            .settingsRowChrome()
            SettingsNavRow { path.append(.phone) } label: {
                let row = phoneRow
                SettingsRowLabel(systemImage: "candybarphone", title: "安卓执行手机", subtitle: row.text,
                                 subtitleTone: row.isWarning ? .warning : .normal, subtitleLines: 2, showsChevron: true)
            }
            .settingsRowChrome()
            SettingsNavRow { path.append(.devices) } label: {
                SettingsRowLabel(systemImage: "iphone.gen3", title: "已配对设备",
                                 value: model.devices.isEmpty ? nil : "\(model.devices.count) 台", showsChevron: true)
            }
            .settingsRowChrome()
        } header: {
            SettingsSectionHeader("连接与设备")
        }
        .textCase(nil)
    }

    /// "已连接 · 局域网" and friends: the second line of the Mac row.
    private var macLine: (text: String, isWarning: Bool) {
        switch model.connection {
        case .connected(let path): ("已连接 · " + path.settingsLabel, false)
        case .idle, .connecting, .handshaking: ("正在连接…", false)
        case .awaitingPairConfirm: ("等待 Mac 确认", false)
        case .waitingRetry: ("正在重新连接…", false)
        case .hostOffline: ("Mac 离线 · 消息会排队", true)
        case .failed: ("连接失败", true)
        }
    }

    private var phoneRow: (text: String, isWarning: Bool) {
        phone.state.rowSummary
    }

    // MARK: 记忆、主动与通知

    private var memorySection: some View {
        let s = model.settings
        return Section {
            SettingsNavRow { path.append(.memory) } label: {
                SettingsRowLabel(systemImage: "book.closed", title: "记忆",
                                 value: model.memories.isEmpty ? nil : "\(model.memories.count) 条", showsChevron: true)
            }
            .settingsRowChrome()
            SettingsNavRow { path.append(.proactivity) } label: {
                SettingsRowLabel(systemImage: "slider.horizontal.3", title: "主动程度", value: s.proactivity.label, showsChevron: true)
            }
            .settingsRowChrome()
            SettingsNavRow { path.append(.quietHours) } label: {
                SettingsRowLabel(systemImage: "moon", title: "安静时段", value: "\(s.quietHours.start)–\(s.quietHours.end)", showsChevron: true)
            }
            .settingsRowChrome()
            Stepper(value: Binding {
                model.settings.dailyNotifyBudget
            } set: { model.updateSettings(["dailyNotifyBudget": .number(Double($0))]) }, in: 0...50) {
                SettingsRowLabel(systemImage: "bell", title: "每日通知上限", value: "\(s.dailyNotifyBudget) 条")
            }
            .settingsRowChrome()
        } header: {
            SettingsSectionHeader("记忆、主动与通知")
        } footer: {
            SettingsFooter("每日上限只管 Orbit 主动发给你的通知；确认请求和紧急事项不受限。")
        }
        .textCase(nil)
    }

    // MARK: 权限与隐私

    private var privacySection: some View {
        Section {
            SettingsNavRow { path.append(.permission) } label: {
                SettingsRowLabel(systemImage: "checkmark.shield", title: "执行权限", value: model.settings.executionAccess.label, showsChevron: true)
            }
            .settingsRowChrome()
            SettingsRowLabel(systemImage: "hand.tap", title: "安卓手机上的敏感点击",
                             subtitle: "自动执行，并记录在案。没有你的明确授权，Orbit 只查询，不下单、不付款。")
                .settingsRowChrome()
            SettingsNavRow { path.append(.deviceInfo) } label: {
                SettingsRowLabel(systemImage: "lock", title: "设备信息", value: access.summary, showsChevron: true)
            }
            .settingsRowChrome()
        } header: {
            SettingsSectionHeader("权限与隐私")
        }
        .textCase(nil)
    }

    // MARK: 高级

    private var advancedSection: some View {
        Section {
            SettingsNavRow { path.append(.models) } label: {
                SettingsRowLabel(systemImage: "cpu", title: "模型", value: botModelName, showsChevron: true)
            }
            .settingsRowChrome()
            if let host = model.pairedHost {
                SettingsValueRow(title: "Host ID", value: String(host.hostId.prefix(12)) + "…", full: host.hostId, monospaced: true)
                    .settingsRowChrome(icon: false)
                if let relay = host.relay {
                    SettingsValueRow(title: "中继地址", value: URL(string: relay)?.host() ?? relay, full: relay)
                        .settingsRowChrome(icon: false)
                }
                SettingsValueRow(title: "配对时间", value: Fmt.dateTime(host.pairedAt))
                    .settingsRowChrome(icon: false)
            }
            LabeledContent {
                TextField("iPhone", text: Binding { model.deviceName } set: { model.deviceName = $0 })
                    .multilineTextAlignment(.trailing)
                    .foregroundStyle(Color.inkSecondary)
                    .submitLabel(.done)
            } label: {
                Text("本机名称").font(.orbitBody).foregroundStyle(Color.ink)
            }
            .settingsRowChrome(icon: false)
            SettingsValueRow(title: "本机 ID", value: String(model.identity.deviceId.prefix(12)) + "…",
                             full: model.identity.deviceId, monospaced: true)
                .settingsRowChrome(icon: false)
            if model.outboxCount > 0 {
                SettingsValueRow(title: "待发送", value: "\(model.outboxCount) 条")
                    .settingsRowChrome(icon: false)
            }
            if model.isDemo {
                Button { model.exitDemo() } label: {
                    Text("退出演示模式").font(.orbitBody).foregroundStyle(Color.accentText)
                }
                .settingsRowChrome(icon: false)
            }
            Button(role: .destructive) { confirmUnpair = true } label: {
                Text("解除配对").font(.orbitBody).foregroundStyle(Color.danger)
            }
            .settingsRowChrome(icon: false)
        } header: {
            SettingsSectionHeader("高级")
        } footer: {
            SettingsFooter("解除配对会删除本机缓存的对话与任务记录。设备身份密钥保留在钥匙串中。")
        }
        .textCase(nil)
    }

    /// The bot model as shown on the 高级 row: its display name, or 自动 when Orbit follows the latest.
    private var botModelName: String {
        let id = model.settings.models.butler
        guard !id.isEmpty else { return "自动" }
        let entries = ModelsList.includingGPT61Sol(in: model.models?.butler ?? [])
        return entries.first(where: { $0.id == id })?.label ?? id
    }

    #if DEBUG
    private static func debugInitialPath() -> [SettingsRoute] {
        guard let raw = UserDefaults.standard.string(forKey: "OPASettingsRoute"), let route = SettingsRoute(rawValue: raw) else { return [] }
        return [route]
    }
    #endif
}

// MARK: - Header

/// Orbit's avatar (40 pt), its name and the Mac connection, left aligned in one block: the name beside the avatar and,
/// under it, a state dot and "已连接 · Herry 的 MacBook". Tapping the avatar opens 名字和形象.
private struct SettingsHeader: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dynamicTypeSize) private var typeSize
    @ScaledMetric(relativeTo: .title2) private var avatarSize: CGFloat = 40
    var openIdentity: () -> Void

    var body: some View {
        HStack(spacing: Space.m) {
            Button(action: openIdentity) {
                SettingsAvatarView(avatar: model.settings.butler.avatar, size: avatarSize)
                    .contentShape(.circle)
            }
            .buttonStyle(.pressable)
            .accessibilityLabel("名字和形象")
            .accessibilityValue(model.settings.butler.name)

            VStack(alignment: .leading, spacing: 1) {
                Text(verbatim: model.settings.butler.name)
                    .font(.system(.title2, weight: .semibold))
                    .foregroundStyle(Color.ink)
                    .lineLimit(1)
                DotLabel(color: statusDot, text: statusText, style: .subheadline, lineLimit: typeSize.isAccessibilitySize ? 3 : 1)
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 6)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var hostName: String { model.hostName ?? "Mac" }

    private var statusText: String {
        switch model.connection {
        case .connected: "已连接 · \(hostName)"
        case .idle, .connecting, .handshaking, .awaitingPairConfirm, .waitingRetry: "正在连接 · \(hostName)"
        case .hostOffline: "离线 · \(hostName)"
        case .failed: "没有连上 · \(hostName)"
        }
    }

    private var statusDot: Color {
        switch model.connection {
        case .connected: .success
        case .hostOffline, .failed: .warning
        default: .inkTertiary
        }
    }
}

// MARK: - Value row

/// A label / value row without navigation (Host ID, 配对时间…). Long values can be selected and copied.
struct SettingsValueRow: View {
    var title: String
    var value: String
    /// The untruncated text to copy, when `value` is shortened.
    var full: String?
    var monospaced = false

    var body: some View {
        LabeledContent {
            Text(verbatim: value)
                .font(monospaced ? .system(.footnote, design: .monospaced) : .orbitSecondary)
                .foregroundStyle(Color.inkSecondary)
                .multilineTextAlignment(.trailing)
                .textSelection(.enabled)
        } label: {
            Text(verbatim: title).font(.orbitBody).foregroundStyle(Color.ink)
        }
        .accessibilityElement(children: .combine)
        .accessibilityValue(full ?? value)
    }
}

// MARK: - Labels

extension TransportPath {
    /// 局域网 / 外网中继 (the settings wording; `label` is the connection sheet's).
    var settingsLabel: String { self == .lan ? "局域网" : "外网中继" }
}

extension OPASession.Permission {
    /// The user-facing name of an execution permission.
    var accessLabel: String { self == .auto ? "完全访问" : "逐项确认" }
}

#Preview {
    let m = AppModel(inMemory: true)
    m.enterDemo()
    return SettingsView().environment(m)
}
