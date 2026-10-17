import SwiftUI

// Building blocks shared by every settings page: row label, row chrome, footers, the save-status capsule and the
// avatar view that shows the user's own picture (or Orbit's character by default).

// MARK: - Rows

/// The rounded-square icon of a settings row: a 28 pt SurfaceInset tile with an SF Symbol in Ink.
struct SettingsIconTile: View {
    var systemImage: String

    @ScaledMetric(relativeTo: .body) private var side: CGFloat = 28

    var body: some View {
        Image(systemName: systemImage)
            .symbolRenderingMode(.monochrome)
            .font(.system(.subheadline, weight: .medium))
            .foregroundStyle(Color.ink)
            .frame(width: side, height: side)
            .background(Color.surfaceInset, in: .rect(cornerRadius: Radius.small, style: .continuous))
            .accessibilityHidden(true)
    }
}

/// The content of one settings row: optional icon tile, title, optional second line and optional trailing value.
/// At accessibility text sizes the value moves under the title so nothing gets squeezed.
/// Put it inside a `NavigationLink` (the system draws the chevron) or a `Button` (pass `showsChevron`).
struct SettingsRowLabel: View {
    enum Tone: Sendable { case normal, warning }

    var systemImage: String?
    var title: String
    var subtitle: String?
    var subtitleTone: Tone
    var subtitleLines: Int?
    var value: String?
    var showsChevron: Bool

    @Environment(\.dynamicTypeSize) private var typeSize

    init(systemImage: String? = nil, title: String, subtitle: String? = nil, subtitleTone: Tone = .normal,
         subtitleLines: Int? = nil, value: String? = nil, showsChevron: Bool = false) {
        self.systemImage = systemImage
        self.title = title
        self.subtitle = subtitle
        self.subtitleTone = subtitleTone
        self.subtitleLines = subtitleLines
        self.value = value
        self.showsChevron = showsChevron
    }

    var body: some View {
        Group {
            if typeSize.isAccessibilitySize { stacked } else { inline }
        }
        .accessibilityElement(children: .combine)
    }

    private var inline: some View {
        HStack(spacing: Space.m) {
            if let systemImage { SettingsIconTile(systemImage: systemImage) }
            VStack(alignment: .leading, spacing: 2) {
                titleText
                subtitleText
            }
            Spacer(minLength: Space.s)
            valueText
            chevron
        }
    }

    private var stacked: some View {
        VStack(alignment: .leading, spacing: Space.xs) {
            HStack(alignment: .top, spacing: Space.m) {
                if let systemImage { SettingsIconTile(systemImage: systemImage) }
                titleText
                Spacer(minLength: 0)
                chevron
            }
            subtitleText
            valueText
        }
    }

    private var titleText: some View {
        Text(verbatim: title)
            .font(.orbitBody)
            .foregroundStyle(Color.ink)
            .fixedSize(horizontal: false, vertical: true)
    }

    @ViewBuilder
    private var subtitleText: some View {
        if let subtitle, !subtitle.isEmpty {
            Text(verbatim: subtitle)
                .font(.orbitMeta)
                .foregroundStyle(subtitleTone == .warning ? Color.warning : Color.inkSecondary)
                .lineLimit(subtitleLines)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    @ViewBuilder
    private var valueText: some View {
        if let value, !value.isEmpty {
            Text(verbatim: value)
                .font(.orbitSecondary)
                .foregroundStyle(Color.inkSecondary)
                .lineLimit(typeSize.isAccessibilitySize ? 3 : 1)
                .multilineTextAlignment(.trailing)
        }
    }

    @ViewBuilder
    private var chevron: some View {
        if showsChevron {
            Image(systemName: "chevron.right")
                .font(.system(.footnote, weight: .semibold))
                .foregroundStyle(Color.inkTertiary)
                .accessibilityHidden(true)
        }
    }
}

/// A row that opens another page (or a sheet): the row label with the design's chevron (InkTertiary). It is a button
/// rather than a `NavigationLink` so the chevron is the same on every row, including the ones that open a sheet.
struct SettingsNavRow<Label: View>: View {
    var action: () -> Void
    @ViewBuilder var label: Label

    var body: some View {
        Button(action: action) { label.contentShape(Rectangle()) }
            .accessibilityAddTraits(.isButton)
    }
}

extension View {
    /// Row chrome of the settings lists: Surface fill, 16 pt insets, Hairline separators. Rows with an icon tile start
    /// their separator under the text (28 pt tile + 12 pt gap), the others at the row's leading edge.
    func settingsRowChrome(icon: Bool = true) -> some View {
        self
            .listRowInsets(EdgeInsets(top: 10, leading: Space.l, bottom: 10, trailing: Space.l))
            .listRowBackground(Color.surface)
            .listRowSeparatorTint(Color.hairline)
            .alignmentGuide(.listRowSeparatorLeading) { dimensions in icon ? 40 : dimensions[.leading] }
    }

    /// The list canvas of every settings page: Canvas behind transparent grouped sections, the minimum row height of
    /// the design (50 pt) and the save-status capsule.
    func settingsListChrome() -> some View {
        self
            .listStyle(.insetGrouped)
            .scrollContentBackground(.hidden)
            .background(Color.canvas)
            .environment(\.defaultMinListRowHeight, 50)
            .settingsSyncBanner()
    }
}

/// Section title in the lists: the design system's `SectionHeader`, pulled left so it lines up with the icon tiles
/// (a list header sits further in than the 6 pt the component adds).
struct SettingsSectionHeader: View {
    var title: String

    init(_ title: String) { self.title = title }

    var body: some View {
        SectionHeader(title: title).listRowInsets(EdgeInsets())
    }
}

/// Footer text under a section (12.5 pt InkTertiary in the design).
struct SettingsFooter: View {
    var text: String

    init(_ text: String) { self.text = text }

    var body: some View {
        Text(verbatim: text)
            .font(.orbitMeta)
            .foregroundStyle(Color.inkTertiary)
            .fixedSize(horizontal: false, vertical: true)
    }
}

/// A selectable row of a "pick one" list: title, explanation and a checkmark when selected.
struct SettingsChoiceRow: View {
    var title: String
    var subtitle: String?
    var selected: Bool
    var action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(alignment: .firstTextBaseline, spacing: Space.m) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(verbatim: title).font(.orbitBody).foregroundStyle(Color.ink)
                    if let subtitle {
                        Text(verbatim: subtitle).font(.orbitMeta).foregroundStyle(Color.inkSecondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                Spacer(minLength: Space.s)
                Image(systemName: "checkmark")
                    .font(.system(.body, weight: .semibold))
                    .foregroundStyle(Color.accentText)
                    .opacity(selected ? 1 : 0)
                    .accessibilityHidden(true)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(selected ? [.isButton, .isSelected] : .isButton)
    }
}

// MARK: - Save status

/// Floating capsule that reports `settingsSync`: 保存中… / 已保存 / 没有保存成功（值已恢复为 Mac 上的值）.
/// It only reports changes that happen while the page is on screen (an old failure never greets you again) and a
/// failure stays up for a few seconds.
private struct SettingsSyncBannerModifier: ViewModifier {
    @Environment(AppModel.self) private var model
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var shown: SettingsSyncState = .idle
    @State private var hideTask: Task<Void, Never>?

    func body(content: Content) -> some View {
        content
            .safeAreaInset(edge: .bottom, spacing: 0) {
                if shown != .idle {
                    SettingsSyncCapsule(state: shown)
                        .padding(.horizontal, Space.l)
                        .padding(.bottom, Space.s)
                        .transition(reduceMotion ? .opacity : .move(edge: .bottom).combined(with: .opacity))
                }
            }
            .onChange(of: model.settingsSync) { _, new in show(new) }
            .onAppear { if model.settingsSync == .saving { shown = .saving } }
            .onDisappear { hideTask?.cancel() }
    }

    private func show(_ new: SettingsSyncState) {
        hideTask?.cancel()
        withAnimation(MotionAware(reduce: reduceMotion).snappy) { shown = new }
        guard case .failed = new else { return }
        hideTask = Task {
            try? await Task.sleep(for: .seconds(6))
            guard !Task.isCancelled else { return }
            withAnimation(MotionAware(reduce: reduceMotion).snappy) { shown = .idle }
        }
    }
}

private struct SettingsSyncCapsule: View {
    var state: SettingsSyncState

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: Space.s) {
            switch state {
            case .idle:
                EmptyView()
            case .saving:
                ProgressView().controlSize(.small)
                Text("保存中…").font(.system(.subheadline, weight: .medium))
            case .saved:
                Image(systemName: "checkmark.circle.fill").foregroundStyle(Color.success)
                Text("已保存").font(.system(.subheadline, weight: .medium))
            case .failed(let message):
                Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(Color.warning)
                VStack(alignment: .leading, spacing: 2) {
                    Text("没有保存成功，已恢复为 Mac 上的值").font(.system(.subheadline, weight: .medium))
                    if !message.isEmpty {
                        Text(verbatim: message).font(.orbitMeta).foregroundStyle(Color.inkSecondary)
                    }
                }
            }
        }
        .foregroundStyle(Color.ink)
        .padding(.horizontal, Space.l)
        .padding(.vertical, 10)
        .orbitGlass(in: .rect(cornerRadius: 22, style: .continuous))
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(.updatesFrequently)
    }
}

extension View {
    /// Shows the save status (`settingsSync`) as a capsule above the bottom edge of the page.
    func settingsSyncBanner() -> some View { modifier(SettingsSyncBannerModifier()) }
}

// MARK: - Avatar

/// Decodes avatar strings once (`data:image/jpeg;base64,…` payloads are tens of kilobytes).
@MainActor
enum SettingsAvatarCache {
    private final class Box {
        let value: AvatarValue
        init(_ value: AvatarValue) { self.value = value }
    }

    private static let cache = NSCache<NSString, Box>()

    static func value(for raw: String?) -> AvatarValue {
        guard let raw, !raw.isEmpty else { return .none }
        let key = raw as NSString
        if let hit = cache.object(forKey: key) { return hit.value }
        let decoded = AvatarValue(raw)
        cache.setObject(Box(decoded), forKey: key)
        return decoded
    }
}

/// Orbit's avatar as the user set it: their own photo, an emoji, or (default) the character. Decorative.
struct SettingsAvatarView: View {
    var avatar: String?
    var size: CGFloat
    var ring = false

    var body: some View {
        Group {
            switch SettingsAvatarCache.value(for: avatar) {
            case .image(let image):
                Image(decorative: image, scale: 1)
                    .resizable()
                    .scaledToFill()
                    .frame(width: size, height: size)
                    .clipShape(.circle)
                    .overlay { Circle().strokeBorder(Color.hairline, lineWidth: 0.5) }
            case .emoji(let emoji):
                Circle()
                    .fill(Color.surfaceInset)
                    .frame(width: size, height: size)
                    .overlay { Text(verbatim: emoji).font(.system(size: size * 0.55)) }
                    .overlay { Circle().strokeBorder(Color.hairline, lineWidth: 0.5) }
            case .none:
                OrbitAvatar(size: size, ring: ring)
            }
        }
        .frame(width: size, height: size)
        .accessibilityHidden(true)
    }
}
