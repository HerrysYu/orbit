import SwiftUI

/// "连上了": the character celebrates once (the happy pose bounces when it appears, then stays still), the Mac's name,
/// how it is reached, and one button into the app.
struct PairingSuccessPage: View {
    var host: PairedHost
    var onContinue: () -> Void

    @State private var arrived = false

    var body: some View {
        PairingPage { viewportHeight in
            VStack(spacing: 0) {
                OrbitMascot(pose: .happy, size: 168)
                Text("连上了")
                    .font(.orbitWelcome)
                    .tracking(-0.5)
                    .padding(.top, 20)
                    .accessibilityAddTraits(.isHeader)
                Text(host.hostName)
                    .font(.callout)
                    .foregroundStyle(Color.inkSecondary)
                    .multilineTextAlignment(.center)
                    .padding(.top, 8)
                HStack(spacing: Space.l) {
                    StatusChip(kind: .ok, text: "已加密")
                    StatusChip(kind: .planning, text: pairingRouteSummary(host))
                }
                .padding(.top, Space.l)
            }
            .padding(.horizontal, 24)
            .padding(.top, max(Space.xl, viewportHeight * 0.19))
            .frame(maxWidth: .infinity, minHeight: viewportHeight, alignment: .top)
        } actions: {
            VStack(spacing: Space.m) {
                Button(action: onContinue) {
                    HStack(spacing: Space.s) {
                        Text("开始和 Orbit 聊聊")
                        Image(systemName: "arrow.right").fontWeight(.semibold)
                    }
                }
                .buttonStyle(.orbitPrimary)
                Text("之后可以在 设置 › 连接与设备 里查看或断开")
                    .font(.caption)
                    .foregroundStyle(Color.inkTertiary)
                    .multilineTextAlignment(.center)
            }
        }
        .sensoryFeedback(.success, trigger: arrived)
        .onAppear { arrived = true }
    }
}
