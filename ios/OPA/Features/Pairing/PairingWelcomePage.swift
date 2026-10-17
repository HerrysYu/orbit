import SwiftUI

/// Welcome: the waving character, what Orbit is in three lines, and the way in ("连接我的 Mac").
struct PairingWelcomePage: View {
    /// Why the last attempt failed before it began (an expired link opened from Notes, for example).
    var errorMessage: String?
    var onConnect: () -> Void
    var onPaste: () -> Void
    var onDemo: () -> Void

    var body: some View {
        PairingPage { viewportHeight in
            VStack(spacing: 0) {
                hero
                // The points sit about 100 pt under the title; whatever height is left goes below them.
                Spacer(minLength: Space.xxl).frame(maxHeight: 98)
                points
                Spacer(minLength: Space.xxl)
            }
            .padding(.top, 36)
            .padding(.horizontal, 34)
            .frame(maxWidth: .infinity, minHeight: viewportHeight)
        } actions: {
            actions
        }
    }

    // MARK: Pieces

    private var hero: some View {
        VStack(spacing: 0) {
            OrbitMascot(pose: .wave, size: 178, greet: true)
            Text("你好，我是 Orbit")
                .font(.orbitWelcome)
                .tracking(-0.5)
                .multilineTextAlignment(.center)
                .padding(.top, 24)
                .accessibilityAddTraits(.isHeader)
            Text("连接你的 Mac，把想做的事交给我。")
                .font(.callout)
                .foregroundStyle(Color.inkSecondary)
                .multilineTextAlignment(.center)
                .padding(.top, 8)
        }
    }

    private var points: some View {
        VStack(alignment: .leading, spacing: 18) {
            WelcomePoint(symbol: "laptopcomputer", title: "在你的 Mac 上执行", detail: "我的大脑和工具都在你的电脑上运行")
            WelcomePoint(symbol: "iphone", title: "手机随时查看", detail: "进度、结果和需要你的时候，都会推到这里")
            WelcomePoint(symbol: "checkmark.shield", title: "重要的事由你决定", detail: "花钱、对外发送，只在你要求或批准后才做")
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var actions: some View {
        VStack(spacing: 6) {
            if let errorMessage {
                NoteBlock(kind: .danger, systemImage: "exclamationmark.triangle.fill", text: errorMessage)
                    .padding(.bottom, 6)
                    .transition(.opacity)
            }
            Button(action: onConnect) {
                Label("连接我的 Mac", systemImage: "qrcode.viewfinder")
            }
            .buttonStyle(.orbitPrimary)

            ViewThatFits(in: .horizontal) {
                HStack(spacing: Space.s) {
                    pasteButton
                    Spacer(minLength: Space.s)
                    demoButton
                }
                VStack(spacing: 0) {
                    pasteButton
                    demoButton
                }
            }
            // The text buttons carry 20 pt of padding of their own; the board has their labels about 8 pt from the edge.
            .padding(.horizontal, -Space.m)
        }
        .animation(Motion.snappy, value: errorMessage)
    }

    private var pasteButton: some View {
        Button(action: onPaste) {
            Label("粘贴配对链接", systemImage: "doc.on.clipboard")
        }
        .buttonStyle(.orbitPlain)
        .fixedSize()
    }

    private var demoButton: some View {
        Button(action: onDemo) {
            Text("体验演示").foregroundStyle(Color.inkSecondary)
        }
        .buttonStyle(.orbitPlain)
        .fixedSize()
        .accessibilityHint("不连接 Mac，用示例数据看看 Orbit 能做什么")
    }
}

/// One line of the welcome page: an icon tile (BrandSoft + AccentText), a title and a sentence.
private struct WelcomePoint: View {
    var symbol: String
    var title: String
    var detail: String

    @ScaledMetric(relativeTo: .body) private var tile: CGFloat = 36

    var body: some View {
        HStack(alignment: .top, spacing: 14) {
            Image(systemName: symbol)
                .pairingFont(17, weight: .medium)
                .foregroundStyle(Color.accentText)
                .frame(width: tile, height: tile)
                .background(Color.brandSoft, in: .rect(cornerRadius: 11, style: .continuous))
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .pairingFont(16, weight: .semibold)
                    .foregroundStyle(Color.ink)
                Text(detail)
                    .pairingFont(14, relativeTo: .subheadline)
                    .foregroundStyle(Color.inkSecondary)
                    .lineSpacing(2)
            }
            .fixedSize(horizontal: false, vertical: true)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .accessibilityElement(children: .combine)
    }
}
