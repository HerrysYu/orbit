import SwiftUI

// MARK: - Activity indicators

/// Three dots that breathe in sequence. Static under Reduce Motion.
/// (For "Orbit is thinking" prefer `OrbitMark(size:orbiting: true)`; these stay for compact inline use.)
struct PulsingDots: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    var color: Color = .inkSecondary

    var body: some View {
        TimelineView(.animation(minimumInterval: 1 / 30, paused: reduceMotion)) { ctx in
            let t = ctx.date.timeIntervalSinceReferenceDate
            HStack(spacing: 5) {
                ForEach(0..<3, id: \.self) { i in
                    let phase = reduceMotion ? 0.6 : (sin(t * 4.2 - Double(i) * 0.9) + 1) / 2
                    Circle()
                        .fill(color)
                        .frame(width: 6, height: 6)
                        .opacity(0.3 + 0.7 * phase)
                        .offset(y: reduceMotion ? 0 : -2 * phase)
                }
            }
        }
        .accessibilityHidden(true)
    }
}

/// Moving highlight across text (acting indicator). Off under Reduce Motion.
struct Shimmer: ViewModifier {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.colorScheme) private var scheme
    var active: Bool

    func body(content: Content) -> some View {
        if active && !reduceMotion {
            content
                .overlay {
                    TimelineView(.animation) { ctx in
                        let t = ctx.date.timeIntervalSinceReferenceDate.truncatingRemainder(dividingBy: 1.8) / 1.8
                        GeometryReader { geo in
                            LinearGradient(colors: [.clear, (scheme == .dark ? Color.ink : Color.accentText).opacity(0.5), .clear],
                                           startPoint: .leading, endPoint: .trailing)
                                .frame(width: geo.size.width * 0.45)
                                .offset(x: -geo.size.width * 0.45 + t * geo.size.width * 1.45)
                        }
                    }
                    .mask(content)
                    .allowsHitTesting(false)
                }
        } else {
            content
        }
    }
}

extension View {
    func shimmer(_ active: Bool = true) -> some View { modifier(Shimmer(active: active)) }
}
