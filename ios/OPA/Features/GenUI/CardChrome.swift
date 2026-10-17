import SwiftUI

// MARK: - Shared card building blocks
//
// Every GenUI card is an `OrbitCard` (Surface, 12 pt corners, 0.5 pt Hairline, no shadow) with the same rhythm:
// header (title, status, accessory) -> content -> meta / footer -> actions. Inside a card nothing is tinted or boxed:
// groups are divided by hairlines. The paddings come from docs/design/v2-direction.md (14 all round, 10 between header
// and content) and live here so the cards stay consistent.

enum CardMetrics {
    static let side: CGFloat = Space.card
    static let headerTop: CGFloat = Space.card
    static let headerBottom: CGFloat = 10
    static let bodyBottom: CGFloat = Space.card
}

extension View {
    /// Inset of a card's header row.
    func cardHeaderInsets() -> some View {
        padding(EdgeInsets(top: CardMetrics.headerTop, leading: CardMetrics.side,
                           bottom: CardMetrics.headerBottom, trailing: CardMetrics.side))
    }

    /// Inset of a card's content block that sits under a header.
    func cardBodyInsets() -> some View {
        padding(EdgeInsets(top: 0, leading: CardMetrics.side, bottom: CardMetrics.bodyBottom, trailing: CardMetrics.side))
    }

    /// Inset of card content without a header: 14 on all four sides.
    func cardInsets() -> some View {
        padding(CardMetrics.side)
    }
}

// MARK: - Shell

/// The `OrbitCard` every component sits in, plus the card's action row (`Card.actions`) at the bottom.
/// Components with their own buttons (`task_progress`, `approval_card`, `memory_saved`) draw their own card instead.
struct CardShell<Content: View>: View {
    var card: Card
    @ViewBuilder var content: Content

    var body: some View {
        OrbitCard {
            VStack(alignment: .leading, spacing: 0) {
                content
                if let actions = card.actions, !actions.isEmpty {
                    CardActionBar(card: card, actions: actions)
                        .padding(.horizontal, CardMetrics.side)
                        .padding(.bottom, CardMetrics.side)
                }
            }
        }
    }
}

// MARK: - Header

/// Title row of a card: optional icon, semibold title, optional trailing accessory (status chip, menu).
/// At accessibility text sizes the accessory moves under the title so the title keeps the full width.
struct CardHeader<Accessory: View>: View {
    var title: String
    var symbol: String?
    var accessory: Accessory

    @Environment(\.dynamicTypeSize) private var typeSize

    init(_ title: String, symbol: String? = nil, @ViewBuilder accessory: () -> Accessory) {
        self.title = title
        self.symbol = symbol
        self.accessory = accessory()
    }

    var body: some View {
        let layout = typeSize.isAccessibilitySize
            ? AnyLayout(VStackLayout(alignment: .leading, spacing: Space.s))
            : AnyLayout(HStackLayout(alignment: .center, spacing: 10))
        layout {
            HStack(spacing: 8) {
                if let symbol { CardGlyph(symbol: symbol) }
                Text(title)
                    .font(.orbitCardTitle)
                    .foregroundStyle(Color.ink)
                    .fixedSize(horizontal: false, vertical: true)
                    .accessibilityAddTraits(.isHeader)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            accessory
        }
    }
}

extension CardHeader where Accessory == EmptyView {
    init(_ title: String, symbol: String? = nil) {
        self.init(title, symbol: symbol) { EmptyView() }
    }
}

/// Small icon used in card headers: a plain SF Symbol in InkSecondary, no tile behind it, in a slot a little wider than
/// the glyph so the title stays aligned from card to card.
struct CardGlyph: View {
    var symbol: String

    @ScaledMetric(relativeTo: .headline) private var slot: CGFloat = 20

    var body: some View {
        // Grows with the text size, but stops at 32 pt: it is a marker, not content.
        let side = min(slot, 32)
        Image(systemName: symbol)
            .font(.system(size: 15, weight: .regular))
            .foregroundStyle(Color.inkSecondary)
            .frame(width: side, height: side)
            .accessibilityHidden(true)
    }
}

/// Larger icon used as the visual anchor of commerce cards: a plain SF Symbol in InkSecondary, no tile behind it.
struct CardIcon: View {
    var symbol: String
    var side: CGFloat = 28

    @ScaledMetric(relativeTo: .body) private var factor: CGFloat = 1

    var body: some View {
        // Scales with the text size up to 1.35x so the slot never takes over a narrow card.
        let scaled = side * min(factor, 1.35)
        Image(systemName: symbol)
            .font(.system(size: scaled * 0.62, weight: .regular))
            .foregroundStyle(Color.inkSecondary)
            .frame(width: scaled, height: scaled)
            .accessibilityHidden(true)
    }
}

// MARK: - Footer

/// Meta row at the bottom of a card, separated from the content by a hairline.
struct CardFooter<Content: View>: View {
    @ViewBuilder var content: Content

    var body: some View {
        VStack(spacing: 0) {
            HairlineRule()
            content
                .padding(.horizontal, CardMetrics.side)
                .padding(.vertical, 10)
        }
    }
}

/// Text link in a card ("查看任务"): Accent, 15 pt medium, with the press feedback of a link.
struct CardLinkStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.orbitAction)
            .foregroundStyle(Color.accentText)
            .opacity(configuration.isPressed ? 0.55 : 1)
    }
}

// MARK: - Hint row

/// The frame of a hint: at least 38 pt tall, a Hairline above and below, a 2 pt inset on the sides. Hints are the
/// lightest thing in the thread ("已记住：…", "需要你确认：…"): one line, no card, no icon block.
struct HintRowChrome: ViewModifier {
    func body(content: Content) -> some View {
        content
            .padding(.horizontal, 2)
            .frame(maxWidth: .infinity, minHeight: 38, alignment: .leading)
            .overlay(alignment: .top) { HairlineRule() }
            .overlay(alignment: .bottom) { HairlineRule() }
    }
}

extension View {
    func hintRowChrome() -> some View { modifier(HintRowChrome()) }
}

/// A one-line hint with an optional action on the right: the words in 15 pt (InkSecondary, or Ink when `emphasized`),
/// an optional 6 pt status dot before them, and `action` (an Accent text button, 15 pt medium) after them. At
/// accessibility text sizes the action drops under the words.
struct HintRow<Action: View>: View {
    var label: Text
    var dot: Color?
    var emphasized: Bool
    var action: Action

    @Environment(\.dynamicTypeSize) private var typeSize
    @ScaledMetric(relativeTo: .subheadline) private var dotLift: CGFloat = 5

    init(_ label: Text, dot: Color? = nil, emphasized: Bool = false, @ViewBuilder action: () -> Action) {
        self.label = label
        self.dot = dot
        self.emphasized = emphasized
        self.action = action()
    }

    init(text: String, dot: Color? = nil, emphasized: Bool = false, @ViewBuilder action: () -> Action) {
        self.init(Text(verbatim: text), dot: dot, emphasized: emphasized, action: action)
    }

    var body: some View {
        let lift = dotLift
        let layout = typeSize.isAccessibilitySize
            ? AnyLayout(VStackLayout(alignment: .leading, spacing: Space.xs))
            : AnyLayout(HStackLayout(alignment: .center, spacing: Space.m))
        layout {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                if let dot {
                    Circle()
                        .fill(dot)
                        .frame(width: 6, height: 6)
                        .alignmentGuide(.firstTextBaseline) { $0[VerticalAlignment.center] + lift }
                        .accessibilityHidden(true)
                }
                label
                    .font(.orbitSecondary)
                    .foregroundStyle(emphasized ? Color.ink : Color.inkSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            action
        }
        .padding(.vertical, 6)
        .hintRowChrome()
    }
}

extension HintRow where Action == EmptyView {
    init(_ label: Text, dot: Color? = nil, emphasized: Bool = false) {
        self.init(label, dot: dot, emphasized: emphasized) { EmptyView() }
    }

    init(text: String, dot: Color? = nil, emphasized: Bool = false) {
        self.init(Text(verbatim: text), dot: dot, emphasized: emphasized) { EmptyView() }
    }
}

// MARK: - Buttons row

private struct CardButtonsStackedKey: EnvironmentKey {
    static let defaultValue = false
}

extension EnvironmentValues {
    /// True while a `CardButtonRow` had to stack its buttons: each button then takes the full width.
    var cardButtonsStacked: Bool {
        get { self[CardButtonsStackedKey.self] }
        set { self[CardButtonsStackedKey.self] = newValue }
    }
}

/// Horizontal row of buttons that falls back to a vertical stack when they no longer fit (large text sizes).
struct CardButtonRow<Content: View>: View {
    @ViewBuilder var content: Content

    var body: some View {
        ViewThatFits(in: .horizontal) {
            HStack(spacing: 10) { content }
            VStack(spacing: 8) { content }
                .environment(\.cardButtonsStacked, true)
        }
    }
}

/// Width of a button inside a `CardButtonRow`: the main button takes the free width, the others hug their label;
/// stacked, all of them fill the row.
struct CardButtonWidth: ViewModifier {
    var expands: Bool
    @Environment(\.cardButtonsStacked) private var stacked

    func body(content: Content) -> some View {
        content.frame(maxWidth: expands || stacked ? .infinity : nil)
    }
}

extension View {
    func cardButtonWidth(expands: Bool) -> some View {
        modifier(CardButtonWidth(expands: expands))
    }
}

// MARK: - Placeholder

/// Compact stand-in for a card whose data is gone or not here yet ("这个任务已从列表清除", "这个确认已失效"): a hint
/// row without an action.
struct CardPlaceholder: View {
    var symbol: String?
    var text: String
    var loading = false

    var body: some View {
        HStack(spacing: 10) {
            if loading {
                ProgressView().controlSize(.small)
            } else if let symbol {
                Image(systemName: symbol).font(.system(.subheadline, weight: .regular))
            }
            Text(text).font(.orbitSecondary)
        }
        .foregroundStyle(Color.inkSecondary)
        .padding(.vertical, 6)
        .hintRowChrome()
        .accessibilityElement(children: .combine)
    }
}

// MARK: - Formatting

enum CardFormat {
    /// The app's copy is Chinese, so dates and amounts in cards are too, whatever the device region is.
    static let locale = Locale(identifier: "zh_CN")

    /// "¥44", "¥12.50". CNY always shows the yen sign.
    static func money(_ value: Double, currency: String = "CNY") -> String {
        value.formatted(
            .currency(code: currency)
                .locale(locale)
                .precision(.fractionLength(value.rounded() == value ? 0 : 2)))
    }

    /// "10 月 18 日 周六".
    static func day(_ date: Date) -> String {
        date.formatted(Date.VerbatimFormatStyle(
            format: "\(month: .defaultDigits) 月 \(day: .defaultDigits) 日 \(weekday: .abbreviated)",
            locale: locale, timeZone: .current, calendar: .current))
    }

    /// "19:00" (24-hour, as in the design).
    static func time(_ date: Date) -> String {
        date.formatted(Date.VerbatimFormatStyle(
            format: "\(hour: .twoDigits(clock: .twentyFourHour, hourCycle: .zeroBased)):\(minute: .twoDigits)",
            locale: locale, timeZone: .current, calendar: .current))
    }

    /// "今天 19:00", "明天 08:00", "10 月 18 日 周六 19:00".
    static func dateTime(_ ms: Int64) -> String {
        let date = Clock.date(ms: ms)
        if Calendar.current.isDateInToday(date) { return "今天 " + time(date) }
        if Calendar.current.isDateInTomorrow(date) { return "明天 " + time(date) }
        return day(date) + " " + time(date)
    }
}

// MARK: - Feedback

/// Haptics for the one thing a card does: success once the host accepted an action, error when it refused.
struct SubmitFeedback: ViewModifier {
    var success: Int
    var failure: Int

    func body(content: Content) -> some View {
        content
            .sensoryFeedback(.success, trigger: success)
            .sensoryFeedback(.error, trigger: failure)
    }
}

extension View {
    func submitFeedback(success: Int, failure: Int) -> some View {
        modifier(SubmitFeedback(success: success, failure: failure))
    }
}

// MARK: - Interaction memory

extension Card {
    /// Identifies one render of a card: its id plus the time the host rendered it. A card the host renders again
    /// under the same id (a new `ui.render`, or a demo run that starts over) is a fresh card and starts with no memory.
    var interactionKey: String { "\(id)#\(ts)" }
}

/// What the user already did on a card, kept in memory per card.
///
/// The chat is a lazy list: a card that scrolls far away loses its `@State`, and coming back it would offer the
/// same choice or purchase again. Selections, submitted flags, typed form values and finished action buttons
/// therefore live here. (After a relaunch the host's `ui.patch` props such as `submitted` take over.)
@MainActor
@Observable
final class CardInteractionStore {
    static let shared = CardInteractionStore()

    private init() {}

    /// `choice_list` / `comparison`: the option ids the user picked.
    private(set) var selections: [String: Set<String>] = [:]
    /// Cards whose select / submit the host accepted.
    private(set) var submitted: Set<String> = []
    /// Action-bar buttons the host accepted, per card.
    private(set) var doneActions: [String: Set<String>] = [:]
    /// `form`: the values typed so far.
    private(set) var formValues: [String: [String: JSONValue]] = [:]

    func selection(_ card: Card) -> Set<String> { selections[card.interactionKey] ?? [] }

    func setSelection(_ ids: Set<String>, for card: Card) { selections[card.interactionKey] = ids }

    func isSubmitted(_ card: Card) -> Bool { submitted.contains(card.interactionKey) }

    func markSubmitted(_ card: Card) { submitted.insert(card.interactionKey) }

    func isDone(_ actionId: String, card: Card) -> Bool { doneActions[card.interactionKey]?.contains(actionId) ?? false }

    func markDone(_ actionId: String, card: Card) { doneActions[card.interactionKey, default: []].insert(actionId) }

    /// The values typed into a form, or nil while the user has not touched it.
    func values(of card: Card) -> [String: JSONValue]? { formValues[card.interactionKey] }

    func setValues(_ values: [String: JSONValue], for card: Card) { formValues[card.interactionKey] = values }
}
