import SwiftUI

// 记忆、主动与通知: how proactive Orbit is and when it stays quiet, and whether this phone lets its notifications
// through. The wording follows what the Mac does with the settings (host/src/butler: proactivity tiers, heartbeat,
// quiet hours, daily notification budget).

// MARK: - 主动程度

struct ProactivityView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        List {
            Section {
                ForEach(Settings.Proactivity.allCases, id: \.self) { level in
                    SettingsChoiceRow(title: level.label, subtitle: Self.explanation(level),
                                      selected: model.settings.proactivity == level) {
                        guard model.settings.proactivity != level else { return }
                        model.updateSettings(["proactivity": .string(level.rawValue)])
                    }
                    .settingsRowChrome(icon: false)
                }
            } header: {
                SettingsSectionHeader("Orbit 多主动")
            } footer: {
                SettingsFooter("主动只是提醒和建议；花钱、对外发送这类事，仍然只在你明确要求或批准后才做。")
            }
            .textCase(nil)

            Section {
                Stepper(value: Binding {
                    model.settings.heartbeatMinutes
                } set: { model.updateSettings(["heartbeatMinutes": .number(Double($0))]) }, in: 5...240, step: 5) {
                    SettingsRowLabel(title: "检查频率", value: "每 \(model.settings.heartbeatMinutes) 分钟")
                }
                .settingsRowChrome(icon: false)
            } header: {
                SettingsSectionHeader("检查频率")
            } footer: {
                SettingsFooter("Orbit 每隔这么久看一眼有没有需要处理的事，比如很久没有进展的任务、快到的日程。安静时段内不检查。")
            }
            .textCase(nil)

            NotificationPermissionSection()
        }
        .settingsListChrome()
        .navigationTitle("主动程度")
        .navigationBarTitleDisplayMode(.inline)
    }

    private static func explanation(_ level: Settings.Proactivity) -> String {
        switch level {
        case .low: "只在任务有结果、或事情有时效时才开口。"
        case .normal: "默认。需要时提醒你，也会跟进等你回复的任务。"
        case .high: "更主动地提出建议和跟进，也可能多打扰你几次。"
        }
    }
}

// MARK: - 安静时段

struct QuietHoursView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        List {
            Section {
                DatePicker(selection: time(start: true), displayedComponents: .hourAndMinute) {
                    Text("开始").font(.orbitBody).foregroundStyle(Color.ink)
                }
                .settingsRowChrome(icon: false)
                DatePicker(selection: time(start: false), displayedComponents: .hourAndMinute) {
                    Text("结束").font(.orbitBody).foregroundStyle(Color.ink)
                }
                .settingsRowChrome(icon: false)
            } footer: {
                SettingsFooter(summary)
            }
            .textCase(nil)

            NotificationPermissionSection()
        }
        .settingsListChrome()
        .navigationTitle("安静时段")
        .navigationBarTitleDisplayMode(.inline)
    }

    private var summary: String {
        let quiet = model.settings.quietHours
        let overnight = quiet.start >= quiet.end
        return "每天 \(quiet.start) 到\(overnight ? "次日 " : "")\(quiet.end) 是安静时段：Orbit 不推送通知，也不主动检查；紧急事项除外。"
    }

    private func time(start: Bool) -> Binding<Date> {
        Binding {
            QuietTime.date(from: start ? model.settings.quietHours.start : model.settings.quietHours.end)
        } set: { date in
            model.updateSettings(["quietHours": [start ? "start" : "end": .string(QuietTime.text(from: date))]])
        }
    }
}

// MARK: - 系统通知

/// Whether this phone lets Orbit's notifications through. Confirm requests and Orbit's own messages reach the lock
/// screen as pushes; with notifications off they are only seen once the app is open. The decision is the system's:
/// before it is made the button asks (the system prompt appears once), after a "no" it leads to the system settings.
struct NotificationPermissionSection: View {
    @Environment(AppModel.self) private var model
    @Environment(\.openURL) private var openURL

    var body: some View {
        let permission = model.pushPermission
        Section {
            SettingsRowLabel(systemImage: "bell.badge", title: "推送通知", subtitle: Self.explanation(permission),
                             subtitleTone: permission == .denied ? .warning : .normal, value: Self.status(permission))
                .settingsRowChrome()
                .task { await model.refreshPushPermission() }
            switch permission {
            case .notDetermined:
                Button { Task { await model.refreshPushPermission(ask: true) } } label: {
                    Label("开启通知", systemImage: "bell").font(.orbitBody).foregroundStyle(Color.accentText)
                }
                .settingsRowChrome(icon: false)
            case .denied:
                Button(action: openSystemSettings) {
                    Label("去系统设置开启", systemImage: "gearshape").font(.orbitBody).foregroundStyle(Color.accentText)
                }
                .settingsRowChrome(icon: false)
            case .authorized, .provisional, .ephemeral, nil:
                EmptyView()
            }
        } header: {
            SettingsSectionHeader("系统通知")
        } footer: {
            if permission == .denied {
                SettingsFooter("在系统设置里打开通知后回到这里，Orbit 会自动接上。")
            }
        }
        .textCase(nil)
    }

    private func openSystemSettings() {
        if let url = URL(string: UIApplication.openSettingsURLString) { openURL(url) }
    }

    private static func status(_ permission: NotificationPermission?) -> String? {
        switch permission {
        case .authorized, .ephemeral: "已开启"
        case .provisional: "静默送达"
        case .denied: "已关闭"
        case .notDetermined: "未开启"
        case nil: nil
        }
    }

    private static func explanation(_ permission: NotificationPermission?) -> String? {
        switch permission {
        case .authorized, .ephemeral: "需要你确认的事和 Orbit 的主动消息，会推送到锁屏。"
        case .provisional: "通知会悄悄放进通知中心，不会在锁屏上弹出。"
        case .notDetermined: "开启后，需要你确认的事和 Orbit 的主动消息才能推送到锁屏。"
        case .denied: "已在系统设置里关闭，Orbit 没法把确认请求推送到锁屏。"
        case nil: nil
        }
    }
}

/// "HH:mm" (what the Mac stores) ⇄ a `Date` for the time picker.
enum QuietTime {
    static func date(from text: String, calendar: Calendar = .current, reference: Date = Date()) -> Date {
        let parts = text.split(separator: ":").compactMap { Int($0) }
        let hour = parts.first ?? 0
        let minute = parts.count > 1 ? parts[1] : 0
        return calendar.date(bySettingHour: min(max(hour, 0), 23), minute: min(max(minute, 0), 59), second: 0, of: reference) ?? reference
    }

    static func text(from date: Date, calendar: Calendar = .current) -> String {
        let parts = calendar.dateComponents([.hour, .minute], from: date)
        return String(format: "%02d:%02d", parts.hour ?? 0, parts.minute ?? 0)
    }
}
