import SwiftUI

// 连接与设备: the Android execution phone (`phone.status`) and the devices paired with the Mac (`devices.list`).
// The Mac row itself opens the connection sheet (`model.showConnection`), which belongs to the chat feature.

// MARK: - phone.status

/// `phone.status` (docs/protocol.md §4.2): the dedicated Android phone Orbit operates. Read-only; the Mac only asks adb
/// which devices are connected. `available` does NOT mean everything is verified: USB debugging (security settings) and
/// the ADB Keyboard input method are only checked by `opa phone status` on the Mac, so the screen never says "全部就绪".
struct AndroidPhoneStatus: Equatable, Sendable {
    struct Device: Equatable, Sendable {
        var serial: String
        /// adb's state: `device` (usable), `unauthorized`, `offline`…
        var state: String
        var model: String?
    }

    var available: Bool
    /// Present exactly when `available` is false: what to fix, in words for the owner.
    var reason: String?
    var serial: String
    var device: Device?
    /// Whether ADB Keyboard is installed; nil means unknown (never shown as "not installed").
    var adbKeyboard: Bool?

    init(available: Bool, reason: String? = nil, serial: String, device: Device? = nil, adbKeyboard: Bool? = nil) {
        self.available = available
        self.reason = reason
        self.serial = serial
        self.device = device
        self.adbKeyboard = adbKeyboard
    }

    /// nil when `json` is not a `phone.status` answer (no `available` flag), e.g. an older Mac or the demo host.
    init?(json: JSONValue) {
        guard let available = json["available"]?.bool else { return nil }
        let reason = json["reason"]?.string?.trimmingCharacters(in: .whitespacesAndNewlines)
        let device = json["device"].flatMap { d -> Device? in
            guard let state = d["state"]?.string else { return nil }
            return Device(serial: d["serial"]?.string ?? "", state: state, model: d["model"]?.string)
        }
        self.init(available: available,
                  reason: (reason?.isEmpty ?? true) ? nil : reason,
                  serial: json["serial"]?.string ?? device?.serial ?? "",
                  device: device,
                  adbKeyboard: json["adbKeyboard"]?.bool)
    }

    /// adb writes spaces in the model as underscores ("Redmi_Note_12").
    var modelName: String? {
        guard let model = device?.model, !model.isEmpty else { return nil }
        return model.replacingOccurrences(of: "_", with: " ")
    }

    /// The name of the phone for a row title: its model, else its serial, else a generic name.
    var displayName: String {
        modelName ?? (serial.isEmpty ? "安卓手机" : serial)
    }

    /// What adb says about the phone, in words.
    var linkLabel: String {
        switch device?.state {
        case "device": "已连接"
        case "unauthorized": "未授权这台 Mac"
        case "offline": "离线"
        case .none: "没有发现"
        case .some(let other): other
        }
    }

    /// Sample answer for the demo host, which has no `phone.status`.
    static let demo = AndroidPhoneStatus(available: true, serial: "e7fe2f2a",
                                         device: Device(serial: "e7fe2f2a", state: "device", model: "23116PN5BC"),
                                         adbKeyboard: true)
}

/// Loads `phone.status` for the settings home and the phone page.
@MainActor @Observable
final class AndroidPhoneStatusStore {
    enum State: Equatable {
        case idle
        case loading
        case loaded(AndroidPhoneStatus)
        /// The Mac answered "unknown method": it needs an update.
        case unsupported
        /// There is no connection to the Mac to ask.
        case unreachable
        case failed(String)
    }

    private(set) var state: State = .idle
    @ObservationIgnored private var inFlight = false

    /// Asks the Mac. A loaded answer stays on screen while the new one is on its way.
    func refresh(using model: AppModel) async {
        guard !inFlight else { return }
        inFlight = true
        defer { inFlight = false }
        if case .loaded = state {} else { state = .loading }
        do {
            // The Mac needs up to about 8 s on a cache miss (3 s per adb call); stay well above that.
            let answer = try await model.request("phone.status", [:], timeout: .seconds(15))
            if let status = AndroidPhoneStatus(json: answer) {
                state = .loaded(status)
            } else if model.isDemo {
                state = .loaded(.demo)
            } else {
                state = .unsupported
            }
        } catch OPAError.notConnected {
            state = .unreachable
        } catch OPAError.remote(let message) where Self.isUnknownMethod(message) {
            state = .unsupported
        } catch {
            state = .failed(error.localizedDescription)
        }
    }

    /// The host answers `unknown method phone.status` when it predates the request.
    nonisolated static func isUnknownMethod(_ message: String) -> Bool {
        message.lowercased().contains("unknown method")
    }
}

extension AndroidPhoneStatusStore.State {
    /// The second line of the phone row on the settings home.
    var rowSummary: (text: String, isWarning: Bool) {
        switch self {
        case .idle, .loading: ("正在检查…", false)
        case .unsupported: ("需要更新 Mac 端", true)
        case .unreachable: ("连接 Mac 后显示状态", false)
        case .failed(let message): ("暂时无法获取状态：" + message, true)
        case .loaded(let status):
            status.available ? (status.displayName + " · 已就绪", false) : (status.reason ?? "暂时不能使用", true)
        }
    }
}

// MARK: - 安卓执行手机

struct AndroidPhoneStatusView: View {
    var store: AndroidPhoneStatusStore
    @Environment(AppModel.self) private var model

    var body: some View {
        List {
            Section {
                EmptyView()
            } footer: {
                SettingsFooter("Orbit 用这台专用安卓手机，替你操作只有手机 App 才有的服务。手机需要用数据线连在 Mac 上，并允许 USB 调试。")
            }
            .textCase(nil)

            switch store.state {
            case .idle, .loading:
                Section {
                    HStack(spacing: Space.m) {
                        ProgressView()
                        Text("正在向 Mac 询问手机状态…").font(.orbitBody).foregroundStyle(Color.inkSecondary)
                    }
                    .settingsRowChrome(icon: false)
                }
            case .loaded(let status):
                loaded(status)
            case .unsupported:
                notice(.info, "info.circle", "这台 Mac 上的 Orbit 还不能查看手机状态。更新 Mac 端后再回来看看。")
            case .unreachable:
                notice(.info, "laptopcomputer.slash", "连接 Mac 之后才能查看手机状态。")
            case .failed(let message):
                notice(.warn, "exclamationmark.triangle", "没有拿到手机状态：\(message)")
            }

            if showsRecheck {
                Section {
                    Button { Task { await store.refresh(using: model) } } label: {
                        Label("重新检查", systemImage: "arrow.clockwise").font(.orbitBody).foregroundStyle(Color.accentText)
                    }
                    .settingsRowChrome(icon: false)
                }
            }
        }
        .settingsListChrome()
        .navigationTitle("安卓执行手机")
        .navigationBarTitleDisplayMode(.inline)
        .task { await store.refresh(using: model) }
        .refreshable { await store.refresh(using: model) }
    }

    private var showsRecheck: Bool {
        switch store.state {
        case .idle, .loading: false
        default: true
        }
    }

    // MARK: States

    @ViewBuilder
    private func loaded(_ status: AndroidPhoneStatus) -> some View {
        Section {
            HStack(spacing: Space.m) {
                SettingsIconTile(systemImage: "candybarphone")
                VStack(alignment: .leading, spacing: 2) {
                    Text(verbatim: status.displayName).font(.orbitBody).foregroundStyle(Color.ink)
                    if status.modelName != nil, !status.serial.isEmpty {
                        Text(verbatim: status.serial).font(.system(.footnote, design: .monospaced)).foregroundStyle(Color.inkSecondary)
                    }
                }
                Spacer(minLength: Space.s)
                StatusChip(kind: status.available ? .ok : .blocked, text: status.available ? "已就绪" : "不可用")
            }
            .accessibilityElement(children: .combine)
            .settingsRowChrome()
            if !status.available, let reason = status.reason {
                NoteBlock(kind: .warn, systemImage: "exclamationmark.triangle", text: reason)
                    .listRowBackground(Color.clear)
                    .listRowInsets(EdgeInsets(top: Space.xs, leading: 0, bottom: Space.xs, trailing: 0))
                    .listRowSeparator(.hidden)
            }
        }

        Section {
            if let modelName = status.modelName { SettingsValueRow(title: "型号", value: modelName).settingsRowChrome(icon: false) }
            if !status.serial.isEmpty {
                SettingsValueRow(title: "序列号", value: status.serial, monospaced: true).settingsRowChrome(icon: false)
            }
            SettingsValueRow(title: "USB 连接", value: status.linkLabel).settingsRowChrome(icon: false)
            if let keyboard = status.adbKeyboard {
                SettingsValueRow(title: "ADB Keyboard", value: keyboard ? "已安装" : "未安装").settingsRowChrome(icon: false)
            }
        } header: {
            SettingsSectionHeader("详情")
        } footer: {
            SettingsFooter("USB 调试的“安全设置”和 ADB Keyboard 输入法是否已启用，要在 Mac 终端运行 opa phone status 才能检查。")
        }
        .textCase(nil)
    }

    private func notice(_ kind: NoteKind, _ symbol: String, _ text: String) -> some View {
        Section {
            NoteBlock(kind: kind, systemImage: symbol, text: text)
                .listRowBackground(Color.clear)
                .listRowInsets(EdgeInsets())
                .listRowSeparator(.hidden)
        }
    }
}

// MARK: - 已配对设备

struct PairedDevicesView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        List {
            Section {
                if devices.isEmpty {
                    Text("还没有读到设备列表。连上 Mac 之后下拉刷新。")
                        .font(.orbitSecondary)
                        .foregroundStyle(Color.inkSecondary)
                        .settingsRowChrome(icon: false)
                }
                ForEach(devices) { device in
                    DeviceRow(device: device, isThisDevice: device.id == model.identity.deviceId,
                              isConnected: model.connection.isConnected)
                        .settingsRowChrome()
                }
            } footer: {
                SettingsFooter("这些设备都能连上你的 Mac 并和 Orbit 对话。")
            }
            .textCase(nil)
        }
        .settingsListChrome()
        .navigationTitle("已配对设备")
        .navigationBarTitleDisplayMode(.inline)
        .task { await model.loadDevices() }
        .refreshable { await model.loadDevices() }
    }

    /// This phone first, then the most recently seen.
    private var devices: [PairedDevice] {
        model.devices.sorted { a, b in
            let aThis = a.id == model.identity.deviceId, bThis = b.id == model.identity.deviceId
            if aThis != bThis { return aThis }
            return (a.lastSeen ?? 0) > (b.lastSeen ?? 0)
        }
    }
}

private struct DeviceRow: View {
    var device: PairedDevice
    var isThisDevice: Bool
    var isConnected: Bool

    var body: some View {
        HStack(spacing: Space.m) {
            SettingsIconTile(systemImage: device.name.localizedCaseInsensitiveContains("ipad") ? "ipad" : "iphone.gen3")
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: Space.s) {
                    Text(verbatim: device.name).font(.orbitBody).foregroundStyle(Color.ink)
                    if isThisDevice { StatusChip(kind: .planning, text: "本机") }
                }
                if let line = detail {
                    Text(verbatim: line).font(.orbitMeta).foregroundStyle(Color.inkSecondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            Spacer(minLength: 0)
        }
        .accessibilityElement(children: .combine)
    }

    private var detail: String? {
        var parts: [String] = []
        if isThisDevice, isConnected {
            parts.append("正在使用")
        } else if let seen = device.lastSeen {
            parts.append("最近在线 " + Fmt.relative(seen))
        }
        if let paired = device.pairedAt { parts.append("配对于 " + Fmt.dateTime(paired)) }
        return parts.isEmpty ? nil : parts.joined(separator: " · ")
    }
}
