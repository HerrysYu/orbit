import SwiftUI

// MARK: - Hairline

/// A 0.5 pt separator in the Hairline color, full width of its container. The one way to divide things in v2: rows,
/// card footers, grouped lists, key-value rows. (A tinted block is never the answer.)
struct HairlineRule: View {
    var body: some View {
        Rectangle()
            .fill(Color.hairline)
            .frame(height: 0.5)
            .accessibilityHidden(true)
    }
}

// MARK: - Card

/// Card chrome: Surface fill, 12 pt continuous corners, a 0.5 pt Hairline stroke, content clipped to the corners.
/// No shadow in light or dark mode: the card is separated by its fill and its stroke alone.
struct OrbitCardSurface: ViewModifier {
    var padding: CGFloat = 0

    func body(content: Content) -> some View {
        let shape = RoundedRectangle(cornerRadius: Radius.card, style: .continuous)
        content
            .padding(padding)
            .frame(maxWidth: .infinity, alignment: .leading)
            .clipShape(shape)
            .background { shape.fill(Color.surface) }
            .overlay { shape.strokeBorder(Color.hairline, lineWidth: 0.5) }
    }
}

/// Card container. `padding` defaults to 0 so header / body / footer rows and grouped-list rows can run edge to edge
/// (a footer with a hairline divider, a row separator); pass `padding: Space.card` (14) for simple content.
struct OrbitCard<Content: View>: View {
    var padding: CGFloat
    @ViewBuilder var content: Content

    init(padding: CGFloat = 0, @ViewBuilder content: () -> Content) {
        self.padding = padding
        self.content = content()
    }

    var body: some View {
        content.modifier(OrbitCardSurface(padding: padding))
    }
}

// MARK: - Note block

enum NoteKind: Sendable, Hashable, CaseIterable {
    /// Neutral explanation: secondary text, nothing behind it.
    case info
    /// Needs attention, e.g. offline or waiting (Warning text).
    case warn
    /// Consequence or failure (Danger text).
    case danger
    /// Positive confirmation (Success text).
    case good
}

/// An inline notice: one run of 15 pt text, with a small leading SF Symbol for the kinds that call for attention.
/// No fill, no stroke, no padding of its own: the text lines up with whatever it sits next to. `.info` is plain
/// secondary text without an icon ("批准后：我会在安卓手机上…"); `.warn` / `.danger` / `.good` color the text and
/// carry the icon, so the meaning never rests on color alone. `showsIcon` overrides the default either way.
struct NoteBlock<Content: View>: View {
    var kind: NoteKind
    var systemImage: String
    var showsIcon: Bool
    @ViewBuilder var content: Content

    init(kind: NoteKind, systemImage: String, showsIcon: Bool? = nil, @ViewBuilder content: () -> Content) {
        self.kind = kind
        self.systemImage = systemImage
        self.showsIcon = showsIcon ?? (kind != .info)
        self.content = content()
    }

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            if showsIcon && !systemImage.isEmpty {
                Image(systemName: systemImage)
                    .symbolRenderingMode(.monochrome)
                    .font(.system(.footnote, weight: .semibold))
            }
            content
                .font(.orbitSecondary)
                .lineSpacing(2)
                .frame(maxWidth: .infinity, alignment: .leading)
                .fixedSize(horizontal: false, vertical: true)
        }
        .foregroundStyle(foreground)
        .accessibilityElement(children: .combine)
    }

    private var foreground: Color {
        switch kind {
        case .info: .inkSecondary
        case .warn: .warning
        case .danger: .danger
        case .good: .success
        }
    }
}

extension NoteBlock where Content == Text {
    /// Plain-text convenience.
    init(kind: NoteKind, systemImage: String, showsIcon: Bool? = nil, text: String) {
        self.init(kind: kind, systemImage: systemImage, showsIcon: showsIcon) { Text(text) }
    }
}

// MARK: - Key-value list

/// Label / value rows divided by hairlines ("餐厅 / 时间 / 人数 / 费用"): label 15 pt InkSecondary, value 17 pt Ink.
/// No fill. Inside a card the rows sit flush with the card's padding and only the gaps between rows get a line;
/// `framed` (a sheet) adds a line above the first row and below the last. At accessibility text sizes each row
/// stacks its label above the value.
struct KeyValueList: View {
    var rows: [(String, String)]
    /// Also draw a hairline above the first row and below the last (approval sheet). Default: lines between rows only.
    var framed: Bool = false

    @Environment(\.dynamicTypeSize) private var typeSize
    @ScaledMetric(relativeTo: .body) private var keyWidth: CGFloat = 64

    var body: some View {
        // 11 pt above and below each row inside a frame; 8 pt in a card, where the first and last rows touch the padding.
        let gap: CGFloat = framed ? 11 : 8
        VStack(spacing: 0) {
            if framed { HairlineRule() }
            ForEach(Array(rows.enumerated()), id: \.offset) { index, row in
                if index > 0 { HairlineRule() }
                line(row.0, row.1)
                    .padding(.top, index == 0 && !framed ? 0 : gap)
                    .padding(.bottom, index == rows.count - 1 && !framed ? 0 : gap)
            }
            if framed { HairlineRule() }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    @ViewBuilder
    private func line(_ key: String, _ value: String) -> some View {
        if typeSize.isAccessibilitySize {
            VStack(alignment: .leading, spacing: 2) {
                keyText(key)
                valueText(value)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .accessibilityElement(children: .combine)
        } else {
            HStack(alignment: .firstTextBaseline, spacing: Space.m) {
                keyText(key).frame(width: keyWidth, alignment: .leading)
                valueText(value).frame(maxWidth: .infinity, alignment: .leading)
            }
            .accessibilityElement(children: .combine)
        }
    }

    private func keyText(_ key: String) -> some View {
        Text(verbatim: key).font(.orbitSecondary).foregroundStyle(Color.inkSecondary)
    }

    private func valueText(_ value: String) -> some View {
        Text(verbatim: value).font(.orbitBody).foregroundStyle(Color.ink)
    }
}

// MARK: - Section header

/// List section title: 13 pt semibold InkSecondary, an optional count that follows the title as "标题 · 2" (same size
/// and color, no pill) and an optional trailing control (for example a "清除" button). A zero or missing count shows
/// nothing.
struct SectionHeader: View {
    var title: String
    var count: Int? = nil
    var trailing: AnyView? = nil

    var body: some View {
        let shown = count.flatMap { $0 > 0 ? $0 : nil }
        HStack(spacing: 6) {
            Text(verbatim: shown.map { "\(title) · \($0)" } ?? title)
                .font(.system(.footnote, weight: .semibold))
                .foregroundStyle(Color.inkSecondary)
                .accessibilityLabel(shown.map { "\(title)，\($0) 项" } ?? title)
                .accessibilityAddTraits(.isHeader)
            Spacer(minLength: Space.s)
            if let trailing { trailing }
        }
        .padding(.horizontal, 6)
        .accessibilityElement(children: .contain)
    }
}
