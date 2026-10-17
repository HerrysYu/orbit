import SwiftUI

/// Renders one `Card` at full width. Every component draws its own `OrbitCard`, so images, footers and the card's
/// action row (`Card.actions`) sit inside the card instead of floating under it.
struct CardHost: View {
    var card: Card

    var body: some View {
        CardBody(card: card)
            .equatable()
            .frame(maxWidth: .infinity, alignment: .leading)
    }
}

/// Dispatches a card to its component view (protocol section 5). Unknown components fall back to a plain note with
/// their data kept under a collapsed "技术详情".
struct CardBody: View, Equatable {
    let card: Card

    nonisolated static func == (a: CardBody, b: CardBody) -> Bool { a.card == b.card }

    var body: some View {
        switch card.component {
        case "text_card": TextCardView(card: card)
        case "link_preview": LinkPreviewView(card: card)
        case "table": TableCardView(card: card)
        case "document": DocumentCardView(card: card)
        case "calendar_events": CalendarEventsView(card: card)
        case "video": VideoCardView(card: card)
        case "image_gallery": ImageGalleryView(card: card)
        case "map_place": MapPlaceView(card: card)
        case "choice_list": ChoiceListView(card: card)
        case "form": FormCardView(card: card)
        case "order_card": OrderCardView(card: card)
        case "ticket_card": TicketCardView(card: card)
        case "booking_card": BookingCardView(card: card)
        case "task_progress": TaskProgressCard(taskId: card.props["taskId"]?.string ?? "")
        case "approval_card": ApprovalCardView(approvalId: card.props["approvalId"]?.string ?? "")
        case "comparison": ComparisonView(card: card)
        case "memory_saved": MemorySavedView(card: card)
        default: UnknownCardView(card: card)
        }
    }
}

// MARK: - Action bar

/// The card's buttons (`Card.actions`). A button that `requiresApproval` asks for Face ID before anything is sent;
/// while one is in flight (Face ID prompt included) all of them are disabled, so a double tap cannot send twice.
/// A button the host accepted shows a check and stays done, even after the card scrolled away and came back.
/// Roles: primary = the filled button, secondary = Surface + hairline, destructive = Danger text.
struct CardActionBar: View {
    @Environment(AppModel.self) private var model
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    var card: Card
    var actions: [CardAction]

    @State private var busy: String?
    @State private var successTick = 0
    @State private var failureTick = 0

    private var store: CardInteractionStore { .shared }

    var body: some View {
        CardButtonRow {
            ForEach(actions) { action in
                button(action)
            }
        }
        .submitFeedback(success: successTick, failure: failureTick)
    }

    private func button(_ action: CardAction) -> some View {
        let done = store.isDone(action.id, card: card)
        let kind = Self.kind(action.style ?? .secondary)
        let isBusy = busy == action.id
        return Button {
            Task { await run(action) }
        } label: {
            HStack(spacing: 6) {
                if isBusy {
                    ProgressView().controlSize(.small).tint(kind == .primary ? Color.onPrimary : Color.inkSecondary)
                } else if done {
                    Image(systemName: "checkmark")
                } else if action.requiresApproval == true {
                    Image(systemName: "faceid")
                }
                Text(action.label)
            }
            .cardButtonWidth(expands: kind == .primary)
        }
        .buttonStyle(.orbit(kind, size: .small))
        .disabled(busy != nil || done)
        .accessibilityHint(action.requiresApproval == true ? "需要面容 ID 验证" : "")
    }

    private static func kind(_ style: CardAction.Style) -> OrbitButtonKind {
        switch style {
        case .primary: .primary
        case .destructive: .destructive
        case .secondary: .secondary
        }
    }

    private func run(_ action: CardAction) async {
        guard busy == nil else { return }
        busy = action.id
        defer { busy = nil }
        if action.requiresApproval == true {
            guard await Biometrics.authenticate(reason: "确认操作：\(action.label)") else { return }
        }
        let accepted = await model.sendAction(cardId: card.id, actionId: action.id)
        if accepted {
            withAnimation(MotionAware(reduce: reduceMotion).snappy) { store.markDone(action.id, card: card) }
            successTick += 1
        } else {
            failureTick += 1
        }
    }
}

// MARK: - Unknown component

/// Any component this app version does not know. The owner sees a plain note; the card's data (the component name and a
/// summary of its props, protocol section 5) is kept, collapsed under "技术详情".
struct UnknownCardView: View {
    var card: Card

    var body: some View {
        CardShell(card: card) {
            VStack(alignment: .leading, spacing: 10) {
                Label("这张卡片暂时无法显示", systemImage: "square.dashed")
                    .font(.orbitChip)
                    .foregroundStyle(Color.inkSecondary)
                Text("更新 Orbit 之后就能看到它。")
                    .font(.orbitSecondary)
                    .foregroundStyle(Color.inkSecondary)
                TechnicalDetails(text: technical)
            }
            .cardInsets()
        }
    }

    /// The component name, then one `key: value` line per prop.
    private var technical: String {
        "component: \(card.component)\n" + summary
    }

    private var summary: String {
        if case .object(let o) = card.props {
            return o.keys.sorted().map { "\($0): \(o[$0]?.displayString ?? "")" }.joined(separator: "\n")
        }
        return card.props.compactJSON
    }
}
