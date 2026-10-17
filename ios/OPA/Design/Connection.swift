import SwiftUI

// MARK: - Connection indicator

/// The Mac connection control in the page headers. Independent of Orbit's own state and of task states.
/// No glass, no capsule, no fill (v2):
/// - connected: a bare 24 pt laptop line icon in InkSecondary, in a 44 x 44 touch target.
/// - connecting / handshaking / waiting to retry: icon + "恢复中", 13 pt, Warning.
/// - Mac offline / failed: icon + "Mac 离线", 13 pt, Warning.
/// Tapping calls `action` (opens the connection details).
struct ConnectionIndicator: View {
    var state: ConnectionState
    var action: () -> Void

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private enum Look: Hashable {
        case connected, recovering, offline
    }

    private var look: Look {
        switch state {
        case .connected: .connected
        case .hostOffline, .failed: .offline
        case .idle, .connecting, .handshaking, .awaitingPairConfirm, .waitingRetry: .recovering
        }
    }

    var body: some View {
        Button(action: action) {
            content
        }
        .buttonStyle(.pressable)
        .animation(MotionAware(reduce: reduceMotion).snappy, value: look)
        .accessibilityLabel(accessibilityText)
        .accessibilityHint("查看连接详情")
    }

    @ViewBuilder
    private var content: some View {
        switch look {
        case .connected:
            Image(systemName: "laptopcomputer")
                .symbolRenderingMode(.monochrome)
                .font(.system(size: 19, weight: .regular))
                .foregroundStyle(Color.inkSecondary)
                .frame(width: 44, height: 44)
                .contentShape(.rect)
        case .recovering:
            label(symbol: "arrow.clockwise", text: "恢复中")
        case .offline:
            label(symbol: "laptopcomputer", text: "Mac 离线")
        }
    }

    /// Icon and a 13 pt word in Warning. The word, not the color, says what is wrong.
    private func label(symbol: String, text: String) -> some View {
        HStack(spacing: 6) {
            Image(systemName: symbol)
                .symbolRenderingMode(.monochrome)
                .font(.system(size: 15, weight: .regular))
            Text(text)
                .font(.orbitMeta)
        }
        .foregroundStyle(Color.warning)
        .padding(.horizontal, 6)
        .frame(minHeight: 44)
        .contentShape(.rect)
    }

    private var accessibilityText: String {
        switch look {
        case .connected:
            if case .connected(let path) = state { "Mac 已连接，\(path.label)" } else { "Mac 已连接" }
        case .recovering: "正在恢复与 Mac 的连接"
        case .offline: "Mac 离线"
        }
    }
}
