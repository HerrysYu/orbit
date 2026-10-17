import SwiftUI

// MARK: - Typography
//
// System font only, default design (no rounded). Every token is built from a Dynamic Type text style so it scales
// with the user's text size and never locks a container height. Target sizes at the default text size
// (docs/design/v2-direction.md section 2):
//
//   token             design spec               text style used
//   orbitWelcome      30 / 36 bold              .title      (28: no text style is 30; kept on a style so it scales)
//   orbitEmptyTitle   22 / 28 semibold          .title2     (22)
//   orbitPageTitle    22 / 28 semibold          .title2     (22)   sheet titles, settings header name
//   orbitCardTitle    17 / 22 semibold          .headline   (17)
//   orbitBody         17 / 25 regular           .body       (17, + orbitBodyText() for the 1.5 line height)
//   orbitSecondary    15 / 21 regular           .subheadline(15)
//   orbitMeta         13 / 18 regular           .footnote   (13)
//   orbitAction       15 medium                 .subheadline(15)   inline text buttons and links ("查看", "撤销")
//   orbitChip         13 medium                 .footnote   (13)   small labels
//
// Section titles are 13 / 18 semibold InkSecondary (`SectionHeader`), button labels are 17 semibold (`OrbitButtonStyle`).
// Numbers that line up (prices, times, counts) add `.monospacedDigit()`.

extension Font {
    /// Welcome title and top-level page titles: "你好，我是 Orbit", "任务".
    static let orbitWelcome = Font.system(.title, design: .default, weight: .bold)
    /// Chat empty-state title: "今天想把什么交给我？".
    static let orbitEmptyTitle = Font.system(.title2, design: .default, weight: .semibold)
    /// Sheet / page title: "提交这家餐厅的预订".
    static let orbitPageTitle = Font.system(.title2, design: .default, weight: .semibold)
    /// Card title.
    static let orbitCardTitle = Font.system(.headline, design: .default, weight: .semibold)
    /// Body text (messages, rows).
    static let orbitBody = Font.system(.body, design: .default, weight: .regular)
    /// Secondary text under titles.
    static let orbitSecondary = Font.system(.subheadline, design: .default, weight: .regular)
    /// Auxiliary text: timestamps, counts, captions.
    static let orbitMeta = Font.system(.footnote, design: .default, weight: .regular)
    /// Inline text buttons and links.
    static let orbitAction = Font.system(.subheadline, design: .default, weight: .medium)
    /// Small labels.
    static let orbitChip = Font.system(.footnote, design: .default, weight: .medium)
}

extension View {
    /// Body text with the design's relaxed line height (about 1.5) for messages and long copy.
    func orbitBodyText() -> some View {
        font(.orbitBody).lineSpacing(3)
    }
}
