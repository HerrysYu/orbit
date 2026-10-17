import SwiftUI

/// The paste-a-link way in: for a link copied from the Mac's terminal (or from a note). The system paste button
/// pastes without the "allow paste" prompt and connects at once; typing or pasting into the field works too.
struct PasteLinkSheet: View {
    /// Returns why the link was refused, or nil when pairing has started.
    var onSubmit: (String) -> String?

    @Environment(\.dismiss) private var dismiss
    @State private var link = PasteLinkSheet.initialText
    @State private var error: String?
    /// The text that was refused: the message stays until the text changes.
    @State private var refused: String?

    /// Release builds start empty; debug builds can prefill the field (`-OPAPasteText`, see `PairingDebug`).
    private static var initialText: String {
        #if DEBUG
        UserDefaults.standard.string(forKey: "OPAPasteText") ?? ""
        #else
        ""
        #endif
    }

    private var trimmed: String { link.trimmingCharacters(in: .whitespacesAndNewlines) }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: Space.l) {
                VStack(alignment: .leading, spacing: 6) {
                    Text("粘贴配对链接")
                        .font(.orbitPageTitle)
                        .accessibilityAddTraits(.isHeader)
                    Text("在 Mac 终端运行 opa pair，复制二维码下面那行 opa:// 链接。在备忘录或信息里直接点这个链接也可以。")
                        .font(.subheadline)
                        .foregroundStyle(Color.inkSecondary)
                }

                TextField("opa://pair?d=…", text: $link, axis: .vertical)
                    .lineLimit(3...6)
                    .font(.system(.footnote, design: .monospaced))
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .padding(Space.m)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(Color.surfaceInset, in: .rect(cornerRadius: Radius.note, style: .continuous))
                    .onChange(of: link) { if trimmed != refused { error = nil } }

                if let error {
                    NoteBlock(kind: .danger, systemImage: "exclamationmark.triangle.fill", text: error)
                        .transition(.opacity)
                }

                HStack(spacing: Space.m) {
                    PasteButton(payloadType: String.self) { strings in
                        guard let text = strings.first else { return }
                        link = text
                        submit()
                    }
                    .buttonBorderShape(.capsule)
                    .labelStyle(.titleAndIcon)
                    .tint(Color.accentText)
                    Spacer(minLength: 0)
                }

                Button("连接", action: submit)
                    .buttonStyle(.orbitPrimary)
                    .disabled(trimmed.isEmpty)
            }
            .padding(.horizontal, Space.xl)
            .padding(.top, Space.xxl)
            .padding(.bottom, Space.xl)
            .animation(Motion.snappy, value: error)
        }
        .scrollDismissesKeyboard(.interactively)
        #if DEBUG
        .task { if UserDefaults.standard.bool(forKey: "OPAPasteSubmit") { submit() } }
        #endif
        .presentationDetents([.medium, .large])
        .presentationDragIndicator(.visible)
        .presentationBackground(Color.canvas)
    }

    private func submit() {
        guard !trimmed.isEmpty else { return }
        if let reason = onSubmit(trimmed) {
            refused = trimmed
            error = reason
        } else {
            dismiss()
        }
    }
}
