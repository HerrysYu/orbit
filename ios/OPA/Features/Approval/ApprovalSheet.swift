import SwiftUI

// MARK: - Global confirm sheet

/// The global confirm sheet (`model.presentedApprovalId`, mounted by the root view). It shows one approval in full
/// and lets you approve or deny it; closing it is not an answer.
///
/// Lifecycle on screen: pending → submitting (buttons locked, Face ID prompt included) → approved "已批准 · 等执行结果"
/// or denied; or expired (buttons disabled, with the reason); or failed (content kept, the answer can be sent again).
/// An id that no longer exists reads "这个确认已失效".
struct ApprovalSheet: View {
    let approvalId: String

    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.dynamicTypeSize) private var typeSize

    /// The answer sent last (true = approve). Only used to label a failed one "重试".
    @State private var lastAnswer: Bool?
    @State private var answeredCount = 0

    var body: some View {
        let motion = MotionAware(reduce: reduceMotion)
        let approval = model.approvals[approvalId]
        let status = model.approvalStatus(approvalId)

        VStack(spacing: 0) {
            header
            if let approval {
                // Room enough: the buttons follow the content directly. Not enough (a long command, large text sizes):
                // the details scroll and the buttons stay pinned within reach.
                ViewThatFits(in: .vertical) {
                    VStack(spacing: 0) {
                        details(approval, status)
                        actions(approval, status)
                        Spacer(minLength: 0)
                    }
                    VStack(spacing: 0) {
                        ScrollView { details(approval, status) }
                            .scrollBounceBehavior(.basedOnSize)
                        actions(approval, status)
                            .overlay(alignment: .top) { Rectangle().fill(Color.hairline).frame(height: 0.5) }
                    }
                }
            } else {
                unavailable
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .background(Color.surface)
        .animation(motion.spring, value: status)
        .presentationDetents(detents(hasApproval: approval != nil))
        .presentationDragIndicator(.visible)
        .presentationBackground(Color.surface)
        .sensoryFeedback(.success, trigger: answeredCount)
    }

    /// About three quarters of the screen, as in the design; the second detent is for long content. At accessibility text
    /// sizes the sheet opens full height: there is no room to spare.
    private func detents(hasApproval: Bool) -> Set<PresentationDetent> {
        if typeSize.isAccessibilitySize { return [.large] }
        return hasApproval ? [.fraction(0.72), .large] : [.fraction(0.4), .large]
    }

    private var botName: String { TaskText.clean(model.settings.butler.name) ?? "Orbit" }

    // MARK: Header

    /// The 3D avatar, "需要你确认" and a bare ✕ (no fill). Closing is not an answer.
    private var header: some View {
        HStack(spacing: Space.s) {
            ChatAvatar(size: 26)
            Text("需要你确认")
                .font(.system(.subheadline))
                .foregroundStyle(Color.inkSecondary)
                .accessibilityAddTraits(.isHeader)
            Spacer(minLength: Space.s)
            Button { dismiss() } label: {
                Image(systemName: "xmark")
                    .font(.system(size: 17, weight: .medium))
                    .foregroundStyle(Color.inkSecondary)
                    .frame(width: 44, height: 44)
                    .contentShape(.rect)
            }
            .buttonStyle(.pressable)
            .accessibilityLabel("关闭")
            .accessibilityHint("关闭不等于拒绝，这个请求仍在等你确认")
        }
        .padding(.leading, 22)
        .padding(.trailing, 17)
        .padding(.top, Space.s)
    }

    // MARK: Details

    /// Orbit's own requests (kind `action`) read as written. A request that comes out of an execution (command, file
    /// change, permissions, elicitation) shows its title and its reason; the raw command, the directory, JSON
    /// parameters and anything unrecognised wait behind a collapsed "技术详情" (nothing is dropped).
    ///
    /// Top to bottom: the title (22 semibold); "中风险 · 28 分钟后过期"; the `标签：内容` rows between Hairlines; what happens
    /// after approving, as plain secondary text (no fill, no icon).
    private func details(_ approval: Approval, _ status: ApprovalStatus) -> some View {
        let content = ApprovalContent(approval: approval)
        let stillOpen = status.isActionable || status == .submitting
        return VStack(alignment: .leading, spacing: 0) {
            Text(verbatim: approval.title)
                .font(.system(.title2, weight: .semibold))
                .foregroundStyle(Color.ink)
                .multilineTextAlignment(.leading)
                .fixedSize(horizontal: false, vertical: true)
                .accessibilityAddTraits(.isHeader)
            riskLine(approval, status)
                .padding(.top, 4)
            if let body = content.body {
                bodyBlock(body)
                    .padding(.top, Space.l)
            }
            if !content.rows.isEmpty {
                ApprovalRows(rows: content.rows)
                    .padding(.top, Space.l)
            }
            if let after = content.after {
                Text(verbatim: after)
                    .font(.system(.subheadline))
                    .lineSpacing(3)
                    .foregroundStyle(Color.inkSecondary)
                    .multilineTextAlignment(.leading)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.top, Space.l)
            }
            if let technical = content.technical {
                TechnicalDetails(text: technical)
                    .padding(.top, Space.l)
            }
            if stillOpen, let risk = ApprovalCopy.riskNote(approval.risk) {
                NoteBlock(kind: .warn, systemImage: "exclamationmark.triangle", text: risk)
                    .padding(.top, Space.l)
            }
        }
        .padding(.horizontal, 22)
        .padding(.top, Space.m)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    /// "中风险 · 28 分钟后过期": the risk word in its color (Warning for medium), then the time left on the Mac's clock
    /// while the request is still open. Wraps at large text sizes instead of cutting the words.
    private func riskLine(_ approval: Approval, _ status: ApprovalStatus) -> some View {
        TimelineView(.periodic(from: .now, by: 1)) { context in
            let risk = Text(verbatim: ApprovalCopy.riskLabel(approval.risk)).foregroundStyle(approval.risk.tint)
            Text("\(risk)\(riskTail(approval, status, now: context.date))")
                .font(.system(.footnote))
                .foregroundStyle(Color.inkSecondary)
                .multilineTextAlignment(.leading)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private func riskTail(_ approval: Approval, _ status: ApprovalStatus, now: Date) -> String {
        switch status {
        case .expired: return " · 已过期"
        case .approved, .denied: return ""
        case .pending, .submitting, .failed:
            guard let expiresAt = approval.expiresAt else { return "" }
            return " · " + ApprovalCopy.expiry(remainingMs: expiresAt - (Clock.ms(now) + model.hostClockOffsetMs))
        }
    }

    /// Orbit's own text of the request that is not a `标签：内容` row. Shown whole, as plain text.
    private func bodyBlock(_ text: String) -> some View {
        Text(verbatim: text)
            .font(.orbitBody)
            .lineSpacing(3)
            .foregroundStyle(Color.ink)
            .multilineTextAlignment(.leading)
            .textSelection(.enabled)
            .frame(maxWidth: .infinity, alignment: .leading)
    }

    // MARK: Actions

    @ViewBuilder
    private func actions(_ approval: Approval, _ status: ApprovalStatus) -> some View {
        VStack(spacing: 10) {
            switch status {
            case .approved:
                resolved(kind: .good, symbol: "checkmark.circle", title: "已批准 · 等执行结果", detail: "结果会同步到对话和任务页。")
                doneButton
            case .denied:
                resolved(kind: .info, symbol: "xmark.circle", title: "已拒绝", detail: "\(botName) 不会执行这个操作。")
                doneButton
            case .pending, .submitting, .failed, .expired:
                if case .failed(let message) = status {
                    NoteBlock(kind: .danger, systemImage: "exclamationmark.circle", text: "没有提交成功：\(message)。内容已保留，可以再试一次。")
                }
                if status == .expired {
                    NoteBlock(kind: .warn, systemImage: "clock", text: "这条确认已过期，不能再批准或拒绝。需要的话让 \(botName) 重新发起。")
                }
                approveButton(approval, status)
                denyButton(approval, status)
            }
            if let source = ApprovalSource.resolve(approval: approval, sessions: model.sessions, tasks: model.tasks) {
                Text(verbatim: source.text)
                    .font(.orbitMeta)
                    .foregroundStyle(Color.inkTertiary)
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: .infinity)
                    .padding(.top, Space.xs)
            }
        }
        .padding(.horizontal, 22)
        .padding(.top, 22)
        .padding(.bottom, Space.l)
        .frame(maxWidth: .infinity)
        .background(Color.surface)
    }

    private func approveButton(_ approval: Approval, _ status: ApprovalStatus) -> some View {
        let busy = status == .submitting
        let verb = ApprovalCopy.approveVerb(approval.kind)
        let retry = retrying(status, answer: true)
        return Button {
            answer(approval, approve: true)
        } label: {
            if busy && lastAnswer != false {
                HStack(spacing: Space.s) {
                    ProgressView().tint(Color.onPrimary)
                    Text("提交中…")
                }
            } else {
                HStack(spacing: Space.s) {
                    if approval.requireBiometric { Image(systemName: BiometricLabel.current.symbol) }
                    Text(verbatim: retry ? "重试 · \(verb)" : verb)
                }
            }
        }
        .buttonStyle(.orbit(.primary))
        .allowsHitTesting(!busy)
        .disabled(!status.isActionable && !busy)
        .accessibilityLabel(approval.requireBiometric ? "\(verb)，需要 \(BiometricLabel.current.name) 验证" : verb)
    }

    private func denyButton(_ approval: Approval, _ status: ApprovalStatus) -> some View {
        let busy = status == .submitting && lastAnswer == false
        let retry = retrying(status, answer: false)
        return Button {
            answer(approval, approve: false)
        } label: {
            if busy {
                HStack(spacing: Space.s) {
                    ProgressView()
                    Text("提交中…")
                }
            } else {
                Text(verbatim: retry ? "重试 · 拒绝" : "拒绝")
            }
        }
        .buttonStyle(.orbit(.inset))
        .allowsHitTesting(!busy)
        .disabled(!status.isActionable && !busy)
    }

    /// A failed answer is offered again as "重试 · …", but only for the answer that actually failed.
    private func retrying(_ status: ApprovalStatus, answer: Bool) -> Bool {
        if case .failed = status { return lastAnswer == answer }
        return false
    }

    private func answer(_ approval: Approval, approve: Bool) {
        lastAnswer = approve
        Task {
            if await model.respond(approval: approval, approve: approve) { answeredCount += 1 }
        }
    }

    private func resolved(kind: NoteKind, symbol: String, title: String, detail: String) -> some View {
        NoteBlock(kind: kind, systemImage: symbol) {
            VStack(alignment: .leading, spacing: 2) {
                Text(verbatim: title).fontWeight(.semibold)
                Text(verbatim: detail)
            }
        }
    }

    private var doneButton: some View {
        Button("完成") { dismiss() }
            .buttonStyle(.orbit(.inset))
    }

    // MARK: Gone

    private var unavailable: some View {
        VStack(spacing: Space.s) {
            Image(systemName: "exclamationmark.circle")
                .font(.system(size: 34, weight: .light))
                .foregroundStyle(Color.inkTertiary)
                .accessibilityHidden(true)
            Text("这个确认已失效")
                .font(.orbitCardTitle)
                .foregroundStyle(Color.ink)
            Text("它可能已经处理完，或已被撤回。")
                .font(.orbitSecondary)
                .foregroundStyle(Color.inkSecondary)
                .multilineTextAlignment(.center)
            doneButton
                .padding(.top, Space.m)
        }
        .padding(.horizontal, 22)
        .padding(.top, Space.xxl)
        .padding(.bottom, Space.l)
        .frame(maxWidth: .infinity)
    }
}

// MARK: - Rows

/// The `标签：内容` rows of a request: label 15 InkSecondary, value 17 Ink, a Hairline above the first row, between the
/// rows and below the last. No fill. At accessibility text sizes each row stacks its label above the value.
private struct ApprovalRows: View {
    var rows: [ApprovalContent.Row]

    @Environment(\.dynamicTypeSize) private var typeSize
    @ScaledMetric(relativeTo: .body) private var keyWidth: CGFloat = 64

    var body: some View {
        VStack(spacing: 0) {
            line
            ForEach(Array(rows.enumerated()), id: \.offset) { _, row in
                item(row)
                line
            }
        }
    }

    private var line: some View {
        Rectangle().fill(Color.hairline).frame(height: 0.5)
    }

    @ViewBuilder
    private func item(_ row: ApprovalContent.Row) -> some View {
        if typeSize.isAccessibilitySize {
            VStack(alignment: .leading, spacing: 2) {
                key(row.label)
                value(row.value)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.vertical, 11)
            .accessibilityElement(children: .combine)
        } else {
            HStack(alignment: .firstTextBaseline, spacing: Space.m) {
                key(row.label).frame(width: keyWidth, alignment: .leading)
                value(row.value).frame(maxWidth: .infinity, alignment: .leading)
            }
            .padding(.vertical, 11)
            .accessibilityElement(children: .combine)
        }
    }

    private func key(_ text: String) -> some View {
        Text(verbatim: text).font(.system(.subheadline)).foregroundStyle(Color.inkSecondary)
    }

    private func value(_ text: String) -> some View {
        Text(verbatim: text).font(.system(.body)).foregroundStyle(Color.ink).fixedSize(horizontal: false, vertical: true)
    }
}

#if DEBUG
#Preview {
    let model = AppModel(inMemory: true)
    model.enterDemo()
    return Color.canvas
        .sheet(isPresented: .constant(true)) { ApprovalSheet(approvalId: "ap1") }
        .environment(model)
}
#endif
