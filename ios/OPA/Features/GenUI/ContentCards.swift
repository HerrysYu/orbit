import AVKit
import MapKit
import SwiftUI

// MARK: - text_card

struct TextCardView: View {
    var card: Card

    var body: some View {
        let p = card.props
        CardShell(card: card) {
            VStack(alignment: .leading, spacing: 10) {
                if let title = p["title"]?.string, !title.isEmpty {
                    CardHeader(title, symbol: p["icon"]?.string.flatMap(SymbolName.valid))
                }
                BlockMarkdown(markdown: p["markdown"]?.string ?? "")
            }
            .cardInsets()
        }
    }
}

enum SymbolName {
    /// Accepts SF Symbol names only (ignores emoji / urls).
    static func valid(_ s: String) -> String? {
        s.allSatisfy { $0.isASCII && ($0.isLetter || $0.isNumber || $0 == ".") } ? s : nil
    }
}

/// Block-level markdown: splits lines so headings, lists and quotes look right, with inline
/// formatting via AttributedString(markdown:).
struct BlockMarkdown: View {
    var markdown: String
    /// Body font; text cards use the 17 pt body, previews that are cut short use the 15 pt secondary.
    var font: Font = .orbitBody

    var body: some View {
        VStack(alignment: .leading, spacing: Space.s) {
            ForEach(Array(blocks.enumerated()), id: \.offset) { _, b in
                block(b)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private enum Block { case heading(Int, String), bullet(String), numbered(String, String), quote(String), code(String), para(String) }

    private var blocks: [Block] {
        var out: [Block] = []
        var inCode = false
        var code: [String] = []
        for raw in markdown.components(separatedBy: "\n") {
            let line = raw.trimmingCharacters(in: .whitespaces)
            if line.hasPrefix("```") {
                if inCode { out.append(.code(code.joined(separator: "\n"))); code = [] }
                inCode.toggle()
                continue
            }
            if inCode { code.append(raw); continue }
            if line.isEmpty { continue }
            if let m = line.firstMatch(of: /^(#{1,4})\s+(.*)$/) {
                out.append(.heading(m.1.count, String(m.2)))
            } else if let m = line.firstMatch(of: /^[-*•]\s+(.*)$/) {
                out.append(.bullet(String(m.1)))
            } else if let m = line.firstMatch(of: /^(\d+)[.)]\s+(.*)$/) {
                out.append(.numbered(String(m.1), String(m.2)))
            } else if line.hasPrefix(">") {
                out.append(.quote(String(line.dropFirst()).trimmingCharacters(in: .whitespaces)))
            } else {
                out.append(.para(line))
            }
        }
        if inCode, !code.isEmpty { out.append(.code(code.joined(separator: "\n"))) }
        return out
    }

    private func inline(_ s: String) -> Text {
        Text((try? AttributedString(markdown: s, options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace))) ?? AttributedString(s))
    }

    @ViewBuilder private func block(_ b: Block) -> some View {
        switch b {
        case .heading(let level, let s):
            inline(s)
                .font(level <= 2 ? .orbitCardTitle : .orbitSecondary.weight(.semibold))
                .foregroundStyle(Color.ink)
                .padding(.top, Space.xs)
                .accessibilityAddTraits(.isHeader)
        case .bullet(let s):
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text("•").font(font.weight(.bold)).foregroundStyle(Color.inkSecondary)
                inline(s).font(font).foregroundStyle(Color.ink).lineSpacing(3)
            }
        case .numbered(let n, let s):
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                Text("\(n).").font(font).monospacedDigit().foregroundStyle(Color.inkSecondary)
                inline(s).font(font).foregroundStyle(Color.ink).lineSpacing(3)
            }
        case .quote(let s):
            HStack(spacing: 8) {
                Capsule().fill(Color.hairline).frame(width: 3)
                inline(s).font(font).foregroundStyle(Color.inkSecondary).lineSpacing(3)
            }
        case .code(let s):
            ScrollView(.horizontal, showsIndicators: false) {
                Text(s).font(.footnote.monospaced()).foregroundStyle(Color.ink).padding(Space.m)
            }
            .overlay { RoundedRectangle(cornerRadius: Radius.control, style: .continuous).strokeBorder(Color.hairline, lineWidth: 0.5) }
        case .para(let s):
            inline(s).font(font).foregroundStyle(Color.ink).lineSpacing(3)
        }
    }
}

// MARK: - link_preview

struct LinkPreviewView: View {
    var card: Card
    @Environment(\.openURL) private var openURL

    var body: some View {
        let p = card.props
        let url = p["url"]?.string.flatMap(URL.init(string:))
        let site = p["siteName"]?.string.flatMap { $0.isEmpty ? nil : $0 } ?? url?.host() ?? ""
        CardShell(card: card) {
            Button {
                if let url { openURL(url) }
            } label: {
                VStack(alignment: .leading, spacing: 0) {
                    if let image = p["imageUrl"]?.pictureString {
                        CardImage(source: image, ratio: 1.91)
                    }
                    VStack(alignment: .leading, spacing: 6) {
                        HStack(spacing: 6) {
                            Image(systemName: "globe").font(.system(.caption, weight: .medium))
                            Text(site).font(.system(.footnote, weight: .medium)).lineLimit(1)
                            Spacer(minLength: Space.s)
                            Image(systemName: "arrow.up.right").font(.system(.caption, weight: .semibold))
                        }
                        .foregroundStyle(Color.inkSecondary)
                        Text(p["title"]?.string ?? "")
                            .font(.orbitCardTitle)
                            .foregroundStyle(Color.ink)
                            .lineLimit(2)
                        if let description = p["description"]?.string, !description.isEmpty {
                            Text(description)
                                .font(.orbitSecondary)
                                .foregroundStyle(Color.inkSecondary)
                                .lineLimit(3)
                        }
                    }
                    .multilineTextAlignment(.leading)
                    .cardInsets()
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .contentShape(.rect)
            }
            .buttonStyle(CardContentPressStyle())
            .accessibilityHint("在浏览器中打开")
        }
    }
}

/// Press feedback for the tappable body of a card: the content dims while the finger is down.
struct CardContentPressStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label.opacity(configuration.isPressed ? 0.72 : 1)
    }
}

// MARK: - table

struct TableCardView: View {
    var card: Card

    /// Width of the scroll view, so a narrow table still fills the card while a wide one scrolls inside it.
    @State private var viewport: CGFloat = 0

    var body: some View {
        let p = card.props
        let cols = p["columns"]?.items ?? []
        let rows = p["rows"]?.items ?? []
        CardShell(card: card) {
            VStack(alignment: .leading, spacing: 0) {
                if let title = p["title"]?.string, !title.isEmpty {
                    CardHeader(title).cardHeaderInsets()
                }
                ScrollView(.horizontal) {
                    grid(cols, rows)
                        .padding(.horizontal, CardMetrics.side)
                        .padding(.bottom, p["footnote"]?.string == nil ? CardMetrics.bodyBottom : Space.s)
                        .padding(.top, p["title"]?.string == nil ? CardMetrics.side : 0)
                        .frame(minWidth: viewport, alignment: .leading)
                }
                .scrollIndicators(.hidden)
                .onGeometryChange(for: CGFloat.self) { $0.size.width } action: { viewport = $0 }
                if let footnote = p["footnote"]?.string, !footnote.isEmpty {
                    Text(footnote)
                        .font(.orbitMeta)
                        .foregroundStyle(Color.inkSecondary)
                        .cardBodyInsets()
                }
            }
        }
    }

    private func grid(_ cols: [JSONValue], _ rows: [JSONValue]) -> some View {
        Grid(alignment: .leading, horizontalSpacing: Space.xl, verticalSpacing: 0) {
            GridRow {
                ForEach(Array(cols.enumerated()), id: \.offset) { _, c in
                    Text(c["label"]?.string ?? "")
                        .font(.system(.footnote, weight: .semibold))
                        .foregroundStyle(Color.inkSecondary)
                        .padding(.bottom, Space.s)
                        .gridColumnAlignment(alignment(c))
                }
            }
            ForEach(Array(rows.enumerated()), id: \.offset) { _, r in
                Rectangle().fill(Color.hairline).frame(height: 0.5)
                GridRow {
                    ForEach(Array(cols.enumerated()), id: \.offset) { _, c in
                        let v = r[c["key"]?.string ?? ""] ?? .null
                        Text(v.displayString)
                            .font(.orbitSecondary)
                            .monospacedDigit()
                            .foregroundStyle(Color.ink)
                            .contentTransition(.numericText())
                            .padding(.vertical, 10)
                    }
                }
            }
        }
    }

    private func alignment(_ c: JSONValue) -> HorizontalAlignment {
        switch c["align"]?.string {
        case "right": .trailing
        case "center": .center
        default: .leading
        }
    }
}

// MARK: - document

struct DocumentCardView: View {
    var card: Card
    @Environment(\.openURL) private var openURL
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    @State private var expanded = false
    /// Natural height of the whole text, measured off the clipped copy.
    @State private var fullHeight: CGFloat = 0
    private let collapsedHeight: CGFloat = 132

    var body: some View {
        let p = card.props
        let motion = MotionAware(reduce: reduceMotion)
        let collapsible = fullHeight > collapsedHeight + 12
        let showsAll = expanded || !collapsible
        CardShell(card: card) {
            VStack(alignment: .leading, spacing: 10) {
                if let title = p["title"]?.string, !title.isEmpty {
                    CardHeader(title, symbol: "doc.text")
                }
                BlockMarkdown(markdown: p["markdown"]?.string ?? "", font: .orbitSecondary)
                    .fixedSize(horizontal: false, vertical: true)
                    .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { fullHeight = $0 }
                    .frame(height: fullHeight > 0 ? (showsAll ? fullHeight : collapsedHeight) : nil, alignment: .top)
                    .clipped()
                    .mask {
                        LinearGradient(stops: [.init(color: .black, location: 0),
                                               .init(color: .black, location: 0.6),
                                               .init(color: .black.opacity(showsAll ? 1 : 0), location: 1)],
                                       startPoint: .top, endPoint: .bottom)
                    }
                if collapsible {
                    Button {
                        withAnimation(motion.spring) { expanded.toggle() }
                    } label: {
                        HStack(spacing: 4) {
                            Text(expanded ? "收起" : "展开全文")
                            Image(systemName: "chevron.down")
                                .font(.system(size: 11, weight: .bold))
                                .rotationEffect(.degrees(expanded ? 180 : 0))
                        }
                    }
                    .buttonStyle(.orbit(.plain, size: .mini))
                    .accessibilityLabel(expanded ? "收起文档" : "展开全文")
                }
                ForEach(Array((p["attachments"]?.items ?? []).enumerated()), id: \.offset) { _, a in
                    Button {
                        if let u = a["url"]?.string.flatMap(URL.init(string:)) { openURL(u) }
                    } label: {
                        HStack(spacing: Space.s) {
                            Image(systemName: "paperclip").font(.system(.footnote, weight: .semibold))
                            Text(a["name"]?.string ?? "附件")
                                .font(.system(.footnote, weight: .medium))
                                .lineLimit(1)
                            Spacer(minLength: Space.s)
                            Image(systemName: "arrow.up.right").font(.system(.caption2, weight: .semibold))
                        }
                        .foregroundStyle(Color.ink)
                        .padding(10)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .overlay { RoundedRectangle(cornerRadius: Radius.control, style: .continuous).strokeBorder(Color.hairline, lineWidth: 0.5) }
                    }
                    .buttonStyle(.pressable)
                }
            }
            .cardInsets()
        }
    }
}

// MARK: - calendar_events

struct CalendarEventsView: View {
    var card: Card

    @ScaledMetric(relativeTo: .footnote) private var timeWidth: CGFloat = 44

    private struct Event: Identifiable {
        var id: String
        var title: String
        var start: Date
        var end: Date
        var location: String?
        var color: Color
    }

    var body: some View {
        let p = card.props
        let events = (p["events"]?.items ?? []).enumerated().map { i, e in
            Event(id: e["id"]?.string ?? "\(i)", title: e["title"]?.string ?? "",
                  start: Clock.date(ms: e["start"]?.int64 ?? 0), end: Clock.date(ms: e["end"]?.int64 ?? 0),
                  location: e["location"]?.string,
                  color: e["color"]?.string.flatMap { Color(hex: $0) } ?? Color.inkTertiary)
        }.sorted { $0.start < $1.start }
        let days = Dictionary(grouping: events) { Calendar.current.startOfDay(for: $0.start) }.sorted { $0.key < $1.key }
        CardShell(card: card) {
            VStack(alignment: .leading, spacing: 12) {
                CardHeader(p["title"]?.string ?? "日程", symbol: "calendar")
                if events.isEmpty {
                    Text("没有日程")
                        .font(.orbitSecondary)
                        .foregroundStyle(Color.inkSecondary)
                }
                ForEach(days, id: \.key) { day, dayEvents in
                    VStack(alignment: .leading, spacing: 0) {
                        Text(dayLabel(day))
                            .font(.system(.footnote, weight: .semibold))
                            .foregroundStyle(Color.inkSecondary)
                            .padding(.bottom, Space.xs)
                        ForEach(Array(dayEvents.enumerated()), id: \.element.id) { index, event in
                            if index > 0 { HairlineRule() }
                            row(event)
                        }
                    }
                }
            }
            .cardInsets()
        }
    }

    private func row(_ e: Event) -> some View {
        HStack(alignment: .top, spacing: 10) {
            VStack(alignment: .trailing, spacing: 2) {
                Text(CardFormat.time(e.start))
                    .font(.system(.footnote, weight: .semibold))
                    .monospacedDigit()
                    .foregroundStyle(Color.ink)
                Text(CardFormat.time(e.end))
                    .font(.system(.caption2))
                    .monospacedDigit()
                    .foregroundStyle(Color.inkSecondary)
            }
            .frame(minWidth: timeWidth, alignment: .trailing)
            Capsule().fill(e.color).frame(width: 3)
            VStack(alignment: .leading, spacing: 2) {
                Text(e.title)
                    .font(.orbitSecondary.weight(.medium))
                    .foregroundStyle(Color.ink)
                if let l = e.location, !l.isEmpty {
                    Label(l, systemImage: "mappin")
                        .font(.orbitMeta)
                        .foregroundStyle(Color.inkSecondary)
                }
            }
            Spacer(minLength: 0)
        }
        .padding(.vertical, 10)
        .accessibilityElement(children: .combine)
    }

    private func dayLabel(_ d: Date) -> String {
        if Calendar.current.isDateInToday(d) { return "今天" }
        if Calendar.current.isDateInTomorrow(d) { return "明天" }
        return CardFormat.day(d)
    }
}

// MARK: - video

struct VideoCardView: View {
    var card: Card
    @State private var player: AVPlayer?

    var body: some View {
        let p = card.props
        CardShell(card: card) {
            VStack(alignment: .leading, spacing: 10) {
                if let title = p["title"]?.string, !title.isEmpty {
                    CardHeader(title)
                }
                ZStack {
                    if let player {
                        VideoPlayer(player: player)
                    } else {
                        if let poster = p["posterUrl"]?.pictureString {
                            CardImage(source: poster, ratio: 16.0 / 9.0)
                        } else {
                            Color.black
                        }
                        Button {
                            guard let u = p["url"]?.string.flatMap(URL.init(string:)) else { return }
                            let item = AVPlayer(url: u)
                            player = item
                            item.play()
                        } label: {
                            Image(systemName: "play.fill")
                                .font(.title2)
                                .foregroundStyle(.white)
                                .frame(width: 60, height: 60)
                                .background(.black.opacity(0.5), in: .circle)
                                .overlay { Circle().strokeBorder(.white.opacity(0.4), lineWidth: 1) }
                        }
                        .buttonStyle(.pressable)
                        .accessibilityLabel("播放视频")
                    }
                }
                .aspectRatio(16.0 / 9.0, contentMode: .fit)
                .clipShape(.rect(cornerRadius: Radius.note, style: .continuous))
            }
            .cardInsets()
        }
        .onDisappear { player?.pause() }
    }
}

// MARK: - image_gallery

struct ImageGalleryView: View {
    var card: Card
    @State private var page: Int? = 0

    var body: some View {
        let p = card.props
        let images = p["images"]?.items ?? []
        CardShell(card: card) {
            VStack(alignment: .leading, spacing: 10) {
                if let title = p["title"]?.string, !title.isEmpty {
                    CardHeader(title)
                }
                ScrollView(.horizontal) {
                    LazyHStack(spacing: Space.s) {
                        ForEach(Array(images.enumerated()), id: \.offset) { i, img in
                            ZStack(alignment: .bottomLeading) {
                                CardImage(source: img["url"]?.pictureString, ratio: 4.0 / 3.0, caption: img["caption"]?.string)
                                if let c = img["caption"]?.string, !c.isEmpty {
                                    Text(c)
                                        .font(.system(.caption, weight: .medium))
                                        .foregroundStyle(.white)
                                        .padding(.horizontal, 10)
                                        .padding(.vertical, 6)
                                        .background(.ultraThinMaterial.opacity(0.9), in: .rect(cornerRadius: Radius.small, style: .continuous))
                                        .environment(\.colorScheme, .dark)
                                        .padding(10)
                                }
                            }
                            .containerRelativeFrame(.horizontal)
                            .clipShape(.rect(cornerRadius: Radius.note, style: .continuous))
                            .id(i)
                            .accessibilityElement(children: .ignore)
                            .accessibilityLabel(img["caption"]?.string ?? "图片 \(i + 1) / \(images.count)")
                        }
                    }
                    .scrollTargetLayout()
                }
                .scrollIndicators(.hidden)
                .scrollTargetBehavior(.viewAligned)
                .scrollPosition(id: $page)
                if images.count > 1 {
                    HStack(spacing: 6) {
                        ForEach(0..<images.count, id: \.self) { i in
                            Circle()
                                .fill(i == (page ?? 0) ? Color.inkSecondary : Color.inkTertiary.opacity(0.35))
                                .frame(width: 6, height: 6)
                        }
                    }
                    .frame(maxWidth: .infinity)
                    .animation(Motion.snappy, value: page)
                    .accessibilityHidden(true)
                }
            }
            .cardInsets()
        }
    }
}

// MARK: - map_place

struct MapPlaceView: View {
    var card: Card
    @Environment(\.openURL) private var openURL

    /// Opens the place in Apple Maps.
    private func openMaps() {
        let p = card.props
        let lat = p["lat"]?.double ?? 0
        let lon = p["lon"]?.double ?? 0
        let q = (p["name"]?.string ?? "").addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? ""
        if let u = URL(string: "https://maps.apple.com/?ll=\(lat),\(lon)&q=\(q)") { openURL(u) }
    }

    var body: some View {
        let p = card.props
        let lat = p["lat"]?.double ?? 0
        let lon = p["lon"]?.double ?? 0
        let coord = CLLocationCoordinate2D(latitude: lat, longitude: lon)
        let name = p["name"]?.string ?? ""
        CardShell(card: card) {
            VStack(alignment: .leading, spacing: 0) {
                // A still map: a pannable one would swallow the drag that scrolls the chat. Tapping it opens Apple Maps.
                Button {
                    openMaps()
                } label: {
                    Map(initialPosition: .region(MKCoordinateRegion(center: coord, latitudinalMeters: 900, longitudinalMeters: 900)),
                        interactionModes: []) {
                        Marker(name, coordinate: coord).tint(Color.primaryFill)
                    }
                    .allowsHitTesting(false)
                    .frame(height: 150)
                    .contentShape(.rect)
                }
                .buttonStyle(CardContentPressStyle())
                .accessibilityLabel("在地图中打开 \(name)")

                VStack(alignment: .leading, spacing: 10) {
                    HStack(alignment: .top, spacing: 12) {
                        VStack(alignment: .leading, spacing: 4) {
                            Text(name)
                                .font(.orbitCardTitle)
                                .foregroundStyle(Color.ink)
                                .fixedSize(horizontal: false, vertical: true)
                            if let address = p["address"]?.string, !address.isEmpty {
                                Text(address).font(.orbitSecondary).foregroundStyle(Color.inkSecondary)
                            }
                            HStack(spacing: 12) {
                                if let rating = p["rating"]?.double {
                                    Label(String(format: "%.1f", rating), systemImage: "star.fill")
                                        .font(.system(.footnote, weight: .semibold))
                                        .foregroundStyle(Color.warning)
                                }
                                if let phone = p["phone"]?.string, let u = URL(string: "tel:" + phone.filter { $0.isNumber || $0 == "+" }) {
                                    Button { openURL(u) } label: {
                                        Label(phone, systemImage: "phone").font(.system(.footnote, weight: .medium))
                                    }
                                    .buttonStyle(.orbit(.plain, size: .mini))
                                }
                            }
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                        Button {
                            openMaps()
                        } label: {
                            Label("路线", systemImage: "arrow.triangle.turn.up.right.diamond.fill")
                        }
                        .buttonStyle(.orbit(.primary, size: .small))
                        .accessibilityLabel("在地图中打开")
                    }
                    if let u = p["url"]?.string.flatMap(URL.init(string:)) {
                        Link(destination: u) {
                            Label("查看详情", systemImage: "safari").font(.system(.footnote, weight: .medium))
                        }
                    }
                }
                .cardInsets()
            }
        }
    }
}
