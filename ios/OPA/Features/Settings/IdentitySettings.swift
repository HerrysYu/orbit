import PhotosUI
import SwiftUI

// 我的 Orbit: name and picture, how Orbit addresses you, and its personality. Text is edited as a local draft and sent
// when the field loses focus or the page closes; `settingsSync` reports the result and a refused edit is rolled back
// (the draft then shows the Mac's value again).

// MARK: - 名字和形象

struct BotIdentityView: View {
    @Environment(AppModel.self) private var model
    @State private var name = ""
    @State private var photo: PhotosPickerItem?
    @State private var loadingPhoto = false
    @FocusState private var nameFocused: Bool

    private static let emojis = ["🪐", "✨", "🌙", "🦊", "🐱", "🦉", "🐼", "🤖", "🌿", "☕️"]

    var body: some View {
        List {
            Section {
                avatarEditor
                    .listRowBackground(Color.clear)
                    .listRowSeparator(.hidden)
                    .listRowInsets(EdgeInsets(top: Space.s, leading: 0, bottom: Space.s, trailing: 0))
            }
            Section {
                LabeledContent {
                    TextField(model.settings.butler.name, text: $name)
                        .multilineTextAlignment(.trailing)
                        .foregroundStyle(Color.inkSecondary)
                        .submitLabel(.done)
                        .focused($nameFocused)
                        .onSubmit(commitName)
                } label: {
                    Text("名字").font(.orbitBody).foregroundStyle(Color.ink)
                }
                .settingsRowChrome(icon: false)
            } footer: {
                SettingsFooter("这是 Orbit 在对话和通知里使用的名字。")
            }
            .textCase(nil)
        }
        .settingsListChrome()
        .navigationTitle("名字和形象")
        .navigationBarTitleDisplayMode(.inline)
        .onAppear { name = model.settings.butler.name }
        .onDisappear(perform: commitName)
        .onChange(of: nameFocused) { _, focused in if !focused { commitName() } }
        .onChange(of: model.settings.butler.name) { _, new in if !nameFocused { name = new } }
        .onChange(of: model.settingsSync) { _, state in
            if case .failed = state { name = model.settings.butler.name }
        }
        .onChange(of: photo) { _, item in
            guard let item else { return }
            Task { await setPhoto(item) }
        }
    }

    // MARK: Avatar

    private var avatarEditor: some View {
        let current = model.settings.butler.avatar
        return VStack(spacing: Space.l) {
            SettingsAvatarView(avatar: current, size: 96)
                .elevation(1)
                .overlay {
                    if loadingPhoto {
                        Circle().fill(.ultraThinMaterial)
                        ProgressView()
                    }
                }
                .animation(Motion.snappy, value: current)
                .accessibilityHidden(true)

            PhotosPicker(selection: $photo, matching: .images) {
                Label("从相册选择", systemImage: "photo")
            }
            .buttonStyle(.orbit(.soft, size: .small))
            .disabled(loadingPhoto)

            VStack(alignment: .leading, spacing: Space.s) {
                Text("或者选一个").font(.orbitMeta).foregroundStyle(Color.inkSecondary)
                    .padding(.horizontal, Space.xl)
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: Space.m) {
                        option(selected: current == nil || current == "", label: "Orbit 形象（默认）") {
                            model.updateSettings(["butler": ["avatar": .string("")]])
                        } content: {
                            OrbitAvatar(size: 46)
                        }
                        ForEach(Self.emojis, id: \.self) { emoji in
                            option(selected: current == "emoji:" + emoji, label: "使用 \(emoji) 作为头像") {
                                model.updateSettings(["butler": ["avatar": .string("emoji:" + emoji)]])
                            } content: {
                                Circle().fill(Color.surfaceInset).frame(width: 46, height: 46)
                                    .overlay { Text(verbatim: emoji).font(.system(size: 24)) }
                            }
                        }
                    }
                    .padding(.horizontal, Space.xl)
                    .padding(.vertical, 5)
                }
            }
        }
        .frame(maxWidth: .infinity)
    }

    private func option<Content: View>(selected: Bool, label: String, action: @escaping () -> Void,
                                       @ViewBuilder content: () -> Content) -> some View {
        Button(action: action) {
            content()
                .padding(3)
                .overlay { Circle().strokeBorder(Color.brandApricot, lineWidth: 2.5).opacity(selected ? 1 : 0) }
                .frame(minWidth: 52, minHeight: 52)
        }
        .buttonStyle(.pressable)
        .animation(Motion.snappy, value: selected)
        .accessibilityLabel(label)
        .accessibilityAddTraits(selected ? .isSelected : [])
    }

    // MARK: Actions

    private func commitName() {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        let current = model.settings.butler.name
        guard !trimmed.isEmpty else { name = current; return }
        name = trimmed
        guard trimmed != current else { return }
        model.updateSettings(["butler": ["name": .string(trimmed)]])
    }

    private func setPhoto(_ item: PhotosPickerItem) async {
        loadingPhoto = true
        defer { loadingPhoto = false; photo = nil }
        guard let data = try? await item.loadTransferable(type: Data.self),
              let jpeg = ImageTools.squareAvatarJPEG(data, side: 256) else {
            model.showToast("这张图片无法用作头像")
            return
        }
        model.updateSettings(["butler": ["avatar": .string("data:image/jpeg;base64," + jpeg.base64EncodedString())]])
    }
}

// MARK: - 怎么称呼你

struct UserTitleView: View {
    @Environment(AppModel.self) private var model
    @State private var title = ""
    @FocusState private var focused: Bool

    var body: some View {
        List {
            Section {
                LabeledContent {
                    TextField("你", text: $title)
                        .multilineTextAlignment(.trailing)
                        .foregroundStyle(Color.inkSecondary)
                        .submitLabel(.done)
                        .focused($focused)
                        .onSubmit(commit)
                } label: {
                    Text("称呼").font(.orbitBody).foregroundStyle(Color.ink)
                }
                .settingsRowChrome(icon: false)
            } footer: {
                let shown = title.trimmingCharacters(in: .whitespaces).isEmpty ? "你" : title.trimmingCharacters(in: .whitespaces)
                SettingsFooter("Orbit 会这样称呼你，比如“好的，\(shown)。”")
            }
            .textCase(nil)
        }
        .settingsListChrome()
        .navigationTitle("怎么称呼你")
        .navigationBarTitleDisplayMode(.inline)
        .onAppear { title = model.settings.butler.userTitle }
        .onDisappear(perform: commit)
        .onChange(of: focused) { _, now in if !now { commit() } }
        .onChange(of: model.settings.butler.userTitle) { _, new in if !focused { title = new } }
        .onChange(of: model.settingsSync) { _, state in
            if case .failed = state { title = model.settings.butler.userTitle }
        }
    }

    private func commit() {
        let trimmed = title.trimmingCharacters(in: .whitespacesAndNewlines)
        let current = model.settings.butler.userTitle
        guard !trimmed.isEmpty else { title = current; return }
        title = trimmed
        guard trimmed != current else { return }
        model.updateSettings(["butler": ["userTitle": .string(trimmed)]])
    }
}

// MARK: - 性格

struct PersonaView: View {
    @Environment(AppModel.self) private var model
    @State private var persona = ""
    @FocusState private var focused: Bool

    var body: some View {
        List {
            Section {
                TextEditor(text: $persona)
                    .font(.orbitBody)
                    .foregroundStyle(Color.ink)
                    .scrollContentBackground(.hidden)
                    .focused($focused)
                    .frame(minHeight: 160)
                    .overlay(alignment: .topLeading) {
                        if persona.isEmpty {
                            Text("例如：温和、靠谱，说话简洁；重要的事会提前提醒。")
                                .font(.orbitBody)
                                .foregroundStyle(Color.inkTertiary)
                                .padding(.top, 8)
                                .padding(.leading, 5)
                                .allowsHitTesting(false)
                                .accessibilityHidden(true)
                        }
                    }
                    .accessibilityLabel("性格")
                    .settingsRowChrome(icon: false)
            } footer: {
                SettingsFooter("用几句话描述 Orbit 的说话方式和做事风格。它在每次对话里都会参考这段话。")
            }
            .textCase(nil)
        }
        .settingsListChrome()
        .navigationTitle("性格")
        .navigationBarTitleDisplayMode(.inline)
        .onAppear { persona = model.settings.butler.persona }
        .onDisappear(perform: commit)
        .onChange(of: focused) { _, now in if !now { commit() } }
        .onChange(of: model.settings.butler.persona) { _, new in if !focused { persona = new } }
        .onChange(of: model.settingsSync) { _, state in
            if case .failed = state { persona = model.settings.butler.persona }
        }
        .toolbar {
            ToolbarItemGroup(placement: .keyboard) {
                Spacer()
                Button("完成") { focused = false }
            }
        }
    }

    private func commit() {
        let trimmed = persona.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed != model.settings.butler.persona else { return }
        model.updateSettings(["butler": ["persona": .string(trimmed)]])
    }
}
