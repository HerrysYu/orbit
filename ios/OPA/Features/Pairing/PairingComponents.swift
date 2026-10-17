import SwiftUI

// Small building blocks shared by the pairing pages: the stage backdrop, the scrolling page with its bottom actions,
// the waiting spinner, a font helper that keeps the mock's exact sizes but still follows Dynamic Type, and the
// transport-path wording.

// MARK: - Backdrops

/// A radial glow drawn as an ellipse: `radiusX` / `radiusY` are fractions of the view's width / height and
/// `center` is a unit point, which is how the mock's CSS `radial-gradient(120% 70% at 50% 30%, …)` is written.
struct EllipseGlow: View {
    var stops: [Gradient.Stop]
    var center: UnitPoint
    var radiusX: CGFloat
    var radiusY: CGFloat

    var body: some View {
        GeometryReader { geo in
            RadialGradient(stops: stops, center: .center, startRadius: 0, endRadius: 100)
                .frame(width: 200, height: 200)
                .scaleEffect(x: geo.size.width * radiusX / 100, y: geo.size.height * radiusY / 100)
                .position(x: geo.size.width * center.x, y: geo.size.height * center.y)
        }
    }
}

/// Page background: Canvas plus, for the welcome and success pages, the soft warm "stage" glow behind the character.
struct PairingBackdrop: View {
    var glow = true

    @Environment(\.colorScheme) private var scheme

    var body: some View {
        ZStack {
            Color.canvas
            if glow {
                // The mock's stop at 62 % of a 120 % x 70 % ellipse, centred at 50 % / 30 %.
                EllipseGlow(stops: [.init(color: glowColor, location: 0), .init(color: glowColor.opacity(0), location: 1)],
                            center: UnitPoint(x: 0.5, y: 0.3), radiusX: 0.744, radiusY: 0.434)
            }
        }
        .ignoresSafeArea()
        .accessibilityHidden(true)
    }

    private var glowColor: Color {
        Color(hex: scheme == .dark ? "#2A221C" : "#FFF3E6") ?? .brandSoft
    }
}

// MARK: - Page container

/// A scrolling page with its actions at the bottom.
///
/// Normally the actions are pinned to the bottom edge on a Canvas bar that fades in over whatever scrolls behind it.
/// At accessibility text sizes pinned buttons would cover half the screen (and the page with it), so the actions move
/// to the end of the content and scroll with it.
struct PairingPage<Content: View, Actions: View>: View {
    /// Gets the height of the visible area, so a page can spread its content over it (0 when the actions scroll too).
    @ViewBuilder var content: (_ viewportHeight: CGFloat) -> Content
    @ViewBuilder var actions: Actions

    @Environment(\.dynamicTypeSize) private var typeSize

    var body: some View {
        GeometryReader { proxy in
            ScrollView {
                VStack(spacing: 0) {
                    content(typeSize.isAccessibilitySize ? 0 : proxy.size.height)
                    if typeSize.isAccessibilitySize {
                        actions
                            .padding(.horizontal, Space.xl)
                            .padding(.vertical, Space.xl)
                    }
                }
            }
            .scrollBounceBehavior(.basedOnSize)
        }
        .safeAreaInset(edge: .bottom, spacing: 0) {
            if !typeSize.isAccessibilitySize {
                actions
                    .padding(.horizontal, Space.xl)
                    .padding(.top, Space.xs)
                    .padding(.bottom, 10)
                    .background(alignment: .top) { PairingBarBackground() }
            }
        }
    }
}

/// The bar behind pinned actions: Canvas, with a soft top edge so content that scrolls underneath fades out.
private struct PairingBarBackground: View {
    private let fade: CGFloat = 18

    var body: some View {
        VStack(spacing: 0) {
            LinearGradient(colors: [Color.canvas.opacity(0), Color.canvas], startPoint: .top, endPoint: .bottom)
                .frame(height: fade)
            Color.canvas
        }
        .padding(.top, -fade)                 // the fade sits above the bar's own frame
        .ignoresSafeArea(edges: .bottom)      // and the bar runs on under the home indicator
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }
}

// MARK: - Spinner

/// The small "waiting" indicator: a hairline ring with an apricot arc. Still under Reduce Motion (the text beside it
/// carries the meaning).
struct OrbitSpinner: View {
    var size: CGFloat = 16

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        TimelineView(.animation(paused: reduceMotion)) { context in
            let turn = context.date.timeIntervalSinceReferenceDate.truncatingRemainder(dividingBy: 0.9) / 0.9
            ZStack {
                Circle().strokeBorder(Color.hairline, lineWidth: 2)
                Circle()
                    .trim(from: 0, to: 0.25)
                    .rotation(.degrees(-135))
                    .stroke(Color.brandApricot, style: StrokeStyle(lineWidth: 2, lineCap: .round))
                    .padding(1)
            }
            .rotationEffect(.degrees(reduceMotion ? 0 : turn * 360))
        }
        .frame(width: size, height: size)
        .accessibilityHidden(true)
    }
}

// MARK: - Fonts

extension View {
    /// A system font at the mock's exact point size that still scales with Dynamic Type (relative to `style`).
    func pairingFont(_ size: CGFloat, weight: Font.Weight = .regular, design: Font.Design = .default,
                     relativeTo style: Font.TextStyle = .body) -> some View {
        modifier(PairingScaledFont(size: size, weight: weight, design: design, style: style))
    }
}

private struct PairingScaledFont: ViewModifier {
    @ScaledMetric private var scaled: CGFloat
    private let weight: Font.Weight
    private let design: Font.Design

    init(size: CGFloat, weight: Font.Weight, design: Font.Design, style: Font.TextStyle) {
        _scaled = ScaledMetric(wrappedValue: size, relativeTo: style)
        self.weight = weight
        self.design = design
    }

    func body(content: Content) -> some View {
        content.font(.system(size: scaled, weight: weight, design: design))
    }
}

// MARK: - Wording

/// How the pairing pages name a transport path ("局域网" / "外网中继", as on the board).
func pairingPathName(_ path: TransportPath) -> String {
    switch path {
    case .lan: "局域网"
    case .relay: "外网中继"
    }
}

/// What a paired Mac can be reached through, from the pairing payload ("局域网 + 外网中继").
func pairingRouteSummary(_ host: PairedHost) -> String {
    let lan = !host.lan.isEmpty
    let relay = !(host.relay ?? "").isEmpty
    switch (lan, relay) {
    case (true, true): return "局域网 + 外网中继"
    case (false, true): return "仅外网中继"
    case (true, false), (false, false): return "仅局域网"
    }
}
