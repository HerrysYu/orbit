import SwiftUI

#if DEBUG

/// Debug-only design-system gallery. Launch with `-OPAGallery YES`.
///
/// Extra launch arguments for automated screenshots:
/// - `-OPAGalleryScroll <section>`: scroll to a section on launch (`colors type dyn space motion components buttons
///   chips steps cards glass avatar mascot mark`).
/// - `-OPAGalleryScheme light|dark`, `-OPAGalleryText standard|large|accessibility`, `-OPAGalleryFallback YES`
///   preset the three controls at the top.
struct DesignGallery: View {
    @State private var scheme = GalleryScheme(argument: UserDefaults.standard.string(forKey: "OPAGalleryScheme"))
    @State private var textSize = GalleryTextSize(argument: UserDefaults.standard.string(forKey: "OPAGalleryText"))
    @State private var forceFallback = UserDefaults.standard.bool(forKey: "OPAGalleryFallback")

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView {
                VStack(alignment: .leading, spacing: Space.xxxl) {
                    GalleryHeader(scheme: $scheme, textSize: $textSize, forceFallback: $forceFallback)
                    // The text-size override applies to the specimens only, never to the controls above.
                    VStack(alignment: .leading, spacing: Space.xxxl) {
                        ColorsSection().id("colors")
                        TypographySection().id("type")
                        DynamicTypeSection().id("dyn")
                        SpaceSection().id("space")
                        MotionSection().id("motion")
                        ComponentsBoardSection().id("components")
                        ButtonsSection().id("buttons")
                        ChipsSection().id("chips")
                        StepsSection().id("steps")
                        CardsSection().id("cards")
                        GlassSection().id("glass")
                        AvatarSection().id("avatar")
                        MascotSection().id("mascot")
                        MarkSection().id("mark")
                    }
                    .modifier(GalleryTextSizeModifier(size: textSize.size))
                }
                .padding(.horizontal, Space.xl)
                .padding(.top, Space.xl)
                .padding(.bottom, Space.xxxl * 2)
            }
            .task {
                guard let target = UserDefaults.standard.string(forKey: "OPAGalleryScroll") else { return }
                try? await Task.sleep(for: .milliseconds(400))
                proxy.scrollTo(target, anchor: .top)
            }
        }
        .background(Color.canvas.ignoresSafeArea())
        .preferredColorScheme(scheme.colorScheme)
        .environment(\.orbitGlassFallback, forceFallback)
    }
}

// MARK: - Controls

private enum GalleryScheme: String, CaseIterable, Identifiable {
    case system, light, dark
    var id: String { rawValue }

    init(argument: String?) {
        self = argument.flatMap(GalleryScheme.init(rawValue:)) ?? .system
    }

    var label: String {
        switch self {
        case .system: "跟随系统"
        case .light: "浅色"
        case .dark: "深色"
        }
    }

    var colorScheme: ColorScheme? {
        switch self {
        case .system: nil
        case .light: .light
        case .dark: .dark
        }
    }
}

private enum GalleryTextSize: String, CaseIterable, Identifiable {
    case standard, large, accessibility
    var id: String { rawValue }

    init(argument: String?) {
        self = argument.flatMap(GalleryTextSize.init(rawValue:)) ?? .standard
    }

    var label: String {
        switch self {
        case .standard: "默认字号"
        case .large: "特大"
        case .accessibility: "辅助 3"
        }
    }

    var size: DynamicTypeSize? {
        switch self {
        case .standard: nil
        case .large: .xxxLarge
        case .accessibility: .accessibility3
        }
    }
}

private struct GalleryTextSizeModifier: ViewModifier {
    var size: DynamicTypeSize?

    @ViewBuilder
    func body(content: Content) -> some View {
        if let size { content.dynamicTypeSize(size) } else { content }
    }
}

private struct GalleryHeader: View {
    @Binding var scheme: GalleryScheme
    @Binding var textSize: GalleryTextSize
    @Binding var forceFallback: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: Space.m) {
            HStack(spacing: Space.m) {
                OrbitMark(size: 44, outlined: true, orbiting: true)
                VStack(alignment: .leading, spacing: 2) {
                    Text("Orbit 设计系统").font(.orbitPageTitle).foregroundStyle(Color.ink)
                    Text("token · 组件 · 角色  (调试画廊)").font(.orbitMeta).foregroundStyle(Color.inkSecondary)
                }
            }
            Picker("外观", selection: $scheme) {
                ForEach(GalleryScheme.allCases) { Text($0.label).tag($0) }
            }
            .pickerStyle(.segmented)
            Picker("字号", selection: $textSize) {
                ForEach(GalleryTextSize.allCases) { Text($0.label).tag($0) }
            }
            .pickerStyle(.segmented)
            Toggle("强制 iOS 18 材质回退（玻璃）", isOn: $forceFallback)
                .font(.orbitSecondary)
                .foregroundStyle(Color.inkSecondary)
                .tint(Color.accentText)
        }
    }
}

private struct GallerySection<Content: View>: View {
    var title: String
    var note: String? = nil
    @ViewBuilder var content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: Space.m) {
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.orbitCardTitle).foregroundStyle(Color.ink)
                if let note {
                    Text(note).font(.orbitMeta).foregroundStyle(Color.inkSecondary)
                }
            }
            content
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

private func caption(_ text: String) -> some View {
    Text(text).font(.orbitMeta).foregroundStyle(Color.inkSecondary)
}

/// Wraps its children onto as many lines as needed. Items wider than the container are squeezed to it.
private struct FlowLayout: Layout {
    var spacing: CGFloat = 8
    var lineSpacing: CGFloat = 8

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let rows = arrange(width: proposal.width ?? .infinity, subviews: subviews)
        let width = rows.map(\.width).max() ?? 0
        let height = rows.map(\.height).reduce(0, +) + CGFloat(max(rows.count - 1, 0)) * lineSpacing
        return CGSize(width: width, height: height)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        var y = bounds.minY
        for row in arrange(width: bounds.width, subviews: subviews) {
            var x = bounds.minX
            for item in row.items {
                subviews[item.index].place(at: CGPoint(x: x, y: y + (row.height - item.size.height) / 2), proposal: item.proposal)
                x += item.size.width + spacing
            }
            y += row.height + lineSpacing
        }
    }

    private struct Item {
        var index: Int
        var size: CGSize
        /// What the subview must be proposed again when placing it, so it lays out exactly as measured.
        var proposal: ProposedViewSize
    }

    private struct Row {
        var items: [Item] = []
        var width: CGFloat = 0
        var height: CGFloat = 0
    }

    private func arrange(width: CGFloat, subviews: Subviews) -> [Row] {
        var rows: [Row] = [Row()]
        for index in subviews.indices {
            // Ideal size first; only items wider than the container are squeezed (and may wrap).
            var proposal = ProposedViewSize.unspecified
            var size = subviews[index].sizeThatFits(proposal)
            if width.isFinite, size.width > width {
                proposal = ProposedViewSize(width: width, height: nil)
                size = subviews[index].sizeThatFits(proposal)
            }
            let isFirst = rows[rows.count - 1].items.isEmpty
            // 0.5 pt of slack: the container is handed exactly the width this layout reported, and a rounding
            // difference must not wrap the last item onto a row that was never measured.
            if !isFirst, rows[rows.count - 1].width + spacing + size.width > width + 0.5 {
                rows.append(Row())
            }
            let first = rows[rows.count - 1].items.isEmpty
            rows[rows.count - 1].items.append(Item(index: index, size: size, proposal: proposal))
            rows[rows.count - 1].width += first ? size.width : spacing + size.width
            rows[rows.count - 1].height = max(rows[rows.count - 1].height, size.height)
        }
        return rows
    }
}

// MARK: - Colors

private struct Swatch: Identifiable {
    let name: String
    let light: String
    let dark: String
    let color: Color
    var id: String { name }
}

private struct ColorsSection: View {
    private let swatches: [Swatch] = [
        Swatch(name: "canvas", light: "F7F6F4", dark: "121110", color: .canvas),
        Swatch(name: "surface", light: "FFFFFF", dark: "1C1B19", color: .surface),
        Swatch(name: "ink", light: "1D1B19", dark: "F2F0EC", color: .ink),
        Swatch(name: "inkSecondary", light: "5F5B55", dark: "A8A49D", color: .inkSecondary),
        Swatch(name: "inkTertiary", light: "736F69", dark: "8C8882", color: .inkTertiary),
        Swatch(name: "hairline", light: "E6E3DE", dark: "2E2C29", color: .hairline),
        Swatch(name: "accentText", light: "A9521A", dark: "F0A15E", color: .accentText),
        Swatch(name: "primaryFill", light: "1D1B19", dark: "F2F0EC", color: .primaryFill),
        Swatch(name: "onPrimary", light: "FFFFFF", dark: "121110", color: .onPrimary),
        Swatch(name: "userBubble", light: "ECEAE6", dark: "2A2826", color: .userBubble),
        Swatch(name: "success", light: "1F7A4A", dark: "5FC48A", color: .success),
        Swatch(name: "warning", light: "8A6100", dark: "E8C14E", color: .warning),
        Swatch(name: "danger", light: "B3261E", dark: "FF8A80", color: .danger),
        Swatch(name: "mascotDisc（角色专用）", light: "FCE9D8", dark: "453022", color: .mascotDisc),
    ]

    private let columns = [GridItem(.adaptive(minimum: 170), spacing: Space.m, alignment: .topLeading)]

    var body: some View {
        GallerySection(title: "颜色 token", note: "资源目录 Any + Dark；下面显示 浅 / 深 色值。旧名（brandSoft、surfaceInset 等）只保留兼容，已无色") {
            LazyVGrid(columns: columns, alignment: .leading, spacing: Space.s) {
                ForEach(swatches) { swatch in
                    HStack(spacing: Space.s) {
                        RoundedRectangle(cornerRadius: 10, style: .continuous)
                            .fill(swatch.color)
                            .frame(width: 34, height: 34)
                            .overlay { RoundedRectangle(cornerRadius: 10, style: .continuous).strokeBorder(Color.ink.opacity(0.15), lineWidth: 0.5) }
                        VStack(alignment: .leading, spacing: 0) {
                            Text(swatch.name).font(.system(.footnote, weight: .semibold)).foregroundStyle(Color.ink)
                            Text("\(swatch.light) / \(swatch.dark)")
                                .font(.system(.caption2, design: .monospaced))
                                .foregroundStyle(Color.inkSecondary)
                        }
                        .lineLimit(1)
                        .minimumScaleFactor(0.5)
                    }
                }
            }
        }
    }
}

// MARK: - Typography

private struct TypographySection: View {
    var body: some View {
        GallerySection(title: "字体", note: "系统字体（无圆体），文本样式映射，随动态字体缩放") {
            VStack(alignment: .leading, spacing: Space.m) {
                row("orbitWelcome", "30 / 28pt 粗体（标题 .title）") { Text("你好，我是 Orbit").font(.orbitWelcome) }
                row("orbitEmptyTitle", "22pt 半粗") { Text("今天想把什么交给我？").font(.orbitEmptyTitle) }
                row("orbitWelcome", "页面大标题同一档") { Text("任务").font(.orbitWelcome) }
                row("orbitPageTitle", "22pt 半粗") { Text("提交这家餐厅的预订").font(.orbitPageTitle) }
                row("orbitCardTitle", "17pt 半粗") { Text("订周六晚的日料").font(.orbitCardTitle) }
                row("orbitBody", "17pt") { Text("好，我先找 3 家周六 19:00 有位的店。").font(.orbitBody) }
                row("orbitBodyText()", "17pt + 行高 1.5") {
                    Text("好，我先找 3 家周六 19:00 有位的店，比较价格和评价后给你选。提交预订前会先问你。").orbitBodyText()
                }
                row("orbitSecondary", "15pt") { Text("正在把发票金额填进报销表模板").font(.orbitSecondary).foregroundStyle(Color.inkSecondary) }
                row("orbitMeta", "13pt") { Text("已完成 2 / 3 步 · 3 分钟前").font(.orbitMeta).foregroundStyle(Color.inkTertiary) }
                row("orbitAction", "15pt 中粗（行内文字按钮）") { Text("查看").font(.orbitAction).foregroundStyle(Color.accentText) }
                row("orbitChip", "13pt 中粗") { Text("进行中").font(.orbitChip).foregroundStyle(Color.inkSecondary) }
            }
            .foregroundStyle(Color.ink)
        }
    }

    private func row<Sample: View>(_ name: String, _ spec: String, @ViewBuilder sample: () -> Sample) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack(spacing: Space.s) {
                Text(name).font(.system(.caption2, design: .monospaced)).foregroundStyle(Color.inkSecondary)
                Text(spec).font(.system(.caption2)).foregroundStyle(Color.inkSecondary)
            }
            sample()
        }
    }
}

/// Diagnostic: does a fixed-size system font follow Dynamic Type? (Switch "字号" at the top to compare.)
private struct DynamicTypeSection: View {
    var body: some View {
        GallerySection(title: "动态字体对照", note: "切换顶部“字号”，看固定字号与文本样式字体谁在缩放") {
            VStack(alignment: .leading, spacing: Space.m) {
                HStack(alignment: .firstTextBaseline, spacing: Space.l) {
                    VStack(alignment: .leading) {
                        caption("system(size: 30)")
                        Text("你好Hg").font(.system(size: 30, weight: .bold))
                    }
                    VStack(alignment: .leading) {
                        caption("orbitWelcome")
                        Text("你好Hg").font(.orbitWelcome)
                    }
                }
                .foregroundStyle(Color.ink)
                HStack(alignment: .firstTextBaseline, spacing: Space.l) {
                    VStack(alignment: .leading) {
                        caption("system(size: 17)")
                        Text("你好Hg").font(.system(size: 17))
                    }
                    VStack(alignment: .leading) {
                        caption("orbitBody")
                        Text("你好Hg").font(.orbitBody)
                    }
                }
                .foregroundStyle(Color.ink)
            }
        }
    }
}

// MARK: - Space and radius

private struct SpaceSection: View {
    var body: some View {
        GallerySection(title: "间距、圆角与动效", note: "4pt 节奏（卡片内边距 14）；圆角全部 continuous；没有阴影") {
            VStack(alignment: .leading, spacing: Space.l) {
                FlowLayout(spacing: Space.m, lineSpacing: Space.m) {
                    ForEach([("xs", Space.xs), ("s", Space.s), ("m", Space.m), ("l", Space.l), ("xl", Space.xl), ("xxl", Space.xxl), ("xxxl", Space.xxxl)], id: \.0) { item in
                        VStack(spacing: 4) {
                            RoundedRectangle(cornerRadius: 3, style: .continuous).fill(Color.inkTertiary).frame(width: item.1, height: item.1)
                            caption("\(Int(item.1))")
                        }
                    }
                }
                FlowLayout(spacing: Space.m, lineSpacing: Space.m) {
                    ForEach([("8 小标签", Radius.small), ("12 卡片 / 按钮 / 输入框", Radius.card), ("16 用户气泡", Radius.bubble)], id: \.0) { item in
                        VStack(spacing: 4) {
                            RoundedRectangle(cornerRadius: item.1, style: .continuous)
                                .fill(Color.surface)
                                .frame(width: 66, height: 48)
                                .overlay { RoundedRectangle(cornerRadius: item.1, style: .continuous).strokeBorder(Color.hairline, lineWidth: 0.5) }
                            caption(item.0).lineLimit(1).minimumScaleFactor(0.7)
                        }
                    }
                }
                VStack(alignment: .leading, spacing: 4) {
                    caption("Motion：press 0.18 / snappy 0.26 / standard 0.38 / fly 0.4（bounce 0），momentum 0.42 bounce 0.18，Reduce Motion 0.15s 淡变")
                }
            }
        }
    }
}

// MARK: - Component board (mirrors the "组件" panel of the system board)

private struct ComponentsBoardSection: View {
    var body: some View {
        GallerySection(title: "组件（对照设计板）", note: "按钮 / 状态 / 步骤标记 / 连接入口 / 进度线，v2 外观") {
            VStack(alignment: .leading, spacing: Space.m) {
                FlowLayout(spacing: 10, lineSpacing: 10) {
                    Button { } label: { Label("确认预订", systemImage: "faceid") }
                        .buttonStyle(.orbit(.primary, size: .small))
                    Button("拒绝") { }.buttonStyle(.orbit(.secondary, size: .small))
                    Button("粘贴配对链接") { }.buttonStyle(.orbit(.plain, size: .small))
                    Button("取消任务") { }.buttonStyle(.orbit(.destructive, size: .small))
                }
                FlowLayout(spacing: 8, lineSpacing: 8) {
                    StatusChip(kind: .planning, text: "规划中")
                    StatusChip(kind: .running, text: "进行中", dot: true)
                    StatusChip(kind: .waiting, text: "等你补充")
                    StatusChip(kind: .blocked, text: "遇到阻碍")
                    StatusChip(kind: .done, text: "已完成")
                    StatusChip(kind: .failed, text: "未完成")
                    StatusChip(kind: .cancelled, text: "已取消")
                    StatusChip(kind: .draft, text: "草稿")
                }
                FlowLayout(spacing: 18, lineSpacing: 8) {
                    markerLabel(.done, "完成")
                    markerLabel(.running, "进行中")
                    markerLabel(.pending, "待开始")
                    markerLabel(.failed, "失败")
                    markerLabel(.skipped, "跳过")
                }
                .padding(.top, 4)
                FlowLayout(spacing: 12, lineSpacing: 8) {
                    ConnectionIndicator(state: .connected(.lan)) { }
                    ConnectionIndicator(state: .connecting) { }
                    ConnectionIndicator(state: .hostOffline) { }
                    Text("连接状态（独立于 Orbit 状态和任务状态）").font(.orbitMeta).foregroundStyle(Color.inkTertiary)
                }
                SegmentedStepBar(total: 4, done: 2, currentIndex: 2)
                    .frame(width: 200)
            }
            .padding(Space.xl)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Color.canvas, in: .rect(cornerRadius: Radius.card, style: .continuous))
            .overlay { RoundedRectangle(cornerRadius: Radius.card, style: .continuous).strokeBorder(Color.hairline, lineWidth: 0.5) }
        }
    }

    private func markerLabel(_ status: TaskStep.Status, _ text: String) -> some View {
        HStack(spacing: 6) {
            StepMarker(status: status)
            Text(text).font(.orbitMeta).foregroundStyle(Color.inkSecondary)
        }
    }
}

// MARK: - Buttons

private struct ButtonsSection: View {
    private let kinds: [(OrbitButtonKind, String)] = [
        (.primary, "确认预订"), (.secondary, "拒绝"), (.plain, "粘贴配对链接"), (.destructive, "取消任务"),
    ]

    var body: some View {
        GallerySection(title: "按钮", note: "4 种角色 x regular 48 · small 36 · mini 30；圆角 12，无胶囊；按下缩放 0.97") {
            VStack(alignment: .leading, spacing: Space.l) {
                caption("regular（整行宽 48 / 文字型 44）")
                VStack(spacing: Space.s) {
                    ForEach(kinds, id: \.1) { kind, title in
                        Button { } label: {
                            if kind == .primary { Label(title, systemImage: "faceid") } else { Text(title) }
                        }
                        .buttonStyle(.orbit(kind))
                    }
                }
                caption("small（36，贴合文字；文字型 15 中粗无内边距）")
                FlowLayout(spacing: 10, lineSpacing: 10) {
                    ForEach(kinds, id: \.1) { kind, title in
                        Button(title) { }.buttonStyle(.orbit(kind, size: .small))
                    }
                }
                caption("mini（30，贴合文字；点击区域仍 ≥ 44）")
                FlowLayout(spacing: 10, lineSpacing: 10) {
                    ForEach(kinds, id: \.1) { kind, title in
                        Button(title) { }.buttonStyle(.orbit(kind, size: .mini))
                    }
                }
                caption("命名别名：.orbitPrimary / .orbitSecondary / .orbitPlain / .orbitDestructive（旧 .soft / .inset 等同 secondary）")
                FlowLayout(spacing: 10, lineSpacing: 10) {
                    Button("Primary") { }.buttonStyle(.orbitPrimary)
                    Button("Secondary") { }.buttonStyle(.orbitSecondary)
                }
                caption("禁用（40% 不透明度）")
                FlowLayout(spacing: 10, lineSpacing: 10) {
                    Button("确认预订") { }.buttonStyle(.orbit(.primary, size: .small)).disabled(true)
                    Button("拒绝") { }.buttonStyle(.orbit(.secondary, size: .small)).disabled(true)
                    Button("取消任务") { }.buttonStyle(.orbit(.destructive, size: .small)).disabled(true)
                }
            }
        }
    }
}

// MARK: - Chips

private struct ChipsSection: View {
    var body: some View {
        GallerySection(title: "状态标签", note: "StatusChip(kind:text:) · 6pt 圆点（状态色）+ 13pt 次要文字，无底色无描边") {
            VStack(alignment: .leading, spacing: Space.m) {
                FlowLayout(spacing: 8, lineSpacing: 8) {
                    StatusChip(kind: .planning, text: "规划中")
                    StatusChip(kind: .running, text: "进行中", dot: true)
                    StatusChip(kind: .waiting, text: "等你补充")
                    StatusChip(kind: .blocked, text: "遇到阻碍")
                    StatusChip(kind: .done, text: "已完成")
                    StatusChip(kind: .failed, text: "未完成")
                    StatusChip(kind: .cancelled, text: "已取消")
                    StatusChip(kind: .draft, text: "草稿")
                    StatusChip(kind: .ok, text: "已连接")
                }
                caption("OPATask.Status.chipKind")
                FlowLayout(spacing: 8, lineSpacing: 8) {
                    ForEach([OPATask.Status.planning, .running, .waiting_user, .blocked, .done, .failed, .cancelled], id: \.self) { status in
                        StatusChip(kind: status.chipKind, text: status.label, dot: status == .running)
                    }
                }
            }
        }
    }
}

// MARK: - Steps

private struct StepsSection: View {
    var body: some View {
        GallerySection(title: "步骤与进度", note: "StepMarker 20pt 圆环 · 进度线 2pt（轨道 Hairline，填充 Accent；只用步数，不用百分比）") {
            VStack(alignment: .leading, spacing: Space.l) {
                OrbitCard(padding: Space.card) {
                    VStack(alignment: .leading, spacing: 0) {
                        GalleryStepRow(status: .done, title: "理解需求", subtitle: nil, isLast: false)
                        GalleryStepRow(status: .running, title: "搜索附近的日料店", subtitle: "在大众点评筛选：评分 4.5+、人均 ≤ ¥300、静安附近", isLast: false)
                        GalleryStepRow(status: .pending, title: "核对周六 19:00 的空位", subtitle: nil, isLast: false)
                        GalleryStepRow(status: .failed, title: "提交预订", subtitle: "餐厅没有回应", isLast: false)
                        GalleryStepRow(status: .skipped, title: "通知同行的人", subtitle: nil, isLast: true)
                    }
                }
                VStack(alignment: .leading, spacing: Space.m) {
                    barRow("0 / 4", total: 4, done: 0, current: 0)
                    barRow("1 / 4 · 第 2 步进行中", total: 4, done: 1, current: 1)
                    barRow("2 / 4 · 第 3 步进行中", total: 4, done: 2, current: 2)
                    barRow("4 / 4", total: 4, done: 4, current: nil)
                    barRow("2 / 6", total: 6, done: 2, current: 2)
                }
            }
        }
    }

    private func barRow(_ label: String, total: Int, done: Int, current: Int?) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            caption(label)
            SegmentedStepBar(total: total, done: done, currentIndex: current)
        }
    }
}

/// Step row with the vertical hairline rail used by task cards (gallery-only composition).
private struct GalleryStepRow: View {
    var status: TaskStep.Status
    var title: String
    var subtitle: String?
    var isLast: Bool

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            StepMarker(status: status).padding(.top, 1)
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.orbitSecondary.weight(status == .running ? .semibold : .regular))
                    .foregroundStyle(status == .running ? Color.ink : (status == .pending ? Color.inkTertiary : Color.inkSecondary))
                if let subtitle {
                    Text(subtitle).font(.orbitMeta).foregroundStyle(Color.inkSecondary)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(.vertical, 5)
        .background(alignment: .topLeading) {
            if !isLast {
                Rectangle().fill(Color.hairline).frame(width: 1).padding(.top, 25).padding(.bottom, -5).padding(.leading, 9.5)
            }
        }
    }
}

// MARK: - Cards, notes, key-value list, section header

private struct CardsSection: View {
    var body: some View {
        GallerySection(title: "卡片、提示块、键值表", note: "OrbitCard · NoteBlock · KeyValueList · SectionHeader · HintRow") {
            VStack(alignment: .leading, spacing: Space.l) {
                caption("任务进度卡：标题 + 一行状态 + 2pt 进度线")
                OrbitCard(padding: Space.card) {
                    VStack(alignment: .leading, spacing: 0) {
                        Text("订周六晚上的日料").font(.orbitCardTitle).foregroundStyle(Color.ink)
                        StatusChip(kind: .running, text: "3/4 步 · 正在确认空位").padding(.top, 2)
                        ProgressLine(fraction: 0.75).padding(.top, 10)
                    }
                }
                caption("对比卡行：名称 | 价格（等宽数字），下一行事实 + 选这家")
                OrbitCard(padding: Space.card) {
                    VStack(alignment: .leading, spacing: 0) {
                        galleryOption("鮨 · 静安店", recommended: true, facts: "4.8 分 · 1.2 km", price: "¥280", unit: "/人")
                        HairlineRule().padding(.vertical, 10)
                        galleryOption("一番寿司", recommended: false, facts: "4.6 分 · 2.0 km", price: "¥240", unit: "/人")
                        HairlineRule().padding(.top, 10)
                        Text("鮨 · 静安店：评分最高，有吧台位，19:00 有位")
                            .font(.orbitMeta).foregroundStyle(Color.inkSecondary).padding(.top, 10)
                    }
                }
                caption("键值行（卡片内：只有行间分隔线）")
                OrbitCard(padding: Space.card) {
                    KeyValueList(rows: [("餐厅", "鮨 · 静安店"), ("时间", "10 月 18 日 周六 19:00"), ("人数", "2 人 · 吧台位")])
                }
                caption("键值行（framed：上下也有分隔线，用于 Sheet）")
                KeyValueList(rows: [
                    ("餐厅", "鮨 · 静安店（大众点评 4.8）"),
                    ("时间", "10 月 18 日 周六 19:00"),
                    ("人数", "2 人 · 吧台位"),
                    ("费用", "人均约 ¥280，到店付款"),
                ], framed: true)
                caption("提示行：一行文字 + Accent 文字按钮，上下各一条 Hairline")
                VStack(spacing: 0) {
                    HintRow(text: "已记住：Herry 不吃香菜") { Button("撤销") { }.buttonStyle(.orbit(.plain, size: .mini)) }
                    HintRow(text: "需要你确认：提交这家餐厅的预订", dot: .warning, emphasized: true) {
                        Button("查看") { }.buttonStyle(.orbit(.plain, size: .mini))
                    }
                }
                caption("提示块 NoteBlock：info 次要文字；warn / danger / good 只有文字色和小图标")
                VStack(alignment: .leading, spacing: Space.s) {
                    NoteBlock(kind: .info, systemImage: "info.circle") { Text("批准后：我会在安卓手机上用大众点评提交预订，餐厅可能会发确认短信。不会在线付款。") }
                    NoteBlock(kind: .warn, systemImage: "clock", text: "Mac 暂时离线，消息会排队，连上后自动发送。")
                    NoteBlock(kind: .danger, systemImage: "exclamationmark.circle") { Text("这会向餐厅发送真实预订，无法由 Orbit 撤回。") }
                    NoteBlock(kind: .good, systemImage: "checkmark.circle", text: "已预订：鮨 · 静安店，周六 19:00。")
                }
                VStack(alignment: .leading, spacing: Space.s) {
                    SectionHeader(title: "进行中")
                    SectionHeader(title: "等你处理", count: 2)
                    SectionHeader(
                        title: "已结束",
                        count: 5,
                        trailing: AnyView(Button("清除") { }.buttonStyle(.orbit(.plain, size: .mini)))
                    )
                }
            }
        }
    }

    private func galleryOption(_ name: String, recommended: Bool, facts: String, price: String, unit: String) -> some View {
        HStack(alignment: .top, spacing: 12) {
            VStack(alignment: .leading, spacing: 2) {
                HStack(alignment: .firstTextBaseline, spacing: 6) {
                    Text(name).font(.orbitBody.weight(recommended ? .semibold : .regular)).foregroundStyle(Color.ink)
                    if recommended { Text("推荐").font(.orbitChip).foregroundStyle(Color.accentText) }
                }
                Text(facts).font(.orbitMeta).monospacedDigit().foregroundStyle(Color.inkSecondary)
            }
            Spacer(minLength: 0)
            VStack(alignment: .trailing, spacing: 2) {
                Text("\(Text(price).font(.orbitBody).monospacedDigit())\(Text(unit).font(.orbitMeta).foregroundStyle(Color.inkSecondary))")
                    .foregroundStyle(Color.ink)
                Button("选这家") { }.buttonStyle(.orbit(.plain, size: .mini))
            }
        }
    }
}

// MARK: - Glass and connection

private struct GlassSection: View {
    var body: some View {
        GallerySection(title: "玻璃按钮与连接入口", note: "玻璃只留在扫码页和返回按钮：iOS 26 glassEffect，iOS 18 回退为 ultraThinMaterial + 描边；连接入口无底色") {
            VStack(alignment: .leading, spacing: Space.l) {
                caption("GlassCircleButton（画布 / 彩色背景）")
                HStack(spacing: Space.l) {
                    GlassCircleButton(systemImage: "laptopcomputer", accessibilityLabel: "连接") { }
                    GlassCircleButton(systemImage: "plus", accessibilityLabel: "添加") { }
                    GlassCircleButton(systemImage: "xmark", accessibilityLabel: "关闭") { }
                    ZStack {
                        LinearGradient(colors: [Color.accentText, Color.hairline, Color.success], startPoint: .topLeading, endPoint: .bottomTrailing)
                        HStack(spacing: Space.l) {
                            GlassCircleButton(systemImage: "laptopcomputer", accessibilityLabel: "连接") { }
                            GlassCircleButton(systemImage: "arrow.up", accessibilityLabel: "发送") { }
                        }
                    }
                    .frame(height: 76)
                    .clipShape(.rect(cornerRadius: Radius.note, style: .continuous))
                }
                caption("ConnectionIndicator（无底色）：已连接 / 连接中 / 重连等待 / Mac 离线 / 失败")
                FlowLayout(spacing: 14, lineSpacing: 12) {
                    ConnectionIndicator(state: .connected(.lan)) { }
                    ConnectionIndicator(state: .connected(.relay)) { }
                    ConnectionIndicator(state: .connecting) { }
                    ConnectionIndicator(state: .waitingRetry(seconds: 5, reason: "网络变化")) { }
                    ConnectionIndicator(state: .hostOffline) { }
                    ConnectionIndicator(state: .failed("连接失败")) { }
                }
                caption("同一组件，强制材质回退（iOS 18 路径）")
                HStack(spacing: Space.l) {
                    GlassCircleButton(systemImage: "laptopcomputer", accessibilityLabel: "连接") { }
                    ConnectionIndicator(state: .connected(.lan)) { }
                    ConnectionIndicator(state: .connecting) { }
                }
                .environment(\.orbitGlassFallback, true)
            }
        }
    }
}

// MARK: - Avatar

private struct AvatarSection: View {
    var body: some View {
        GallerySection(title: "头像", note: "OrbitAvatar(size:ring:) · 20 / 42 / 76；v2 页头不加环") {
            VStack(alignment: .leading, spacing: Space.m) {
                FlowLayout(spacing: Space.xl, lineSpacing: Space.m) {
                    labeled("20") { OrbitAvatar(size: 20) }
                    labeled("42") { OrbitAvatar(size: 42) }
                    labeled("76") { OrbitAvatar(size: 76) }
                    labeled("20 ring") { OrbitAvatar(size: 20, ring: true) }
                    labeled("42 ring") { OrbitAvatar(size: 42, ring: true) }
                    labeled("76 ring") { OrbitAvatar(size: 76, ring: true) }
                }
                HStack(spacing: Space.s) {
                    OrbitAvatar(size: 20)
                    Text("Orbit · 17:20").font(.system(.footnote, weight: .medium)).foregroundStyle(Color.inkTertiary)
                }
                VStack(spacing: 3) {
                    OrbitAvatar(size: 42, ring: true)
                    HStack(spacing: 2) {
                        Text("Orbit").font(.system(.subheadline, weight: .semibold))
                        Image(systemName: "chevron.right").font(.system(size: 10, weight: .semibold)).foregroundStyle(Color.inkTertiary)
                    }
                    .foregroundStyle(Color.ink)
                    HStack(spacing: 6) {
                        Circle().fill(Color.accentText).frame(width: 6, height: 6)
                        Text("正在搜索附近的日料店").font(.orbitMeta).foregroundStyle(Color.inkSecondary)
                    }
                }
                .frame(maxWidth: .infinity)
            }
        }
    }

    private func labeled<V: View>(_ label: String, @ViewBuilder _ view: () -> V) -> some View {
        VStack(spacing: 6) {
            view()
            caption(label)
        }
    }
}

// MARK: - Mascot

private struct MascotSection: View {
    @State private var replay = 0

    var body: some View {
        GallerySection(title: "角色", note: "OrbitMascot(pose:size:greet:) · 96 / 140 / 178 · 临时抠图素材") {
            VStack(alignment: .leading, spacing: Space.l) {
                caption("96pt · 六种姿态（任务空状态尺度）")
                LazyVGrid(columns: Array(repeating: GridItem(.flexible(), alignment: .bottom), count: 3), spacing: Space.l) {
                    ForEach(MascotPose.allCases, id: \.self) { pose in
                        VStack(spacing: 4) {
                            OrbitMascot(pose: pose, size: 96)
                            caption(pose.rawValue)
                        }
                    }
                }
                caption("140pt · 六种姿态（对话空状态尺度，可横向滑动）")
                posesRow(size: 140)
                caption("178pt · 六种姿态（欢迎尺度，可横向滑动）")
                posesRow(size: 178)
                caption("greet：出现时挥手一次（±6° 两次）；.happy：出现时单次 squash 弹跳")
                HStack(alignment: .bottom, spacing: Space.m) {
                    OrbitMascot(pose: .wave, size: 120, greet: true).id(replay)
                    OrbitMascot(pose: .happy, size: 120).id(replay)
                    Button("重播动效") { replay += 1 }.buttonStyle(.orbit(.secondary, size: .small))
                }
            }
        }
    }

    private func posesRow(size: CGFloat) -> some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(alignment: .bottom, spacing: Space.m) {
                ForEach(MascotPose.allCases, id: \.self) { pose in
                    VStack(spacing: 4) {
                        OrbitMascot(pose: pose, size: size)
                        caption(pose.rawValue)
                    }
                }
            }
            .padding(.bottom, Space.s)
        }
        .scrollClipDisabled()
    }
}

// MARK: - Motion demo

/// Live demo of the motion tokens: chip swap (snappy), card expand (standard) and press feedback.
private struct MotionSection: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var step = 0
    @State private var expanded = false
    private let chips: [(StatusKind, String, Bool)] = [
        (.planning, "规划中", false), (.running, "进行中", true), (.waiting, "等你补充", false), (.done, "已完成", false),
    ]

    var body: some View {
        let motion = MotionAware(reduce: reduceMotion)
        GallerySection(title: "动效演示", note: "点按试试：snappy 0.26 / standard 0.38；减少动态效果时改为 0.15s 淡变") {
            VStack(alignment: .leading, spacing: Space.l) {
                HStack(spacing: Space.m) {
                    let chip = chips[step % chips.count]
                    StatusChip(kind: chip.0, text: chip.1, dot: chip.2)
                    Spacer()
                    Button("切换状态") { withAnimation(motion.snappy) { step += 1 } }
                        .buttonStyle(.orbit(.secondary, size: .small))
                }
                OrbitCard {
                    VStack(alignment: .leading, spacing: 0) {
                        Button {
                            withAnimation(motion.spring) { expanded.toggle() }
                        } label: {
                            HStack {
                                Text("订周六晚的日料").font(.orbitCardTitle).foregroundStyle(Color.ink)
                                Spacer()
                                Image(systemName: "chevron.down")
                                    .font(.system(size: 13, weight: .semibold))
                                    .foregroundStyle(Color.inkTertiary)
                                    .rotationEffect(.degrees(expanded ? 180 : 0))
                            }
                            .padding(Space.l)
                            .contentShape(.rect)
                        }
                        .buttonStyle(.pressable)
                        if expanded {
                            Text("原位展开，内容不跳动。已完成 1 / 4 步 · 刚刚更新")
                                .font(.orbitSecondary)
                                .foregroundStyle(Color.inkSecondary)
                                .padding([.horizontal, .bottom], Space.l)
                                .transition(.opacity)
                        }
                    }
                }
            }
        }
    }
}

// MARK: - Orbit mark

private struct MarkSection: View {
    var body: some View {
        GallerySection(title: "星环标识 OrbitMark", note: "矢量，16 / 24 / 40 / 64；Shared/OrbitMark.swift（App 与 Widget 共用）") {
            VStack(alignment: .leading, spacing: Space.l) {
                caption("浅底（outlined）")
                HStack(alignment: .center, spacing: Space.xl) {
                    OrbitMark(size: 64, outlined: true)
                    OrbitMark(size: 40, outlined: true)
                    OrbitMark(size: 24, outlined: true)
                    OrbitMark(size: 16, outlined: true)
                }
                caption("无描边")
                HStack(alignment: .center, spacing: Space.xl) {
                    OrbitMark(size: 64)
                    OrbitMark(size: 40)
                    OrbitMark(size: 24)
                    OrbitMark(size: 16)
                }
                caption("orbiting（小卫星沿星环运行；减少动态效果时静止）")
                HStack(alignment: .center, spacing: Space.xl) {
                    OrbitMark(size: 64, outlined: true, orbiting: true)
                    OrbitMark(size: 40, outlined: true, orbiting: true)
                    OrbitMark(size: 24, outlined: true, orbiting: true)
                    OrbitMark(size: 16, outlined: true, orbiting: true)
                }
                caption("灵动岛 / 深色底")
                HStack(spacing: Space.l) {
                    HStack(spacing: 12) {
                        OrbitMark(size: 24)
                        OrbitMark(size: 16)
                    }
                    .padding(.horizontal, 14)
                    .padding(.vertical, 8)
                    .background(Color.black, in: .rect(cornerRadius: 20, style: .continuous))
                    HStack(spacing: 12) {
                        OrbitMark(size: 24, orbiting: true)
                        Text("2/4").font(.system(.subheadline, weight: .semibold)).foregroundStyle(Color(red: 0xF2 / 255, green: 0xAD / 255, blue: 0x73 / 255))
                    }
                    .padding(.horizontal, 14)
                    .padding(.vertical, 6)
                    .background(Color.black, in: .capsule)
                }
                caption("旧调用 OrbitMark(size:)（迁移期兼容）")
                OrbitMark(size: 76).frame(width: 76, height: 76).clipShape(.circle).background(Color.mascotDisc, in: .circle)
            }
        }
    }
}

#else

/// Release builds ship a one-line stand-in so the `-OPAGallery YES` hook in `RootView` still compiles.
struct DesignGallery: View {
    var body: some View {
        Text("设计画廊仅在 Debug 构建中可用")
            .font(.orbitMeta)
            .foregroundStyle(Color.inkSecondary)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(Color.canvas)
    }
}

#endif
