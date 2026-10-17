import PhotosUI
import SwiftUI
import UniformTypeIdentifiers

/// The floating input bar and, when "+" is tapped, the attachment tray in the keyboard's place.
///
/// Inside the bar: "+" on the left; in the middle the attachments you picked (above) and the multi-line text field
/// (up to 6 lines, then it scrolls inside); on the right ■ (stop the reply) and / or ↑ (send). While Orbit is
/// replying and the field is empty only ■ shows; with a draft both do, so you can add to the work in progress
/// without stopping it.
struct ComposerView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var focus: FocusState<Bool>.Binding
    @Binding var trayOpen: Bool
    /// Called after a message was sent (the thread scrolls to it).
    var onSend: () -> Void

    // Photos picked in the tray. The picker's selection and the draft stay in step: a photo that is deselected
    // leaves the draft, a photo removed from the bar is deselected, and sending clears both.
    @State private var photoSelection: [PhotosPickerItem] = []
    @State private var photoSlots: [PhotosPickerItem: PhotoSlot] = [:]
    @State private var photoTasks: [PhotosPickerItem: Task<Void, Never>] = [:]

    @State private var showFiles = false
    @State private var showLinkSheet = false
    @State private var showReminders = false
    @State private var showPhotoLibrary = false
    @State private var sendCount = 0
    @State private var stopCount = 0

    private enum PhotoSlot: Equatable {
        case loading
        case ready(DraftItem.ID)
    }

    // MARK: State

    private var hasContent: Bool {
        !model.draftText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || !model.draftItems.isEmpty
    }

    private var isProcessing: Bool { photoSlots.values.contains(.loading) }

    /// Something is written or attached (even if a photo is still being prepared).
    private var hasDraft: Bool { hasContent || isProcessing }

    /// Sending waits until every photo is ready.
    private var canSend: Bool { hasContent && !isProcessing }

    private var showsStop: Bool { model.isReplying }
    private var showsSend: Bool { !model.isReplying || hasDraft }

    private var attachments: [ComposerAttachment] {
        model.draftItems.map(ComposerAttachment.ready) + photoSelection.filter { photoSlots[$0] == .loading }.map(ComposerAttachment.loading)
    }

    private var placeholder: String {
        let name = model.chatBotName
        if !model.canUseHost { return "可以继续输入，连上后发送" }
        if model.isReplying { return "补充要求，或交给 \(name) 新的事…" }
        return "给 \(name) 发消息"
    }

    /// A global sheet (confirm / activity / connection) is up or about to be: local sheets must not compete with it.
    private var globalSheetRequested: Bool {
        model.presentedApprovalId != nil || model.showActivity || model.showConnection
    }

    // MARK: Body

    var body: some View {
        let motion = MotionAware(reduce: reduceMotion)
        VStack(spacing: 0) {
            bar(motion)
            if trayOpen {
                AttachmentTray(selection: $photoSelection, onAction: handle, onDismiss: closeTray)
                    .transition(reduceMotion ? .opacity : .move(edge: .bottom).combined(with: .opacity))
            }
        }
        .animation(motion.spring, value: attachments.count)
        .animation(motion.snappy, value: showsStop)
        .animation(motion.snappy, value: showsSend)
        .sensoryFeedback(.impact(weight: .light), trigger: sendCount)
        .sensoryFeedback(.impact(weight: .medium), trigger: stopCount)
        .onChange(of: focus.wrappedValue) { _, focused in
            if focused, trayOpen { withAnimation(motion.snappy) { trayOpen = false } }
        }
        .onChange(of: photoSelection) { old, new in syncPhotos(from: old, to: new) }
        .onChange(of: globalSheetRequested) { _, requested in
            if requested { yieldToGlobalSheet() }
        }
        .fileImporter(isPresented: $showFiles, allowedContentTypes: [.item], allowsMultipleSelection: true) { result in
            guard case .success(let urls) = result else { return }
            addFiles(urls)
        }
        .photosPicker(isPresented: $showPhotoLibrary, selection: $photoSelection, maxSelectionCount: AttachmentTray.maxPhotos, matching: .images)
        .sheet(isPresented: $showLinkSheet) {
            LinkTextSheet { model.addToDraft($0) }
                .presentationDetents([.height(320), .medium])
                .presentationDragIndicator(.visible)
                .presentationBackground(Color.canvas)
        }
        .sheet(isPresented: $showReminders) {
            ReminderPickerSheet { model.addToDraft($0) }
                .presentationDetents([.medium, .large])
                .presentationDragIndicator(.visible)
                .presentationBackground(Color.canvas)
        }
        .dropDestination(for: DroppedItem.self) { items, _ in
            handleDrop(items)
            return !items.isEmpty
        }
        #if DEBUG
        .task { await debugPickPhotos() }
        #endif
    }

    #if DEBUG
    /// `-OPAChatPickPhotos N`: shows N photos as "still being prepared" (spinner thumbnails, send disabled) without
    /// loading anything, so the processing state can be looked at; the simulator cannot be tapped from a script.
    private func debugPickPhotos() async {
        // `-OPAChatSheet link|reminders`: opens one of the local sheets right away (to check that a global sheet wins).
        if let which = UserDefaults.standard.string(forKey: "OPAChatSheet") {
            try? await Task.sleep(for: .milliseconds(400))
            if which == "link" { showLinkSheet = true } else if which == "reminders" { showReminders = true }
        }
        guard let raw = UserDefaults.standard.string(forKey: "OPAChatPickPhotos"), let count = Int(raw), count > 0 else { return }
        try? await Task.sleep(for: .seconds(2))
        let items = (0..<count).map { PhotosPickerItem(itemIdentifier: "debug-\($0)") }
        for item in items { photoSlots[item] = .loading }
        photoSelection = items
    }
    #endif

    // MARK: Bar

    /// One 48 pt row on a Surface with a 0.5 pt Hairline, 12 pt corners and no shadow: "+" at the left (InkSecondary),
    /// the text between, and at the right the send arrow (InkTertiary while there is nothing to send, Ink once there is)
    /// and, while Orbit replies, ■ to stop it. Longer text grows the bar; the buttons stay at the bottom.
    private func bar(_ motion: MotionAware) -> some View {
        @Bindable var model = model
        let shape = RoundedRectangle(cornerRadius: Radius.input, style: .continuous)
        return HStack(alignment: .bottom, spacing: 0) {
            plusButton
            VStack(alignment: .leading, spacing: 0) {
                if !attachments.isEmpty {
                    ComposerAttachmentRow(attachments: attachments, onRemove: remove)
                        .padding(.top, Space.s)
                        .transition(.opacity)
                }
                TextField("", text: $model.draftText,
                          prompt: Text(placeholder).foregroundStyle(Color.inkTertiary), axis: .vertical)
                    .font(.orbitBody)
                    .foregroundStyle(Color.ink)
                    .tint(Color.accentText)
                    .lineLimit(1...6)
                    .focused(focus)
                    .padding(.leading, 4)
                    .padding(.vertical, 13)
                    .accessibilityLabel("给 \(model.chatBotName) 发消息")
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .contentShape(.rect)
            .onTapGesture { focus.wrappedValue = true }
            HStack(spacing: 0) {
                if showsStop {
                    iconButton("stop.circle.fill", size: 24, tint: .ink, label: "停止回复") {
                        stopCount += 1
                        model.stopReply()
                    }
                    .transition(buttonTransition)
                }
                if showsSend {
                    iconButton("arrow.up", size: 19, tint: canSend ? .ink : .inkTertiary, label: "发送", enabled: canSend, action: send)
                        .transition(buttonTransition)
                }
            }
        }
        .frame(minHeight: 48)
        .background(Color.surface, in: shape)
        .overlay { shape.strokeBorder(Color.hairline, lineWidth: 0.5) }
        .padding(.horizontal, Space.l)
        .padding(.top, Space.s)
        .padding(.bottom, trayOpen ? Space.m : 10)
    }

    /// "+": InkSecondary, no fill; a 44 × 48 touch target.
    private var plusButton: some View {
        Button {
            toggleTray()
        } label: {
            // The "+" stays while the tray is open: tapping it again puts the tray away.
            Image(systemName: "plus")
                .font(.system(size: 20, weight: .regular))
                .foregroundStyle(Color.inkSecondary)
                .frame(width: 44, height: 48)
                .contentShape(.rect)
        }
        .buttonStyle(.pressable)
        .accessibilityLabel(trayOpen ? "收起附件菜单" : "添加附件")
    }

    /// A bare icon in a 44 × 48 touch target (the bar is 48 pt tall).
    private func iconButton(_ symbol: String, size: CGFloat, tint: Color, label: String, enabled: Bool = true,
                            action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: size, weight: .semibold))
                .foregroundStyle(tint)
                .frame(width: 44, height: 48)
                .contentShape(.rect)
        }
        .buttonStyle(.pressable)
        .disabled(!enabled)
        .accessibilityLabel(label)
    }

    private var buttonTransition: AnyTransition {
        reduceMotion ? .opacity : .scale(scale: 0.6).combined(with: .opacity)
    }

    // MARK: Actions

    private func toggleTray() {
        let motion = MotionAware(reduce: reduceMotion)
        withAnimation(motion.spring) { trayOpen.toggle() }
        if trayOpen { focus.wrappedValue = false }
    }

    private func closeTray() {
        withAnimation(MotionAware(reduce: reduceMotion).spring) { trayOpen = false }
    }

    private func handle(_ action: AttachmentTray.Action) {
        // One sheet at a time: while a global sheet is up (or about to be) nothing local is presented.
        guard !globalSheetRequested else { return }
        switch action {
        case .photoLibrary:
            showPhotoLibrary = true
        case .files:
            closeTray()
            showFiles = true
        case .link:
            closeTray()
            showLinkSheet = true
        case .reminders:
            closeTray()
            showReminders = true
        }
    }

    /// A global sheet (confirm / activity / connection) was requested while one of our own sheets or pickers is on
    /// screen. SwiftUI cannot present the root's sheet over ours and then believes it is already presenting, so it
    /// would never show it. So the request is withdrawn at once (the root resets), ours are closed, and the same
    /// request is made again once their dismissal animation is over.
    private func yieldToGlobalSheet() {
        guard showFiles || showLinkSheet || showReminders || showPhotoLibrary else { return }
        let approvalId = model.presentedApprovalId
        let activity = model.showActivity
        let connection = model.showConnection
        model.presentedApprovalId = nil
        model.showActivity = false
        model.showConnection = false
        showFiles = false
        showLinkSheet = false
        showReminders = false
        showPhotoLibrary = false
        Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(800))
            // Anything requested in the meantime wins.
            guard !globalSheetRequested else { return }
            if let approvalId { model.openApproval(approvalId) }
            else if activity { model.showActivity = true }
            else if connection { model.showConnection = true }
        }
    }

    private func send() {
        guard canSend else { return }
        model.sendDraft(text: model.draftText)
        model.draftText = ""
        photoSelection = []
        sendCount += 1
        if trayOpen { closeTray() }
        onSend()
    }

    private func remove(_ attachment: ComposerAttachment) {
        switch attachment {
        case .loading(let item):
            photoSelection.removeAll { $0 == item }
        case .ready(let draft):
            model.removeDraft(draft.id)
            if let item = photoSlots.first(where: { $0.value == .ready(draft.id) })?.key {
                photoSelection.removeAll { $0 == item }   // also takes the checkmark off in the picker
            }
        }
    }

    // MARK: Photos

    private func syncPhotos(from old: [PhotosPickerItem], to new: [PhotosPickerItem]) {
        for item in old where !new.contains(item) {
            photoTasks[item]?.cancel()
            photoTasks[item] = nil
            if case .ready(let id)? = photoSlots[item] { model.removeDraft(id) }
            photoSlots[item] = nil
        }
        for item in new where photoSlots[item] == nil {
            photoSlots[item] = .loading
            photoTasks[item] = Task { await loadPhoto(item) }
        }
    }

    /// Loads the picked photo and shrinks it (≤ 2048 px JPEG) off the main thread, then puts it in the draft.
    private func loadPhoto(_ item: PhotosPickerItem) async {
        let data = try? await item.loadTransferable(type: Data.self)
        guard !Task.isCancelled, photoSlots[item] == .loading else { return }
        var draft: DraftItem?
        if let data { draft = await Task.detached(priority: .userInitiated) { DraftItem.image(from: data) }.value }
        guard !Task.isCancelled, photoSlots[item] == .loading else { return }
        guard let draft else {
            photoSlots[item] = nil
            photoSelection.removeAll { $0 == item }
            model.showToast("无法读取这张照片")
            return
        }
        photoSlots[item] = .ready(draft.id)
        model.addToDraft([draft])
    }

    // MARK: Files and drops

    private func addFiles(_ urls: [URL]) {
        var out: [DraftItem] = []
        for url in urls {
            switch DraftItem.file(at: url) {
            case .success(let draft): out.append(draft)
            case .failure(let error): model.showToast(error.localizedDescription)
            }
        }
        model.addToDraft(out)
    }

    private func handleDrop(_ items: [DroppedItem]) {
        var out: [DraftItem] = []
        var files: [URL] = []
        for item in items {
            switch item {
            case .image(let data): if let draft = DraftItem.image(from: data) { out.append(draft) }
            case .url(let url): if url.isFileURL { files.append(url) } else { out += DraftItem.fromPasted(url.absoluteString) }
            case .text(let text): out += DraftItem.fromPasted(text)
            case .file(let url): files.append(url)
            }
        }
        model.addToDraft(out)
        addFiles(files)
    }
}

/// Anything the user can drag into the chat.
enum DroppedItem: Transferable {
    case image(Data), url(URL), text(String), file(URL)

    static var transferRepresentation: some TransferRepresentation {
        DataRepresentation(importedContentType: .image) { DroppedItem.image($0) }
        ProxyRepresentation { (url: URL) in DroppedItem.url(url) }
        ProxyRepresentation { (text: String) in DroppedItem.text(text) }
        FileRepresentation(importedContentType: .data) { received in
            let dest = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString + "-" + received.file.lastPathComponent)
            try FileManager.default.copyItem(at: received.file, to: dest)
            return DroppedItem.file(dest)
        }
    }
}
