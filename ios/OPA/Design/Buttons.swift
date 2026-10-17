import SwiftUI

// MARK: - Orbit buttons

/// The four button roles of the design system (docs/design/v2-direction.md section 3). No capsules: filled buttons are
/// 12 pt rounded rectangles.
/// - primary: PrimaryFill + OnPrimary label (dark on light, light on dark).
/// - secondary: Surface fill + 0.5 pt Hairline stroke + Ink label ("拒绝", "换一家").
/// - plain: text only, Accent ("粘贴配对链接", "查看").
/// - destructive: text only, Danger ("取消任务").
enum OrbitButtonKind: Sendable, Hashable, CaseIterable {
    case primary, secondary, plain, destructive

    /// Legacy name of the secondary look. v2 has no tinted "soft" button.
    static var soft: OrbitButtonKind { .secondary }
    /// Legacy name of the secondary look. v2 has no recessed "inset" button.
    static var inset: OrbitButtonKind { .secondary }

    /// Text-only roles draw no fill and no stroke.
    var isTextOnly: Bool { self == .plain || self == .destructive }
}

/// regular = 48 pt full width (44 for text-only roles); small = 36 pt and mini = 30 pt hug their label, and the
/// text-only small / mini are just the text (15 pt medium, no padding). Every size keeps a 44 pt touch target without
/// changing its layout size.
enum OrbitButtonSize: Sendable, Hashable, CaseIterable {
    case regular, small, mini
}

/// `.buttonStyle(.orbit(.primary, size: .small))`. Presses scale to 0.97 with immediate color feedback
/// (no scale under Reduce Motion), disabled controls dim to 40 %.
struct OrbitButtonStyle: ButtonStyle {
    var kind: OrbitButtonKind
    var size: OrbitButtonSize = .regular

    func makeBody(configuration: Configuration) -> some View {
        OrbitButtonBody(configuration: configuration, kind: kind, size: size)
    }

    private struct OrbitButtonBody: View {
        @Environment(\.isEnabled) private var isEnabled
        @Environment(\.accessibilityReduceMotion) private var reduceMotion
        let configuration: ButtonStyleConfiguration
        let kind: OrbitButtonKind
        let size: OrbitButtonSize

        var body: some View {
            let pressed = configuration.isPressed
            configuration.label
                .font(font)
                .multilineTextAlignment(.center)
                .foregroundStyle(foreground)
                .padding(.horizontal, horizontalPadding)
                .padding(.vertical, verticalPadding)
                .frame(maxWidth: size == .regular ? .infinity : nil, minHeight: minHeight)
                .background { chrome }
                .contentShape(Rectangle().inset(by: -touchOutset))
                .scaleEffect(pressed && !reduceMotion ? 0.97 : 1)
                .animation(MotionAware(reduce: reduceMotion).press, value: pressed)
                // Below the animation modifier on purpose: color feedback lands on the touch-down frame.
                .opacity(isEnabled ? (pressed ? (kind.isTextOnly ? 0.6 : 0.8) : 1) : 0.4)
        }

        private var font: Font {
            switch size {
            case .regular: .system(.headline, design: .default, weight: kind.isTextOnly ? .medium : .semibold)
            case .small: .system(.subheadline, design: .default, weight: kind.isTextOnly ? .medium : .semibold)
            case .mini: kind.isTextOnly
                ? .system(.subheadline, design: .default, weight: .medium)
                : .system(.footnote, design: .default, weight: .semibold)
            }
        }

        /// Height of the visible control (text-only small / mini: about one line of text).
        private var visibleHeight: CGFloat {
            switch size {
            case .regular: kind.isTextOnly ? 44 : 48
            case .small: kind.isTextOnly ? 20 : 36
            case .mini: kind.isTextOnly ? 18 : 30
            }
        }

        private var minHeight: CGFloat? {
            switch size {
            case .regular: visibleHeight
            case .small, .mini: kind.isTextOnly ? nil : visibleHeight
            }
        }

        private var horizontalPadding: CGFloat {
            switch size {
            case .regular: Space.xl
            case .small: kind.isTextOnly ? 0 : 14
            case .mini: kind.isTextOnly ? 0 : Space.m
            }
        }

        private var verticalPadding: CGFloat {
            switch size {
            case .regular: Space.m
            case .small: kind.isTextOnly ? 0 : Space.s
            case .mini: kind.isTextOnly ? 0 : 6
            }
        }

        /// Extra hit area so small/mini buttons still reach 44 pt without growing their layout.
        private var touchOutset: CGFloat { max(0, (44 - visibleHeight) / 2) }

        private var foreground: Color {
            switch kind {
            case .primary: .onPrimary
            case .secondary: .ink
            case .plain: .accentText
            case .destructive: .danger
            }
        }

        @ViewBuilder
        private var chrome: some View {
            let shape = RoundedRectangle(cornerRadius: Radius.control, style: .continuous)
            switch kind {
            case .primary:
                shape.fill(Color.primaryFill)
            case .secondary:
                shape.fill(Color.surface)
                    .overlay { shape.strokeBorder(Color.hairline, lineWidth: 0.5) }
            case .plain, .destructive:
                Color.clear
            }
        }
    }
}

extension ButtonStyle where Self == OrbitButtonStyle {
    /// `.buttonStyle(.orbit(.primary, size: .small))`.
    static func orbit(_ kind: OrbitButtonKind, size: OrbitButtonSize = .regular) -> OrbitButtonStyle {
        OrbitButtonStyle(kind: kind, size: size)
    }

    static var orbitPrimary: OrbitButtonStyle { .orbit(.primary) }
    static var orbitSecondary: OrbitButtonStyle { .orbit(.secondary) }
    /// Legacy names of the secondary look.
    static var orbitSoft: OrbitButtonStyle { .orbit(.secondary) }
    static var orbitInset: OrbitButtonStyle { .orbit(.secondary) }
    static var orbitPlain: OrbitButtonStyle { .orbit(.plain) }
    /// Text-style red, for "取消任务" / "删除".
    static var orbitDestructive: OrbitButtonStyle { .orbit(.destructive) }
}

// MARK: - Press feedback for custom tappable surfaces

/// Scales to 0.97 on touch-down and springs back; use for rows, cards and icon buttons that are not
/// one of the Orbit button roles. No scale under Reduce Motion.
struct PressableStyle: ButtonStyle {
    var scale: CGFloat = 0.97

    func makeBody(configuration: Configuration) -> some View {
        PressBody(configuration: configuration, scale: scale)
    }

    private struct PressBody: View {
        @Environment(\.accessibilityReduceMotion) private var reduceMotion
        let configuration: Configuration
        let scale: CGFloat

        var body: some View {
            configuration.label
                .scaleEffect(configuration.isPressed && !reduceMotion ? scale : 1)
                .animation(MotionAware(reduce: reduceMotion).press, value: configuration.isPressed)
                .opacity(configuration.isPressed ? 0.82 : 1)
        }
    }
}

extension ButtonStyle where Self == PressableStyle {
    static var pressable: PressableStyle { .init() }
}
