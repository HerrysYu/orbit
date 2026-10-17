import SwiftUI

/// Connect your Mac: welcome → scan → verify code → success. `RootView` shows it while nothing is paired.
///
/// The page on screen comes from `AppModel.connection` (see `PairingStage`); the scanner and the paste sheet are
/// presentations on top of it. `PairingFlow` holds what the model does not: the sheets, what the scanner just read,
/// and the finished pairing that waits for the "开始和 Orbit 聊聊" tap.
struct PairingView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var flow = PairingFlow()
    /// `RootView` draws this page for its first frame(s), before `bootstrap()` has loaded a stored pairing (or demo mode).
    /// Someone who is already paired must not see the welcome page flash by, so until the root has switched the page
    /// shows only its backdrop. A safety timer ends that wait if the switch never comes.
    @State private var restoring = PairingView.launchWillRestoreSession()
    #if DEBUG
    @State private var appliedLaunchArguments = false
    #endif

    var body: some View {
        @Bindable var flow = flow
        let stage = currentStage
        ZStack {
            PairingBackdrop(glow: !restoring && (stage.kind == .welcome || stage.kind == .paired))
            if !restoring {
                page(for: stage)
                    .id(stage.kind)
                    .transition(.opacity)
            }
        }
        .animation(MotionAware(reduce: reduceMotion).spring, value: stage.kind)
        .fullScreenCover(isPresented: $flow.scannerPresented) {
            ScanScreen(flow: flow)
        }
        .sheet(isPresented: $flow.pastePresented) {
            PasteLinkSheet { flow.submit(link: $0) }
        }
        .task {
            flow.attach(to: model)
            #if DEBUG
            // `.task` runs again whenever a sheet closes and this page reappears: apply the arguments once.
            if !appliedLaunchArguments {
                appliedLaunchArguments = true
                flow.applyLaunchArguments()
            }
            #endif
        }
        .task {
            guard restoring else { return }
            try? await Task.sleep(for: .seconds(1))
            restoring = false
        }
        .onChange(of: stage.kind) {
            AccessibilityNotification.ScreenChanged().post()
            #if DEBUG
            flow.debugStageChanged(stage.kind)
            #endif
        }
        .onChange(of: model.connection) { _, new in
            // Pairing was started somewhere else (an opa:// link, a launch argument) while the scanner is up:
            // get out of its way. A code the scanner itself just read closes the page on its own after a moment.
            if flow.scannerPresented, flow.recognizedHostName == nil, new != .idle { flow.scannerPresented = false }
        }
        .onDisappear {
            // Also fires when a sheet covers this page; only let go of the core's handler when the root replaced us.
            if model.pairedHost != nil || model.isDemo { flow.detach() }
        }
    }

    /// True when a stored pairing or demo mode is about to be restored by `RootView`'s `bootstrap()`.
    private static func launchWillRestoreSession() -> Bool {
        let defaults = UserDefaults.standard
        return PairedHost.load(from: defaults) != nil
            || defaults.bool(forKey: AppModel.DefaultsKey.demo)
            || defaults.bool(forKey: "OPADemo")
    }

    // MARK: Stage

    private var currentStage: PairingStage {
        let name = model.hostName ?? "Mac"
        if let host = flow.completedHost {
            // A second pairing started while the success page was up (another opa:// link): its code needs checking too.
            if case .awaitingPairConfirm(let code, let path) = model.connection { return .verify(code: code, hostName: name, path: path) }
            return .paired(host)
        }
        switch model.connection {
        case .awaitingPairConfirm(let code, let path): return .verify(code: code, hostName: name, path: path)
        case .connecting, .handshaking: return .connecting(hostName: name, retrying: false)
        case .waitingRetry, .hostOffline: return .connecting(hostName: name, retrying: true)
        case .failed(let message): return .failed(reason: message)
        case .idle, .connected: return .welcome
        }
    }

    @ViewBuilder
    private func page(for stage: PairingStage) -> some View {
        switch stage {
        case .welcome:
            PairingWelcomePage(errorMessage: model.pairingError,
                               onConnect: { flow.presentScanner() },
                               onPaste: { flow.presentPaste() },
                               onDemo: { model.enterDemo() })
        case .connecting(let hostName, let retrying):
            PairingConnectingPage(hostName: hostName, retrying: retrying, onCancel: { flow.cancel() })
        case .verify(let code, let hostName, let path):
            PairingVerifyPage(code: code, hostName: hostName, path: path, onCancel: { flow.cancel() })
        case .failed(let reason):
            PairingFailedPage(reason: reason, onRetry: { flow.retry() }, onBack: { flow.cancel() })
        case .paired(let host):
            PairingSuccessPage(host: host, onContinue: { flow.finish() })
        }
    }
}

#Preview("Pairing") {
    PairingView().environment(AppModel(inMemory: true))
}
