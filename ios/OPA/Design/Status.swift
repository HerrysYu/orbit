import SwiftUI

// MARK: - Status kinds

/// Visual vocabulary of status marks. Task states map onto it through `OPATask.Status.chipKind`.
enum StatusKind: Sendable, Hashable, CaseIterable {
    /// 规划中 — neutral.
    case planning
    /// 进行中 — accent.
    case running
    /// 等你补充 / 等你确认 — warning.
    case waiting
    /// 遇到阻碍 — danger.
    case blocked
    /// 已完成 — success.
    case done
    /// 未完成 — danger.
    case failed
    /// 已取消 — neutral, quieter.
    case cancelled
    /// 草稿 — neutral.
    case draft
    /// Generic positive confirmation (e.g. "已连接", "已批准") — success.
    case ok
}

extension StatusKind {
    /// Color of the 6 pt status dot: Success (done, ok), Accent (running), Warning (waiting for you), Danger (blocked,
    /// failed), InkTertiary (planning, cancelled, draft).
    var dotColor: Color {
        switch self {
        case .planning, .cancelled, .draft: .inkTertiary
        case .running: .accentText
        case .waiting: .warning
        case .blocked, .failed: .danger
        case .done, .ok: .success
        }
    }
}

extension OPATask.Status {
    /// Chip appearance for this task state. The chip text comes from `OPATask.Status.label`.
    var chipKind: StatusKind {
        switch self {
        case .planning: .planning
        case .running: .running
        case .waiting_user: .waiting
        case .blocked: .blocked
        case .done: .done
        case .failed: .failed
        case .cancelled: .cancelled
        }
    }
}

// MARK: - Status chip

/// A status mark: a 6 pt dot in the status color and the status word beside it (13 pt, InkSecondary). No capsule, no
/// fill, no outline, so it sits in a row like plain text. Dot colors: Success (done, ok), Accent (running), Warning
/// (waiting for you), Danger (blocked, failed), InkTertiary (planning, cancelled, draft). The word and the dot color
/// animate when the status changes (for example on `ui.patch`). State is always conveyed by the word, never by color
/// alone.
struct StatusChip: View {
    /// Where the colors come from: a design-system kind, or a free color (legacy call sites).
    enum Source {
        case kind(StatusKind)
        case custom(color: Color, symbol: String?)
    }

    var source: Source
    var text: String
    /// Kept so existing call sites compile: every status carries its dot now, whatever is passed here.
    var dot: Bool

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    /// How far the dot's center sits above the baseline of the word (about the middle of the letters).
    @ScaledMetric(relativeTo: .footnote) private var dotLift: CGFloat = 4.8

    init(kind: StatusKind, text: String, dot: Bool = false) {
        self.init(source: .kind(kind), text: text, dot: dot)
    }

    init(source: Source, text: String, dot: Bool) {
        self.source = source
        self.text = text
        self.dot = dot
    }

    var body: some View {
        let look = Look(source)
        let lift = dotLift
        // Baseline-aligned, so beside a title the chip's word sits on the title's baseline (the dot reports a baseline
        // below its center, which puts it at the middle of the word).
        HStack(alignment: .firstTextBaseline, spacing: 6) {
            if let symbol = look.symbol {
                Image(systemName: symbol)
                    .imageScale(.small)
                    .contentTransition(.symbolEffect(.replace))
            } else {
                Circle()
                    .fill(look.dot)
                    .frame(width: 6, height: 6)
                    .alignmentGuide(.firstTextBaseline) { $0[VerticalAlignment.center] + lift }
            }
            Text(text).contentTransition(.interpolate)
        }
        .font(.orbitMeta)
        .foregroundStyle(look.foreground)
        .fixedSize(horizontal: true, vertical: false)
        .animation(MotionAware(reduce: reduceMotion).snappy, value: text)
        .accessibilityElement(children: .combine)
    }

    private struct Look {
        /// The word.
        var foreground: Color
        /// The 6 pt dot.
        var dot: Color
        var symbol: String? = nil

        init(_ source: Source) {
            switch source {
            case .kind(let kind):
                // The word is always InkSecondary; only the dot carries the status color.
                self.init(.inkSecondary, dot: kind.dotColor)
            case .custom(let color, let symbol):
                self.init(color, symbol: symbol)
            }
        }

        private init(_ foreground: Color, dot: Color? = nil, symbol: String? = nil) {
            self.foreground = foreground
            self.dot = dot ?? foreground
            self.symbol = symbol
        }
    }
}
