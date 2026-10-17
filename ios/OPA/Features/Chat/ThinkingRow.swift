import SwiftUI

// MARK: - Waiting row

/// "Orbit is on it": the place where the reply will appear, while Orbit is thinking or working and nothing readable
/// has come back yet. It looks like the reply it stands in for: the same "Orbit · 17:20" line above (once, and only
/// when the reply would open a group; see `ChatRows.waitingRow`) and three small dots below, in the place of the first
/// line of text. The first words replace the dots where they are, so nothing around them moves.
///
/// The whole row is one VoiceOver element, "正在回复"; the dots are hidden from it.
struct ThinkingRow: View {
    var ts: Int64
    var showsByline: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: ReplyLayout.bylineSpacing) {
            if showsByline { Byline(ts: ts) }
            WaitingDots()
                .padding(.horizontal, ReplyLayout.textInset)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("正在回复")
    }
}

// MARK: - Dots

/// Three 6 pt dots in InkTertiary, 5 pt apart. Each fades from 0.25 up to 1 and back, one round per second, eased in
/// and out, and each follows the one before it by 0.15 s. They do not scale, bounce or glow, and carry no words.
/// Under Reduce Motion they hold still at 0.4.
///
/// The row is as tall as one line of body text (17 pt, as Orbit's text is set), which is what the reply's first line
/// will take. The opacity is worked out from the clock, so a dot that is drawn anew (scrolled back into view, replaced
/// by a fresh row) picks up where the others are instead of starting over.
struct WaitingDots: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private static let diameter: CGFloat = 6
    private static let spacing: CGFloat = 5
    private static let count = 3
    /// Seconds for one round, and how far each dot runs behind the one before it.
    private static let period: TimeInterval = 1
    private static let stagger: TimeInterval = 0.15
    private static let faint = 0.25
    private static let still = 0.4

    var body: some View {
        ZStack(alignment: .leading) {
            // Never drawn: it only gives the row the height of one line of body text.
            Text(verbatim: "回")
                .orbitBodyText()
                .hidden()
            dots
        }
        .accessibilityHidden(true)
    }

    @ViewBuilder private var dots: some View {
        if reduceMotion {
            row(Array(repeating: Self.still, count: Self.count))
        } else {
            TimelineView(.animation(minimumInterval: 1.0 / 30.0)) { context in
                let now = context.date.timeIntervalSinceReferenceDate
                row((0..<Self.count).map { Self.opacity(at: now - Double($0) * Self.stagger) })
            }
        }
    }

    private func row(_ opacities: [Double]) -> some View {
        HStack(spacing: Self.spacing) {
            ForEach(opacities.indices, id: \.self) { i in
                Circle()
                    .fill(Color.inkTertiary)
                    .frame(width: Self.diameter, height: Self.diameter)
                    .opacity(opacities[i])
            }
        }
    }

    /// A dot's opacity `t` seconds into the clock: 0.25 up to 1 over half a round and back down over the other half,
    /// both legs eased in and out.
    static func opacity(at t: TimeInterval) -> Double {
        var phase = (t / period).truncatingRemainder(dividingBy: 1)
        if phase < 0 { phase += 1 }
        let leg = phase < 0.5 ? phase * 2 : (1 - phase) * 2
        return faint + (1 - faint) * UnitCurve.easeInOut.value(at: leg)
    }
}

#if DEBUG
#Preview("Thinking row") {
    let model = AppModel(inMemory: true)
    let now = Clock.nowMs
    return VStack(alignment: .leading, spacing: 24) {
        ThinkingRow(ts: now, showsByline: true)
        ThinkingRow(ts: now, showsByline: false)
        // The same line height as a reply's first line.
        VStack(alignment: .leading, spacing: ReplyLayout.bylineSpacing) {
            Byline(ts: now)
            MarkdownText("好的，我来看一下。")
                .padding(.horizontal, ReplyLayout.textInset)
        }
    }
    .padding()
    .background(Color.canvas)
    .environment(model)
}
#endif
