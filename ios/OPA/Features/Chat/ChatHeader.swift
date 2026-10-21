import SwiftUI

/// The shared id of the character that flies from the empty-state stage into the header avatar.
enum ChatHero {
    static let id = "orbit.hero"
}

/// Ties the stage character and the header avatar together so one flies into the other. Under Reduce Motion there is
/// no flight: the two simply cross-fade (the view transitions are opacity only).
struct HeroMatch: ViewModifier {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    var namespace: Namespace.ID

    @ViewBuilder
    func body(content: Content) -> some View {
        if reduceMotion {
            content
        } else {
            content.matchedGeometryEffect(id: ChatHero.id, in: namespace)
        }
    }
}

// MARK: - Presence header

/// Top of the chat, over the messages, aligned to the left: Orbit's 3D avatar (36 pt, no ring), its name (17 semibold) and
/// one live status line (a 6 pt dot and 13 pt text) beside it; the Mac connection control at the right. Tapping the
/// avatar block opens "活动与权限". Its background fades from Canvas to clear so messages scroll away under it.
///
/// While the empty-state stage shows the big character (`showsPresence == false`) only the connection control is
/// drawn; when the stage goes away the character shrinks into the avatar slot (matched geometry).
struct ChatHeader: View {
    @Environment(AppModel.self) private var model
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var showsPresence: Bool
    var hero: Namespace.ID
    var onClearChat: () -> Void

    /// Height of the fade below the content.
    private static let fadeHeight: CGFloat = 24
    /// Avatar 36 beside name 22 + status 18 (scales with the text size); the same with or without the avatar block, so
    /// nothing below shifts when the character flies in.
    @ScaledMetric(relativeTo: .body) private var presenceHeight: CGFloat = 48

    var body: some View {
        let connection = model.connection
        let motion = MotionAware(reduce: reduceMotion)
        HStack(alignment: .center, spacing: Space.s) {
            if showsPresence {
                PresenceButton(hero: hero, reduceMotion: reduceMotion)
                    .layoutPriority(1)
            }
            Spacer(minLength: 0)
            if model.isDemo { DemoTag() }
            ConnectionIndicator(state: connection) { model.showConnection = true }
            Menu {
                Button(role: .destructive, action: onClearChat) {
                    Label("清除聊天记录", systemImage: "trash")
                }
                .disabled(model.isClearingChat)
            } label: {
                Image(systemName: "ellipsis")
                    .font(.system(size: 18, weight: .semibold))
                    .foregroundStyle(Color.inkSecondary)
                    .frame(width: 44, height: 44)
                    .contentShape(.rect)
            }
            .accessibilityLabel("更多聊天操作")
        }
        .frame(minHeight: presenceHeight, alignment: .center)
        .padding(.leading, 20)
        .padding(.trailing, Space.s)
        .padding(.top, 2)
        .padding(.bottom, Self.fadeHeight)
        .frame(maxWidth: .infinity)
        .background(alignment: .top) {
            // Solid Canvas behind the avatar and the status line, then a short fade into the thread
            // (the board's `linear-gradient(canvas 72%, clear)`). Not on the empty-state stage: there the
            // warm glow runs behind the whole screen.
            if showsPresence {
                VStack(spacing: 0) {
                    Color.canvas
                    LinearGradient(colors: [.canvas, Color.canvas.opacity(0)], startPoint: .top, endPoint: .bottom)
                        .frame(height: Self.fadeHeight)
                }
                .ignoresSafeArea(edges: .top)
                .transition(.opacity)
            }
        }
        .animation(motion.fly, value: showsPresence)
        .animation(motion.snappy, value: connection.isConnected)
    }
}

/// Avatar, name and status line. One button: opens "活动与权限".
private struct PresenceButton: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dynamicTypeSize) private var typeSize
    var hero: Namespace.ID
    var reduceMotion: Bool

    var body: some View {
        let presence = model.presence
        let motion = MotionAware(reduce: reduceMotion)
        Button {
            model.showActivity = true
        } label: {
            HStack(spacing: 10) {
                ChatAvatar(size: 36)
                    .modifier(HeroMatch(namespace: hero))
                VStack(alignment: .leading, spacing: 0) {
                    Text(model.chatBotName)
                        .font(.system(.body, weight: .semibold))
                        .foregroundStyle(Color.ink)
                        .lineLimit(1)
                    DotLabel(color: presence.dotColor, text: presence.text, lineLimit: typeSize.isAccessibilitySize ? 3 : 1)
                }
            }
            .frame(minHeight: 44, alignment: .leading)
            .contentShape(.rect)
        }
        .buttonStyle(.pressable)
        .animation(motion.snappy, value: presence)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(model.chatBotName)，\(presence.text)")
        .accessibilityHint("查看活动与权限")
    }
}

/// "演示" marker beside the connection control while the app runs on the built-in demo data: a small dot and 13 pt
/// secondary text, no background.
private struct DemoTag: View {
    var body: some View {
        HStack(spacing: 6) {
            Circle().fill(Color.inkTertiary).frame(width: 6, height: 6)
            Text("演示")
                .font(.system(.footnote, weight: .medium))
                .foregroundStyle(Color.inkSecondary)
        }
        .frame(minHeight: 26)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("演示模式")
    }
}
