import SwiftUI

/// The chat tab: one long conversation with Orbit.
///
/// Top: the presence header (avatar, name, live status at the left; the Mac connection at the right). Middle: the
/// thread, or the empty-state stage (with "最近") before the first message. Bottom: the composer (and the attachment
/// tray in the keyboard's place). The
/// global sheets ("活动与权限", "连接详情") are mounted by the root view; this view only flips `model.showActivity` /
/// `model.showConnection`.
struct ChatView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Namespace private var hero
    @FocusState private var composerFocused: Bool
    @State private var trayOpen = false
    @State private var scrollPosition = ScrollPosition()
    @State private var confirmClearChat = false
    /// Whether the thread is scrolled to its end. New content only moves the view when it was.
    @State private var atBottom = true
    @State private var hasNewReply = false
    #if DEBUG
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
    @State private var debugEnv = ""
    #endif

    var body: some View {
        let motion = MotionAware(reduce: reduceMotion)
        let timeline = model.timeline
        // Replies with nothing to read are not shown, so a thread made of nothing else is still the empty one.
        let isBlank = !timeline.contains(where: ChatRows.isVisible)
        let showsStage = isBlank && !composerFocused && !trayOpen
        ZStack(alignment: .bottom) {
            if isBlank {
                if showsStage {
                    ChatStage(hero: hero)
                        .transition(.opacity)
                }
            } else {
                thread(timeline, motion: motion)
                    .transition(.opacity)
            }
            if hasNewReply && !atBottom {
                NewReplyPill { scrollToBottom() }
                    .padding(.bottom, Space.m)
                    .transition(reduceMotion ? .opacity : .scale(scale: 0.9).combined(with: .opacity))
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color.canvas)
        .animation(motion.fly, value: showsStage)
        .animation(motion.snappy, value: hasNewReply && !atBottom)
        .safeAreaInset(edge: .top, spacing: 0) {
            ChatHeader(showsPresence: !showsStage, hero: hero) {
                guard model.canUseHost else {
                    model.showToast("请先连接 Mac，再清除聊天记录")
                    return
                }
                confirmClearChat = true
            }
        }
        .composerBar {
            ComposerView(focus: $composerFocused, trayOpen: $trayOpen) { scrollToBottom() }
                .id(model.chatGeneration)
                .disabled(model.isClearingChat)
        }
        .confirmationDialog("清除聊天记录？", isPresented: $confirmClearChat, titleVisibility: .visible) {
            Button("清除聊天记录", role: .destructive) {
                composerFocused = false
                trayOpen = false
                Task { await model.clearChatHistory() }
            }
        } message: {
            Text("这会清空当前对话和未发送消息，并重置 Orbit 的当前对话上下文。长期记忆和任务会保留。")
        }
        .onChange(of: model.chatGeneration) { _, _ in
            composerFocused = false
            trayOpen = false
            hasNewReply = false
            atBottom = true
            scrollPosition.scrollTo(edge: .bottom)
        }
        .toolbarVisibility(trayOpen ? .hidden : .automatic, for: .tabBar)
        #if DEBUG
        .task { await debugHooks() }
        .overlay(alignment: .topLeading) {
            if !debugEnv.isEmpty {
                Text(debugEnv).font(.system(size: 10, design: .monospaced)).padding(3)
                    .background(.yellow.opacity(0.85)).allowsHitTesting(false)
            }
        }
        #endif
    }

    // MARK: Thread

    private func thread(_ timeline: [TimelineItem], motion: MotionAware) -> some View {
        let rows = ChatRows.build(timeline)
        return ScrollView {
            LazyVStack(alignment: .leading, spacing: 0) {
                ForEach(rows) { row in
                    ChatRowView(row: row)
                        .equatable()
                        .id(row.id)
                        .transition(transition(for: row))
                }
                ThinkingFooter()
            }
            .padding(.horizontal, Space.l)
            .padding(.top, Space.s)
            .padding(.bottom, Space.m)
            .calmedForReduceMotion(reduceMotion)
        }
        .scrollPosition($scrollPosition)
        .defaultScrollAnchor(.bottom)
        .scrollDismissesKeyboard(.interactively)
        .onScrollGeometryChange(for: ScrollMetrics.self) { geometry in
            // `visibleRect` is the whole scroll view frame in content coordinates (insets included), so its bottom edge
            // meets the end of the content (plus the bottom inset) exactly when the thread is scrolled to its end.
            ScrollMetrics(atBottom: geometry.contentSize.height + geometry.contentInsets.bottom - geometry.visibleRect.maxY < 40,
                          bottomInset: geometry.contentInsets.bottom.rounded())
        } action: { old, new in
            if new.bottomInset != old.bottomInset {
                // The keyboard, the attachment tray or a taller composer moved the bottom edge up. SwiftUI keeps the
                // anchor for content size changes but not for inset changes, so follow it here: a reader who was at
                // the end stays at the end; one who had scrolled up is left where they are.
                if atBottom { scrollPosition.scrollTo(edge: .bottom) }
                return
            }
            let isAtBottom = new.atBottom
            if isAtBottom != atBottom { atBottom = isAtBottom }
            if isAtBottom && hasNewReply { hasNewReply = false }
        }
        .onChange(of: ThreadTick(timeline.last)) { old, new in
            guard new.id != nil, new.id != old.id || new.textLength > old.textLength else { return }
            if atBottom {
                if new.id != old.id { scrollToBottom() }
            } else if new.fromOrbit {
                hasNewReply = true
            }
        }
    }

    /// Your messages and the cards slide up as they arrive. Orbit's words appear where they are: they often take the
    /// place of the waiting row, and nothing may move when they do.
    private func transition(for row: ChatRow) -> AnyTransition {
        if case .assistant = row.item { return .asymmetric(insertion: .identity, removal: .opacity) }
        return reduceMotion ? .opacity : .asymmetric(insertion: .offset(y: 14).combined(with: .opacity), removal: .opacity)
    }

    private func scrollToBottom() {
        hasNewReply = false
        withAnimation(MotionAware(reduce: reduceMotion).spring) { scrollPosition.scrollTo(edge: .bottom) }
    }

    // MARK: Debug

    #if DEBUG
    /// Launch-argument helpers for screenshots and manual checks (none of them exist in release builds):
    /// - `-OPAChatEmpty YES`: empties the demo conversation after a second, to look at the empty state;
    /// - `-OPAChatEmptyThread YES`: the same, but the tasks stay (the empty state with its "最近" list);
    /// - `-OPAChatConnection hostOffline|failed|waitingRetry|connecting`: fakes the connection state (demo keeps
    ///   its "connected" look for the placeholder; use the next one to see the real thing);
    /// - `-OPAChatOffline YES` (+ `-OPAChatDeliveryDemo YES`): see `ChatDebug.goOffline`;
    /// - `-OPAChatGhostReplies YES`: adds the replies old data and old Mac versions left behind (empty, blank, "主动" with
    ///   nothing to say, a reply that streams only line breaks) and one real "主动" reply, after a second: only the
    ///   real one may show, with the waiting row after it;
    /// - `-OPAChatImageCards YES`: adds cards with pictures of every kind (`data:` URL, https, local path, broken),
    ///   after a second (combine with `-OPAChatEmpty YES` and `-OPAScrollTo card-img-gallery`; add
    ///   `-OPAChatImageCardsWarm YES` to decode the pictures first, so they are there in the first frame);
    /// - `-OPADraft "text"`: fills the draft; `-OPADraftItems YES`: adds sample attachments;
    /// - `-OPAChatTray YES` opens the attachment tray, `-OPAChatFocus YES` focuses the composer,
    ///   `-OPAChatPickPhotos N` shows N photos as still processing (see `ComposerView`);
    /// - `-OPAChatScrollTop YES`: scrolls to the oldest message after 3 s;
    /// - `-OPAChatShowEnv YES`: prints the Reduce Motion / Reduce Transparency flags the view sees, top left;
    /// - `-OPAScrollTo card-compare`: scrolls to a card (`c:` prefix) or any timeline id after 3 s.
    private func debugHooks() async {
        let defaults = UserDefaults.standard
        if defaults.bool(forKey: "OPAChatShowEnv") { debugEnv = "RM:\(reduceMotion) RT:\(reduceTransparency)" }
        if defaults.bool(forKey: "OPAChatEmpty") {
            try? await Task.sleep(for: .seconds(1))
            model.clearState()
        } else if defaults.bool(forKey: "OPAChatEmptyThread") {
            try? await Task.sleep(for: .seconds(1))
            model.timelineStore.removeAll()
        }
        if let raw = defaults.string(forKey: "OPAChatConnection") {
            try? await Task.sleep(for: .seconds(1))
            switch raw {
            case "hostOffline": model.connection = .hostOffline
            case "failed": model.connection = .failed("连接失败")
            case "waitingRetry": model.connection = .waitingRetry(seconds: 5, reason: "")
            case "connecting": model.connection = .connecting
            default: break
            }
        }
        if defaults.bool(forKey: "OPAChatOffline") || defaults.bool(forKey: "OPAChatDeliveryDemo") {
            try? await Task.sleep(for: .seconds(1))
            await ChatDebug.goOffline(model, withMessages: defaults.bool(forKey: "OPAChatDeliveryDemo"))
        }
        if defaults.bool(forKey: "OPAChatGhostReplies") {
            try? await Task.sleep(for: .seconds(1))
            ChatDebug.addGhostReplies(model)
        }
        if defaults.bool(forKey: "OPAChatImageCards") {
            try? await Task.sleep(for: .seconds(1))
            await ChatDebug.addImageCards(model)
        }
        if let text = defaults.string(forKey: "OPADraft") { model.draftText = text }
        if defaults.bool(forKey: "OPADraftItems") { model.addToDraft(ChatDebug.sampleDraftItems()) }
        if defaults.bool(forKey: "OPAChatTray") { trayOpen = true }
        if defaults.bool(forKey: "OPAChatFocus") { composerFocused = true }
        if defaults.bool(forKey: "OPAChatScrollTop") {
            try? await Task.sleep(for: .seconds(3))
            scrollPosition.scrollTo(edge: .top)
        }
        if let target = defaults.string(forKey: "OPAScrollTo") {
            // Wait for the demo events to settle (each new item pulls the thread to the bottom).
            try? await Task.sleep(for: .seconds(3))
            scrollPosition.scrollTo(id: target.contains(":") ? target : "c:" + target, anchor: .top)
        }
    }
    #endif

    // MARK: Scroll bookkeeping

    private struct ScrollMetrics: Equatable, Sendable {
        var atBottom: Bool
        var bottomInset: CGFloat
    }

    /// The newest item, reduced to what decides whether "something new arrived": a new id, or more text.
    private struct ThreadTick: Equatable {
        var id: String?
        var textLength = 0
        var fromOrbit = false

        init(_ item: TimelineItem?) {
            guard let item else { return }
            id = item.id
            switch item {
            case .user: break
            case .assistant(let message): textLength = message.text.utf8.count; fromOrbit = message.hasVisibleText
            case .card: fromOrbit = true
            }
        }
    }
}

/// "Orbit is on it" at the end of the thread: from the moment Orbit starts thinking or working until the first readable
/// text of its reply arrives, the waiting row (`ThinkingRow`) stands where that reply will be. The moment there is text
/// to read it is gone, and the reply's own row is in its place.
/// Its own view so that frequent status updates only re-render this row, not the whole thread.
private struct ThinkingFooter: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        if isWaiting {
            let previous = model.timeline.last(where: ChatRows.isVisible)
            // Once a minute, so the time in the byline keeps up when Orbit takes long.
            TimelineView(.everyMinute) { context in
                ChatRowView(row: ChatRows.waitingRow(after: previous, now: Clock.ms(context.date)))
            }
            .id("thinking")
            .transition(.asymmetric(insertion: .opacity, removal: .identity))
        }
    }

    /// Orbit is thinking, working or streaming, and no reply that is coming in has anything to read yet. (A reply that
    /// has a first word is on screen as an ordinary row; one that is only blank lines counts as not started.)
    private var isWaiting: Bool {
        guard model.isReplying else { return false }
        return !model.streamingIds.contains { model.assistantMessage(id: $0)?.hasVisibleText == true }
    }
}

extension View {
    /// Pins the composer to the bottom. On iOS 26 `safeAreaBar` adds the system scroll-edge blur where content passes
    /// under it; earlier systems get a plain inset.
    @ViewBuilder func composerBar(@ViewBuilder _ content: () -> some View) -> some View {
        if #available(iOS 26.0, *) {
            self.safeAreaBar(edge: .bottom, spacing: 0, content: content)
        } else {
            self.safeAreaInset(edge: .bottom, spacing: 0, content: content)
        }
    }
}

#Preview("Chat demo") {
    let model = AppModel(inMemory: true)
    model.enterDemo()
    return ChatView().environment(model)
}
