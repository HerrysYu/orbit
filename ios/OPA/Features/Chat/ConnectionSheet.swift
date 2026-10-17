import SwiftUI

/// "连接详情": opened from the connection control in the chat header. Which Mac, the
/// state and path of the connection, when it was last connected, and what happens to messages while the Mac is
/// away. Mounted by the root view (`model.showConnection`).
struct ConnectionSheet: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        let info = model.connectionInfo
        ScrollView {
            VStack(spacing: Space.l) {
                header(info)
                KeyValueList(rows: rows(info))
                notes(info)
                actions(info)
            }
            .padding(.horizontal, Space.xl)
            .padding(.top, Space.xxl)
            .padding(.bottom, Space.xxl)
        }
        .scrollBounceBehavior(.basedOnSize)
        .presentationDetents([.medium, .large])
        .presentationDragIndicator(.visible)
        .presentationBackground(Color.surface)
    }

    // MARK: Header

    private func header(_ info: ConnectionInfo) -> some View {
        VStack(spacing: 6) {
            // The state is in the line below (a dot and a word), so the icon needs no mark and no fill of its own.
            Image(systemName: "laptopcomputer")
                .symbolRenderingMode(.monochrome)
                .font(.system(size: 30, weight: .regular))
                .foregroundStyle(Color.inkSecondary)
                .frame(width: 54, height: 54)
                .accessibilityHidden(true)
            Text(hostName(info))
                .font(.system(.title2, weight: .semibold))
                .foregroundStyle(Color.ink)
                .multilineTextAlignment(.center)
                .padding(.top, 4)
            StatusChip(kind: chipKind(info), text: headline(info))
        }
        .frame(maxWidth: .infinity)
        .accessibilityElement(children: .combine)
    }

    private func hostName(_ info: ConnectionInfo) -> String {
        if let name = info.hostName?.trimmingCharacters(in: .whitespacesAndNewlines), !name.isEmpty { return name }
        return model.isDemo ? "演示 Mac" : "你的 Mac"
    }

    /// The short state in the chip.
    private func headline(_ info: ConnectionInfo) -> String {
        switch info.state {
        case .connected: "已连接"
        case .hostOffline: "Mac 离线"
        case .failed: "连接失败"
        case .waitingRetry: "稍后重试"
        case .idle, .connecting, .handshaking, .awaitingPairConfirm: "连接中…"
        }
    }

    private func chipKind(_ info: ConnectionInfo) -> StatusKind {
        switch info.state {
        case .connected: .ok
        case .hostOffline, .waitingRetry: .waiting
        case .failed: .failed
        case .idle, .connecting, .handshaking, .awaitingPairConfirm: .planning
        }
    }

    // MARK: Rows

    private func rows(_ info: ConnectionInfo) -> [(String, String)] {
        var rows: [(String, String)] = []
        switch info.state {
        case .connected(let path):
            rows.append(("状态", "已连接"))
            rows.append(("路径", ChatFormat.pathName(path)))
            if let connectedAt = info.lastConnectedAt { rows.append(("连接于", Fmt.dateTime(Clock.ms(connectedAt)))) }
        default:
            rows.append(("状态", info.state.label))
            if let connectedAt = info.lastConnectedAt { rows.append(("上次连接", Fmt.dateTime(Clock.ms(connectedAt)))) }
            if let seen = info.lastSeenOnlineAt { rows.append(("最后在线", Presence.ago(seen, now: Date()) + "在线")) }
        }
        let queued = model.queuedMessageCount
        if queued > 0 { rows.append(("待发送", "\(queued) 条消息")) }
        if model.isDemo { rows.append(("模式", "演示（示例数据）")) }
        return rows
    }

    // MARK: Notes

    @ViewBuilder
    private func notes(_ info: ConnectionInfo) -> some View {
        switch info.state {
        case .connected:
            EmptyView()
        case .failed(let message):
            NoteBlock(kind: .danger, systemImage: "exclamationmark.circle") { Text(message) }
            offlineNote
        case .hostOffline, .waitingRetry:
            offlineNote
        case .idle, .connecting, .handshaking, .awaitingPairConfirm:
            EmptyView()
        }
    }

    private var offlineNote: some View {
        NoteBlock(kind: .warn, systemImage: "clock") {
            Text("消息会排队；Mac 离线不代表任务停止。连上后消息会自动发出，进行中的任务也会同步最新状态。")
        }
    }

    // MARK: Actions

    private func actions(_ info: ConnectionInfo) -> some View {
        VStack(spacing: 10) {
            if !info.state.isConnected {
                let connecting = isConnecting(info)
                Button {
                    model.connectionManager.kick()
                } label: {
                    HStack(spacing: Space.s) {
                        if connecting { ProgressView().controlSize(.small).tint(Color.onPrimary) }
                        Text(connecting ? "正在连接…" : "重新连接")
                    }
                }
                .buttonStyle(.orbit(.primary))
                .disabled(connecting)
            }
            Button("管理设备") {
                model.showConnection = false
                model.selectedTab = .settings
            }
            .buttonStyle(.orbit(.inset))
        }
        .padding(.top, Space.xs)
    }

    private func isConnecting(_ info: ConnectionInfo) -> Bool {
        switch info.state {
        case .connecting, .handshaking, .awaitingPairConfirm: true
        default: false
        }
    }
}
