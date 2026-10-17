import SwiftUI

// Small shared pieces of the chat feature: the bot's display name, an avatar that honours a custom picture,
// a width-limiting layout for bubbles, and a few formatters.

// MARK: - Display name

extension AppModel {
    /// The bot's name as shown in the chat ("Orbit" unless the user renamed it).
    var chatBotName: String {
        let name = settings.butler.name.trimmingCharacters(in: .whitespacesAndNewlines)
        return name.isEmpty ? "Orbit" : name
    }
}

// MARK: - Avatar

/// The avatar string is a base64 picture; decoding it on every view update would be wasteful, so the last
/// decoded value is kept (there is only one bot avatar).
@MainActor
private enum AvatarDecodeCache {
    private static var raw: String?
    private static var value = AvatarValue.none

    static func decode(_ string: String?) -> AvatarValue {
        if string == raw { return value }
        raw = string
        value = AvatarValue(string)
        return value
    }
}

/// Orbit's avatar, or the picture / emoji the user picked in settings. `ring` marks "working" (an Accent inner ring);
/// the chat header and the sheets leave it off.
/// Decorative: hidden from VoiceOver (the surrounding control carries the label).
struct ChatAvatar: View {
    @Environment(AppModel.self) private var model
    var size: CGFloat
    var ring = false

    var body: some View {
        switch AvatarDecodeCache.decode(model.settings.butler.avatar) {
        case .none:
            OrbitAvatar(size: size, ring: ring)
        case .image(let cg):
            custom {
                Image(decorative: cg, scale: 1).resizable().scaledToFill()
            }
        case .emoji(let emoji):
            custom {
                ZStack {
                    Color.hairline
                    Text(emoji).font(.system(size: size * 0.55))
                }
            }
        }
    }

    private func custom(@ViewBuilder _ content: () -> some View) -> some View {
        content()
            .frame(width: size, height: size)
            .clipShape(.circle)
            .overlay {
                Circle().strokeBorder(ring ? Color.accentText : Color.hairline, lineWidth: ring ? 1.5 : 0.5)
            }
            .accessibilityHidden(true)
    }
}

// MARK: - State dot

/// A state mark: a 6 pt dot in the state's color and one line of text beside it, the dot level with the middle of the
/// letters. The word carries the state, the dot only adds color (never the other way round). Used for the presence line
/// in the chat header, the connection line on the settings home and the status lines of the task rows.
struct DotLabel: View {
    var color: Color
    var text: String
    /// 13 pt (`.footnote`) or 15 pt (`.subheadline`).
    var style: Font.TextStyle = .footnote
    var textColor: Color = .inkSecondary
    /// Lines the text may take; nil = as many as it needs (accessibility text sizes).
    var lineLimit: Int? = 1

    /// How far the dot's center sits above the baseline of the first line.
    @ScaledMetric(relativeTo: .footnote) private var footnoteLift: CGFloat = 4.8
    @ScaledMetric(relativeTo: .subheadline) private var subheadlineLift: CGFloat = 5.5

    var body: some View {
        let lift = style == .subheadline ? subheadlineLift : footnoteLift
        HStack(alignment: .firstTextBaseline, spacing: 6) {
            Circle()
                .fill(color)
                .frame(width: 6, height: 6)
                .alignmentGuide(.firstTextBaseline) { $0[VerticalAlignment.center] + lift }
                .accessibilityHidden(true)
            Text(verbatim: text)
                .font(.system(style))
                .foregroundStyle(textColor)
                .lineLimit(lineLimit)
                .multilineTextAlignment(.leading)
        }
        .accessibilityElement(children: .combine)
    }
}

extension Presence {
    /// The color of the dot before the status line: Accent while Orbit works, Warning when it waits for you or the Mac is
    /// gone, Success while it stands by, and a quiet grey while the connection comes back.
    var dotColor: Color {
        switch tone {
        case .live: .accentText
        case .warn: .warning
        case .neutral: mood == .wave ? .success : .inkTertiary
        }
    }
}

// MARK: - Press feedback

/// Press feedback for a row that has no card of its own: the label dims while the finger is down.
struct DimPressStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label.opacity(configuration.isPressed ? 0.55 : 1)
    }
}

// MARK: - Layout

/// Offers its single child at most `fraction` of the width it is given and pins the child to one side. The row
/// itself takes the full width, so bubbles line up on the same edge whatever their text length.
struct FractionalWidth: Layout {
    enum Side { case leading, trailing }

    var fraction: CGFloat
    var side: Side = .leading

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        guard let child = subviews.first else { return .zero }
        let limit = proposal.width.map { $0 * fraction }
        let size = child.sizeThatFits(ProposedViewSize(width: limit, height: proposal.height))
        return CGSize(width: proposal.width ?? size.width, height: size.height)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        guard let child = subviews.first else { return }
        let size = child.sizeThatFits(ProposedViewSize(width: bounds.width * fraction, height: bounds.height))
        let x = side == .trailing ? bounds.maxX - size.width : bounds.minX
        child.place(at: CGPoint(x: x, y: bounds.minY), anchor: .topLeading, proposal: ProposedViewSize(size))
    }
}

// MARK: - Reduce Motion

extension View {
    /// Under Reduce Motion every animation that reaches this subtree (the model animates its own state changes
    /// with springs) is swapped for the 0.15 s fade.
    func calmedForReduceMotion(_ reduce: Bool) -> some View {
        transaction { transaction in
            if reduce, transaction.animation != nil { transaction.animation = Motion.fade }
        }
    }
}

// MARK: - Formatting

enum ChatFormat {
    /// "今天 17:20", "昨天 17:20", "10月14日 17:20" — the centered label above the first message of a day.
    static func dayLabel(_ ms: Int64, calendar: Calendar = .current) -> String {
        let date = Clock.date(ms: ms)
        let time = Fmt.time(ms)
        if calendar.isDateInToday(date) { return "今天 " + time }
        if calendar.isDateInYesterday(date) { return "昨天 " + time }
        return date.formatted(.dateTime.month().day()) + " " + time
    }

    /// How the Mac is reached, in the words the boards use.
    static func pathName(_ path: TransportPath) -> String {
        switch path {
        case .lan: "局域网"
        case .relay: "外网中继"
        }
    }
}
