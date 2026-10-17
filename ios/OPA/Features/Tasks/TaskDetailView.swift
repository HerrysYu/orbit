import SwiftUI

// MARK: - Task detail

/// One task: state, goal, what it waits for, the step timeline, the outcome, and the ways out (back to the
/// conversation, cancel). Pushed through `model.tasksPath` (see `MainTabView`).
///
/// It speaks in titles, states, step counts and results. How the work is carried out (execution sessions, what they
/// log) is not part of it; a debug build can open that with `-OPAShowExecution YES` (see `ExecutionDebug`).
///
/// The page draws its own glass back / more buttons and hides the navigation bar; the system back gesture stays.
struct TaskDetailView: View {
    let taskId: String

    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.dynamicTypeSize) private var typeSize
    @ScaledMetric(relativeTo: .title2) private var titleSize: CGFloat = 22

    #if DEBUG
    @State private var presentedSession: OPASession?
    #endif
    @State private var confirmingCancel = false
    @State private var expandedSteps: Set<String> = []

    var body: some View {
        let motion = MotionAware(reduce: reduceMotion)
        Group {
            if let task = model.tasks[taskId] {
                ScrollView { content(TaskInfo(task: task, model: model), motion) }
                    .scrollBounceBehavior(.basedOnSize)
            } else {
                removedState
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color.canvas.ignoresSafeArea())
        .toolbar(.hidden, for: .navigationBar)
        .safeAreaInset(edge: .top, spacing: 0) { topBar }
        .animation(motion.spring, value: model.tasks[taskId])
        #if DEBUG
        .sheet(item: $presentedSession) { session in
            SessionDetailSheet(session: session)
        }
        #endif
        .confirmationDialog("取消这个任务？", isPresented: $confirmingCancel, titleVisibility: .visible) {
            Button("取消任务", role: .destructive) {
                let id = taskId
                Task { await model.cancelTask(id: id) }
            }
            Button("继续执行", role: .cancel) {}
        } message: {
            Text("会停止进行中的步骤，已完成的不会撤销。")
        }
        // One sheet at a time: when the root presents a global sheet (a confirm request), this page's own sheet and
        // dialog step aside.
        .onChange(of: globalSheetIsUp) { _, isUp in
            if isUp {
                #if DEBUG
                presentedSession = nil
                #endif
                confirmingCancel = false
            }
        }
    }

    private var globalSheetIsUp: Bool {
        model.presentedApprovalId != nil || model.showActivity || model.showConnection
    }

    /// The execution session behind a step, offered only to developers (`ExecutionDebug`); nil in every release build.
    private func executionSession(for step: TaskStep) -> OPASession? {
        #if DEBUG
        guard ExecutionDebug.isOn, let id = step.sessionId else { return nil }
        return model.sessions[id]
        #else
        return nil
        #endif
    }

    private func openExecution(_ session: OPASession) {
        #if DEBUG
        guard !globalSheetIsUp else { return }
        presentedSession = session
        #endif
    }

    // MARK: Top bar

    private var topBar: some View {
        HStack {
            GlassCircleButton(systemImage: "chevron.left", accessibilityLabel: "返回") { dismiss() }
            Spacer(minLength: Space.m)
            if let task = model.tasks[taskId] { moreMenu(task) }
        }
        .padding(.horizontal, Space.l)
        .padding(.top, Space.xs)
        .padding(.bottom, Space.s)
        .background {
            // Content scrolls under the buttons and the status bar: fade it out instead of cutting it.
            LinearGradient(stops: [.init(color: .canvas, location: 0), .init(color: .canvas, location: 0.7),
                                   .init(color: .canvas.opacity(0), location: 1)],
                           startPoint: .top, endPoint: .bottom)
                .ignoresSafeArea(edges: .top)
                .allowsHitTesting(false)
        }
    }

    private func moreMenu(_ task: OPATask) -> some View {
        Menu {
            if task.status.isActive {
                Button(role: .destructive) { confirmingCancel = true } label: {
                    Label("取消任务", systemImage: "xmark.circle")
                }
                .disabled(model.isCancelling(task.id))
            } else {
                Button(role: .destructive) { clear(task) } label: {
                    Label("从列表清除", systemImage: "trash")
                }
            }
        } label: {
            Image(systemName: "ellipsis")
                .symbolRenderingMode(.monochrome)
                .font(.system(size: 18, weight: .medium))
                .foregroundStyle(Color.ink)
                .frame(width: 44, height: 44)
                .orbitGlass(in: .circle, interactive: true)
                .contentShape(.circle)
        }
        .menuIndicator(.hidden)
        .accessibilityLabel("更多操作")
    }

    /// Clears a finished task from the list; the page closes itself when the task is gone (`applyTaskRemoval`).
    private func clear(_ task: OPATask) {
        Task {
            await model.clearTask(id: task.id)
            if model.isTaskRemoved(task.id) { model.showToast("已从列表清除") }
        }
    }

    // MARK: Content

    private func content(_ info: TaskInfo, _ motion: MotionAware) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            header(info)
            attention(info)
            stepsSection(info, motion)
            resultSection(info)
            #if DEBUG
            sessionsSection(info)
            #endif
            actions(info)
        }
        .padding(.horizontal, Space.xl)
        .padding(.top, Space.s)
        .padding(.bottom, Space.xxxl)
    }

    private func header(_ info: TaskInfo) -> some View {
        let task = info.task
        let chip = info.chip
        let stacked = typeSize.isAccessibilitySize
        let line = stacked ? AnyLayout(VStackLayout(alignment: .leading, spacing: Space.s)) : AnyLayout(HStackLayout(alignment: .center, spacing: Space.s))
        return VStack(alignment: .leading, spacing: 0) {
            line {
                StatusChip(kind: chip.kind, text: chip.text, dot: chip.dot)
                TaskMinuteText { now in
                    TaskTime.headerLine(createdAt: task.createdAt, updatedAt: task.updatedAt, finished: task.status.isFinished, now: now)
                }
                .font(.orbitMeta)
                .foregroundStyle(Color.inkTertiary)
                .multilineTextAlignment(.leading)
            }
            Text(verbatim: info.displayTitle)
                .font(.system(size: titleSize, weight: .semibold))
                .foregroundStyle(Color.ink)
                .multilineTextAlignment(.leading)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.top, 10)
                .accessibilityAddTraits(.isHeader)
            if let goal = TaskText.clean(task.goal) {
                Text(verbatim: goal)
                    .font(.orbitSecondary)
                    .foregroundStyle(Color.inkSecondary)
                    .lineSpacing(3)
                    .multilineTextAlignment(.leading)
                    .padding(.top, 6)
            }
        }
    }

    /// "现在等你…": a confirmation to give, a question to answer, or what blocks the task.
    @ViewBuilder
    private func attention(_ info: TaskInfo) -> some View {
        if let approval = info.pendingApprovals.first {
            AwaitingNote(title: "现在等你确认：\(approval.title)",
                         detail: ApprovalContent(approval: approval).summary(maxRows: 3),
                         buttonTitle: "查看") { model.openApproval(approval.id) }
                .padding(.top, Space.l)
        } else if info.awaitingConfirmation {
            // An execution session waits for a confirmation that is not linked to this task (Orbit's own requests carry no
            // session): say so, and point at the conversation, where the confirmation card is.
            AwaitingNote(title: "现在等你确认", detail: info.question, buttonTitle: "回到对话") { model.selectedTab = .chat }
                .padding(.top, Space.l)
        } else if info.task.status == .waiting_user {
            AwaitingNote(title: "现在等你补充", detail: info.question, buttonTitle: "回到对话") { model.selectedTab = .chat }
                .padding(.top, Space.l)
        } else if info.task.status == .blocked {
            NoteBlock(kind: .danger, systemImage: "exclamationmark.circle") {
                VStack(alignment: .leading, spacing: 2) {
                    Text("遇到阻碍").fontWeight(.semibold)
                    if let reason = info.blockedReason { Text(verbatim: reason) }
                }
            }
            .padding(.top, Space.l)
        }
    }

    // MARK: Steps

    @ViewBuilder
    private func stepsSection(_ info: TaskInfo, _ motion: MotionAware) -> some View {
        let steps = info.task.steps
        if !steps.isEmpty {
            sectionTitle("步骤")
            VStack(spacing: 2) {
                ForEach(Array(steps.enumerated()), id: \.element.id) { index, step in
                    let session = executionSession(for: step)
                    let isCurrent = step.id == info.highlightedStepId
                    let nextIsCurrent = index + 1 < steps.count && steps[index + 1].id == info.highlightedStepId
                    StepTimelineRow(step: step,
                                    subtitle: info.stepSubtitle(step),
                                    isCurrent: isCurrent,
                                    isLast: index == steps.count - 1,
                                    railOvershoot: isCurrent ? 19 : (nextIsCurrent ? 17 : 12),
                                    session: session,
                                    expanded: expandedSteps.contains(step.id),
                                    toggle: {
                                        withAnimation(motion.spring) {
                                            if expandedSteps.contains(step.id) { expandedSteps.remove(step.id) } else { expandedSteps.insert(step.id) }
                                        }
                                    },
                                    open: { openExecution($0) })
                }
            }
        }
    }

    // MARK: Outcome and sessions

    /// The host's summary: the outcome of a finished task, a progress note for one still going. (When the "现在等你…" note
    /// already says it, it is not repeated.)
    @ViewBuilder
    private func resultSection(_ info: TaskInfo) -> some View {
        if let summary = TaskText.clean(info.task.summary), !info.noteQuotesSummary {
            sectionTitle(info.task.status.isFinished ? "结果" : "摘要")
            OrbitCard(padding: 14) {
                Text(verbatim: summary)
                    .font(.orbitBody)
                    .foregroundStyle(Color.ink)
                    .lineSpacing(3)
                    .multilineTextAlignment(.leading)
                    .textSelection(.enabled)
            }
        }
    }

    #if DEBUG
    /// Developers only (`-OPAShowExecution YES`): the execution sessions of the task, each opening its log.
    @ViewBuilder
    private func sessionsSection(_ info: TaskInfo) -> some View {
        let sessions = info.sessions
        if ExecutionDebug.isOn, !sessions.isEmpty {
            sectionTitle("执行详情")
            OrbitCard {
                VStack(spacing: 0) {
                    ForEach(Array(sessions.enumerated()), id: \.element.id) { index, session in
                        if index > 0 {
                            Rectangle().fill(Color.hairline).frame(height: 0.5).padding(.leading, 56)
                        }
                        Button { openExecution(session) } label: { SessionRow(session: session) }
                            .buttonStyle(.pressable)
                            .accessibilityHint("查看执行详情")
                    }
                }
            }
            Text(verbatim: sessionsSummary(sessions))
                .font(.system(.caption))
                .foregroundStyle(Color.inkTertiary)
                .padding(.horizontal, 6)
                .padding(.top, 8)
        }
    }

    /// "2 个执行会话 · 1 个在安卓手机上".
    private func sessionsSummary(_ sessions: [OPASession]) -> String {
        let phone = sessions.filter { SessionKind.parse(title: $0.title).kind == .phone }.count
        return "\(sessions.count) 个执行会话" + (phone > 0 ? " · \(phone) 个在安卓手机上" : "")
    }
    #endif

    // MARK: Actions

    private func actions(_ info: TaskInfo) -> some View {
        let cancelling = model.isCancelling(info.task.id)
        let layout = typeSize.isAccessibilitySize ? AnyLayout(VStackLayout(spacing: Space.s)) : AnyLayout(HStackLayout(spacing: 10))
        return layout {
            Button { model.selectedTab = .chat } label: {
                Label("回到对话", systemImage: "bubble.left")
            }
            .buttonStyle(.orbit(.inset))
            if info.task.status.isActive {
                Button { confirmingCancel = true } label: {
                    if cancelling {
                        HStack(spacing: Space.s) {
                            ProgressView().controlSize(.small)
                            Text("正在取消…")
                        }
                    } else {
                        Text("取消任务")
                    }
                }
                .buttonStyle(.orbit(.destructive))
                .fixedSize(horizontal: !typeSize.isAccessibilitySize, vertical: false)
                .disabled(cancelling)
            }
        }
        .padding(.top, Space.xl)
    }

    private func sectionTitle(_ title: String) -> some View {
        SectionHeader(title: title)
            .padding(.horizontal, -4)
            .padding(.top, 22)
            .padding(.bottom, 10)
    }

    // MARK: Gone

    private var removedState: some View {
        VStack(spacing: 10) {
            OrbitMascot(pose: .attentive, size: 80)
            Text("这个任务已不在列表中")
                .font(.system(.title3, weight: .semibold))
                .foregroundStyle(Color.ink)
                .multilineTextAlignment(.center)
                .padding(.top, 8)
            Text("它可能已经被清除。")
                .font(.orbitSecondary)
                .foregroundStyle(Color.inkSecondary)
            Button("返回任务列表") { dismiss() }
                .buttonStyle(.orbit(.soft, size: .small))
                .padding(.top, Space.s)
        }
        .padding(.horizontal, 40)
        .padding(.top, 80)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
    }
}

// MARK: - "现在等你…"

/// What the task waits for, as a card under the goal: a Warning dot and the line in Ink, the host's words under it, and
/// the one action that gets you there as Accent text at the end. No tinted fill, no icon.
private struct AwaitingNote: View {
    var title: String
    var detail: String?
    var buttonTitle: String
    var action: () -> Void

    @Environment(\.dynamicTypeSize) private var typeSize

    var body: some View {
        let stacked = typeSize.isAccessibilitySize
        let layout = stacked
            ? AnyLayout(VStackLayout(alignment: .leading, spacing: Space.m))
            : AnyLayout(HStackLayout(alignment: .center, spacing: Space.m))
        let dot = Text(Image(systemName: "circle.fill")).font(.system(size: 6)).foregroundStyle(Color.warning).baselineOffset(2)
        OrbitCard(padding: 14) {
            layout {
                VStack(alignment: .leading, spacing: 2) {
                    Text("\(dot)  \(title)")
                        .font(.system(.subheadline, weight: .semibold))
                        .foregroundStyle(Color.ink)
                    if let detail {
                        Text(verbatim: detail)
                            .font(.subheadline)
                            .foregroundStyle(Color.inkSecondary)
                            .lineLimit(2)
                    }
                }
                .multilineTextAlignment(.leading)
                .frame(maxWidth: .infinity, alignment: .leading)
                .accessibilityElement(children: .combine)
                Button(action: action) {
                    Text(buttonTitle)
                        .font(.system(.subheadline, weight: .medium))
                        .foregroundStyle(Color.accentText)
                        .contentShape(Rectangle().inset(by: -12))
                }
                .buttonStyle(DimPressStyle())
            }
        }
    }
}

// MARK: - Step timeline

/// One step on the timeline: marker, title, and (for the step being worked on) what its session is doing. Only the
/// current step sits on a raised card, so history stays quiet. A step with an execution session can be opened up to
/// reach that session.
private struct StepTimelineRow: View {
    let step: TaskStep
    let subtitle: String?
    let isCurrent: Bool
    let isLast: Bool
    /// How far the rail below the marker reaches past this row so that it meets the next marker (rows are padded and
    /// spaced; the current step sits on a card that adds more).
    let railOvershoot: CGFloat
    let session: OPASession?
    let expanded: Bool
    let toggle: () -> Void
    let open: (OPASession) -> Void

    private var expandable: Bool { session != nil && step.status != .pending }

    var body: some View {
        if isCurrent {
            rowContent
                .padding(.horizontal, 10)
                .padding(.top, 6)
                .padding(.bottom, 8)
                .background(Color.surface, in: .rect(cornerRadius: Radius.card, style: .continuous))
                .overlay { RoundedRectangle(cornerRadius: Radius.card, style: .continuous).strokeBorder(Color.hairline, lineWidth: 0.5) }
                .padding(.horizontal, -10)
                .padding(.vertical, 4)
        } else {
            rowContent.padding(.vertical, 5)
        }
    }

    private var rowContent: some View {
        rowBody
            .background(alignment: .topLeading) {
                if !isLast {
                    Rectangle().fill(Color.hairline).frame(width: 1)
                        .padding(.top, 25).padding(.bottom, -railOvershoot).padding(.leading, 9.5)
                        .accessibilityHidden(true)
                }
            }
    }

    private var rowBody: some View {
        HStack(alignment: .top, spacing: 10) {
            StepMarker(status: step.status)
                .padding(.top, 1)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 6) {
                if expandable {
                    Button(action: toggle) {
                        HStack(alignment: .top, spacing: Space.s) {
                            titleBlock
                            Image(systemName: "chevron.down")
                                .font(.system(size: 11, weight: .semibold))
                                .foregroundStyle(Color.inkTertiary)
                                .rotationEffect(.degrees(expanded ? 180 : 0))
                                .padding(.top, 5)
                                .accessibilityHidden(true)
                        }
                        .contentShape(.rect)
                    }
                    .buttonStyle(.plain)
                    .accessibilityHint(expanded ? "收起执行会话" : "展开执行会话")
                } else {
                    titleBlock
                }
                if expanded, let session {
                    Button { open(session) } label: {
                        SessionRow(session: session)
                            .background(Color.surface, in: .rect(cornerRadius: Radius.card, style: .continuous))
                            .overlay { RoundedRectangle(cornerRadius: Radius.card, style: .continuous).strokeBorder(Color.hairline, lineWidth: 0.5) }
                    }
                    .buttonStyle(.pressable)
                    .accessibilityHint("查看执行详情")
                    .transition(.opacity)
                }
            }
        }
    }

    private var titleBlock: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(verbatim: step.title)
                .font(.system(.subheadline, weight: isCurrent ? .semibold : .regular))
                .foregroundStyle(titleColor)
                .multilineTextAlignment(.leading)
            if let subtitle {
                Text(verbatim: subtitle)
                    .font(.orbitMeta)
                    .foregroundStyle(Color.inkSecondary)
                    .multilineTextAlignment(.leading)
                    .contentTransition(.opacity)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityElement(children: .combine)
        .accessibilityLabel(accessibilityText)
    }

    private var titleColor: Color {
        switch step.status {
        case .running: .ink
        case .pending, .skipped: .inkTertiary
        case .done, .failed: .inkSecondary
        }
    }

    private var accessibilityText: String {
        [step.title, step.status.label, subtitle].compactMap { $0 }.joined(separator: "，")
    }
}
