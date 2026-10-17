import SwiftUI

// MARK: - Developer switch

/// The execution detail (the log of what an execution session did, its model and permission, what it said last) is for
/// developers, not for the owner. Its entries (the "执行详情" list on the task page and the expandable steps) exist in
/// debug builds only, and even there stay closed unless the app is launched with `-OPAShowExecution YES`, so that
/// demo runs and screenshots look like the real thing.
enum ExecutionDebug {
    static var isOn: Bool {
        #if DEBUG
        UserDefaults.standard.bool(forKey: "OPAShowExecution")
        #else
        false
        #endif
    }
}

// MARK: - Execution session row

/// One execution session as a row: where it works (icon), its title, what it is doing, its status. Tapping it
/// (the caller wraps it in a Button) opens `SessionDetailSheet`.
struct SessionRow: View {
    @Environment(AppModel.self) private var model
    var session: OPASession
    /// Starts the line under the title with the task the session belongs to (for lists that mix several tasks).
    var showsTask = false
    var showsChevron = true

    var body: some View {
        let parsed = SessionKind.parse(title: session.title)
        let chip = SessionPresentation.chip(for: session, taskStatus: session.taskId.flatMap { model.tasks[$0]?.status })
        HStack(alignment: .top, spacing: Space.m) {
            SessionGlyph(kind: parsed.kind)
                .padding(.top, 1)
            VStack(alignment: .leading, spacing: 2) {
                HStack(alignment: .center, spacing: Space.s) {
                    Text(verbatim: parsed.title)
                        .font(.system(.callout, weight: .semibold))
                        .foregroundStyle(Color.ink)
                        .multilineTextAlignment(.leading)
                        .frame(maxWidth: .infinity, alignment: .leading)
                    StatusChip(kind: chip.kind, text: chip.text, dot: chip.dot)
                }
                Text(verbatim: detail(kind: parsed.kind))
                    .font(.orbitMeta)
                    .foregroundStyle(Color.inkSecondary)
                    .lineLimit(2)
                    .multilineTextAlignment(.leading)
                    .contentTransition(.opacity)
            }
            if showsChevron {
                Image(systemName: "chevron.right")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(Color.inkTertiary)
                    .padding(.top, 6)
                    .accessibilityHidden(true)
            }
        }
        .padding(.horizontal, Space.l)
        .padding(.vertical, Space.m)
        .frame(maxWidth: .infinity, alignment: .leading)
        .contentShape(.rect)
        .accessibilityElement(children: .combine)
    }

    /// What it is doing: its live line, else its last activity, else where it works.
    private func detail(kind: SessionKind) -> String {
        var parts: [String] = []
        if showsTask, let title = session.taskId.flatMap({ model.tasks[$0]?.title }).flatMap(TaskText.clean) { parts.append(title) }
        parts.append(TaskText.clean(model.sessionProgress[session.id]) ?? TaskText.clean(session.lastActivity) ?? kind.label)
        return parts.joined(separator: " · ")
    }
}

/// The glyph that says where a session works (phone, Mac, Mac desktop): a plain SF Symbol in InkSecondary, in a 28 pt slot.
struct SessionGlyph: View {
    var kind: SessionKind
    @ScaledMetric(relativeTo: .body) private var scaledSide: CGFloat = 28

    var body: some View {
        let side = min(scaledSide, 40)
        Image(systemName: kind.symbol)
            .font(.system(.subheadline, weight: .medium))
            .dynamicTypeSize(...DynamicTypeSize.xxxLarge)
            .foregroundStyle(Color.inkSecondary)
            .frame(width: side, height: side)
            .accessibilityHidden(true)
    }
}

// MARK: - Execution detail sheet

/// One sheet per execution session: where it works, its status and how long it took, the model and permission it
/// runs with, the log of what it did (`session.detail`), and what you can do: add an instruction, stop the current
/// turn, archive.
struct SessionDetailSheet: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    /// The session as the caller knew it. The live copy in `model.sessions` wins as soon as it exists.
    var session: OPASession

    @State private var items: [SessionItem] = []
    @State private var loadState = LoadState.loading
    @State private var fetched: OPASession?
    @State private var composing = false
    @State private var steerText = ""
    @State private var busy = false
    @State private var notice: Notice?
    @State private var noticeToken = 0
    @State private var confirmingArchive = false
    @State private var detent = PresentationDetent.medium
    @State private var sentCount = 0
    @FocusState private var steerFocused: Bool

    private enum LoadState: Equatable {
        case loading
        case loaded
        case failed(String)
    }

    private struct Notice: Equatable {
        var kind: NoteKind
        var text: String
    }

    var body: some View {
        let motion = MotionAware(reduce: reduceMotion)
        let current = model.sessions[session.id] ?? fetched ?? session
        let parsed = SessionKind.parse(title: current.title)
        let chip = SessionPresentation.chip(for: current, taskStatus: current.taskId.flatMap { model.tasks[$0]?.status })

        VStack(spacing: 0) {
            header(current, parsed, chip)
            ScrollView {
                VStack(alignment: .leading, spacing: 0) {
                    tags(current, chip)
                    Rectangle().fill(Color.hairline).frame(height: 0.5)
                    actionLog
                    if parsed.kind == .phone {
                        NoteBlock(kind: .info, systemImage: "info.circle",
                                  text: "截图证据保存在你的 Mac：~/.opa/phone/evidence/。手机上的敏感点击会自动执行，并留有审计记录。")
                            .padding(.top, Space.m)
                    }
                }
                .padding(.horizontal, 22)
                .padding(.bottom, Space.m)
            }
            .scrollBounceBehavior(.basedOnSize)
            .refreshable { await load(silently: true) }
            actionBar(current)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .background(Color.surface)
        .animation(motion.spring, value: composing)
        .animation(motion.snappy, value: notice)
        .presentationDetents([.medium, .large], selection: $detent)
        .presentationDragIndicator(.visible)
        .presentationBackground(Color.surface)
        .sensoryFeedback(.success, trigger: sentCount)
        .task { await load() }
        .onChange(of: current.status) { _, _ in Task { await load(silently: true) } }
        .task(id: current.status == .running) {
            // While it works, keep the log current.
            guard current.status == .running else { return }
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(5))
                guard !Task.isCancelled else { return }
                await load(silently: true)
            }
        }
        .confirmationDialog("归档这个会话？", isPresented: $confirmingArchive, titleVisibility: .visible) {
            Button("归档并停止", role: .destructive) { archive(current) }
            Button("取消", role: .cancel) {}
        } message: {
            Text("它还在工作，归档会让它停下来。")
        }
    }

    // MARK: Header

    private func header(_ s: OPASession, _ parsed: (kind: SessionKind, title: String), _ chip: TaskChip) -> some View {
        HStack(alignment: .center, spacing: 10) {
            Image(systemName: parsed.kind.symbol)
                .font(.system(.title3, weight: .regular))
                .foregroundStyle(Color.inkSecondary)
                .frame(width: 40, height: 40)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 2) {
                Text(verbatim: parsed.title)
                    .font(.orbitCardTitle)
                    .foregroundStyle(Color.ink)
                    .lineLimit(2)
                    .multilineTextAlignment(.leading)
                    .accessibilityAddTraits(.isHeader)
                TimelineView(.periodic(from: .now, by: 30)) { context in
                    Text(verbatim: SessionPresentation.subtitle(for: s, kind: parsed.kind, chipText: chip.text, now: context.date))
                        .font(.orbitMeta)
                        .foregroundStyle(Color.inkSecondary)
                        .multilineTextAlignment(.leading)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            Button { dismiss() } label: {
                Image(systemName: "xmark")
                    .font(.system(size: 17, weight: .medium))
                    .foregroundStyle(Color.inkSecondary)
                    .frame(width: 44, height: 44)
                    .contentShape(.rect)
            }
            .buttonStyle(.pressable)
            .accessibilityLabel("关闭")
        }
        .padding(.leading, 22)
        .padding(.trailing, 17)
        .padding(.top, 14)
        .padding(.bottom, Space.s)
    }

    private func tags(_ s: OPASession, _ chip: TaskChip) -> some View {
        ChipFlow(spacing: 14) {
            StatusChip(kind: chip.kind, text: chip.text, dot: chip.dot)
                .padding(.trailing, Space.xs)
            if let label = SessionPresentation.modelLabel(s.model, models: model.models) {
                MetaChip(systemImage: "cpu", text: label)
            }
            MetaChip(systemImage: "shield", text: SessionPresentation.permissionLabel(s.permission))
        }
        .padding(.top, 6)
        .padding(.bottom, Space.m)
    }

    // MARK: Log

    @ViewBuilder
    private var actionLog: some View {
        switch loadState {
        case .loading where items.isEmpty:
            HStack(spacing: 10) {
                ProgressView()
                Text("正在读取动作记录…")
                    .font(.orbitSecondary)
                    .foregroundStyle(Color.inkSecondary)
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 28)
            .accessibilityElement(children: .combine)
        case .failed(let message) where items.isEmpty:
            VStack(alignment: .leading, spacing: 10) {
                NoteBlock(kind: .warn, systemImage: "exclamationmark.triangle", text: "没能读取动作记录：\(message)")
                Button("重试") { Task { await load() } }
                    .buttonStyle(.orbit(.inset, size: .small))
            }
            .padding(.top, Space.m)
        default:
            if items.isEmpty {
                Text("暂无动作记录")
                    .font(.orbitSecondary)
                    .foregroundStyle(Color.inkSecondary)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 28)
            } else {
                VStack(spacing: 0) {
                    ForEach(Array(items.enumerated()), id: \.offset) { _, item in
                        SessionItemRow(item: item)
                    }
                }
                .padding(.top, 4)
            }
        }
    }

    // MARK: Actions

    @ViewBuilder
    private func actionBar(_ s: OPASession) -> some View {
        VStack(spacing: 10) {
            if let notice {
                NoteBlock(kind: notice.kind, systemImage: Self.symbol(for: notice.kind), text: notice.text)
                    .transition(.opacity)
            }
            if s.status == .archived {
                NoteBlock(kind: .info, systemImage: "archivebox", text: "这个会话已归档，不能再补充指令。")
            } else if composing {
                composer(s)
            } else {
                buttons(s)
            }
        }
        .padding(.horizontal, 22)
        .padding(.top, 10)
        .padding(.bottom, Space.m)
        .frame(maxWidth: .infinity)
        .background(Color.surface)
    }

    private func buttons(_ s: OPASession) -> some View {
        let canStop = s.status == .running || s.status == .waiting_approval
        return ViewThatFits(in: .horizontal) {
            HStack(spacing: 10) {
                steerButton
                if canStop { stopButton(s) }
                archiveButton(s)
            }
            VStack(spacing: Space.s) {
                steerButton
                if canStop { stopButton(s) }
                archiveButton(s)
            }
        }
    }

    private var steerButton: some View {
        Button {
            withAnimation(MotionAware(reduce: reduceMotion).spring) { composing = true }
            detent = .large
        } label: {
            Label("补充指令", systemImage: "pencil").frame(maxWidth: .infinity)
        }
        .buttonStyle(.orbit(.inset, size: .small))
        .disabled(busy)
    }

    private func stopButton(_ s: OPASession) -> some View {
        Button {
            send("interrupt", to: s, success: "已请求中止这一轮，等 Mac 确认。")
        } label: {
            Label("中止这一轮", systemImage: "stop.circle").frame(maxWidth: .infinity)
        }
        .buttonStyle(.orbit(.inset, size: .small))
        .disabled(busy)
    }

    private func archiveButton(_ s: OPASession) -> some View {
        Button {
            if s.status == .running || s.status == .waiting_approval { confirmingArchive = true } else { archive(s) }
        } label: {
            Text("归档").frame(maxWidth: .infinity)
        }
        .buttonStyle(.orbit(.inset, size: .small))
        .disabled(busy)
    }

    private func composer(_ s: OPASession) -> some View {
        let text = steerText.trimmingCharacters(in: .whitespacesAndNewlines)
        return VStack(alignment: .leading, spacing: 10) {
            TextField("告诉这个会话接下来怎么做…", text: $steerText, axis: .vertical)
                .lineLimit(1...4)
                .focused($steerFocused)
                .font(.system(.body))
                .padding(.horizontal, 14)
                .padding(.vertical, 10)
                .background(Color.surface, in: .rect(cornerRadius: Radius.control, style: .continuous))
                .overlay { RoundedRectangle(cornerRadius: Radius.control, style: .continuous).strokeBorder(Color.hairline, lineWidth: 0.5) }
                .onAppear { steerFocused = true }
            HStack(spacing: 10) {
                Button("取消") {
                    steerFocused = false
                    withAnimation(MotionAware(reduce: reduceMotion).spring) { composing = false }
                }
                .buttonStyle(.orbit(.plain, size: .small))
                Spacer(minLength: 0)
                Button {
                    send("steer", text: text, to: s, success: "已发送，Orbit 会让这个会话接着照做。") {
                        steerText = ""
                        steerFocused = false
                        composing = false
                    }
                } label: {
                    if busy {
                        ProgressView().tint(Color.onPrimary)
                    } else {
                        Label("发送", systemImage: "arrow.up")
                    }
                }
                .buttonStyle(.orbit(.primary, size: .small))
                .disabled(text.isEmpty || busy)
            }
        }
    }

    private func archive(_ s: OPASession) {
        send("archive", to: s, success: "已归档。") { dismiss() }
    }

    /// `task.cmd` for this session. Answered inline (a toast would sit behind the sheet).
    private func send(_ cmd: String, text: String? = nil, to s: OPASession, success: String, then: (() -> Void)? = nil) {
        guard !busy else { return }
        busy = true
        Task {
            defer { busy = false }
            var params: [String: JSONValue] = ["sessionId": .string(s.id), "cmd": .string(cmd)]
            if let text { params["text"] = .string(text) }
            do {
                try await model.request("task.cmd", .object(params))
                sentCount += 1
                show(Notice(kind: .good, text: success))
                then?()
            } catch {
                show(Notice(kind: .danger, text: error.localizedDescription))
            }
        }
    }

    private func show(_ new: Notice) {
        notice = new
        noticeToken += 1
        let token = noticeToken
        Task {
            try? await Task.sleep(for: .seconds(4))
            if noticeToken == token { notice = nil }
        }
    }

    private static func symbol(for kind: NoteKind) -> String {
        switch kind {
        case .good: "checkmark.circle"
        case .danger: "exclamationmark.circle"
        case .warn: "exclamationmark.triangle"
        case .info: "info.circle"
        }
    }

    // MARK: Loading

    /// Reads the action log. A silent reload (refresh, status change, polling) keeps what is on screen and says
    /// nothing when it fails; the first load shows a spinner and, on failure, the reason with a retry.
    private func load(silently: Bool = false) async {
        if !silently { loadState = .loading }
        do {
            let (detail, entries) = try await model.sessionDetail(session.id)
            fetched = detail ?? fetched
            withAnimation(MotionAware(reduce: reduceMotion).spring) {
                items = entries
                loadState = .loaded
            }
        } catch {
            if items.isEmpty {
                loadState = .failed(error.localizedDescription)
            } else if !silently {
                loadState = .loaded
            }
        }
    }
}

// MARK: - Pieces

/// One line of the action log: time, a symbol for the kind of action, a sentence.
private struct SessionItemRow: View {
    let item: SessionItem
    @ScaledMetric(relativeTo: .caption) private var timeWidth: CGFloat = 44

    var body: some View {
        let isCommand = SessionPresentation.isCommand(kind: item.kind)
        HStack(alignment: .firstTextBaseline, spacing: Space.s) {
            Text(verbatim: Fmt.time(item.ts))
                .font(.system(.caption))
                .monospacedDigit()
                .foregroundStyle(Color.inkTertiary)
                .frame(width: timeWidth, alignment: .leading)
            Image(systemName: SessionPresentation.itemSymbol(kind: item.kind))
                .font(.system(.subheadline))
                .foregroundStyle(Color.inkSecondary)
                .frame(width: 22)
                .accessibilityHidden(true)
            Text(verbatim: item.text)
                .font(isCommand ? .system(.footnote, design: .monospaced) : .system(.subheadline))
                .foregroundStyle(item.kind == "reasoning" ? Color.inkSecondary : Color.ink)
                .lineLimit(4)
                .multilineTextAlignment(.leading)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(.vertical, Space.s)
        .accessibilityElement(children: .combine)
    }
}

/// Neutral tag in secondary text, no fill: the model, the permission.
private struct MetaChip: View {
    var systemImage: String
    var text: String

    var body: some View {
        HStack(spacing: 5) {
            Image(systemName: systemImage).imageScale(.small)
            Text(verbatim: text)
        }
        .font(.system(.footnote, weight: .medium))
        .foregroundStyle(Color.inkSecondary)
        .padding(.vertical, 4)
        .frame(minHeight: 24)
        .fixedSize(horizontal: true, vertical: false)
        .accessibilityElement(children: .combine)
    }
}

/// Lays its children out left to right and wraps onto a new line when the next one does not fit.
private struct ChipFlow: Layout {
    var spacing: CGFloat = 6

    private struct Row {
        var items: [(index: Int, size: CGSize)] = []
        var width: CGFloat = 0
        var height: CGFloat = 0
    }

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let rows = arrange(width: proposal.width ?? .infinity, subviews: subviews)
        let height = rows.reduce(0) { $0 + $1.height } + CGFloat(max(rows.count - 1, 0)) * spacing
        return CGSize(width: rows.map(\.width).max() ?? 0, height: height)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        var y = bounds.minY
        for row in arrange(width: bounds.width, subviews: subviews) {
            var x = bounds.minX
            for item in row.items {
                subviews[item.index].place(at: CGPoint(x: x, y: y), proposal: ProposedViewSize(item.size))
                x += item.size.width + spacing
            }
            y += row.height + spacing
        }
    }

    private func arrange(width: CGFloat, subviews: Subviews) -> [Row] {
        var rows = [Row()]
        for index in subviews.indices {
            var size = subviews[index].sizeThatFits(.unspecified)
            if width.isFinite, size.width > width { size = subviews[index].sizeThatFits(ProposedViewSize(width: width, height: nil)) }
            let startsRow = rows[rows.count - 1].items.isEmpty
            if !startsRow, rows[rows.count - 1].width + spacing + size.width > width { rows.append(Row()) }
            let isFirst = rows[rows.count - 1].items.isEmpty
            rows[rows.count - 1].items.append((index, size))
            rows[rows.count - 1].width += isFirst ? size.width : spacing + size.width
            rows[rows.count - 1].height = max(rows[rows.count - 1].height, size.height)
        }
        return rows
    }
}
