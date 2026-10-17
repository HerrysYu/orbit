import SwiftUI

// MARK: - Step marker

/// 20 pt marker for one task step: a 1.5 pt ring, colored by state, with no fill behind it.
/// - done: Success ring with a check.
/// - running: Accent ring with a 6 pt Accent dot in the middle.
/// - pending: hollow, quiet ring.
/// - failed: Danger ring with a cross.
/// - skipped: quiet ring with a dash.
struct StepMarker: View {
    var status: TaskStep.Status

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        ZStack {
            switch status {
            case .done:
                ring(Color.success)
                glyph("checkmark", color: .success)
            case .running:
                ring(Color.accentText)
                Circle().fill(Color.accentText).frame(width: 6, height: 6)
            case .pending:
                ring(Color.inkTertiary.opacity(0.5))
            case .failed:
                ring(Color.danger)
                glyph("xmark", color: .danger)
            case .skipped:
                ring(Color.inkTertiary.opacity(0.5))
                glyph("minus", color: .inkTertiary)
            }
        }
        .frame(width: 20, height: 20)
        .animation(MotionAware(reduce: reduceMotion).snappy, value: status)
        .accessibilityElement()
        .accessibilityLabel(accessibilityText)
    }

    private func ring(_ color: Color) -> some View {
        Circle().strokeBorder(color, lineWidth: 1.5)
    }

    private func glyph(_ name: String, color: Color) -> some View {
        Image(systemName: name)
            .font(.system(size: 9, weight: .heavy))
            .foregroundStyle(color)
    }

    private var accessibilityText: String {
        switch status {
        case .pending: "待开始"
        case .running: "进行中"
        case .done: "完成"
        case .failed: "失败"
        case .skipped: "跳过"
        }
    }
}

// MARK: - Progress line

/// The progress of a task as a 2 pt line: a Hairline track and an Accent fill that grows with the share of finished
/// steps. It sits 10 pt under the text above it (the caller adds that gap). Never a percentage in words.
struct ProgressLine: View {
    /// 0...1 share of the track that is filled.
    var fraction: Double
    /// Read by VoiceOver in place of the bar, for example "已完成 3 / 4 步".
    var accessibilityValueText: String? = nil

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        let share = min(max(fraction.isFinite ? fraction : 0, 0), 1)
        GeometryReader { proxy in
            ZStack(alignment: .leading) {
                Capsule().fill(Color.hairline)
                Capsule().fill(Color.accentText)
                    .frame(width: proxy.size.width * share)
            }
        }
        .frame(height: 2)
        .animation(MotionAware(reduce: reduceMotion).snappy, value: share)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("进度")
        .accessibilityValue(accessibilityValueText ?? "")
    }
}

/// The step progress of a task: `done` of `total` steps filled on the 2 pt `ProgressLine`. `currentIndex` is kept so
/// existing call sites compile; the line shows finished steps only, which is what the "3/4 步" beside it counts.
struct SegmentedStepBar: View {
    var total: Int
    var done: Int
    /// Index of the step being worked on (0-based). Not drawn in v2.
    var currentIndex: Int? = nil

    /// Share of the line that is filled: finished steps over all steps, clamped to 0...1.
    static func fraction(total: Int, done: Int) -> Double {
        let count = max(total, 0)
        guard count > 0 else { return 0 }
        return Double(min(max(done, 0), count)) / Double(count)
    }

    var body: some View {
        let count = max(total, 0)
        let finished = min(max(done, 0), count)
        ProgressLine(fraction: Self.fraction(total: total, done: done),
                     accessibilityValueText: "已完成 \(finished) / \(count) 步")
    }
}
