import SwiftUI

// Orders, tickets, bookings. Money, time, the other party and the status are what the eye should land on:
// amounts and times use monospaced digits, the status is always a `StatusChip` (a dot and a word) that updates in
// place on `ui.patch`. Nothing inside a card is tinted or boxed: facts sit in hairline-divided rows.

// MARK: - Status vocabulary

/// How a commerce status string looks as a chip. A status this app version does not know shows its raw text in the
/// neutral style rather than disappearing.
struct CommerceStatus {
    var kind: StatusKind
    var label: String
    var dot = false
    /// A settled good outcome (placed, booked, confirmed, done): the card gives one success haptic when it arrives.
    var isSettled = false

    static func order(_ status: String) -> CommerceStatus {
        switch status {
        case "draft": .init(kind: .draft, label: "草稿")
        case "confirming": .init(kind: .waiting, label: "确认中")
        case "placed": .init(kind: .ok, label: "已下单", isSettled: true)
        case "delivering": .init(kind: .running, label: "配送中", dot: true)
        case "done": .init(kind: .done, label: "已完成", isSettled: true)
        case "failed": .init(kind: .failed, label: "失败")
        default: .init(kind: .planning, label: status)
        }
    }

    static func ticket(_ status: String) -> CommerceStatus {
        switch status {
        case "options": .init(kind: .planning, label: "可选方案")
        case "holding": .init(kind: .waiting, label: "已锁座")
        case "booked": .init(kind: .ok, label: "已出票", isSettled: true)
        case "failed": .init(kind: .failed, label: "失败")
        default: .init(kind: .planning, label: status)
        }
    }

    static func booking(_ status: String) -> CommerceStatus {
        switch status {
        case "draft": .init(kind: .draft, label: "草稿")
        case "pending": .init(kind: .waiting, label: "待确认")
        case "confirmed": .init(kind: .ok, label: "已确认", isSettled: true)
        case "failed": .init(kind: .failed, label: "失败")
        default: .init(kind: .planning, label: status)
        }
    }
}

/// Header shared by the commerce cards: icon (or the merchant's picture), title, optional subtitle, status.
/// `image` is the raw picture string of the card (see `CardImage`).
struct CommerceHeader: View {
    var symbol: String
    var image: String? = nil
    var title: String
    var subtitle: String? = nil
    var status: CommerceStatus

    @Environment(\.dynamicTypeSize) private var typeSize

    var body: some View {
        let layout = typeSize.isAccessibilitySize
            ? AnyLayout(VStackLayout(alignment: .leading, spacing: Space.s))
            : AnyLayout(HStackLayout(alignment: .center, spacing: 10))
        layout {
            HStack(spacing: 12) {
                thumb
                VStack(alignment: .leading, spacing: 2) {
                    Text(title)
                        .font(.orbitCardTitle)
                        .foregroundStyle(Color.ink)
                        .fixedSize(horizontal: false, vertical: true)
                        .accessibilityAddTraits(.isHeader)
                    if let subtitle, !subtitle.isEmpty {
                        Text(subtitle)
                            .font(.orbitMeta)
                            .foregroundStyle(Color.inkSecondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            StatusChip(kind: status.kind, text: status.label, dot: status.dot)
        }
        .sensoryFeedback(.success, trigger: status.isSettled) { old, new in !old && new }
    }

    @ViewBuilder
    private var thumb: some View {
        if let image {
            CardImage(source: image, ratio: 1)
                .frame(width: 44, height: 44)
                .clipShape(.rect(cornerRadius: Radius.small, style: .continuous))
        } else {
            CardIcon(symbol: symbol, side: 28)
        }
    }
}

/// A pickup code / confirmation number in a hairline outline (no fill), selectable so it can be copied.
struct CodeBlock: View {
    var label: String
    var code: String

    var body: some View {
        HStack(spacing: Space.m) {
            Text(label)
                .font(.orbitMeta)
                .foregroundStyle(Color.inkSecondary)
            Spacer(minLength: Space.s)
            Text(code)
                .font(.system(.body, design: .monospaced, weight: .semibold))
                .tracking(1)
                .foregroundStyle(Color.success)
                .textSelection(.enabled)
        }
        .padding(.horizontal, Space.card)
        .padding(.vertical, Space.m)
        .overlay {
            RoundedRectangle(cornerRadius: Radius.control, style: .continuous)
                .strokeBorder(Color.hairline, lineWidth: 0.5)
        }
        .accessibilityElement(children: .combine)
    }
}

// MARK: - order_card

struct OrderCardView: View {
    var card: Card

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        let p = card.props
        let currency = p["currency"]?.string ?? "CNY"
        let items = p["items"]?.items ?? []
        let fees = p["fees"]?.items ?? []
        let eta = p["eta"]?.string.flatMap { $0.isEmpty ? nil : $0 }
        CardShell(card: card) {
            VStack(alignment: .leading, spacing: Space.l) {
                CommerceHeader(symbol: "bag",
                               image: p["imageUrl"]?.pictureString,
                               title: p["merchant"]?.string ?? "",
                               subtitle: nil,
                               status: .order(p["status"]?.string ?? "draft"))

                VStack(alignment: .leading, spacing: Space.s) {
                    ForEach(Array(items.enumerated()), id: \.offset) { _, item in
                        line(item, currency: currency)
                    }
                    ForEach(Array(fees.enumerated()), id: \.offset) { _, fee in
                        HStack(alignment: .firstTextBaseline) {
                            Text(fee["label"]?.string ?? "")
                            Spacer(minLength: Space.s)
                            Text(CardFormat.money(fee["amount"]?.double ?? 0, currency: currency)).monospacedDigit()
                        }
                        .font(.orbitMeta)
                        .foregroundStyle(Color.inkSecondary)
                        .accessibilityElement(children: .combine)
                    }
                }

                HairlineRule()

                HStack(alignment: .firstTextBaseline) {
                    Text("合计")
                        .font(.orbitSecondary.weight(.semibold))
                        .foregroundStyle(Color.ink)
                    Spacer(minLength: Space.s)
                    Text(CardFormat.money(p["total"]?.double ?? 0, currency: currency))
                        .font(.system(.title2, design: .default, weight: .semibold))
                        .monospacedDigit()
                        .foregroundStyle(Color.ink)
                        .contentTransition(.numericText())
                }
                .accessibilityElement(children: .combine)

                if let eta {
                    Label(eta, systemImage: "clock")
                        .font(.orbitMeta)
                        .foregroundStyle(Color.inkSecondary)
                        .transition(.opacity)
                }
            }
            .cardInsets()
        }
        .animation(MotionAware(reduce: reduceMotion).spring, value: p)
    }

    /// One ordered item: name and note, quantity, line total (unit price x quantity).
    private func line(_ item: JSONValue, currency: String) -> some View {
        let qty = item["qty"]?.int ?? 1
        return HStack(alignment: .firstTextBaseline, spacing: Space.s) {
            VStack(alignment: .leading, spacing: 1) {
                Text(item["name"]?.string ?? "")
                    .font(.orbitSecondary)
                    .foregroundStyle(Color.ink)
                if let note = item["note"]?.string, !note.isEmpty {
                    Text(note).font(.orbitMeta).foregroundStyle(Color.inkSecondary)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            Text("×\(qty)")
                .font(.orbitMeta.monospacedDigit())
                .foregroundStyle(Color.inkSecondary)
            Text(CardFormat.money((item["price"]?.double ?? 0) * Double(qty), currency: currency))
                .font(.orbitSecondary.monospacedDigit())
                .foregroundStyle(Color.ink)
        }
        .accessibilityElement(children: .combine)
    }
}

// MARK: - ticket_card

struct TicketCardView: View {
    var card: Card

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        let p = card.props
        let kind = p["kind"]?.string ?? "train"
        let departAt = p["departAt"]?.int64
        let hasRoute = p["from"] != nil || p["to"] != nil
        CardShell(card: card) {
            VStack(alignment: .leading, spacing: Space.l) {
                CommerceHeader(symbol: Self.symbol(kind),
                               title: p["title"]?.string ?? "",
                               subtitle: departAt.map { CardFormat.day(Clock.date(ms: $0)) },
                               status: .ticket(p["status"]?.string ?? "options"))

                if hasRoute {
                    TicketRoute(from: p["from"]?.string, to: p["to"]?.string,
                                departAt: departAt, arriveAt: p["arriveAt"]?.int64, symbol: Self.symbol(kind))
                } else if let departAt {
                    Label(CardFormat.dateTime(departAt), systemImage: "clock")
                        .font(.orbitSecondary.weight(.medium))
                        .foregroundStyle(Color.ink)
                }

                if let venue = p["venue"]?.string, !venue.isEmpty {
                    Label(venue, systemImage: "building.2")
                        .font(.orbitMeta)
                        .foregroundStyle(Color.inkSecondary)
                }

                seatAndPrice(p)

                if let code = p["code"]?.string, !code.isEmpty {
                    CodeBlock(label: "取票码", code: code)
                        .transition(.opacity)
                }
            }
            .cardInsets()
        }
        .animation(MotionAware(reduce: reduceMotion).spring, value: p)
    }

    @ViewBuilder
    private func seatAndPrice(_ p: JSONValue) -> some View {
        let seat = p["seat"]?.string.flatMap { $0.isEmpty ? nil : $0 }
        let price = p["price"]?.double
        if seat != nil || price != nil {
            HStack(alignment: .firstTextBaseline, spacing: Space.m) {
                if let seat {
                    Label(seat, systemImage: "chair")
                        .font(.orbitSecondary.weight(.medium))
                        .foregroundStyle(Color.ink)
                        .transition(.opacity)
                }
                Spacer(minLength: Space.s)
                if let price {
                    Text(CardFormat.money(price, currency: p["currency"]?.string ?? "CNY"))
                        .font(.system(.title2, design: .default, weight: .semibold))
                        .monospacedDigit()
                        .foregroundStyle(Color.ink)
                        .contentTransition(.numericText())
                }
            }
        }
    }

    static func symbol(_ kind: String) -> String {
        switch kind {
        case "flight": "airplane"
        case "movie": "film"
        case "show": "theatermasks"
        case "bus": "bus"
        default: "tram.fill"
        }
    }
}

/// Departure and arrival: big times at both ends, the duration and a route line between them.
private struct TicketRoute: View {
    var from: String?
    var to: String?
    var departAt: Int64?
    var arriveAt: Int64?
    var symbol: String

    @Environment(\.dynamicTypeSize) private var typeSize

    var body: some View {
        if typeSize.isAccessibilitySize {
            VStack(alignment: .leading, spacing: Space.s) {
                endpoint(name: from, at: departAt, alignment: .leading)
                Image(systemName: "arrow.down")
                    .font(.system(.footnote, weight: .semibold))
                    .foregroundStyle(Color.inkSecondary)
                    .accessibilityHidden(true)
                endpoint(name: to, at: arriveAt, alignment: .leading)
            }
        } else {
            HStack(alignment: .top, spacing: Space.s) {
                endpoint(name: from, at: departAt, alignment: .leading)
                VStack(spacing: Space.xs) {
                    if let duration {
                        Text(duration)
                            .font(.orbitMeta.monospacedDigit())
                            .foregroundStyle(Color.inkSecondary)
                    }
                    HStack(spacing: Space.xs) {
                        Circle().strokeBorder(Color.inkTertiary, lineWidth: 1).frame(width: 5, height: 5)
                        Rectangle().fill(Color.hairline).frame(height: 1)
                        Image(systemName: symbol).font(.system(size: 12, weight: .semibold)).foregroundStyle(Color.inkSecondary)
                        Rectangle().fill(Color.hairline).frame(height: 1)
                        Circle().fill(Color.inkTertiary).frame(width: 5, height: 5)
                    }
                }
                .frame(maxWidth: .infinity)
                .padding(.top, Space.s)
                .accessibilityHidden(true)
                endpoint(name: to, at: arriveAt, alignment: .trailing)
            }
        }
    }

    private func endpoint(name: String?, at ms: Int64?, alignment: HorizontalAlignment) -> some View {
        VStack(alignment: alignment, spacing: 2) {
            if let ms {
                HStack(alignment: .firstTextBaseline, spacing: 3) {
                    Text(CardFormat.time(Clock.date(ms: ms)))
                        .font(.system(.title2, design: .default, weight: .semibold))
                        .monospacedDigit()
                        .foregroundStyle(Color.ink)
                    if alignment == .trailing, nextDay {
                        Text("+1").font(.system(.caption2, weight: .semibold)).foregroundStyle(Color.inkSecondary)
                    }
                }
            }
            if let name, !name.isEmpty {
                Text(name).font(.orbitMeta).foregroundStyle(Color.inkSecondary)
            }
        }
        .accessibilityElement(children: .combine)
    }

    /// The arrival is on a later day than the departure (night train, red-eye flight).
    private var nextDay: Bool {
        guard let a = departAt, let b = arriveAt else { return false }
        return !Calendar.current.isDate(Clock.date(ms: a), inSameDayAs: Clock.date(ms: b)) && b > a
    }

    private var duration: String? {
        guard let a = departAt, let b = arriveAt, b > a else { return nil }
        let minutes = Int((b - a) / 60_000)
        if minutes % 60 == 0 { return "\(minutes / 60) 小时" }
        return minutes < 60 ? "\(minutes) 分" : "\(minutes / 60) 小时 \(minutes % 60) 分"
    }
}

// MARK: - booking_card

/// A booking as hairline-divided rows ("餐厅 / 时间 / 人数 / 地点"), then its status as a dot and a word, the note as one
/// secondary line, and the confirmation number when there is one.
struct BookingCardView: View {
    var card: Card

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        let p = card.props
        let kind = p["kind"]?.string ?? "other"
        let status = CommerceStatus.booking(p["status"]?.string ?? "draft")
        let rows = detailRows(p, kind: kind)
        CardShell(card: card) {
            VStack(alignment: .leading, spacing: 0) {
                if !rows.isEmpty { KeyValueList(rows: rows) }

                if !rows.isEmpty { HairlineRule().padding(.top, 10) }
                StatusChip(kind: status.kind, text: status.label, dot: status.dot)
                    .padding(.top, rows.isEmpty ? 0 : 10)

                if let note = p["note"]?.string, !note.isEmpty {
                    NoteBlock(kind: .info, systemImage: "text.bubble") { Text(note) }
                        .padding(.top, Space.s)
                }

                if let confirmation = p["confirmation"]?.string, !confirmation.isEmpty {
                    CodeBlock(label: "确认号", code: confirmation)
                        .padding(.top, Space.m)
                        .transition(.opacity)
                }
            }
            .cardInsets()
            .sensoryFeedback(.success, trigger: status.isSettled) { old, new in !old && new }
        }
        .animation(MotionAware(reduce: reduceMotion).spring, value: p)
    }

    /// The kind and name come first ("餐厅  鮨 · 静安店"), then the time, party size and place, whichever the card has.
    private func detailRows(_ p: JSONValue, kind: String) -> [(String, String)] {
        var rows: [(String, String)] = []
        if let name = p["name"]?.string, !name.isEmpty { rows.append((Self.kindLabel(kind), name)) }
        if let time = timeText(p["time"]) { rows.append(("时间", time)) }
        if let n = p["partySize"]?.int { rows.append(("人数", "\(n) 人")) }
        if let address = p["address"]?.string, !address.isEmpty { rows.append(("地点", address)) }
        return rows
    }

    /// `time` is free text ("10/20 入住 · 4 晚"); a Unix-millisecond number is formatted as a date and time.
    private func timeText(_ value: JSONValue?) -> String? {
        guard let value else { return nil }
        if case .number(let n) = value, n > 100_000_000_000 { return CardFormat.dateTime(Int64(n)) }
        let text = value.displayString
        return text.isEmpty ? nil : text
    }

    private static func kindLabel(_ kind: String) -> String {
        switch kind {
        case "restaurant": "餐厅"
        case "hotel": "酒店"
        case "appointment": "预约"
        default: "预订"
        }
    }
}
