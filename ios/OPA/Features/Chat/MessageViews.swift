import SwiftUI

// MARK: - Rows

/// One row of the thread with everything layout needs to know about its neighbours.
struct ChatRow: Identifiable, Equatable {
    var item: TimelineItem
    /// Orbit's side only: this row opens a reply group, so it carries the avatar + "Orbit · 17:20" line.
    var startsGroup: Bool
    /// Centered label above the first message of a day.
    var dayLabel: String?
    /// Space above the row.
    var gap: CGFloat
    /// The waiting row at the end of the thread (`ThinkingRow`), not a message: `item` only carries the time for the
    /// byline.
    var isWaiting = false

    var id: String { item.id }
}

enum ChatRows {
    /// A pause this long between two of Orbit's items starts a new reply group (and shows the time again).
    static let groupGapMs: Int64 = 10 * 60_000

    /// Rows for the timeline in arrival order. Replies with nothing to read (no text, only blank lines, or a
    /// streaming placeholder that has not got its first words yet) are left out whole: no avatar, name, time or tag.
    /// The waiting row at the end of the thread covers the moment before the words come.
    static func build(_ timeline: [TimelineItem], calendar: Calendar = .current) -> [ChatRow] {
        var rows: [ChatRow] = []
        rows.reserveCapacity(timeline.count)
        var previous: TimelineItem?
        for item in timeline where isVisible(item) {
            rows.append(row(for: item, after: previous, calendar: calendar))
            previous = item
        }
        return rows
    }

    /// The row Orbit's reply gets while it is still being prepared: the group, day label and gap are worked out exactly
    /// as for the reply itself (`previous` is the last row of the thread), so the reply later takes the same place.
    static func waitingRow(after previous: TimelineItem?, now: Int64, calendar: Calendar = .current) -> ChatRow {
        let stand = AssistantMessage(id: "waiting", text: "", proactive: false, interrupted: false, streaming: true, ts: now)
        var waiting = row(for: .assistant(stand), after: previous, calendar: calendar)
        waiting.isWaiting = true
        return waiting
    }

    private static func row(for item: TimelineItem, after previous: TimelineItem?, calendar: Calendar) -> ChatRow {
        let newDay = previous.map { !calendar.isDate(Clock.date(ms: $0.ts), inSameDayAs: Clock.date(ms: item.ts)) } ?? true
        let sameSide = previous.map { isUser($0) == isUser(item) } ?? false
        let startsGroup = !isUser(item) && (!sameSide || newDay || abs(item.ts - (previous?.ts ?? 0)) > groupGapMs)
        let gap: CGFloat = previous == nil || newDay ? 0 : (sameSide && !startsGroup ? 6 : 16)
        return ChatRow(item: item, startsGroup: startsGroup,
                       dayLabel: newDay ? ChatFormat.dayLabel(item.ts, calendar: calendar) : nil, gap: gap)
    }

    static func isUser(_ item: TimelineItem) -> Bool {
        if case .user = item { true } else { false }
    }

    /// Whether the thread shows the item. Orbit's replies need something to read, whatever else they carry (a "主动"
    /// tag, a stopped mark): old data and old Mac versions left empty and blank ones behind.
    static func isVisible(_ item: TimelineItem) -> Bool {
        if case .assistant(let m) = item { return m.hasVisibleText }
        return true
    }
}

extension AssistantMessage {
    /// Something a person can read. Spaces, line breaks and invisible characters alone are nothing.
    var hasVisibleText: Bool {
        text.unicodeScalars.contains { !Self.isBlank($0) }
    }

    /// The reply as shown: without the blank lines it starts or ends with, so the first words land on the first line
    /// (where the waiting row had its dots) and the in-progress dot stays on the last line of text.
    var displayText: String {
        let scalars = text.unicodeScalars
        guard let first = scalars.firstIndex(where: { !Self.isBlank($0) }),
              let last = scalars.lastIndex(where: { !Self.isBlank($0) }) else { return "" }
        return String(scalars[first...last])
    }

    private static func isBlank(_ scalar: Unicode.Scalar) -> Bool {
        scalar.properties.isWhitespace || scalar.properties.isDefaultIgnorableCodePoint
    }
}

/// Measures that Orbit's reply and the waiting row standing in for it share, so one replaces the other in place.
enum ReplyLayout {
    /// Between the byline and the text.
    static let bylineSpacing: CGFloat = 4
    /// Side inset of the text (and of the dots).
    static let textInset: CGFloat = 2
}

/// `Equatable` so the thread can skip rows that did not change while one reply streams in.
struct ChatRowView: View, Equatable {
    var row: ChatRow

    nonisolated static func == (a: ChatRowView, b: ChatRowView) -> Bool { a.row == b.row }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            if let label = row.dayLabel {
                Text(label)
                    .font(.system(.footnote, weight: .medium))
                    .foregroundStyle(Color.inkTertiary)
                    .frame(maxWidth: .infinity)
                    .padding(.top, Space.xs)
                    .padding(.bottom, Space.m)
            }
            content
        }
        .padding(.top, row.gap)
    }

    @ViewBuilder private var content: some View {
        if row.isWaiting {
            ThinkingRow(ts: row.item.ts, showsByline: row.startsGroup)
        } else {
            switch row.item {
            case .user(let message): UserMessageRow(message: message)
            case .assistant(let message): AssistantMessageRow(message: message, showsByline: row.startsGroup)
            case .card(let card): CardMessageRow(card: card, showsByline: row.startsGroup)
            }
        }
    }
}

// MARK: - Bubble

private enum Bubble {
    /// Your message takes at most 80 % of the width.
    static let maxWidthFraction: CGFloat = 0.8
}

// MARK: - Your message

/// Your message: on the right, on a UserBubble fill with 16 pt corners all round (no tail), Ink text. Orbit's replies
/// carry no bubble at all (see `AssistantMessageRow`).
struct UserMessageRow: View {
    var message: UserMessage

    var body: some View {
        FractionalWidth(fraction: Bubble.maxWidthFraction, side: .trailing) {
            VStack(alignment: .trailing, spacing: 4) {
                if !message.attachments.isEmpty {
                    SentAttachments(clientId: message.clientId, attachments: message.attachments)
                }
                if !message.text.isEmpty {
                    // Long-press selects the text and offers the system "拷贝".
                    Text(message.text)
                        .font(.orbitBody)
                        .lineSpacing(2)
                        .foregroundStyle(Color.ink)
                        .textSelection(.enabled)
                        .padding(.horizontal, 14)
                        .padding(.vertical, 9)
                        .background(Color.userBubble, in: .rect(cornerRadius: Radius.bubble, style: .continuous))
                        .accessibilityLabel("我：\(message.text)")
                }
                DeliveryLine(message: message)
            }
        }
    }
}

/// Where your message is on its way: nothing while sending / sent, a note when it waits for the Mac, and a
/// retry when the Mac refused it.
private struct DeliveryLine: View {
    @Environment(AppModel.self) private var model
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    var message: UserMessage

    var body: some View {
        Group {
            switch message.delivery {
            case .sending, .sent:
                EmptyView()
            case .queued:
                HStack(spacing: 4) {
                    Image(systemName: "clock").font(.system(size: 11, weight: .semibold)).accessibilityHidden(true)
                    Text("待发送 · Mac 连上后自动发出")
                }
                .foregroundStyle(Color.warning)
                .accessibilityElement(children: .combine)
            case .failed(let reason):
                HStack(spacing: 4) {
                    Image(systemName: "exclamationmark.circle").font(.system(size: 11, weight: .semibold)).accessibilityHidden(true)
                    Text("没有送达")
                    Button {
                        model.retry(clientId: message.clientId)
                    } label: {
                        Text("重试")
                            .fontWeight(.semibold)
                            .foregroundStyle(Color.accentText)
                            .padding(.leading, 6)
                            .contentShape(Rectangle().inset(by: -14))
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("重试发送")
                    .accessibilityHint(reason)
                }
                .foregroundStyle(Color.danger)
            }
        }
        .font(.footnote)
        .padding(.horizontal, 4)
        .transition(.opacity)
        .animation(MotionAware(reduce: reduceMotion).snappy, value: message.delivery)
    }
}

// MARK: - Orbit's message

/// Orbit's reply: no bubble, plain text on the page, left aligned, 17 / 25. The first reply of a group carries the
/// byline above it. Only replies with something to read get here (see `ChatRows.isVisible`); the "主动" tag and the
/// stopped mark never stand alone. While the first words are awaited, `ThinkingRow` takes this place.
struct AssistantMessageRow: View {
    @Environment(AppModel.self) private var model
    var message: AssistantMessage
    var showsByline: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: ReplyLayout.bylineSpacing) {
            if showsByline { Byline(ts: message.ts) }
            text
        }
    }

    private var text: some View {
        let shown = message.displayText
        return VStack(alignment: .leading, spacing: 6) {
            if message.proactive && !shown.isEmpty { ProactiveTag() }
            if !shown.isEmpty { MarkdownText(shown, streaming: message.streaming) }
            if message.interrupted { StoppedMarker() }
        }
        .padding(.horizontal, ReplyLayout.textInset)
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(model.chatBotName)：\(shown)\(message.interrupted ? "，已停止" : "")")
    }
}

/// Avatar + "Orbit · 17:20" above the first item of a reply group.
struct Byline: View {
    @Environment(AppModel.self) private var model
    var ts: Int64

    var body: some View {
        HStack(spacing: 7) {
            ChatAvatar(size: 20)
            Text("\(model.chatBotName) · \(Fmt.time(ts))")
                .font(.system(.footnote, weight: .medium))
                .foregroundStyle(Color.inkTertiary)
        }
        .padding(.leading, 2)
        .padding(.bottom, 3)
        .accessibilityElement(children: .combine)
    }
}

/// "主动": Orbit spoke first. A sparkle and a word in secondary text, no fill.
private struct ProactiveTag: View {
    var body: some View {
        HStack(spacing: 4) {
            Image(systemName: "sparkle").font(.system(size: 11, weight: .semibold)).accessibilityHidden(true)
            Text("主动")
        }
        .font(.system(.footnote, weight: .medium))
        .foregroundStyle(Color.inkSecondary)
    }
}

private struct StoppedMarker: View {
    var body: some View {
        HStack(spacing: 4) {
            Image(systemName: "stop.circle").font(.system(size: 11, weight: .semibold)).accessibilityHidden(true)
            Text("已停止")
        }
        .font(.footnote)
        .foregroundStyle(Color.inkTertiary)
    }
}

/// Renders inline markdown. While the reply streams the text grows as a whole (no per-character fade) and a small
/// static Accent dot marks the end.
struct MarkdownText: View {
    var text: String
    var streaming: Bool

    init(_ text: String, streaming: Bool = false) {
        self.text = text
        self.streaming = streaming
    }

    var body: some View {
        let attributed = MarkdownCache.parse(text, remember: !streaming)
        Group {
            if streaming {
                Text("\(Text(attributed)) \(Text(Image(systemName: "circle.fill")).font(.system(size: 8)).foregroundStyle(Color.accentText).baselineOffset(1))")
            } else {
                Text(attributed)
            }
        }
        .font(.orbitBody)
        .lineSpacing(3)
        .foregroundStyle(Color.ink)
        .textSelection(.enabled)
        .fixedSize(horizontal: false, vertical: true)
    }
}

// MARK: - Cards

struct CardMessageRow: View {
    var card: Card
    var showsByline: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            if showsByline { Byline(ts: card.ts) }
            CardHost(card: card)
        }
    }
}

// MARK: - New reply pill

/// "↓ 有新回复": shown over the bottom of the thread when a reply arrives while you are reading older messages. A small
/// primary button (12 pt corners, no shadow).
struct NewReplyPill: View {
    var action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 6) {
                Image(systemName: "arrow.down").font(.system(size: 12, weight: .bold)).accessibilityHidden(true)
                Text("有新回复").font(.system(.footnote, weight: .semibold))
            }
            .foregroundStyle(Color.onPrimary)
            .padding(.horizontal, 14)
            .frame(minHeight: 36)
            .background(Color.primaryFill, in: .rect(cornerRadius: Radius.control, style: .continuous))
            .contentShape(Rectangle().inset(by: -4))
        }
        .buttonStyle(.pressable)
        .accessibilityLabel("有新回复")
        .accessibilityHint("回到最新消息")
    }
}

// MARK: - Markdown cache

/// Parsed markdown for finished messages, so rows coming back into view don't parse again.
@MainActor
private enum MarkdownCache {
    private static var store: [String: AttributedString] = [:]

    static func parse(_ text: String, remember: Bool) -> AttributedString {
        if let hit = store[text] { return hit }
        let value = (try? AttributedString(markdown: text, options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace)))
            ?? AttributedString(text)
        if remember {
            if store.count > 400 { store.removeAll(keepingCapacity: true) }
            store[text] = value
        }
        return value
    }
}
