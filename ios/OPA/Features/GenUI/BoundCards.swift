import SwiftUI

// MARK: - Words of the task card

/// The words on the task card's status line, next to the status dot: "3/4 步 · 正在确认空位".
enum TaskCardText {
    /// "3/4 步": finished steps out of all steps (never a percentage); nil while there are no steps to count, or while
    /// the task is being cancelled.
    static func stepCount(_ task: OPATask, cancelling: Bool = false) -> String? {
        task.steps.isEmpty || cancelling ? nil : "\(task.doneCount)/\(task.steps.count) 步"
    }

    /// What the task is doing: the step being worked on while it runs ("正在核对周六 19:00 的空位"), otherwise the status
    /// word ("等你补充", "已完成").
    static func detail(_ task: OPATask, cancelling: Bool = false) -> String {
        if cancelling { return "正在取消…" }
        switch task.status {
        case .running:
            if let current = task.currentStep?.title.trimmingCharacters(in: .whitespacesAndNewlines), !current.isEmpty {
                return current.hasPrefix("正在") ? current : "正在" + current
            }
            return task.steps.isEmpty ? "正在规划步骤" : task.status.label
        case .planning:
            return task.steps.isEmpty ? "正在规划步骤" : task.status.label
        default:
            return task.status.label
        }
    }

    /// The whole line: "3/4 步 · 正在确认空位".
    static func line(_ task: OPATask, cancelling: Bool = false) -> String {
        [stepCount(task, cancelling: cancelling), detail(task, cancelling: cancelling)]
            .compactMap { $0 }
            .joined(separator: " · ")
    }

    /// What VoiceOver reads: the finished count spelled out, "已完成 3 / 4 步，正在确认空位".
    static func spoken(_ task: OPATask, cancelling: Bool = false) -> String {
        let doing = detail(task, cancelling: cancelling)
        guard !task.steps.isEmpty, !cancelling else { return doing }
        return "已完成 \(task.doneCount) / \(task.steps.count) 步，" + doing
    }
}

// MARK: - task_progress (bound to live task state)

/// The task card in the chat. It renders `model.tasks[taskId]` live (task.upsert updates it in place) as three things:
/// the title, one status line ("● 3/4 步 · 正在确认空位": a dot in the status color, finished steps out of all steps,
/// and what is being done), and a 2 pt Accent progress line. Tapping the card opens the task page; the "..." menu
/// cancels a running task or clears a finished one. The steps themselves live on the task page. It shows steps and
/// results only: what the execution reports along the way (progress lines, tool calls) stays out of the owner's sight.
struct TaskProgressCard: View {
    @Environment(AppModel.self) private var model
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    var taskId: String

    @State private var confirmCancel = false
    @ScaledMetric(relativeTo: .footnote) private var dotLift: CGFloat = 4.8

    var body: some View {
        if let task = model.tasks[taskId] {
            card(task)
        } else if model.isTaskRemoved(taskId) {
            CardPlaceholder(symbol: "tray", text: "这个任务已从列表清除")
        } else {
            CardPlaceholder(symbol: nil, text: "任务加载中…", loading: true)
        }
    }

    private func card(_ task: OPATask) -> some View {
        let motion = MotionAware(reduce: reduceMotion)
        let cancelling = model.isCancelling(task.id)
        let kind: StatusKind = cancelling ? .planning : task.status.chipKind
        let line = TaskCardText.line(task, cancelling: cancelling)
        let lift = dotLift
        return OrbitCard {
            Button {
                model.openTask(task.id)
            } label: {
                VStack(alignment: .leading, spacing: 0) {
                    Text(task.title)
                        .font(.orbitCardTitle)
                        .foregroundStyle(Color.ink)
                        .multilineTextAlignment(.leading)
                        .fixedSize(horizontal: false, vertical: true)
                        // Room for the "..." button that sits over the corner.
                        .padding(.trailing, 32)
                        .accessibilityAddTraits(.isHeader)

                    HStack(alignment: .firstTextBaseline, spacing: 6) {
                        Circle()
                            .fill(kind.dotColor)
                            .frame(width: 6, height: 6)
                            .alignmentGuide(.firstTextBaseline) { $0[VerticalAlignment.center] + lift }
                            .accessibilityHidden(true)
                        Text(line)
                            .font(.orbitMeta)
                            .monospacedDigit()
                            .foregroundStyle(Color.inkSecondary)
                            .multilineTextAlignment(.leading)
                            .fixedSize(horizontal: false, vertical: true)
                            .contentTransition(.interpolate)
                    }
                    .padding(.top, 2)

                    if showsLine(task) {
                        ProgressLine(fraction: task.progress, accessibilityValueText: "已完成 \(task.doneCount) / \(task.steps.count) 步")
                            .padding(.top, 10)
                    }

                    notes(task)
                }
                .padding(CardMetrics.side)
                .frame(maxWidth: .infinity, alignment: .leading)
                .contentShape(.rect)
            }
            .buttonStyle(CardContentPressStyle())
            .accessibilityElement(children: .combine)
            .accessibilityLabel(spokenLabel(task, cancelling: cancelling))
            .accessibilityHint("查看任务")
        }
        .overlay(alignment: .topTrailing) {
            menu(task, cancelling: cancelling)
                .padding(.top, CardMetrics.headerTop - 11)
                .padding(.trailing, 2)
        }
        .animation(motion.spring, value: task)
        .animation(motion.snappy, value: cancelling)
    }

    /// What VoiceOver reads for the whole card: the title, the status line and the task's own summary.
    private func spokenLabel(_ task: OPATask, cancelling: Bool) -> String {
        [task.title, TaskCardText.spoken(task, cancelling: cancelling), task.summary?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""]
            .filter { !$0.isEmpty }
            .joined(separator: "，")
    }

    /// The line is the task's progress: it shows while the task is open, with steps to count.
    private func showsLine(_ task: OPATask) -> Bool {
        !task.steps.isEmpty && task.status.isActive && !model.isCancelling(task.id)
    }

    // MARK: Header menu

    private func menu(_ task: OPATask, cancelling: Bool) -> some View {
        Menu {
            if task.status.isFinished {
                Button {
                    Task { await model.clearTask(id: task.id) }
                } label: {
                    Label("从列表清除", systemImage: "trash")
                }
            } else {
                Button(role: .destructive) {
                    confirmCancel = true
                } label: {
                    Label("取消任务", systemImage: "xmark.circle")
                }
                .disabled(cancelling)
            }
        } label: {
            Image(systemName: "ellipsis")
                .font(.system(.subheadline, weight: .semibold))
                .foregroundStyle(Color.inkTertiary)
                .frame(width: 44, height: 44)
                .contentShape(.rect)
        }
        .menuIndicator(.hidden)
        .accessibilityLabel("更多操作")
        // Attached here (not to the card) so iOS 26 anchors the dialog at the "..." button it came from.
        .confirmationDialog("取消这个任务？", isPresented: $confirmCancel, titleVisibility: .visible) {
            Button("取消任务", role: .destructive) { Task { await model.cancelTask(id: task.id) } }
            Button("暂不取消", role: .cancel) {}
        } message: {
            Text("停止进行中的步骤，已完成的不撤销。")
        }
    }

    // MARK: Notes

    /// The task's own summary (why it is blocked, what it produced) and, while the Mac is away, the sync note.
    @ViewBuilder
    private func notes(_ task: OPATask) -> some View {
        let summary = task.summary?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let offline = !model.canUseHost && task.status.isActive
        if !summary.isEmpty || offline {
            VStack(alignment: .leading, spacing: Space.s) {
                if !summary.isEmpty { summaryView(task.status, summary) }
                if offline {
                    NoteBlock(kind: .warn, systemImage: "clock") {
                        Text("最后同步 \(syncTime(task))。Mac 离线期间任务可能仍在运行，恢复后自动更新。")
                    }
                }
            }
            .padding(.top, 10)
        }
    }

    @ViewBuilder
    private func summaryView(_ status: OPATask.Status, _ summary: String) -> some View {
        switch status {
        case .blocked: NoteBlock(kind: .danger, systemImage: "exclamationmark.circle") { Text(summary) }
        case .failed: NoteBlock(kind: .danger, systemImage: "xmark.circle") { Text(summary) }
        case .waiting_user: NoteBlock(kind: .warn, systemImage: "questionmark.bubble") { Text(summary) }
        case .done: NoteBlock(kind: .good, systemImage: "checkmark.circle") { Text(summary) }
        case .planning, .running, .cancelled:
            Text(summary)
                .font(.orbitSecondary)
                .foregroundStyle(Color.inkSecondary)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    /// When the card's content was last in sync with the Mac: the last time we heard from it.
    private func syncTime(_ task: OPATask) -> String {
        let date = model.lastSeenOnlineAt ?? Clock.date(ms: task.updatedAt)
        return CardFormat.time(date)
    }
}

// MARK: - Step row

/// One task step: `StepMarker` and the title (bold when current, quiet when pending). The step title says what is being
/// done; nothing the execution reports along the way is added. A hairline rail connects it to the next marker.
struct StepRow: View {
    var step: TaskStep
    /// Bold title. Defaults to "this step is running".
    var isCurrent: Bool?
    /// The last row draws no rail below its marker.
    var isLast = true

    var body: some View {
        let current = isCurrent ?? (step.status == .running)
        HStack(alignment: .top, spacing: 10) {
            StepMarker(status: step.status)
                .padding(.top, 1)
            Text(step.title)
                .font(.orbitSecondary.weight(current ? .semibold : .regular))
                .foregroundStyle(titleColor(current: current))
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(.vertical, 5)
        .background(alignment: .topLeading) {
            if !isLast {
                Rectangle()
                    .fill(Color.hairline)
                    .frame(width: 1)
                    .padding(.top, 25)
                    .padding(.bottom, -5)
                    .padding(.leading, 9.5)
            }
        }
        .accessibilityElement(children: .combine)
    }

    private func titleColor(current: Bool) -> Color {
        if current { return .ink }
        return step.status == .pending ? .inkTertiary : .inkSecondary
    }
}

// MARK: - approval_card (bound to approval state)

/// The compact confirm hint in the chat: one line, "● 需要你确认：提交这家餐厅的预订", with a "查看" link that opens the
/// confirm sheet (`openApproval`), where the details, Face ID and the decision live. Long-pressing the line (or the
/// VoiceOver action) refuses right away. The status comes from `model.approvalStatus`.
struct ApprovalCardView: View {
    @Environment(AppModel.self) private var model
    var approvalId: String

    var body: some View {
        if let approval = model.approvals[approvalId] {
            ApprovalPanel(approval: approval)
        } else {
            CardPlaceholder(symbol: "hand.raised", text: "这个确认已失效")
        }
    }
}

struct ApprovalPanel: View {
    @Environment(AppModel.self) private var model
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    var approval: Approval

    @State private var successTick = 0
    @State private var failureTick = 0

    var body: some View {
        let status = model.approvalStatus(approval.id)
        let motion = MotionAware(reduce: reduceMotion)
        let look = Self.look(of: status, title: approval.title)
        HintRow(text: look.text, dot: look.dot, emphasized: look.emphasized) {
            trailing(status)
        }
        .contentShape(.rect)
        .onTapGesture {
            if status.isActionable { model.openApproval(approval.id) }
        }
        .contextMenu {
            if status.isActionable {
                Button(role: .destructive) {
                    Task { await deny() }
                } label: {
                    Label("拒绝", systemImage: "xmark")
                }
            }
        }
        .accessibilityAction(named: "拒绝") {
            if status.isActionable { Task { await deny() } }
        }
        .animation(motion.snappy, value: look.text)
        .submitFeedback(success: successTick, failure: failureTick)
    }

    // MARK: Look

    /// The words and the dot of the one-line hint for each state.
    private static func look(of status: ApprovalStatus, title: String) -> (text: String, dot: Color, emphasized: Bool) {
        switch status {
        case .pending: ("需要你确认：\(title)", .warning, true)
        case .submitting: ("正在提交：\(title)", .accentText, true)
        case .approved: ("已批准：\(title) · 等执行结果", .success, false)
        case .denied: ("已拒绝：\(title)", .inkTertiary, false)
        case .expired: ("已过期：\(title)", .inkTertiary, false)
        case .failed(let message): ("没有提交成功：\(message)", .danger, true)
        }
    }

    // MARK: Trailing

    @ViewBuilder
    private func trailing(_ status: ApprovalStatus) -> some View {
        if status == .submitting {
            ProgressView().controlSize(.small)
        } else if status.isActionable {
            Button("查看") {
                model.openApproval(approval.id)
            }
            .buttonStyle(.orbit(.plain, size: .mini))
        }
    }

    private func deny() async {
        if await model.respond(approval: approval, approve: false) {
            successTick += 1
        } else {
            failureTick += 1
        }
    }
}
