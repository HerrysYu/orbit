import SwiftUI

// 记忆: what Orbit remembers about you. Filter by who said it (`source`), grouped by category, swipe to delete
// (always after a confirmation: the host has no undo), "+" to add. The list refreshes itself on `memoryRevision`.

// MARK: - Grouping

/// The groups the list is divided into. Places and people share one group, as in the design.
enum MemoryCategory: Int, CaseIterable, Identifiable, Sendable {
    case profile, preference, placesPeople, dates, facts

    var id: Int { rawValue }

    init(kind: Memory.Kind) {
        switch kind {
        case .profile: self = .profile
        case .preference: self = .preference
        case .person, .place: self = .placesPeople
        case .date: self = .dates
        case .fact: self = .facts
        }
    }

    var title: String {
        switch self {
        case .profile: "个人"
        case .preference: "偏好"
        case .placesPeople: "地点与人"
        case .dates: "日期"
        case .facts: "事实"
        }
    }
}

struct MemorySection: Identifiable, Equatable {
    var category: MemoryCategory
    var items: [Memory]
    var id: Int { category.id }
}

enum MemoryFilter: Hashable, Sendable {
    case all, explicit, inferred

    func includes(_ memory: Memory) -> Bool {
        switch self {
        case .all: true
        case .explicit: !memory.isInferred
        case .inferred: memory.isInferred
        }
    }
}

extension Memory {
    /// Orbit worked it out itself (`source` is "inferred"), as opposed to you telling it.
    var isInferred: Bool { source == "inferred" }
}

enum MemoryGrouping {
    /// The memories that pass the filter, grouped by category in the design's order. Each group keeps the order given.
    static func sections(_ memories: [Memory], filter: MemoryFilter) -> [MemorySection] {
        let kept = memories.filter(filter.includes)
        return MemoryCategory.allCases.compactMap { category in
            let items = kept.filter { MemoryCategory(kind: $0.kind) == category }
            return items.isEmpty ? nil : MemorySection(category: category, items: items)
        }
    }
}

// MARK: - Page

struct MemoryView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dynamicTypeSize) private var typeSize
    @State private var filter: MemoryFilter = .all
    @State private var loading = true
    @State private var showAdd = false
    @State private var pendingDelete: Memory?

    var body: some View {
        let memories = model.memories
        let sections = MemoryGrouping.sections(memories, filter: filter)
        List {
            introSection(memories)
            if sections.isEmpty {
                emptySection(hasMemories: !memories.isEmpty)
            } else {
                ForEach(sections) { section in
                    Section {
                        ForEach(section.items) { memory in
                            MemoryRow(memory: memory)
                                .settingsRowChrome(icon: false)
                                .swipeActions(edge: .trailing, allowsFullSwipe: false) {
                                    // The app tint would turn a destructive action brown: keep it red.
                                    Button(role: .destructive) { pendingDelete = memory } label: { Text("删除") }
                                        .tint(Color.swipeDelete)
                                }
                        }
                    } header: {
                        SettingsSectionHeader(section.category.title)
                    } footer: {
                        if section.id == sections.last?.id {
                            SettingsFooter("删除前会再确认一次；删除后 Orbit 不再记得这件事。对 Orbit 说“记住…”也可以添加。")
                        }
                    }
                    .textCase(nil)
                }
            }
        }
        .settingsListChrome()
        .navigationTitle("记忆")
        .navigationBarTitleDisplayMode(.large)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button { showAdd = true } label: { Image(systemName: "plus") }
                    .accessibilityLabel("添加记忆")
            }
        }
        .sheet(isPresented: $showAdd) { AddMemorySheet() }
        // On the page, not on the swiped row: a dialog attached to a row that the list recycles never shows.
        .confirmationDialog("删除这条记忆？",
                            isPresented: Binding { pendingDelete != nil } set: { if !$0 { pendingDelete = nil } },
                            titleVisibility: .visible, presenting: pendingDelete) { memory in
            Button("删除", role: .destructive) { Task { await model.deleteMemory(memory.id) } }
        } message: { memory in
            Text("“\(memory.text)”\n删除后 Orbit 不再记得这件事。")
        }
        .task(id: model.memoryRevision) {
            await model.loadMemories()
            loading = false
            #if DEBUG
            presentDebugDialog()
            #endif
        }
        .refreshable { await model.loadMemories() }
    }

    // MARK: Intro and filter

    private func introSection(_ memories: [Memory]) -> some View {
        Section {
            VStack(alignment: .leading, spacing: Space.m) {
                Text("Orbit 记住的关于你的事。它只在需要时用到这些，你可以随时删除。")
                    .font(.orbitSecondary)
                    .foregroundStyle(Color.inkSecondary)
                    .lineSpacing(3)
                    .fixedSize(horizontal: false, vertical: true)
                if !memories.isEmpty { filterPicker(memories) }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .listRowBackground(Color.clear)
            .listRowSeparator(.hidden)
            // Top and bottom insets keep the text clear of the section's rounded corners, which clip every row.
            .listRowInsets(EdgeInsets(top: Space.m + 2, leading: Space.xs, bottom: Space.m, trailing: Space.xs))
        }
    }

    @ViewBuilder
    private func filterPicker(_ memories: [Memory]) -> some View {
        let told = memories.filter { !$0.isInferred }.count
        let inferred = memories.count - told
        let picker = Picker("筛选", selection: $filter) {
            Text("全部 \(memories.count)").tag(MemoryFilter.all)
            Text("你告诉我的 \(told)").tag(MemoryFilter.explicit)
            Text("我推断的 \(inferred)").tag(MemoryFilter.inferred)
        }
        if typeSize >= .accessibility1 {
            picker.pickerStyle(.menu).frame(maxWidth: .infinity, alignment: .leading)
        } else {
            picker.pickerStyle(.segmented)
        }
    }

    // MARK: Empty states

    @ViewBuilder
    private func emptySection(hasMemories: Bool) -> some View {
        Section {
            VStack(spacing: Space.m) {
                if hasMemories {
                    Text(filter == .inferred ? "Orbit 还没有自己推断出关于你的事。" : "你还没有亲口告诉 Orbit 要记住什么。")
                        .font(.orbitSecondary)
                        .foregroundStyle(Color.inkSecondary)
                        .multilineTextAlignment(.center)
                } else if loading && model.canUseHost {
                    ProgressView().padding(.vertical, Space.xl)
                } else if !model.canUseHost {
                    OrbitMascot(pose: .focused, size: 96)
                    Text("连上 Mac 后才能查看和管理记忆")
                        .font(.orbitCardTitle)
                        .foregroundStyle(Color.ink)
                    Text("Mac 恢复连接后，这里会自动更新。")
                        .font(.orbitSecondary)
                        .foregroundStyle(Color.inkSecondary)
                        .multilineTextAlignment(.center)
                } else {
                    OrbitMascot(pose: .attentive, size: 96)
                    Text("还没有记住什么")
                        .font(.orbitCardTitle)
                        .foregroundStyle(Color.ink)
                    Text("对 Orbit 说“记住…”，或点右上角的 + 手动添加。")
                        .font(.orbitSecondary)
                        .foregroundStyle(Color.inkSecondary)
                        .multilineTextAlignment(.center)
                    Button("添加记忆") { showAdd = true }
                        .buttonStyle(.orbit(.soft, size: .small))
                }
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, Space.xl)
            .listRowBackground(Color.clear)
            .listRowSeparator(.hidden)
        }
    }

    #if DEBUG
    /// `-OPAMemoryDialog add|delete` opens the add sheet / the delete confirmation on launch (screenshots).
    private func presentDebugDialog() {
        switch UserDefaults.standard.string(forKey: "OPAMemoryDialog") {
        case "add": showAdd = true
        case "delete": pendingDelete = model.memories.first
        default: break
        }
    }
    #endif
}

extension Color {
    /// Fill of the red swipe action: the Danger token of the light theme in both themes. A white label sits on it
    /// (the system draws swipe labels white), which the dark theme's light-salmon Danger could not carry.
    static let swipeDelete = Color(red: 0xAC / 255.0, green: 0x39 / 255.0, blue: 0x32 / 255.0)
}

// MARK: - Row

private struct MemoryRow: View {
    var memory: Memory

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(verbatim: memory.text)
                .font(.system(.callout))
                .foregroundStyle(Color.ink)
                .fixedSize(horizontal: false, vertical: true)
            HStack(spacing: 5) {
                if memory.isInferred {
                    Text("我推断的").fontWeight(.semibold).foregroundStyle(Color.accentText)
                } else {
                    Text("你告诉我的").foregroundStyle(Color.inkSecondary)
                }
                Text("· " + dateText).foregroundStyle(Color.inkTertiary)
            }
            .font(.orbitMeta)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.vertical, 2)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(memory.text)
        .accessibilityValue("\(memory.isInferred ? "我推断的" : "你告诉我的")，\(dateText)")
    }

    private var dateText: String {
        let date = Clock.date(ms: memory.updatedAt)
        if Calendar.current.isDate(date, equalTo: Date(), toGranularity: .year) {
            return date.formatted(.dateTime.month().day())
        }
        return date.formatted(.dateTime.year().month().day())
    }
}

// MARK: - Add

private struct AddMemorySheet: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    @State private var text = ""
    @State private var kind: Memory.Kind = .fact
    @State private var saving = false
    @FocusState private var focused: Bool

    private var canSave: Bool { !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && !saving }

    var body: some View {
        NavigationStack {
            List {
                Section {
                    TextField("让 \(model.settings.butler.name) 记住…", text: $text, axis: .vertical)
                        .lineLimit(3...8)
                        .font(.orbitBody)
                        .foregroundStyle(Color.ink)
                        .focused($focused)
                        .disabled(saving)
                        .settingsRowChrome(icon: false)
                } footer: {
                    SettingsFooter("写一件关于你的事，比如“不吃香菜”“妈妈生日是 11 月 3 日”。Orbit 只在需要时用到它。")
                }
                .textCase(nil)

                Section {
                    Picker(selection: $kind) {
                        ForEach(Memory.Kind.allCases, id: \.self) { kind in
                            Label(kind.label, systemImage: kind.symbol).tag(kind)
                        }
                    } label: {
                        Text("类别").font(.orbitBody).foregroundStyle(Color.ink)
                    }
                    .disabled(saving)
                    .settingsRowChrome(icon: false)
                }
            }
            .listStyle(.insetGrouped)
            .scrollContentBackground(.hidden)
            .background(Color.canvas)
            .navigationTitle("添加记忆")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("取消") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    if saving {
                        ProgressView()
                    } else {
                        Button("添加", action: save).disabled(!canSave)
                    }
                }
            }
            .onAppear { focused = true }
        }
        .presentationDetents([.medium, .large])
        .presentationDragIndicator(.visible)
        .interactiveDismissDisabled(saving)
    }

    private func save() {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, !saving else { return }
        saving = true
        Task {
            let before = Set(model.memories.map(\.id))
            await model.addMemory(trimmed, kind: kind)
            saving = false
            // `addMemory` reports a failure with a toast and adds nothing: keep the text so it can be sent again.
            if model.memories.contains(where: { !before.contains($0.id) }) { dismiss() }
        }
    }
}

#Preview {
    let m = AppModel(inMemory: true)
    m.enterDemo()
    return NavigationStack { MemoryView() }.environment(m)
}
