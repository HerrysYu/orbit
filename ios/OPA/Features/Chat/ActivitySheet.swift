import SwiftUI

/// "活动与权限": opened from the avatar in the chat header. What Orbit is doing right now (the tasks it is working
/// on), what waits for your confirmation, what it finished lately, and what it may do on the Mac and on the Android
/// phone, in plain words. Everything shown comes from live state; nothing is invented. What the work is made of (tool
/// calls, progress lines, session or model ids) is not part of it. Mounted by the root view (`model.showActivity`).
struct ActivitySheet: View {
    @Environment(AppModel.self) private var model
    @State private var detent: PresentationDetent = ActivitySheet.initialDetent

    var body: some View {
        let snapshot = ActivitySnapshot.make(sessions: model.sessions, tasks: model.tasks, approvals: model.pendingApprovals)
        ScrollView {
            VStack(spacing: 0) {
                header(snapshot)
                    // Clear of the drag indicator.
                    .padding(.top, Space.xxl)

                SectionHeader(title: "执行中")
                    .padding(.top, Space.l)
                    .padding(.bottom, Space.s)
                // A stack, not a Group: modifiers on a Group would be applied to every row separately.
                VStack(spacing: 0) {
                    if snapshot.runs.isEmpty {
                        emptyLine("现在没有进行中的事")
                    } else {
                        ForEach(Array(snapshot.runs.enumerated()), id: \.element.id) { index, run in
                            if index > 0 { divider }
                            RunRow(run: run) { if let id = run.taskId { model.openTask(id) } }
                        }
                    }
                }
                .boxed()

                if !snapshot.asks.isEmpty {
                    SectionHeader(title: "等你确认", count: snapshot.asks.count)
                        .padding(.top, Space.l)
                        .padding(.bottom, Space.s)
                    VStack(spacing: 0) {
                        ForEach(Array(snapshot.asks.enumerated()), id: \.element.id) { index, ask in
                            if index > 0 { divider }
                            NavRow(symbol: "hand.raised", title: ask.title, detail: ask.detail, hint: "查看并确认") {
                                model.openApproval(ask.id)
                            }
                        }
                    }
                    .boxed()
                }

                SectionHeader(title: "最近完成")
                    .padding(.top, Space.l)
                    .padding(.bottom, Space.s)
                if snapshot.finished.isEmpty {
                    Text("还没有完成的事")
                        .font(.subheadline)
                        .foregroundStyle(Color.inkSecondary)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.horizontal, Space.xs)
                } else {
                    VStack(alignment: .leading, spacing: 6) {
                        ForEach(snapshot.finished) { done in
                            DoneLine(done: done)
                        }
                    }
                    .padding(.horizontal, Space.xs)
                }

                SectionHeader(title: "我能做什么")
                    .padding(.top, Space.l)
                    .padding(.bottom, Space.s)
                VStack(spacing: 0) {
                    NavRow(symbol: "laptopcomputer", title: "Mac 上的操作", detail: macDetail, hint: "在设置中查看和调整", action: openSettings)
                    divider
                    NavRow(symbol: "iphone", title: "安卓手机上的操作", detail: "敏感点击自动执行，并记录在案", hint: "在设置中查看和调整", action: openSettings)
                }
                .boxed()
            }
            .padding(.horizontal, Space.xl)
            .padding(.bottom, Space.xxl)
        }
        .scrollBounceBehavior(.basedOnSize)
        .presentationDetents([.medium, .large], selection: $detent)
        .presentationDragIndicator(.visible)
        .presentationBackground(Color.surface)
    }

    /// Medium first (the chat stays visible behind it); `-OPAActivityLarge YES` opens it tall for screenshots.
    private static var initialDetent: PresentationDetent {
        #if DEBUG
        if UserDefaults.standard.bool(forKey: "OPAActivityLarge") { return .large }
        #endif
        return .medium
    }

    // MARK: Pieces

    private func header(_ snapshot: ActivitySnapshot) -> some View {
        VStack(spacing: 4) {
            ChatAvatar(size: 54)
            Text(snapshot.runs.isEmpty ? "\(model.chatBotName) 待命中" : "\(model.chatBotName) 正在做")
                .font(.system(.title2, weight: .semibold))
                .foregroundStyle(Color.ink)
                .padding(.top, 6)
            Text(subtitle(snapshot))
                .font(.footnote)
                .foregroundStyle(Color.inkSecondary)
                .multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity)
        .accessibilityElement(children: .combine)
    }

    private func subtitle(_ snapshot: ActivitySnapshot) -> String {
        let count = snapshot.runs.isEmpty ? "暂时没有进行中的事" : "\(snapshot.runs.count) 件事在进行"
        return count + " · " + connectionPhrase
    }

    private var connectionPhrase: String {
        switch model.connection {
        case .connected(let path): "Mac 已连接（\(ChatFormat.pathName(path))）"
        case .hostOffline, .failed: "Mac 离线"
        case .waitingRetry: "Mac 暂时离线，正在重试"
        case .idle, .connecting, .handshaking, .awaitingPairConfirm: "正在连接 Mac"
        }
    }

    /// Whether "完全访问" is on, in plain words (the setting itself: manual = off, auto = on).
    private var macDetail: String {
        switch model.settings.defaultPermission {
        case .manual: "完全访问未开启，重要操作会先问你"
        case .auto: "完全访问已开启，不再逐项询问"
        }
    }

    private var divider: some View {
        Rectangle().fill(Color.hairline).frame(height: 0.5).padding(.leading, 52)
    }

    private func emptyLine(_ text: String) -> some View {
        Text(text)
            .font(.subheadline)
            .foregroundStyle(Color.inkSecondary)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, Space.l)
            .padding(.vertical, Space.l)
    }

    /// Both rows go to settings: the permission and the phone live there.
    private func openSettings() {
        model.showActivity = false
        model.selectedTab = .settings
    }
}

// MARK: - Rows

/// "14:25  预订上海出差酒店". The time column grows with the text size; at accessibility sizes the time sits above
/// the text instead.
private struct DoneLine: View {
    @Environment(\.dynamicTypeSize) private var typeSize
    @ScaledMetric(relativeTo: .footnote) private var timeWidth: CGFloat = 44
    var done: ActivitySnapshot.Done

    var body: some View {
        Group {
            if typeSize.isAccessibilitySize {
                VStack(alignment: .leading, spacing: 2) { time; text }
            } else {
                HStack(alignment: .firstTextBaseline, spacing: Space.m) {
                    time.frame(width: timeWidth, alignment: .leading)
                    text
                }
            }
        }
        .accessibilityElement(children: .combine)
    }

    private var time: some View {
        Text(Fmt.time(done.ts))
            .font(.footnote)
            .monospacedDigit()
            .foregroundStyle(Color.inkTertiary)
            .lineLimit(1)
            .fixedSize()
    }

    private var text: some View {
        Text(verbatim: done.title)
            .font(.subheadline)
            .foregroundStyle(Color.inkSecondary)
            .frame(maxWidth: .infinity, alignment: .leading)
    }
}

private struct RunRow: View {
    @Environment(\.dynamicTypeSize) private var typeSize
    var run: ActivitySnapshot.Run
    var action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(alignment: .top, spacing: Space.m) {
                SymbolTile(symbol: run.isPhone ? "iphone" : (run.isMacWindow ? "display" : "laptopcomputer"))
                    .padding(.top, 2)
                VStack(alignment: .leading, spacing: 2) {
                    if typeSize.isAccessibilitySize {
                        VStack(alignment: .leading, spacing: 6) { title; StatusChip(kind: .running, text: "进行中", dot: true) }
                    } else {
                        HStack(alignment: .firstTextBaseline, spacing: Space.s) { title; StatusChip(kind: .running, text: "进行中", dot: true) }
                    }
                    if !run.detail.isEmpty {
                        Text(run.detail)
                            .font(.footnote)
                            .foregroundStyle(Color.inkSecondary)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                }
            }
            .padding(.horizontal, Space.l)
            .padding(.vertical, Space.m)
            .contentShape(.rect)
        }
        .buttonStyle(.pressable)
        .disabled(run.taskId == nil)
        .accessibilityElement(children: .combine)
        .accessibilityHint(run.taskId == nil ? "" : "查看任务")
    }

    private var title: some View {
        Text(run.title)
            .font(.system(.callout, weight: .semibold))
            .foregroundStyle(Color.ink)
            .frame(maxWidth: .infinity, alignment: .leading)
    }
}

/// A tappable row of a list box: glyph, title, a line of plain words under it, and a chevron.
private struct NavRow: View {
    var symbol: String
    var title: String
    var detail: String
    var hint: String
    var action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: Space.m) {
                SymbolTile(symbol: symbol)
                VStack(alignment: .leading, spacing: 2) {
                    Text(verbatim: title)
                        .font(.system(.callout))
                        .foregroundStyle(Color.ink)
                        .multilineTextAlignment(.leading)
                    if !detail.isEmpty {
                        Text(verbatim: detail)
                            .font(.footnote)
                            .foregroundStyle(Color.inkSecondary)
                            .lineLimit(2)
                            .multilineTextAlignment(.leading)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                Image(systemName: "chevron.right")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(Color.inkTertiary)
                    .accessibilityHidden(true)
            }
            .padding(.horizontal, Space.l)
            .padding(.vertical, Space.m)
            .contentShape(.rect)
        }
        .buttonStyle(.pressable)
        .accessibilityElement(children: .combine)
        .accessibilityHint(hint)
    }
}

/// A glyph in a 28 pt slot: a plain SF Symbol in InkSecondary, no tile behind it.
private struct SymbolTile: View {
    var symbol: String

    var body: some View {
        Image(systemName: symbol)
            .symbolRenderingMode(.monochrome)
            .font(.system(size: 14))
            .foregroundStyle(Color.inkSecondary)
            .frame(width: 28, height: 28)
            .accessibilityHidden(true)
    }
}

private extension View {
    /// The sheet's list box: Surface with a hairline outline, 22 pt corners.
    func boxed() -> some View {
        let shape = RoundedRectangle(cornerRadius: Radius.card, style: .continuous)
        return self
            .frame(maxWidth: .infinity)
            .background(Color.surface, in: shape)
            .clipShape(shape)
            .overlay { shape.strokeBorder(Color.hairline, lineWidth: 0.5) }
    }
}

// MARK: - Data

/// What the sheet lists, derived from live tasks, sessions and approvals. Only titles, steps and results: the process
/// text that execution sessions report (`lastActivity`, `session.progress`) is never read here.
struct ActivitySnapshot: Equatable {
    /// One task being worked on (or, rarely, a running session that belongs to no task).
    struct Run: Identifiable, Equatable {
        var id: String
        var title: String
        var isPhone: Bool
        var isMacWindow: Bool
        var taskId: String?
        /// "比较价格与退改政策 · 已完成 1 / 4 步": the step being worked on and how far the task is.
        var detail: String
    }

    /// A confirmation waiting for you.
    struct Ask: Identifiable, Equatable {
        var id: String
        var title: String
        /// The task it belongs to, else what it is about in a few words; may be empty.
        var detail: String
    }

    /// A task that finished well.
    struct Done: Identifiable, Equatable {
        var id: String
        var ts: Int64
        var title: String
    }

    var runs: [Run]
    var asks: [Ask]
    var finished: [Done]

    /// Running work (sessions whose task is still going, or that belong to no task), one row per task, newest first;
    /// pending confirmations, newest first; and the five tasks that finished most recently.
    static func make(sessions: [String: OPASession], tasks: [String: OPATask], approvals: [Approval]) -> ActivitySnapshot {
        func newestFirst(_ a: OPASession, _ b: OPASession) -> Bool {
            a.updatedAt != b.updatedAt ? a.updatedAt > b.updatedAt : a.id < b.id
        }
        var seenTasks = Set<String>()
        var runs: [Run] = []
        for session in sessions.values.sorted(by: newestFirst) where session.status == .running {
            let (sessionTitle, kind) = cleaned(session.title)
            if let taskId = session.taskId, let task = tasks[taskId] {
                guard task.status == .running || task.status == .planning, seenTasks.insert(taskId).inserted else { continue }
                runs.append(Run(id: "task:" + taskId, title: TaskText.clean(task.title) ?? sessionTitle,
                                isPhone: kind == .phone, isMacWindow: kind == .macWindow, taskId: taskId, detail: stepLine(task)))
            } else {
                runs.append(Run(id: "session:" + session.id, title: sessionTitle,
                                isPhone: kind == .phone, isMacWindow: kind == .macWindow, taskId: nil, detail: ""))
            }
        }
        let asks = approvals.map { approval -> Ask in
            let source = ApprovalSource.resolve(approval: approval, sessions: sessions, tasks: tasks)?.taskTitle
            return Ask(id: approval.id, title: TaskText.clean(approval.title) ?? "需要你确认",
                       detail: source ?? ApprovalContent(approval: approval).summary ?? "")
        }
        let finished = tasks.values
            .filter { $0.status == .done }
            .sorted { $0.updatedAt != $1.updatedAt ? $0.updatedAt > $1.updatedAt : $0.id < $1.id }
            .prefix(5)
            .map { Done(id: $0.id, ts: $0.updatedAt, title: TaskText.clean($0.title) ?? "未命名任务") }
        return ActivitySnapshot(runs: runs, asks: asks, finished: Array(finished))
    }

    /// "比较价格与退改政策 · 已完成 1 / 4 步": the step title and the step count, both from the task itself.
    private static func stepLine(_ task: OPATask) -> String {
        var parts: [String] = []
        if let title = task.currentStep.flatMap({ TaskText.clean($0.title) }) { parts.append(title) }
        if !task.steps.isEmpty { parts.append("已完成 \(task.doneCount) / \(task.steps.count) 步") }
        return parts.joined(separator: " · ")
    }

    private enum Where { case mac, phone, macWindow }

    /// A session title may start with 📱 (Android phone) or 🖥 (Mac graphical interface); the icon says it, so the
    /// emoji is dropped from the text.
    private static func cleaned(_ title: String) -> (String, Where) {
        let trimmed = title.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.hasPrefix("📱") { return (String(trimmed.dropFirst()).trimmingCharacters(in: .whitespaces), .phone) }
        if trimmed.hasPrefix("🖥") { return (String(trimmed.dropFirst()).trimmingCharacters(in: .whitespaces), .macWindow) }
        return (trimmed, .mac)
    }
}
