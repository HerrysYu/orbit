import SwiftUI
import WidgetKit

// The views of the task Live Activity (lock screen, Dynamic Island). Only Shared code, this target's own asset
// catalog and `OrbitMark` are available here.
//
// Both surfaces are dark whatever the system appearance (a translucent dark card on the lock screen, the black island),
// so every presentation forces the dark color scheme and the asset tokens resolve to their dark values.
// Design: docs/design/mockups/export/orbit-settings.png (锁屏 · 灵动岛), copy and sizes in `sLock` / `sIsland`.

typealias ActivityState = TaskActivityAttributes.ContentState

// MARK: - Colors for APIs outside the view tree

/// Dark-token values for the modifiers that take a plain `Color` (they cannot see the forced color scheme).
enum LivePalette {
    /// BrandApricot (dark) #F2AD73.
    static let apricot = Color(red: 0xF2 / 255.0, green: 0xAD / 255.0, blue: 0x73 / 255.0)
    /// Warning (dark) #E7BA73.
    static let warning = Color(red: 0xE7 / 255.0, green: 0xBA / 255.0, blue: 0x73 / 255.0)
    /// Success (dark) #91C7A2.
    static let success = Color(red: 0x91 / 255.0, green: 0xC7 / 255.0, blue: 0xA2 / 255.0)
    /// Danger (dark) #F39C91.
    static let danger = Color(red: 0xF3 / 255.0, green: 0x9C / 255.0, blue: 0x91 / 255.0)
    /// InkTertiary (dark) #A99B8D.
    static let neutral = Color(red: 0xA9 / 255.0, green: 0x9B / 255.0, blue: 0x8D / 255.0)
    /// The lock-screen card: #241F1B at 62 % over the system blur.
    static let cardTint = Color(red: 36.0 / 255, green: 31.0 / 255, blue: 27.0 / 255).opacity(0.62)

    /// Island keyline / accent for a phase.
    static func tint(for phase: ActivityState.Phase) -> Color {
        switch phase {
        case .planning, .running: apricot
        case .waiting: warning
        case .done: success
        case .blocked, .failed: danger
        case .cancelled: neutral
        }
    }
}

extension ActivityState.Phase {
    /// Text / icon color of the status on the dark surface.
    var foreground: Color {
        switch self {
        case .planning, .cancelled: .inkSecondary
        case .running: .accentText
        case .waiting: .warning
        case .blocked, .failed: .danger
        case .done: .success
        }
    }

    /// Fill behind the status chip.
    var chipBackground: Color {
        switch self {
        case .planning, .cancelled: .surfaceInset
        case .running: .brandSoft
        case .waiting: .warningSoft
        case .blocked, .failed: .dangerSoft
        case .done: .successSoft
        }
    }
}

// MARK: - Pieces

/// Orbit's face on a BrandSoft disc (the dedicated avatar composition; same framing as `OrbitAvatar` in the app).
struct LiveAvatar: View {
    var size: CGFloat

    var body: some View {
        Circle()
            .fill(Color.brandSoft)
            .overlay {
                Image(.mascotAvatar)
                    .resizable()
                    .scaledToFill()
                    .frame(width: size, height: size)
                    .scaleEffect(1.1)
                    .offset(x: size * 0.044, y: -size * 0.044)
            }
            .frame(width: size, height: size)
            .clipShape(.circle)
            .accessibilityHidden(true)
    }
}

/// 进行中 / 待确认 … as a capsule. 待确认 carries the raised-hand icon: waiting is never shown by color alone.
struct LiveStatusChip: View {
    var phase: ActivityState.Phase

    var body: some View {
        HStack(spacing: 4) {
            if phase.needsYou {
                Image(systemName: "hand.raised.fill").imageScale(.small).accessibilityHidden(true)
            }
            Text(phase.label)
        }
        .font(.system(.caption, weight: .semibold))
        .foregroundStyle(phase.foreground)
        .padding(.horizontal, 9)
        .padding(.vertical, 4)
        .background(phase.chipBackground, in: .capsule)
        .fixedSize()
    }
}

/// One 4 pt segment per step in BrandApricot, the current step half filled, the rest on a translucent track.
/// More than 24 steps fall back to one continuous bar (segments would shrink to slivers).
struct LiveStepBar: View {
    var total: Int
    var done: Int
    var currentIndex: Int?

    private static let segmentLimit = 24

    var body: some View {
        Group {
            if total > Self.segmentLimit {
                continuous
            } else {
                HStack(spacing: 3) {
                    ForEach(0..<max(total, 0), id: \.self) { index in segment(index) }
                }
            }
        }
        .frame(height: 4)
        .accessibilityHidden(true)
    }

    private var track: Color { Color.white.opacity(0.16) }

    private func segment(_ index: Int) -> some View {
        let isDone = index < done
        return Capsule()
            .fill(isDone ? Color.brandApricot : track)
            .overlay(alignment: .leading) {
                if !isDone, index == currentIndex {
                    GeometryReader { proxy in
                        Color.brandApricot.frame(width: proxy.size.width / 2)
                    }
                }
            }
            .clipShape(.capsule)
    }

    private var continuous: some View {
        GeometryReader { proxy in
            let fraction = min(1, max(0, Double(done) / Double(max(total, 1))))
            ZStack(alignment: .leading) {
                Capsule().fill(track)
                Capsule().fill(Color.brandApricot).frame(width: proxy.size.width * fraction)
            }
        }
    }
}

// MARK: - Lock screen

/// The lock-screen card: Orbit's face, the task, its current step, a status chip, one segment per step and the count.
struct TaskLockScreenView: View {
    var state: ActivityState

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 12) {
                LiveAvatar(size: 40)
                VStack(alignment: .leading, spacing: 2) {
                    Text(verbatim: state.displayTitle)
                        .font(.system(.callout, weight: .semibold))
                        .foregroundStyle(Color.ink)
                        .lineLimit(1)
                    Text(verbatim: state.subtitle(on: .lockScreen))
                        .font(.footnote)
                        .foregroundStyle(Color.inkSecondary)
                        .lineLimit(1)
                }
                Spacer(minLength: 8)
                LiveStatusChip(phase: state.phase)
            }
            if state.total > 0 {
                HStack(spacing: 10) {
                    LiveStepBar(total: state.total, done: state.done, currentIndex: state.currentIndex)
                    Text(verbatim: state.stepsText)
                        .font(.caption)
                        .foregroundStyle(Color.inkSecondary)
                        .monospacedDigit()
                        .lineLimit(1)
                        .fixedSize()
                }
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 14)
        .environment(\.colorScheme, .dark)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Orbit")
        .accessibilityValue(state.spokenSummary)
    }
}

// MARK: - Dynamic Island

/// Title and second line of the expanded island.
struct IslandTitleBlock: View {
    var state: ActivityState

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(verbatim: state.displayTitle)
                .font(.system(.callout, weight: .semibold))
                .foregroundStyle(Color.ink)
                .lineLimit(1)
            Text(verbatim: state.subtitle(on: .island))
                .font(.footnote)
                .foregroundStyle(Color.inkSecondary)
                .lineLimit(1)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .environment(\.colorScheme, .dark)
        .accessibilityElement(children: .combine)
    }
}

/// The glyph on the trailing side of the expanded island: the raised hand when Orbit needs you, a mark for the end states.
struct IslandStatusGlyph: View {
    var phase: ActivityState.Phase

    var body: some View {
        Group {
            switch phase {
            case .waiting:
                glyph("hand.raised.fill", label: "需要你确认")
            case .done:
                glyph("checkmark.circle.fill", label: "已完成")
            case .failed, .blocked:
                glyph("exclamationmark.triangle.fill", label: phase.label)
            case .cancelled:
                glyph("minus.circle.fill", label: "已取消")
            case .planning, .running:
                EmptyView()
            }
        }
        .environment(\.colorScheme, .dark)
    }

    private func glyph(_ name: String, label: String) -> some View {
        Image(systemName: name)
            .font(.system(size: 22, weight: .regular))
            .foregroundStyle(phase.foreground)
            .accessibilityLabel(label)
    }
}

/// The segmented bar with its count ("3 / 4 步") under the expanded island's header.
struct IslandProgressRow: View {
    var state: ActivityState

    var body: some View {
        if state.total > 0 {
            HStack(spacing: 10) {
                LiveStepBar(total: state.total, done: state.done, currentIndex: state.currentIndex)
                Text(verbatim: state.shortStepsText)
                    .font(.caption)
                    .foregroundStyle(Color.inkSecondary)
                    .monospacedDigit()
                    .lineLimit(1)
                    .fixedSize()
            }
            .environment(\.colorScheme, .dark)
            .accessibilityElement(children: .ignore)
            .accessibilityLabel("进度")
            .accessibilityValue(state.stepsText)
        }
    }
}

/// 打开 Orbit 确认: a 36 pt apricot capsule shown only while Orbit waits for you.
struct IslandOpenButton: View {
    var taskId: String

    var body: some View {
        let label = Text("打开 Orbit 确认")
            .font(.system(.subheadline, weight: .semibold))
            .foregroundStyle(Color.onPrimary)
            .frame(maxWidth: .infinity, minHeight: 36)
            .background(Color.primaryFill, in: .capsule)
        Group {
            if let url = LiveLink.url(taskId: taskId) {
                Link(destination: url) { label }
            } else {
                label
            }
        }
        .environment(\.colorScheme, .dark)
    }
}

// MARK: - Compact and minimal

/// Right side of the compact island: the step count, or the raised hand with 待确认 when Orbit needs you
/// (the mark and a word, so it is not just a color change).
struct IslandCompactTrailing: View {
    var state: ActivityState

    var body: some View {
        Group {
            switch state.phase {
            case .waiting:
                HStack(spacing: 3) {
                    Image(systemName: "hand.raised.fill").font(.system(size: 12, weight: .semibold))
                    Text(verbatim: state.phase.shortLabel).font(.system(size: 13, weight: .semibold))
                }
                .foregroundStyle(Color.warning)
                .accessibilityElement(children: .combine)
            case .done:
                Image(systemName: "checkmark").font(.system(size: 14, weight: .bold))
                    .foregroundStyle(Color.success)
                    .accessibilityLabel("已完成")
            case .failed, .blocked:
                Image(systemName: "exclamationmark").font(.system(size: 14, weight: .bold))
                    .foregroundStyle(Color.danger)
                    .accessibilityLabel(state.phase.label)
            case .cancelled:
                Image(systemName: "minus").font(.system(size: 14, weight: .bold))
                    .foregroundStyle(Color.inkSecondary)
                    .accessibilityLabel("已取消")
            case .planning, .running:
                if state.total > 0 {
                    Text(verbatim: state.compactStepsText)
                        .font(.system(size: 14, weight: .semibold))
                        .monospacedDigit()
                        .foregroundStyle(Color.accentText)
                        .accessibilityLabel(state.stepsText)
                } else {
                    Image(systemName: "ellipsis").font(.system(size: 14, weight: .bold))
                        .foregroundStyle(Color.accentText)
                        .accessibilityLabel(state.phase.label)
                }
            }
        }
        .environment(\.colorScheme, .dark)
    }
}

/// The one-glyph island: Orbit's mark, or the raised hand when Orbit needs you.
struct IslandMinimal: View {
    var state: ActivityState

    var body: some View {
        Group {
            if state.phase.needsYou {
                Image(systemName: "hand.raised.fill")
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(Color.warning)
                    .accessibilityLabel("需要你确认")
            } else {
                OrbitMark(size: 24)
            }
        }
        .environment(\.colorScheme, .dark)
    }
}
