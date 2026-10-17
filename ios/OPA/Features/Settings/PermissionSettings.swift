import CoreLocation
import EventKit
import SwiftUI

// 权限与隐私: what Orbit may do on the Mac without asking, and which information of this phone it may read.

// MARK: - 执行权限

/// The user-facing execution permission. The Mac keeps two switches (`defaultPermission`, `allowAutoFullAccess`); the
/// two states people choose between set both at once, and any other combination (set by an older app or on the Mac)
/// is shown honestly as 自定义.
enum ExecutionAccess: Equatable, Sendable {
    /// Commands outside the sandbox are asked one by one.
    case perItem
    /// Commands on the Mac are no longer asked one by one.
    case full
    /// Some other combination of the two switches.
    case custom

    var label: String {
        switch self {
        case .perItem: "逐项确认"
        case .full: "完全访问"
        case .custom: "自定义"
        }
    }
}

extension Settings {
    var executionAccess: ExecutionAccess {
        switch (defaultPermission, allowAutoFullAccess) {
        case (.manual, false): .perItem
        case (.auto, true): .full
        default: .custom
        }
    }
}

struct ExecutionPermissionView: View {
    @Environment(AppModel.self) private var model
    @State private var confirmFull = false

    var body: some View {
        let access = model.settings.executionAccess
        List {
            Section {
                SettingsChoiceRow(title: ExecutionAccess.perItem.label, subtitle: "Mac 上沙箱外的命令，会逐项问你。",
                                  selected: access == .perItem, action: setPerItem)
                    .settingsRowChrome(icon: false)
                SettingsChoiceRow(title: ExecutionAccess.full.label, subtitle: "Mac 上的命令不再逐项询问。开启前需要 Face ID。",
                                  selected: access == .full) {
                    if access != .full { confirmFull = true }
                }
                .settingsRowChrome(icon: false)
                if access == .custom {
                    SettingsChoiceRow(title: ExecutionAccess.custom.label, subtitle: customExplanation, selected: true, action: {})
                        .settingsRowChrome(icon: false)
                }
            } header: {
                SettingsSectionHeader("Orbit 在 Mac 上执行任务时")
            } footer: {
                SettingsFooter("这个设置只管 Mac 上的命令和文件修改。花钱、对外发送这类事，仍然只在你明确要求或批准后才做；安卓手机上的敏感点击另有规则，见上一页。")
            }
            .textCase(nil)
        }
        .settingsListChrome()
        .navigationTitle("执行权限")
        .navigationBarTitleDisplayMode(.inline)
        .confirmationDialog("开启完全访问？", isPresented: $confirmFull, titleVisibility: .visible) {
            Button("用 Face ID 开启") { Task { await enableFullAccess() } }
        } message: {
            Text("开启后，Mac 上的命令不再逐项询问。你可以随时改回逐项确认。")
        }
    }

    /// What a combination that is neither of the two choices means.
    private var customExplanation: String {
        let settings = model.settings
        if settings.defaultPermission == .auto {
            return "新任务默认完全访问，但每次都要先问你。"
        }
        return "默认逐项确认；Orbit 认为需要时，可以不经询问使用完全访问。"
    }

    private func setPerItem() {
        guard model.settings.executionAccess != .perItem else { return }
        model.updateSettings(["defaultPermission": .string("manual"), "allowAutoFullAccess": false])
    }

    private func enableFullAccess() async {
        guard await Biometrics.authenticate(reason: "允许 Orbit 在 Mac 上完全访问，不再逐项询问") else { return }
        model.updateSettings(["defaultPermission": .string("auto"), "allowAutoFullAccess": true])
    }
}

// MARK: - 设备信息

/// Authorization of what Orbit may read on this phone. Read straight from the system (the context service only exposes
/// yes / no, but "denied" needs a different button than "not asked yet").
struct DeviceAccess: Equatable, Sendable {
    enum State: Equatable, Sendable { case granted, notDetermined, denied }

    var location: State
    var calendar: State
    var reminders: State

    @MainActor
    static func current() -> DeviceAccess {
        DeviceAccess(location: locationState(CLLocationManager().authorizationStatus),
                     calendar: eventState(EKEventStore.authorizationStatus(for: .event)),
                     reminders: eventState(EKEventStore.authorizationStatus(for: .reminder)))
    }

    private static func locationState(_ status: CLAuthorizationStatus) -> State {
        switch status {
        case .authorizedAlways, .authorizedWhenInUse: .granted
        case .notDetermined: .notDetermined
        default: .denied
        }
    }

    private static func eventState(_ status: EKAuthorizationStatus) -> State {
        switch status {
        case .fullAccess: .granted
        case .notDetermined: .notDetermined
        default: .denied
        }
    }

    /// 位置、日历 — what is granted, for the value of the 设备信息 row.
    var summary: String {
        let granted = [(location, "位置"), (calendar, "日历"), (reminders, "提醒事项")].filter { $0.0 == .granted }.map(\.1)
        return granted.isEmpty ? "未授权" : granted.joined(separator: "、")
    }
}

struct DeviceInfoView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.openURL) private var openURL
    @Environment(\.scenePhase) private var scenePhase
    @State private var access = DeviceAccess.current()

    var body: some View {
        List {
            Section {
                row("位置", "只取大致位置，用于天气和附近的地点", "location", access.location, request: requestLocation)
                row("日历", "未来 24 小时的日程", "calendar", access.calendar) {
                    Task { _ = await model.context.requestCalendar(); access = .current() }
                }
                row("提醒事项", "未完成的提醒", "checklist", access.reminders) {
                    Task { _ = await model.context.requestReminders(); access = .current() }
                }
            } header: {
                SettingsSectionHeader("Orbit 可以读取")
            } footer: {
                SettingsFooter("Orbit 会定期获取时区、网络状态，以及你授权的大致位置、日程和提醒，用来提供更贴心的帮助。随时可以在系统设置里关闭。")
            }
            .textCase(nil)

            Section {
                Button(action: syncContext) {
                    Label("立即同步", systemImage: "arrow.triangle.2.circlepath").font(.orbitBody).foregroundStyle(Color.accentText)
                }
                .settingsRowChrome(icon: false)
            }
        }
        .settingsListChrome()
        .navigationTitle("设备信息")
        .navigationBarTitleDisplayMode(.inline)
        .onAppear { access = .current() }
        // The system permission prompt takes the app inactive and back: re-read what was decided.
        .onChange(of: scenePhase) { _, phase in if phase == .active { access = .current() } }
    }

    @ViewBuilder
    private func row(_ title: String, _ subtitle: String, _ symbol: String, _ state: DeviceAccess.State,
                     request: @escaping () -> Void) -> some View {
        HStack(spacing: Space.m) {
            SettingsIconTile(systemImage: symbol)
            VStack(alignment: .leading, spacing: 2) {
                Text(verbatim: title).font(.orbitBody).foregroundStyle(Color.ink)
                Text(verbatim: subtitle).font(.orbitMeta).foregroundStyle(Color.inkSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: Space.s)
            switch state {
            case .granted:
                Label("已授权", systemImage: "checkmark.circle.fill")
                    .font(.orbitSecondary)
                    .foregroundStyle(Color.success)
            case .notDetermined:
                Button("授权", action: request).buttonStyle(.orbit(.soft, size: .mini))
            case .denied:
                Button("去设置开启") { if let url = URL(string: "app-settings:") { openURL(url) } }
                    .buttonStyle(.orbit(.soft, size: .mini))
            }
        }
        .accessibilityElement(children: .contain)
        .settingsRowChrome()
    }

    private func requestLocation() {
        model.context.requestLocation()
        Task {
            // There is no callback for the location prompt: look for the answer for a while.
            for _ in 0..<20 {
                try? await Task.sleep(for: .milliseconds(500))
                access = .current()
                if access.location != .notDetermined { break }
            }
        }
    }

    private func syncContext() {
        guard model.canUseHost else {
            model.showToast("Mac 没有连上，连上后会自动同步")
            return
        }
        Task {
            await model.sendContext()
            model.showToast("已同步")
        }
    }
}
