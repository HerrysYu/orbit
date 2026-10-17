import PhotosUI
import SwiftUI

// MARK: - Tray panel

/// The attachment tray: an inline panel that takes the keyboard's place when "+" is tapped. Four entries (photos,
/// files, link / text, reminders) and the system photo picker embedded below them; photos selected there appear
/// above the text field at once.
struct AttachmentTray: View {
    enum Action { case photoLibrary, files, link, reminders }

    @Binding var selection: [PhotosPickerItem]
    var onAction: (Action) -> Void
    var onDismiss: () -> Void

    /// About what the keyboard takes (the home-indicator area comes on top).
    static let contentHeight: CGFloat = 340
    static let maxPhotos = 10

    var body: some View {
        let shape = UnevenRoundedRectangle(topLeadingRadius: 28, bottomLeadingRadius: 0, bottomTrailingRadius: 0,
                                           topTrailingRadius: 28, style: .continuous)
        VStack(spacing: 0) {
            VStack(spacing: 0) {
                HStack(spacing: Space.xs) {
                    option("photo", "照片") { onAction(.photoLibrary) }
                    option("doc", "文件") { onAction(.files) }
                    option("link", "链接 / 文本") { onAction(.link) }
                    option("checklist", "提醒事项") { onAction(.reminders) }
                }
                .padding(.top, Space.l)
                HStack {
                    Text("最近照片")
                        .font(.system(.subheadline, weight: .semibold))
                        .foregroundStyle(Color.ink)
                    Spacer(minLength: Space.s)
                    Button("全部照片") { onAction(.photoLibrary) }
                        .font(.system(.subheadline, weight: .semibold))
                        .foregroundStyle(Color.accentText)
                        .buttonStyle(.plain)
                }
                .padding(.horizontal, 2)
                .padding(.top, Space.m)
                .padding(.bottom, Space.s)
            }
            .padding(.horizontal, Space.l)
            .contentShape(.rect)
            // Pulling the top part down puts the tray away (the photo grid below keeps its own scrolling).
            .gesture(DragGesture(minimumDistance: 12).onEnded { value in
                if value.translation.height > 40 { onDismiss() }
            })

            PhotosPicker(selection: $selection, maxSelectionCount: Self.maxPhotos, selectionBehavior: .continuous, matching: .images) {
                Text("选择照片")
            }
            .photosPickerStyle(.inline)
            .photosPickerAccessoryVisibility(.hidden, edges: .all)
            .padding(.horizontal, 3)
        }
        .frame(maxWidth: .infinity)
        .frame(height: Self.contentHeight, alignment: .top)
        .background {
            shape.fill(Color.surface)
                .overlay { shape.strokeBorder(Color.hairline, lineWidth: 0.5) }
                .ignoresSafeArea(edges: .bottom)
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("附件")
    }

    private func option(_ symbol: String, _ title: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            VStack(spacing: 6) {
                Image(systemName: symbol)
                    .font(.system(size: 22))
                    .foregroundStyle(Color.ink)
                    .frame(width: 52, height: 52)
                    .background(Color.surface, in: .rect(cornerRadius: Radius.control, style: .continuous))
                    .overlay { RoundedRectangle(cornerRadius: Radius.control, style: .continuous).strokeBorder(Color.hairline, lineWidth: 0.5) }
                Text(title)
                    .font(.caption)
                    .foregroundStyle(Color.inkSecondary)
                    .lineLimit(1)
                    .minimumScaleFactor(0.8)
            }
            .frame(maxWidth: .infinity)
            .contentShape(.rect)
        }
        .buttonStyle(.pressable)
        .accessibilityLabel(title)
    }
}

// MARK: - Attachments above the text field

/// One thing waiting to be sent with the next message: ready, or still being prepared (a photo being loaded and
/// shrunk to 2048 px).
enum ComposerAttachment: Identifiable {
    case ready(DraftItem)
    case loading(PhotosPickerItem)

    var id: String {
        switch self {
        case .ready(let item): item.id.uuidString
        case .loading(let item): "loading-\(item.hashValue)"
        }
    }

    var isLoading: Bool {
        if case .loading = self { true } else { false }
    }
}

/// The removable thumbnails / chips inside the composer, above the text field.
struct ComposerAttachmentRow: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    var attachments: [ComposerAttachment]
    var onRemove: (ComposerAttachment) -> Void

    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: Space.s) {
                ForEach(attachments) { attachment in
                    AttachmentThumb(attachment: attachment) { onRemove(attachment) }
                        .transition(reduceMotion ? .opacity : .scale(scale: 0.7).combined(with: .opacity))
                }
            }
            // Room for the × badges that sit over the corners.
            .padding(.top, 8)
            .padding(.leading, 2)
            .padding(.trailing, 8)
        }
    }
}

private struct AttachmentThumb: View {
    var attachment: ComposerAttachment
    var onRemove: () -> Void

    var body: some View {
        ZStack(alignment: .topTrailing) {
            content
            Button(action: onRemove) {
                Image(systemName: "xmark")
                    .font(.system(size: 9, weight: .heavy))
                    .foregroundStyle(Color.canvas)
                    .frame(width: 20, height: 20)
                    .background(Color.ink, in: .circle)
                    .padding(2)
                    .background(Color.surface, in: .circle)
                    .contentShape(Circle().inset(by: -10))
            }
            .buttonStyle(.pressable)
            .offset(x: 7, y: -7)
            .accessibilityLabel("移除\(label)")
        }
    }

    private var label: String {
        switch attachment {
        case .loading: "照片"
        case .ready(let item):
            switch item.content {
            case .image: "照片"
            case .file(let name, _, _): name
            case .link(let url): URL(string: url)?.host() ?? "链接"
            case .note(let title, _, _): title
            }
        }
    }

    @ViewBuilder private var content: some View {
        switch attachment {
        case .loading:
            ProgressView()
                .controlSize(.small)
                .tint(Color.inkSecondary)
                .frame(width: 58, height: 58)
                .background(Color.surface, in: .rect(cornerRadius: Radius.control, style: .continuous))
                .overlay { RoundedRectangle(cornerRadius: Radius.control, style: .continuous).strokeBorder(Color.hairline, lineWidth: 0.5) }
                .accessibilityLabel("正在处理照片")
        case .ready(let item):
            switch item.content {
            case .image:
                Group {
                    if let cg = item.preview { Image(decorative: cg, scale: 1).resizable().scaledToFill() } else { Color.hairline }
                }
                .frame(width: 58, height: 58)
                .clipShape(.rect(cornerRadius: Radius.control, style: .continuous))
                .overlay { RoundedRectangle(cornerRadius: Radius.control, style: .continuous).strokeBorder(Color.hairline, lineWidth: 0.5) }
                .accessibilityLabel("照片")
            case .file(let name, _, let data):
                chip(symbol: "doc.text", title: name, subtitle: Fmt.bytes(data.count))
            case .link(let url):
                chip(symbol: "link", title: URL(string: url)?.host() ?? url, subtitle: "链接")
            case .note(let title, _, let symbol):
                chip(symbol: symbol, title: title, subtitle: symbol == "checklist" ? "提醒事项" : "文本")
            }
        }
    }

    private func chip(symbol: String, title: String, subtitle: String) -> some View {
        HStack(spacing: Space.s) {
            Image(systemName: symbol)
                .font(.system(size: 20))
                .foregroundStyle(Color.ink)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 1) {
                Text(title).font(.footnote).foregroundStyle(Color.ink).lineLimit(1)
                Text(subtitle).font(.caption2).foregroundStyle(Color.inkSecondary).lineLimit(1)
            }
            .frame(maxWidth: 140, alignment: .leading)
        }
        .padding(.leading, 10)
        .padding(.trailing, Space.m)
        .frame(height: 58)
        .background(Color.surface, in: .rect(cornerRadius: Radius.control, style: .continuous))
        .overlay { RoundedRectangle(cornerRadius: Radius.control, style: .continuous).strokeBorder(Color.hairline, lineWidth: 0.5) }
        .accessibilityElement(children: .combine)
    }
}

// MARK: - Link / text sheet

struct LinkTextSheet: View {
    @Environment(\.dismiss) private var dismiss
    var onAdd: ([DraftItem]) -> Void
    @State private var text = ""
    @FocusState private var focused: Bool

    var body: some View {
        NavigationStack {
            VStack(alignment: .leading, spacing: Space.m) {
                TextField("粘贴链接或任意文字…", text: $text, axis: .vertical)
                    .font(.orbitBody)
                    .lineLimit(3...8)
                    .focused($focused)
                    .textInputAutocapitalization(.never)
                    .padding(Space.m)
                    .background(Color.surface, in: .rect(cornerRadius: Radius.control, style: .continuous))
                    .overlay { RoundedRectangle(cornerRadius: Radius.control, style: .continuous).strokeBorder(Color.hairline, lineWidth: 0.5) }
                HStack {
                    PasteButton(payloadType: String.self) { strings in
                        Task { @MainActor in text = strings.joined(separator: "\n") }
                    }
                    .buttonBorderShape(.roundedRectangle(radius: Radius.control))
                    .labelStyle(.titleAndIcon)
                    .tint(Color.accentText)
                    Spacer()
                }
                Text("链接会作为链接附件发送；其他文字会附在消息正文里。")
                    .font(.footnote)
                    .foregroundStyle(Color.inkSecondary)
                Spacer(minLength: 0)
            }
            .padding(Space.l)
            .background(Color.canvas)
            .navigationTitle("链接或文本")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("取消") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("添加") {
                        onAdd(DraftItem.fromPasted(text))
                        dismiss()
                    }
                    .disabled(text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
            }
            .onAppear { focused = true }
        }
    }
}

// MARK: - Reminders picker

struct ReminderPickerSheet: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    var onAdd: ([DraftItem]) -> Void
    @State private var reminders: [DeviceContextService.ReminderSummary] = []
    @State private var selected: Set<String> = []
    @State private var state: LoadState = .loading

    enum LoadState { case loading, denied, ready }

    var body: some View {
        NavigationStack {
            Group {
                switch state {
                case .loading:
                    ProgressView()
                case .denied:
                    ContentUnavailableView("无法访问提醒事项", systemImage: "lock",
                                           description: Text("请在“设置 › 隐私与安全性 › 提醒事项”中允许访问"))
                case .ready:
                    if reminders.isEmpty {
                        ContentUnavailableView("没有未完成的提醒", systemImage: "checkmark.circle")
                    } else {
                        List(reminders, selection: $selected) { reminder in
                            VStack(alignment: .leading, spacing: 2) {
                                Text(reminder.title).font(.orbitBody).foregroundStyle(Color.ink)
                                HStack(spacing: Space.s) {
                                    Text(reminder.list)
                                    if let due = reminder.due { Text(due, format: .dateTime.month().day().hour().minute()) }
                                }
                                .font(.caption)
                                .foregroundStyle(Color.inkSecondary)
                            }
                            .tag(reminder.id)
                            .listRowBackground(Color.surface)
                        }
                        .scrollContentBackground(.hidden)
                        .environment(\.editMode, .constant(.active))
                    }
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(Color.canvas)
            .navigationTitle("提醒事项")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("取消") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button { add() } label: {
                        Text(selected.isEmpty ? "添加" : "添加 \(selected.count)").contentTransition(.numericText())
                    }
                    .disabled(selected.isEmpty)
                }
            }
            .animation(Motion.snappy, value: selected.count)
            .task { await load() }
        }
    }

    private func add() {
        let items = reminders.filter { selected.contains($0.id) }.map { reminder in
            var lines = ["提醒事项：\(reminder.title)"]
            if let due = reminder.due { lines.append("截止：\(due.formatted(.dateTime.month().day().hour().minute()))") }
            if !reminder.list.isEmpty { lines.append("列表：\(reminder.list)") }
            if let notes = reminder.notes, !notes.isEmpty { lines.append("备注：\(notes)") }
            return DraftItem(content: .note(title: reminder.title, body: lines.joined(separator: "\n"), symbol: "checklist"))
        }
        onAdd(items)
        dismiss()
    }

    private func load() async {
        if model.isDemo && !model.context.remindersAuthorized {
            reminders = [
                .init(id: "r1", title: "给妈妈订生日蛋糕", due: Date().addingTimeInterval(86400 * 3), notes: nil, list: "家庭"),
                .init(id: "r2", title: "续费云服务器", due: Date().addingTimeInterval(86400 * 7), notes: nil, list: "工作"),
                .init(id: "r3", title: "整理报销单", due: nil, notes: "上海出差", list: "工作"),
            ]
            state = .ready
            return
        }
        let ok = model.context.remindersAuthorized ? true : await model.context.requestReminders()
        guard ok else { state = .denied; return }
        reminders = await model.context.incompleteReminders()
        state = .ready
    }
}
