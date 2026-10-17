import SwiftUI

@main
struct OPAApp: App {
    /// Gets the APNs token and notification taps (UIKit only hands those to a delegate).
    @UIApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @State private var model = AppModel()
    @Environment(\.scenePhase) private var scenePhase

    var body: some Scene {
        WindowGroup {
            RootView()
                .environment(model)
                .task {
                    model.bootstrap()
                    // Launch argument used for automated screenshots: `-OPADemo YES`.
                    if UserDefaults.standard.bool(forKey: "OPADemo"), !model.isDemo { model.enterDemo() }
                    // Hands over the push token / notification tap that arrived before the model existed.
                    appDelegate.attach(model)
                    #if DEBUG
                    // Automated end-to-end tests: `-OPAPairLink opa://pair?d=…` (simulator can't tap the "Open in" prompt).
                    if let link = UserDefaults.standard.string(forKey: "OPAPairLink"), model.pairedHost == nil { model.pair(with: link) }
                    await presentLaunchSheets()
                    #endif
                }
                .onOpenURL { url in handle(url) }
                .onChange(of: scenePhase) { _, phase in model.scenePhaseChanged(phase) }
                .task(id: scenePhase) {
                    // Refresh the device context every 15 minutes while in the foreground.
                    guard scenePhase == .active else { return }
                    while !Task.isCancelled {
                        try? await Task.sleep(for: .seconds(15 * 60))
                        guard !Task.isCancelled else { break }
                        await model.sendContext()
                    }
                }
        }
    }

    #if DEBUG
    /// Launch-argument helpers for screenshots and end-to-end runs (none of them exist in release builds):
    /// - `-OPAOpenTask t1`, `-OPAOpenApproval ap1`, `-OPAShowActivity YES`, `-OPAShowConnection YES`:
    ///   open the task page / a global sheet shortly after launch;
    /// - `-OPASend "text"` (optionally `-OPASendAfter 5`): send a chat message, as if typed, after that many seconds
    ///   (immediately by default, which exercises the offline queue when the Mac is not connected yet).
    @MainActor
    private func presentLaunchSheets() async {
        let d = UserDefaults.standard
        if let text = d.string(forKey: "OPASend") {
            let delay = d.double(forKey: "OPASendAfter")
            if delay > 0 { try? await Task.sleep(for: .seconds(delay)) }
            model.send(text: text, attachments: [])
        }
        let task = d.string(forKey: "OPAOpenTask")
        let approval = d.string(forKey: "OPAOpenApproval")
        let activity = d.bool(forKey: "OPAShowActivity")
        let connection = d.bool(forKey: "OPAShowConnection")
        guard task != nil || approval != nil || activity || connection else { return }
        try? await Task.sleep(for: .milliseconds(900))
        if let task { model.openTask(task) }
        if let approval { model.openApproval(approval) }
        else if activity { model.showActivity = true }
        else if connection { model.showConnection = true }
    }
    #endif

    private func handle(_ url: URL) {
        guard url.scheme == "opa" else { return }
        switch url.host {
        case "pair":
            model.pair(with: url.absoluteString)
        case "task":
            // opa://task?id=…  (Live Activity / Dynamic Island taps)
            if let id = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems?.first(where: { $0.name == "id" })?.value,
               model.pairedHost != nil || model.isDemo {
                model.openTask(id)
            }
        case "import":
            // opa://import?text=…&url=…  (Shortcuts / other apps). Lands in the chat composer tray so the
            // user can add a note before sending.
            let q = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems ?? []
            var items: [DraftItem] = []
            if let link = q.first(where: { $0.name == "url" })?.value { items += DraftItem.fromPasted(link) }
            if let text = q.first(where: { $0.name == "text" })?.value { items += DraftItem.fromPasted(text) }
            model.addToDraft(items)
        default:
            break
        }
    }
}

struct RootView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    /// A new `opa://pair` link while already paired must still show the code check (SAS), not skip it.
    private var isConfirmingNewPairing: Bool {
        if case .awaitingPairConfirm = model.connection { return true }
        return false
    }

    var body: some View {
        ZStack(alignment: .top) {
            if UserDefaults.standard.bool(forKey: "OPAGallery") {
                // Debug: `-OPAGallery YES` shows the design-system gallery (keep this hook).
                DesignGallery()
            } else if (model.pairedHost != nil || model.isDemo) && !isConfirmingNewPairing {
                MainTabView()
                    .transition(.opacity.combined(with: .scale(scale: 0.98)))
            } else {
                PairingView()
                    .transition(.opacity)
            }
            if let toast = model.toast {
                Text(toast)
                    .font(.subheadline.weight(.medium))
                    .padding(.horizontal, Space.l)
                    .padding(.vertical, 10)
                    .background(.regularMaterial, in: .capsule)
                    .overlay { Capsule().strokeBorder(Color.hairline, lineWidth: 0.5) }
                    .elevation(2)
                    .padding(.top, Space.s)
                    .transition(.move(edge: .top).combined(with: .opacity))
                    .zIndex(10)
                    .accessibilityAddTraits(.updatesFrequently)
            }
        }
        .animation(MotionAware(reduce: reduceMotion).spring, value: model.pairedHost != nil || model.isDemo)
        .tint(Color.accentColor)
    }
}

/// A sheet presented from the root (any tab can ask for one by setting model state).
private enum GlobalSheet: Identifiable, Equatable {
    case approval(String)
    case activity
    case connection

    var id: String {
        switch self {
        case .approval(let id): "approval:" + id
        case .activity: "activity"
        case .connection: "connection"
        }
    }
}

struct MainTabView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        @Bindable var model = model
        TabView(selection: $model.selectedTab) {
            Tab("对话", systemImage: "bubble.left.and.text.bubble.right", value: AppTab.chat) {
                ChatView()
            }
            Tab("任务", systemImage: "checklist", value: AppTab.tasks) {
                NavigationStack(path: $model.tasksPath) {
                    TasksView()
                        .navigationDestination(for: String.self) { TaskDetailView(taskId: $0) }
                }
            }
            .badge(model.attentionItems.count)
            Tab("设置", systemImage: "gearshape", value: AppTab.settings) {
                SettingsView()
            }
        }
        .tint(Color.accentColor)
        .sensoryFeedback(.selection, trigger: model.selectedTab)
        .onChange(of: model.chatFocusRequest) { _, _ in model.selectedTab = .chat }
        .sheet(item: globalSheet) { sheet in
            switch sheet {
            case .approval(let id): ApprovalSheet(approvalId: id)
            case .activity: ActivitySheet()
            case .connection: ConnectionSheet()
            }
        }
    }

    /// One sheet at a time: the model keeps three independent flags, the root shows the most specific one
    /// (a confirm request replaces the activity / connection sheet instead of fighting it).
    private var globalSheet: Binding<GlobalSheet?> {
        Binding {
            if let id = model.presentedApprovalId { return .approval(id) }
            if model.showActivity { return .activity }
            if model.showConnection { return .connection }
            return nil
        } set: { newValue in
            if newValue == nil { model.dismissGlobalSheets() }
        }
    }
}
