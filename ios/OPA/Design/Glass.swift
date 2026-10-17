import SwiftUI

// MARK: - Glass material
//
// Floating controls that still sit on glass (the scanner's close button, back buttons, the scan-hint panel) use Liquid
// Glass on iOS 26+ and an `.ultraThinMaterial` + hairline fallback on iOS 18-25. Reduce Transparency swaps both for a
// solid surface. No drop shadows anywhere (v2): depth comes from the material and the hairline. The connection control
// in the chat header is no longer glass at all (see `ConnectionIndicator`).

private struct OrbitGlassFallbackKey: EnvironmentKey {
    static let defaultValue = false
}

extension EnvironmentValues {
    /// Forces the iOS 18 material fallback even on iOS 26+. Used by the design gallery to check both paths.
    var orbitGlassFallback: Bool {
        get { self[OrbitGlassFallbackKey.self] }
        set { self[OrbitGlassFallbackKey.self] = newValue }
    }
}

/// Glass background for a floating control.
struct OrbitGlassBackground<S: InsettableShape>: ViewModifier {
    var shape: S
    var interactive: Bool = false

    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
    @Environment(\.orbitGlassFallback) private var forceFallback
    @Environment(\.colorScheme) private var scheme

    @ViewBuilder
    func body(content: Content) -> some View {
        if reduceTransparency {
            content
                .background(Color.surface, in: shape)
                .overlay { shape.strokeBorder(Color.hairline, lineWidth: 0.5) }
        } else if #available(iOS 26, *), !forceFallback {
            content.glassEffect(interactive ? .regular.interactive() : .regular, in: shape)
        } else {
            content
                .background(.ultraThinMaterial, in: shape)
                .overlay { shape.strokeBorder(edge, lineWidth: 0.5) }
        }
    }

    /// The rim of the material fallback: a bright edge in light mode, a faint one in dark mode.
    private var edge: Color {
        .white.opacity(scheme == .dark ? 0.08 : 0.9)
    }
}

extension View {
    /// Glass background (Liquid Glass on iOS 26+, material fallback below) in the given shape.
    func orbitGlass<S: InsettableShape>(in shape: S, interactive: Bool = false) -> some View {
        modifier(OrbitGlassBackground(shape: shape, interactive: interactive))
    }
}

/// Press feedback for glass controls: iOS 26 interactive glass animates itself, every other path (material
/// fallback, Reduce Transparency, or a non-glass control such as the offline pill) scales to 0.97.
struct OrbitGlassButtonStyle: ButtonStyle {
    /// False when the label is not drawn with `orbitGlass(interactive: true)`.
    var usesInteractiveGlass = true

    func makeBody(configuration: Configuration) -> some View {
        GlassPressBody(configuration: configuration, usesInteractiveGlass: usesInteractiveGlass)
    }

    private struct GlassPressBody: View {
        @Environment(\.accessibilityReduceMotion) private var reduceMotion
        @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
        @Environment(\.orbitGlassFallback) private var forceFallback
        let configuration: ButtonStyleConfiguration
        let usesInteractiveGlass: Bool

        var body: some View {
            configuration.label
                .scaleEffect(scales && configuration.isPressed && !reduceMotion ? 0.97 : 1)
                .animation(MotionAware(reduce: reduceMotion).press, value: configuration.isPressed)
        }

        /// Whether this style has to provide the press scale itself.
        private var scales: Bool {
            if !usesInteractiveGlass || reduceTransparency || forceFallback { return true }
            if #available(iOS 26, *) { return false }
            return true
        }
    }
}

// MARK: - Glass circle button

/// 44 pt glass circle with an SF Symbol: header buttons, floating actions.
struct GlassCircleButton: View {
    var systemImage: String
    var accessibilityLabel: String
    var action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: systemImage)
                .symbolRenderingMode(.monochrome)
                .font(.system(size: 18, weight: .medium))
                .foregroundStyle(Color.ink)
                .frame(width: 44, height: 44)
                .orbitGlass(in: .circle, interactive: true)
                .contentShape(.circle)
        }
        .buttonStyle(OrbitGlassButtonStyle())
        .accessibilityLabel(accessibilityLabel)
    }
}
