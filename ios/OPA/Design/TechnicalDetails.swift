import SwiftUI

// MARK: - Technical details

/// A collapsed "技术详情" block for raw material that only a developer wants: a shell command and its directory, JSON
/// parameters, the data of a card this version cannot draw. Closed by default, so the screen it sits in reads as plain
/// language; one tap opens it, and nothing is dropped. The text is monospaced and selectable.
struct TechnicalDetails: View {
    var text: String

    @State private var expanded: Bool

    /// `startsExpanded` is for previews and screenshots that need to see the inside; in the app it stays closed.
    init(text: String, startsExpanded: Bool = false) {
        self.text = text
        _expanded = State(initialValue: startsExpanded)
    }

    var body: some View {
        DisclosureGroup(isExpanded: $expanded) {
            Text(verbatim: text)
                .font(.system(.footnote, design: .monospaced))
                .foregroundStyle(Color.ink)
                .multilineTextAlignment(.leading)
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
        } label: {
            Text("技术详情")
        }
        .disclosureGroupStyle(TechnicalDisclosureStyle())
    }
}

/// A "技术详情" row with a chevron inside a 0.5 pt Hairline outline (no fill); opened, the content sits under a hairline.
struct TechnicalDisclosureStyle: DisclosureGroupStyle {
    func makeBody(configuration: Configuration) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            Header(configuration: configuration)
            if configuration.isExpanded {
                Rectangle().fill(Color.hairline).frame(height: 0.5)
                configuration.content
                    .padding(.horizontal, Space.m)
                    .padding(.vertical, 10)
                    .transition(.opacity)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .overlay {
            RoundedRectangle(cornerRadius: Radius.note, style: .continuous)
                .strokeBorder(Color.hairline, lineWidth: 0.5)
        }
    }

    private struct Header: View {
        @Environment(\.accessibilityReduceMotion) private var reduceMotion
        let configuration: DisclosureGroupStyleConfiguration

        var body: some View {
            Button {
                withAnimation(MotionAware(reduce: reduceMotion).spring) { configuration.isExpanded.toggle() }
            } label: {
                HStack(spacing: 6) {
                    configuration.label
                        .font(.system(.footnote, weight: .semibold))
                        .foregroundStyle(Color.inkSecondary)
                    Spacer(minLength: Space.s)
                    Image(systemName: "chevron.down")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(Color.inkSecondary)
                        .rotationEffect(.degrees(configuration.isExpanded ? 180 : 0))
                        .accessibilityHidden(true)
                }
                .padding(.horizontal, Space.m)
                .frame(minHeight: 44)
                .contentShape(.rect)
            }
            .buttonStyle(.plain)
            .accessibilityValue(configuration.isExpanded ? "已展开" : "已折叠")
            .accessibilityHint(configuration.isExpanded ? "收起原始内容" : "展开查看原始内容")
        }
    }
}

#if DEBUG
#Preview("Technical details") {
    VStack(spacing: Space.m) {
        TechnicalDetails(text: "npm publish\n目录：~/code/opa-skill")
        TechnicalDetails(text: "npm publish\n目录：~/code/opa-skill", startsExpanded: true)
    }
    .padding()
    .background(Color.surface)
}
#endif
