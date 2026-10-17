import SwiftUI

// The empty state of the chat ("舞台"): a warm vignette, the big character, who is speaking and what Orbit offers.
// It is the only place the character is the protagonist; as soon as there is a first message (or the keyboard /
// attachment tray opens) it shrinks into the header avatar.

struct ChatStage: View {
    @Environment(AppModel.self) private var model
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.colorScheme) private var scheme

    var hero: Namespace.ID

    /// Height of the character, the status line and the two texts, once drawn: what "最近" has to leave room for.
    @State private var stageHeight: CGFloat?
    /// One row of "最近" (56 pt and its Hairline) and its title, scaled with the text size.
    @ScaledMetric(relativeTo: .body) private var recentRowHeight: CGFloat = 56.5
    @ScaledMetric(relativeTo: .footnote) private var recentTitleHeight: CGFloat = 24

    /// Space kept free above the character (it has always sat 30 pt below the header).
    private static let topInset: CGFloat = 30
    /// The least gap between the subtitle and "最近", and the margin under the list (the composer has its own).
    private static let recentGap: CGFloat = 20
    private static let recentBottom: CGFloat = 14

    var body: some View {
        let presence = model.presence
        let finished = Array(model.finishedTasks.prefix(3))
        GeometryReader { proxy in
            let rows = recentRows(of: finished.count, in: proxy.size.height)
            ScrollView {
                VStack(spacing: 0) {
                    VStack(spacing: 0) {
                        OrbitMascot(pose: presence.mood, size: 140, greet: presence.mood == .wave)
                            .modifier(HeroMatch(namespace: hero))
                        speaker(presence)
                            .padding(.top, 14)
                        Text("今天想把什么交给我？")
                            .font(.orbitEmptyTitle)
                            .foregroundStyle(Color.ink)
                            .multilineTextAlignment(.center)
                            .padding(.horizontal, Space.xl)
                            .padding(.top, 10)
                        Text("我在你的 Mac 上动手。花钱、对外发送这类事，只在你明确要求或批准后才做。")
                            .font(.orbitSecondary)
                            .lineSpacing(3)
                            .foregroundStyle(Color.inkSecondary)
                            .multilineTextAlignment(.center)
                            .padding(.horizontal, 48)
                            .padding(.top, 8)
                    }
                    .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { stageHeight = $0 }
                    // "最近" sits at the bottom, above the composer, and only when it fits without pushing the
                    // character: two rows when three do not fit, nothing when two do not.
                    if rows > 0 {
                        Spacer(minLength: Self.recentGap)
                        RecentTasksSection(tasks: Array(finished.prefix(rows)))
                            .padding(.bottom, Self.recentBottom)
                            .transition(.opacity)
                    }
                }
                .padding(.top, Self.topInset)
                .frame(maxWidth: .infinity, minHeight: proxy.size.height, alignment: .top)
                .animation(MotionAware(reduce: reduceMotion).snappy, value: rows)
            }
            .scrollBounceBehavior(.basedOnSize)
            .scrollIndicators(.hidden)
        }
        .background { backdrop }
        .accessibilityElement(children: .contain)
    }

    /// How many of the last finished tasks fit under the stage in a view `height` tall. Nothing until the stage itself has
    /// been measured.
    private func recentRows(of available: Int, in height: CGFloat) -> Int {
        guard let stageHeight else { return 0 }
        let free = height - Self.topInset - stageHeight - Self.recentGap - Self.recentBottom - recentTitleHeight
        return RecentTasksFit.rows(available: available, free: free, rowHeight: recentRowHeight)
    }

    /// "● Orbit · 待命中": the dot is green while idle, Accent while working, warning when Orbit waits or is offline.
    private func speaker(_ presence: Presence) -> some View {
        HStack(spacing: 6) {
            Circle().fill(presence.dotColor).frame(width: 6, height: 6)
            Text("\(model.chatBotName) · \(presence.text)")
                .font(.footnote)
                .foregroundStyle(Color.inkTertiary)
        }
        .accessibilityElement(children: .combine)
    }


    /// The board's `--stage`: a warm radial glow about a third of the way down, fading into Canvas.
    /// (`radial-gradient(120% 70% at 50% 30%, glow, clear 62%)`: wider than tall, no visible edge.)
    private var backdrop: some View {
        let glow = Color(hex: scheme == .dark ? "#2A221C" : "#FFF3E6") ?? .canvas
        return GeometryReader { proxy in
            let radius = proxy.size.height * 0.434
            RadialGradient(colors: [glow, glow.opacity(0)], center: .center, startRadius: 0, endRadius: radius)
                .frame(width: radius * 2, height: radius * 2)
                .scaleEffect(x: 0.8, y: 1)
                .position(x: proxy.size.width / 2, y: proxy.size.height * 0.3)
        }
        .ignoresSafeArea()
        .accessibilityHidden(true)
    }
}

// MARK: - 最近

/// How many rows of "最近" the empty state shows: up to three; when three do not fit, two; when two do not fit, none (the
/// character is never pushed to make room). With only one finished task, that one row.
enum RecentTasksFit {
    static let maxRows = 3

    /// `free`: the height left for the rows under the stage (their title excluded); `rowHeight`: one row, Hairline included.
    static func rows(available: Int, free: CGFloat, rowHeight: CGFloat) -> Int {
        guard available > 0, rowHeight > 0 else { return 0 }
        let fits = Int((free / rowHeight).rounded(.down))
        let rows = min(available, maxRows, max(fits, 0))
        return rows >= min(2, available) ? rows : 0
    }
}

/// "最近": the last finished tasks, under the stage. A 13 semibold title, then up to three rows between Hairlines: the
/// task's title, "昨天 · 已完成" under it and an arrow at the end. A row opens the task's page.
struct RecentTasksSection: View {
    var tasks: [OPATask]

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text("最近")
                .font(.system(.footnote, weight: .semibold))
                .foregroundStyle(Color.inkSecondary)
                .padding(.leading, 6)
                .padding(.bottom, 6)
                .accessibilityAddTraits(.isHeader)
            ForEach(tasks) { task in
                hairline
                RecentTaskRow(task: task)
            }
            hairline
        }
        .padding(.horizontal, Space.l)
    }

    private var hairline: some View {
        Rectangle().fill(Color.hairline).frame(height: 0.5)
    }
}

private struct RecentTaskRow: View {
    @Environment(AppModel.self) private var model
    let task: OPATask

    var body: some View {
        let title = TaskText.clean(task.title) ?? "未命名任务"
        Button { model.openTask(task.id) } label: {
            HStack(spacing: Space.m) {
                VStack(alignment: .leading, spacing: 0) {
                    Text(verbatim: title)
                        .font(.system(.body))
                        .foregroundStyle(Color.ink)
                        .lineLimit(1)
                    Text(verbatim: TaskTime.finishedLine(status: task.status, updatedAt: task.updatedAt))
                        .font(.system(.footnote))
                        .foregroundStyle(Color.inkSecondary)
                        .lineLimit(1)
                }
                Spacer(minLength: Space.s)
                Image(systemName: "chevron.right")
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(Color.inkTertiary)
                    .accessibilityHidden(true)
            }
            .padding(.horizontal, 6)
            .padding(.vertical, 8)
            .frame(maxWidth: .infinity, minHeight: 56, alignment: .leading)
            .contentShape(.rect)
        }
        .buttonStyle(DimPressStyle())
        .accessibilityElement(children: .combine)
        .accessibilityHint("打开任务详情")
    }
}
