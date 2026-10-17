import SwiftUI

// The pages between "scan" and "paired": connecting, verify the code, and what went wrong. They share one layout.

// MARK: - Shared layout

/// Back button, the character, a title, a sentence, the page's own content, and the actions at the bottom (see
/// `PairingPage`: pinned, or at the end of the content at accessibility text sizes). The back button means "cancel the
/// connection".
private struct PairingStatusLayout<Message: View, Content: View, Footer: View>: View {
    var pose: MascotPose
    var mascotSize: CGFloat
    var title: String
    /// What the back button does when that is more than "go back" (it cancels the connection).
    var backHint: String? = nil
    var onBack: () -> Void
    @ViewBuilder var message: Message
    @ViewBuilder var content: Content
    @ViewBuilder var footer: Footer

    var body: some View {
        PairingPage { _ in
            VStack(spacing: 0) {
                OrbitMascot(pose: pose, size: mascotSize)
                Text(title)
                    .font(.orbitPageTitle)
                    .multilineTextAlignment(.center)
                    .padding(.top, 20)
                    .accessibilityAddTraits(.isHeader)
                message
                    .font(.subheadline)
                    .lineSpacing(3)
                    .foregroundStyle(Color.inkSecondary)
                    .multilineTextAlignment(.center)
                    .padding(.top, 8)
                    .padding(.horizontal, 10)
                content
                    .padding(.top, 26)
            }
            .padding(.horizontal, 24)
            .padding(.top, 74)
            .padding(.bottom, Space.xl)
            .frame(maxWidth: .infinity)
        } actions: {
            VStack(spacing: 6) { footer }
        }
        .overlay(alignment: .topLeading) {
            GlassCircleButton(systemImage: "chevron.left", accessibilityLabel: "返回", action: onBack)
                .accessibilityHint(backHint ?? "")
                .padding(.leading, Space.l)
                .padding(.top, 4)
        }
    }
}

/// "等待 Mac 确认…": a small spinner and a line, never a full-screen wheel.
private struct WaitingLine: View {
    var text: String

    var body: some View {
        HStack(spacing: Space.s) {
            OrbitSpinner()
            Text(text)
                .pairingFont(14.5, relativeTo: .subheadline)
                .foregroundStyle(Color.inkSecondary)
        }
        .accessibilityElement(children: .combine)
    }
}

/// Two sentences: on two lines when each fits on one (as on the board), otherwise one paragraph, so that a short tail
/// never ends up alone on its own line at large text sizes.
private struct TwoSentenceMessage: View {
    var first: String
    var second: String

    var body: some View {
        ViewThatFits(in: .horizontal) {
            VStack(spacing: 0) {
                Text(first).fixedSize(horizontal: true, vertical: false)
                Text(second).fixedSize(horizontal: true, vertical: false)
            }
            Text(first + second)
        }
    }
}

// MARK: - Verify the code

/// Both screens must show the same six digits; the user confirms on the Mac.
struct PairingVerifyPage: View {
    var code: String
    var hostName: String
    var path: TransportPath
    var onCancel: () -> Void

    var body: some View {
        PairingStatusLayout(pose: .attentive, mascotSize: 104, title: "核对校验码", backHint: "取消这次连接", onBack: onCancel) {
            TwoSentenceMessage(first: "确认 Mac 上显示的是同样的 6 位数字，", second: "然后在 Mac 上输入 y 并回车。")
        } content: {
            VStack(spacing: 22) {
                codeCard
                WaitingLine(text: "等待 Mac 确认…")
            }
        } footer: {
            Button("数字不一致，取消连接", action: onCancel)
                .buttonStyle(.orbitDestructive)
        }
    }

    private var codeCard: some View {
        OrbitCard {
            VStack(spacing: 14) {
                Text(grouped)
                    .pairingFont(46, weight: .semibold, design: .rounded, relativeTo: .largeTitle)
                    .monospacedDigit()
                    .tracking(3.7)
                    .lineLimit(1)
                    .minimumScaleFactor(0.4)
                    .contentTransition(.numericText())
                    .accessibilityLabel("校验码 " + code.map(String.init).joined(separator: " "))
                macLine
                    .pairingFont(14, relativeTo: .subheadline)
                    .foregroundStyle(Color.inkSecondary)
                    .multilineTextAlignment(.center)
            }
            .padding(.vertical, 22)
            .padding(.horizontal, 28)
            .frame(maxWidth: .infinity)
        }
    }

    /// "Mac 名称 · 局域网" on one line; when it does not fit, the path moves to its own line instead of breaking mid-word.
    private var macLine: some View {
        ViewThatFits(in: .horizontal) {
            Label("\(hostName) · \(pairingPathName(path))", systemImage: "laptopcomputer")
                .fixedSize(horizontal: true, vertical: false)
            VStack(spacing: 2) {
                Label(hostName, systemImage: "laptopcomputer")
                Text(pairingPathName(path))
            }
        }
    }

    /// "153098" → "153 098".
    private var grouped: String {
        code.count == 6 ? "\(code.prefix(3)) \(code.suffix(3))" : code
    }
}

// MARK: - Connecting

/// Between "the code was read" and "the code is on screen" (and while the Mac does not answer).
struct PairingConnectingPage: View {
    var hostName: String
    var retrying: Bool
    var onCancel: () -> Void

    var body: some View {
        PairingStatusLayout(pose: .focused, mascotSize: 104,
                            title: retrying ? "暂时连不上 \(hostName)" : "正在连接 \(hostName)",
                            backHint: "取消这次连接", onBack: onCancel) {
            Text(retrying
                 ? "请确认 Mac 开着、Orbit 在运行，并且和手机在同一个网络（或已设置外网中继）。我会继续尝试。"
                 : "正在建立加密连接，马上就好。")
        } content: {
            WaitingLine(text: retrying ? "正在重试…" : "正在连接…")
        } footer: {
            Button("取消", action: onCancel)
                .buttonStyle(.orbitPlain)
        }
    }
}

// MARK: - Failed

/// The pairing did not go through: expired code, refused on the Mac, or the connection broke. "重试" goes back to
/// scanning, because a code works once.
struct PairingFailedPage: View {
    var reason: String
    var onRetry: () -> Void
    var onBack: () -> Void

    var body: some View {
        PairingStatusLayout(pose: .thinking, mascotSize: 104, title: "没有连上", onBack: onBack) {
            EmptyView()
        } content: {
            VStack(spacing: Space.m) {
                NoteBlock(kind: .danger, systemImage: "exclamationmark.triangle.fill", text: pairingFailureExplanation(reason))
                Text("在 Mac 终端重新运行 opa pair，再扫描新的二维码。")
                    .font(.subheadline)
                    .foregroundStyle(Color.inkSecondary)
                    .multilineTextAlignment(.center)
            }
        } footer: {
            Button("重试", action: onRetry)
                .buttonStyle(.orbitPrimary)
            Button("返回", action: onBack)
                .buttonStyle(.orbitPlain)
        }
    }
}
