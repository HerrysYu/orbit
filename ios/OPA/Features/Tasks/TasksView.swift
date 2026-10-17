import SwiftUI

// MARK: - Tasks tab

/// The tasks tab as three grouped lists: 等你处理 (approvals to confirm, questions to answer, blocked tasks), 进行中,
/// and 已结束 behind one row that opens it.
///
/// Every task is in exactly one group (see `AppModel+Tasks`). The NavigationStack (path: `model.tasksPath`) belongs to
/// `MainTabView`; this view only fills it, and a row pushes the detail page through `model.openTask`.
///
/// It is a plain `List` (swipe to clear, pull to refresh) whose rows draw their own slice of the group's card: Surface
/// fill, 0.5 pt Hairline, no shadow. No chips, no stripes at the side, no thick bars: a state is a 6 pt dot and a word,
/// an action is Accent text at the end of the row, progress is one 2 pt line.
struct TasksView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    /// Whether 已结束 shows its tasks (the group opens with one row: "显示已结束的任务").
    @State private var showsFinished = TasksView.initialShowsFinished

    var body: some View {
        let attention = model.attentionItems
        let active = model.activeTasks
        let finished = model.finishedTasks
        let isEmpty = attention.isEmpty && active.isEmpty && finished.isEmpty
        // Changes whenever a row enters, leaves or moves, including the ones that come from a clock (an approval expiring).
        let layoutKey = attention.map(\.id) + active.map(\.id) + finished.map(\.id) + [showsFinished ? "open" : "closed"]
        // The first group sits close under the large title.
        let first: ListGroup = !attention.isEmpty ? .attention : !active.isEmpty ? .active : .finished

        Group {
            if isEmpty {
                TasksEmptyState { model.selectedTab = .chat }
            } else {
                List {
                    if !attention.isEmpty {
                        groupHeader("等你处理", count: attention.count, isFirst: first == .attention)
                        Section {
                            ForEach(Array(attention.enumerated()), id: \.element.id) { index, item in
                                AttentionRow(item: item).cardRow(at: index, of: attention.count)
                            }
                        }
                    }
                    if !active.isEmpty {
                        groupHeader("进行中", count: active.count, isFirst: first == .active)
                        Section {
                            ForEach(Array(active.enumerated()), id: \.element.id) { index, task in
                                ActiveTaskRow(task: task).cardRow(at: index, of: active.count)
                            }
                        }
                    }
                    if !finished.isEmpty {
                        let rows = showsFinished ? finished.count + 1 : 1
                        groupHeader("已结束", count: finished.count, isFirst: first == .finished)
                        Section {
                            FinishedToggleRow(count: finished.count, expanded: showsFinished, toggle: toggleFinished)
                                .cardRow(at: 0, of: rows)
                            if showsFinished {
                                ForEach(Array(finished.enumerated()), id: \.element.id) { index, task in
                                    FinishedTaskRow(task: task).cardRow(at: index + 1, of: rows)
                                }
                            }
                        }
                    }
                }
                .listStyle(.plain)
                .scrollContentBackground(.hidden)
                .listSectionSeparator(.hidden)
                .listSectionSpacing(.custom(0))
                .environment(\.defaultMinListRowHeight, 1)
                .animation(MotionAware(reduce: reduceMotion).spring, value: layoutKey)
                .transaction { transaction in
                    // Core animates its own changes with a spring; under Reduce Motion that becomes the short fade.
                    if reduceMotion, transaction.animation != nil { transaction.animation = Motion.fade }
                }
            }
        }
        .background(Color.canvas)
        .navigationTitle("任务")
        .navigationBarTitleDisplayMode(.large)
        .toolbar { ConnectionToolbarItem(state: model.connection) { model.showConnection = true } }
        .refreshable { await refresh() }
    }

    private enum ListGroup { case attention, active, finished }

    /// `-OPATasksFinished YES` opens 已结束 right away (screenshots). Release builds always start closed.
    private static var initialShowsFinished: Bool {
        #if DEBUG
        return UserDefaults.standard.bool(forKey: "OPATasksFinished")
        #else
        return false
        #endif
    }

    private func toggleFinished() {
        withAnimation(MotionAware(reduce: reduceMotion).spring) { showsFinished.toggle() }
    }

    /// A group title above its card. It is a row of its own (clear, no separator) so that it sits 6 pt in from the card's
    /// edge whatever insets the system gives list headers on the running OS version.
    private func groupHeader(_ title: String, count: Int, isFirst: Bool) -> some View {
        Section {
            SectionHeader(title: title, count: count)
                .listRowInsets(EdgeInsets(top: isFirst ? 4 : 22, leading: Space.l, bottom: 6, trailing: Space.l))
                .listRowBackground(Color.clear)
                .listRowSeparator(.hidden)
        }
    }

    /// Pull to refresh: reconnect right away when the Mac was unreachable (the reconnect syncs missed events), and
    /// otherwise let the heartbeat probe the connection. Events arrive live, so there is nothing else to fetch.
    private func refresh() async {
        guard !model.isDemo else { return }
        model.connectionManager.kick()
        let deadline = ContinuousClock.now + .seconds(3)
        while !model.connection.isConnected, ContinuousClock.now < deadline {
            try? await Task.sleep(for: .milliseconds(150))
        }
    }
}

/// The connection button in the navigation bar. It draws no background of its own, so on iOS 26 the bar's automatic
/// backing for toolbar items is switched off (otherwise the icon sits in a capsule).
private struct ConnectionToolbarItem: ToolbarContent {
    var state: ConnectionState
    var action: () -> Void

    var body: some ToolbarContent {
        if #available(iOS 26.0, *) {
            ToolbarItem(placement: .topBarTrailing) {
                ConnectionIndicator(state: state, action: action)
            }
            .sharedBackgroundVisibility(.hidden)
        } else {
            ToolbarItem(placement: .topBarTrailing) {
                ConnectionIndicator(state: state, action: action)
            }
        }
    }
}

// MARK: - Card rows

/// Where a row sits in its group's card.
private enum CardPosition {
    case only, first, middle, last

    init(index: Int, count: Int) {
        if count <= 1 { self = .only }
        else if index == 0 { self = .first }
        else if index == count - 1 { self = .last }
        else { self = .middle }
    }

    var hasTop: Bool { self == .only || self == .first }
    var hasBottom: Bool { self == .only || self == .last }
}

/// One row's slice of its group's card: Surface, a 0.5 pt Hairline at the sides (and across the top of the first row and
/// the bottom of the last), the corners rounded where the card has them, and a Hairline between rows that starts 14 pt in.
/// The page margin is part of the slice, so the row itself runs edge to edge.
private struct CardSlice: View {
    var position: CardPosition

    var body: some View {
        let top = position.hasTop, bottom = position.hasBottom
        let radius = Radius.card
        let shape = UnevenRoundedRectangle(topLeadingRadius: top ? radius : 0,
                                           bottomLeadingRadius: bottom ? radius : 0,
                                           bottomTrailingRadius: bottom ? radius : 0,
                                           topTrailingRadius: top ? radius : 0,
                                           style: .continuous)
        GeometryReader { proxy in
            // Where the card goes on, the shape is drawn past the row and clipped, so its edge line falls outside and
            // neighbouring slices join without a seam.
            shape
                .fill(Color.surface)
                .overlay { shape.strokeBorder(Color.hairline, lineWidth: 0.5) }
                .frame(width: proxy.size.width, height: proxy.size.height + (top ? 0 : 2) + (bottom ? 0 : 2))
                .offset(y: top ? 0 : -2)
        }
        .clipped()
        .overlay(alignment: .top) {
            if !top {
                Rectangle().fill(Color.hairline).frame(height: 0.5).padding(.leading, 14)
            }
        }
        .padding(.horizontal, Space.l)
    }
}

/// Row text sizes. Dynamic Type scales all of them.
private enum RowFont {
    /// Row title: 17 / 22 medium.
    static let title = Font.system(.body, weight: .medium)
    /// A quieter title (finished tasks, the "显示已结束的任务" row): 17 / 22 regular.
    static let quietTitle = Font.system(.body)
    /// The goal under a title: 15 / 20.
    static let goal = Font.system(.subheadline)
    /// Description, status and time lines: 13 / 18.
    static let meta = Font.system(.footnote)
    /// The text button at the end of a row ("查看", "回答", "处理", "清除"): 15 medium.
    static let action = Font.system(.subheadline, weight: .medium)
}

private extension View {
    /// A row of a grouped list: it draws its own slice of the card (no system row chrome).
    func cardRow(at index: Int, of count: Int) -> some View {
        listRowInsets(EdgeInsets())
            .listRowBackground(CardSlice(position: CardPosition(index: index, count: count)))
            .listRowSeparator(.hidden)
    }

    /// The padding of a row's content: the page margin plus the card's 14 pt, 12 pt above and below, 48 pt tall at least.
    func cardRowPadding() -> some View {
        padding(.vertical, 12)
            .padding(.horizontal, Space.l + 14)
            .frame(maxWidth: .infinity, minHeight: 48, alignment: .leading)
    }
}

/// The text at the end of a row that is itself the button ("查看", "处理"): Accent, 15 medium.
private struct RowActionLabel: View {
    var title: String

    var body: some View {
        Text(verbatim: title)
            .font(RowFont.action)
            .foregroundStyle(Color.accentText)
            .accessibilityHidden(true)
    }
}

/// The 2 pt line under a running task: Hairline track, Accent fill, steps done out of all steps. No number beside it.
private struct TaskProgressLine: View {
    var fraction: Double
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        Capsule()
            .fill(Color.hairline)
            .frame(height: 2)
            .overlay(alignment: .leading) {
                GeometryReader { proxy in
                    Capsule().fill(Color.accentText).frame(width: proxy.size.width * fraction)
                }
            }
            .animation(MotionAware(reduce: reduceMotion).snappy, value: fraction)
            .accessibilityHidden(true)
    }
}

// MARK: - 等你处理

private struct AttentionRow: View {
    let item: AttentionItem

    var body: some View {
        switch item {
        case .approval(let approval): ApprovalAttentionRow(approval: approval)
        case .task(let task):
            if task.status == .blocked { BlockedAttentionRow(task: task) } else { QuestionAttentionRow(task: task) }
        }
    }
}

/// A pending approval: tap anywhere to open the confirm sheet. "提交这家餐厅的预订 / 中风险 · 28 分钟后过期 / 查看".
private struct ApprovalAttentionRow: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dynamicTypeSize) private var typeSize
    let approval: Approval

    var body: some View {
        let stacked = typeSize.isAccessibilitySize
        let layout = stacked ? AnyLayout(VStackLayout(alignment: .leading, spacing: Space.s)) : AnyLayout(HStackLayout(spacing: Space.m))
        Button { model.openApproval(approval.id) } label: {
            layout {
                VStack(alignment: .leading, spacing: 1) {
                    Text(verbatim: approval.title)
                        .font(RowFont.title)
                        .foregroundStyle(Color.ink)
                        .lineLimit(stacked ? nil : 2)
                        .multilineTextAlignment(.leading)
                    subline(stacked: stacked)
                }
                if !stacked { Spacer(minLength: Space.s) }
                RowActionLabel(title: "查看")
            }
            .cardRowPadding()
            .contentShape(.rect)
        }
        .buttonStyle(DimPressStyle())
        .accessibilityElement(children: .combine)
        .accessibilityHint("查看并确认")
    }

    /// "中风险 · 28 分钟后过期": the risk word in its color, then the time left on the Mac's clock (else a summary).
    private func subline(stacked: Bool) -> some View {
        TimelineView(.periodic(from: .now, by: 15)) { context in
            let risk = Text(verbatim: ApprovalCopy.riskLabel(approval.risk)).foregroundStyle(approval.risk.tint)
            Text("\(risk)\(tail(now: context.date))")
                .font(RowFont.meta)
                .foregroundStyle(Color.inkSecondary)
                .lineLimit(stacked ? nil : 1)
                .multilineTextAlignment(.leading)
        }
    }

    private func tail(now: Date) -> String {
        if let expiresAt = approval.expiresAt {
            return " · " + ApprovalCopy.expiry(remainingMs: expiresAt - (Clock.ms(now) + model.hostClockOffsetMs))
        }
        if let summary = ApprovalContent(approval: approval).summary { return " · " + summary }
        return ""
    }
}

/// A task waiting for your answer: the row opens the task, "回答" jumps to the conversation where the question is.
private struct QuestionAttentionRow: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dynamicTypeSize) private var typeSize
    let task: OPATask

    var body: some View {
        let info = TaskInfo(task: task, model: model)
        let stacked = typeSize.isAccessibilitySize
        let layout = stacked ? AnyLayout(VStackLayout(alignment: .leading, spacing: 0)) : AnyLayout(HStackLayout(spacing: 0))
        layout {
            Button { model.openTask(task.id) } label: {
                VStack(alignment: .leading, spacing: 1) {
                    Text(verbatim: info.displayTitle)
                        .font(RowFont.title)
                        .foregroundStyle(Color.ink)
                        .lineLimit(stacked ? nil : 2)
                        .multilineTextAlignment(.leading)
                    if let question = info.question {
                        Text(verbatim: question)
                            .font(RowFont.meta)
                            .foregroundStyle(Color.inkSecondary)
                            .lineLimit(stacked ? nil : 1)
                            .multilineTextAlignment(.leading)
                    }
                }
                .padding(.vertical, 12)
                .padding(.leading, Space.l + 14)
                .padding(.trailing, stacked ? Space.l + 14 : Space.s)
                .frame(maxWidth: .infinity, minHeight: 48, alignment: .leading)
                .contentShape(.rect)
            }
            .buttonStyle(DimPressStyle())
            .accessibilityHint("打开任务详情")

            Button { model.selectedTab = .chat } label: {
                Text("回答")
                    .font(RowFont.action)
                    .foregroundStyle(Color.accentText)
                    .padding(.leading, stacked ? Space.l + 14 : Space.s)
                    .padding(.trailing, Space.l + 14)
                    .frame(minHeight: 48)
                    .contentShape(.rect)
            }
            .buttonStyle(DimPressStyle())
            .accessibilityLabel("回答：\(info.displayTitle)")
            .accessibilityHint("回到对话回答这个问题")
        }
    }
}

/// A blocked task: "遇到阻碍" (Danger dot and word) and what it needs, then "处理", which opens the task.
private struct BlockedAttentionRow: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dynamicTypeSize) private var typeSize
    let task: OPATask

    var body: some View {
        let info = TaskInfo(task: task, model: model)
        let stacked = typeSize.isAccessibilitySize
        let layout = stacked ? AnyLayout(VStackLayout(alignment: .leading, spacing: Space.s)) : AnyLayout(HStackLayout(spacing: Space.m))
        Button { model.openTask(task.id) } label: {
            layout {
                VStack(alignment: .leading, spacing: 1) {
                    Text(verbatim: info.displayTitle)
                        .font(RowFont.title)
                        .foregroundStyle(Color.ink)
                        .lineLimit(stacked ? nil : 2)
                        .multilineTextAlignment(.leading)
                    reason(info, stacked: stacked)
                }
                if !stacked { Spacer(minLength: Space.s) }
                RowActionLabel(title: "处理")
            }
            .cardRowPadding()
            .contentShape(.rect)
        }
        .buttonStyle(DimPressStyle())
        .accessibilityElement(children: .combine)
        .accessibilityHint("打开任务详情")
    }

    /// "● 遇到阻碍 · 需要你在安卓手机上完成微信登录验证…": the dot rides inside the text, so a second line wraps under it.
    private func reason(_ info: TaskInfo, stacked: Bool) -> some View {
        let dot = Text(Image(systemName: "circle.fill")).font(.system(size: 6)).foregroundStyle(Color.danger).baselineOffset(2)
        let word = Text(verbatim: OPATask.Status.blocked.label).foregroundStyle(Color.danger)
        let because = info.blockedReason.map { " · " + $0 } ?? ""
        return Text("\(dot) \(word)\(because)")
            .font(RowFont.meta)
            .foregroundStyle(Color.inkSecondary)
            .lineLimit(stacked ? nil : 2)
            .multilineTextAlignment(.leading)
    }
}

// MARK: - 进行中

/// A running (or planning) task: title, goal, "2/4 步 · 3 分钟前" and the 2 pt line under them.
private struct ActiveTaskRow: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dynamicTypeSize) private var typeSize
    let task: OPATask

    var body: some View {
        let info = TaskInfo(task: task, model: model)
        let stacked = typeSize.isAccessibilitySize
        Button { model.openTask(task.id) } label: {
            VStack(alignment: .leading, spacing: 0) {
                Text(verbatim: info.displayTitle)
                    .font(RowFont.title)
                    .foregroundStyle(Color.ink)
                    .lineLimit(stacked ? nil : 2)
                    .multilineTextAlignment(.leading)
                if let goal = TaskText.clean(task.goal) ?? info.currentAction {
                    Text(verbatim: goal)
                        .font(RowFont.goal)
                        .foregroundStyle(Color.inkSecondary)
                        .lineLimit(stacked ? nil : 1)
                        .multilineTextAlignment(.leading)
                        .padding(.top, 2)
                }
                meta(info)
                    .padding(.top, 6)
                if let fraction = info.progressFraction {
                    TaskProgressLine(fraction: fraction)
                        .padding(.top, 10)
                }
            }
            .cardRowPadding()
            .contentShape(.rect)
        }
        .buttonStyle(DimPressStyle())
        .accessibilityElement(children: .combine)
        .accessibilityHint("打开任务详情")
    }

    /// "● 2/4 步 · 3 分钟前". The dot is Accent while the task runs (or waits for a confirmation, which 等你处理 lists);
    /// a word comes first only while it is not under way yet or is being stopped ("规划中 · 3 分钟前更新").
    private func meta(_ info: TaskInfo) -> some View {
        let kind = info.chip.kind
        return HStack(alignment: .firstTextBaseline, spacing: 6) {
            MetaDot(color: Self.dotColor(kind))
            TaskMinuteText { now in
                [info.rowStatusWord, info.progressLine(now: now)].compactMap { $0 }.joined(separator: " · ")
            }
            .font(RowFont.meta.monospacedDigit())
            .foregroundStyle(Color.inkTertiary)
            .lineLimit(typeSize.isAccessibilitySize ? nil : 1)
            .multilineTextAlignment(.leading)
        }
    }

    static func dotColor(_ kind: StatusKind) -> Color {
        switch kind {
        case .running, .waiting: .accentText
        case .blocked, .failed: .danger
        case .done, .ok: .success
        case .planning, .cancelled, .draft: .inkTertiary
        }
    }
}

/// A 6 pt dot level with the first line of 13 pt text next to it (same placement as `DotLabel`).
private struct MetaDot: View {
    var color: Color
    @ScaledMetric(relativeTo: .footnote) private var lift: CGFloat = 4.8

    var body: some View {
        let lift = lift
        Circle()
            .fill(color)
            .frame(width: 6, height: 6)
            .alignmentGuide(.firstTextBaseline) { $0[VerticalAlignment.center] + lift }
            .accessibilityHidden(true)
    }
}

// MARK: - 已结束

/// The one row of 已结束 while it is closed: "显示已结束的任务" opens the list, "清除" clears all of it (after asking).
private struct FinishedToggleRow: View {
    let count: Int
    let expanded: Bool
    let toggle: () -> Void

    var body: some View {
        HStack(spacing: 0) {
            Button(action: toggle) {
                Text(expanded ? "隐藏已结束的任务" : "显示已结束的任务")
                    .font(RowFont.quietTitle)
                    .foregroundStyle(Color.ink)
                    .padding(.vertical, 12)
                    .padding(.leading, Space.l + 14)
                    .frame(maxWidth: .infinity, minHeight: 48, alignment: .leading)
                    .contentShape(.rect)
            }
            .buttonStyle(DimPressStyle())
            .accessibilityValue(expanded ? "已展开" : "已收起")
            ClearFinishedButton(count: count)
        }
    }
}

/// A finished task: title and "昨天 · 已完成" under it. Swipe left to clear it from the list.
private struct FinishedTaskRow: View {
    @Environment(AppModel.self) private var model
    @Environment(\.colorScheme) private var scheme
    @Environment(\.dynamicTypeSize) private var typeSize
    let task: OPATask

    var body: some View {
        let title = TaskText.clean(task.title) ?? "未命名任务"
        Button { model.openTask(task.id) } label: {
            VStack(alignment: .leading, spacing: 1) {
                Text(verbatim: title)
                    .font(RowFont.quietTitle)
                    .foregroundStyle(Color.ink)
                    .lineLimit(typeSize.isAccessibilitySize ? nil : 2)
                    .multilineTextAlignment(.leading)
                TaskMinuteText { now in TaskTime.finishedLine(status: task.status, updatedAt: task.updatedAt, now: now) }
                    .font(RowFont.meta)
                    .foregroundStyle(Color.inkSecondary)
                    .lineLimit(typeSize.isAccessibilitySize ? nil : 1)
                    .multilineTextAlignment(.leading)
            }
            .cardRowPadding()
            .contentShape(.rect)
        }
        .buttonStyle(DimPressStyle())
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(task.status.label)，\(title)，\(TaskTime.when(task.updatedAt))")
        .accessibilityHint("打开任务详情")
        .swipeActions(edge: .trailing, allowsFullSwipe: false) {
            Button(role: .destructive) {
                Task { await model.clearTask(id: task.id) }
            } label: {
                Label("清除", systemImage: "trash")
            }
            // The action's label is always white: Danger in light mode, the system red in dark mode (the Danger token
            // is a light salmon there, too pale to carry white text).
            .tint(scheme == .dark ? Color.red : Color.danger)
        }
    }
}

/// "清除" at the end of the 已结束 row: asks first, then removes every finished task and says how many went.
private struct ClearFinishedButton: View {
    @Environment(AppModel.self) private var model
    let count: Int
    @State private var confirming = false

    var body: some View {
        Button { confirming = true } label: {
            Text("清除")
                .font(RowFont.action)
                .foregroundStyle(Color.accentText)
                .padding(.horizontal, 14)
                .padding(.trailing, Space.l)
                .frame(minHeight: 48)
                .contentShape(.rect)
        }
        .buttonStyle(DimPressStyle())
        .accessibilityLabel("清除已结束的任务")
        .confirmationDialog("清除 \(count) 个已结束的任务？", isPresented: $confirming, titleVisibility: .visible) {
            Button("清除 \(count) 个任务", role: .destructive) { clear() }
            Button("取消", role: .cancel) {}
        } message: {
            Text("清除后无法恢复。")
        }
    }

    private func clear() {
        Task {
            let removed = await model.clearFinishedTasks()
            if removed > 0 { model.showToast("已清除 \(removed) 个任务") }
        }
    }
}

// MARK: - Empty

private struct TasksEmptyState: View {
    var goChat: () -> Void

    var body: some View {
        ScrollView {
            VStack(spacing: 0) {
                OrbitMascot(pose: .attentive, size: 96)
                Text("这里会记录我替你做的事")
                    .font(.system(.title3, weight: .semibold))
                    .foregroundStyle(Color.ink)
                    .multilineTextAlignment(.center)
                    .padding(.top, 18)
                Text("进行中、等你确认和已完成的任务都会出现在这里。")
                    .font(.orbitSecondary)
                    .foregroundStyle(Color.inkSecondary)
                    .multilineTextAlignment(.center)
                    .lineSpacing(3)
                    .padding(.top, 6)
                    .padding(.horizontal, 40)
                Button(action: goChat) {
                    Label("去聊聊", systemImage: "bubble.left")
                }
                .buttonStyle(.orbit(.soft, size: .small))
                .padding(.top, 14)
            }
            .frame(maxWidth: .infinity)
            .containerRelativeFrame(.vertical) { height, _ in height * 0.72 }
        }
        .scrollBounceBehavior(.basedOnSize)
    }
}

#if DEBUG
#Preview {
    let model = AppModel(inMemory: true)
    model.enterDemo()
    return NavigationStack { TasksView() }.environment(model)
}
#endif
