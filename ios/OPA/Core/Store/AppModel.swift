import Foundation
import Observation
import SwiftUI

/// The backend the UI talks to: the real connection or the demo mock.
@MainActor
protocol HostBackend: AnyObject {
    func request(_ m: String, _ d: JSONValue, timeout: Duration) async throws -> JSONValue
}

/// The app's state and actions. Everything is `@MainActor`; views read it through `@Environment(AppModel.self)`.
///
/// The logic lives in extensions next to this file (stored properties must be declared here):
/// - `AppModel+Events`: inbound frames → state (`handle`, `apply`, live events)
/// - `AppModel+Chat`: timeline, sending, delivery states, streaming, `stopReply`
/// - `AppModel+Tasks`: task groups, clearing, cancelling, task navigation
/// - `AppModel+Approvals`: pending approvals, status, `respond`, expiry
/// - `AppModel+Settings`: settings sync with rollback, memory, devices, models
/// - `AppModel+Connection`: `presence`, `connectionInfo`, connection state handling, host clock
@MainActor
@Observable
final class AppModel {
    // MARK: Connection & pairing

    var connection: ConnectionState = .idle
    var pairedHost: PairedHost?
    var hostName: String?
    var isDemo: Bool = false
    var pairingSAS: String?
    var pairingError: String?
    /// When the current / last connection to the Mac was established.
    var lastConnectedAt: Date?
    /// The last time anything arrived from the Mac while connected.
    var lastSeenOnlineAt: Date?

    // MARK: Chat

    /// The chat timeline, ordered by arrival (see `TimelineStore`). Read it through `timeline`.
    var timelineStore = TimelineStore()
    /// Ids of assistant messages that are still streaming (changes on start/end only, not per delta).
    var streamingIds: Set<String> = []
    var butlerState: ButlerState = .idle
    /// A human phrase for what the bot is doing ("派出任务"), from `butler.status`.
    var butlerDetail: String?
    /// The raw tool name behind `butlerDetail`, when the host sends it.
    var butlerTool: String?
    var outboxCount = 0
    var toast: String?
    /// True while `chat.clear` is in flight; prevents duplicate host requests.
    var isClearingChat = false
    /// Items waiting in the chat composer tray (photos, files, links, reminders). Lives on the model so
    /// drag & drop and `opa://import` can land here from anywhere.
    var draftItems: [DraftItem] = []
    var draftText = ""
    /// Bumped to ask the UI to switch to the chat tab (e.g. after `opa://import`).
    var chatFocusRequest = 0

    // MARK: Host state

    var tasks: [String: OPATask] = [:]
    var sessions: [String: OPASession] = [:]
    var approvals: [String: Approval] = [:]
    var resolvedApprovals: [String: ApprovalResolution] = [:]
    var sessionProgress: [String: String] = [:]
    /// Approvals whose `approval.respond` is in flight (double-submit guard; also drives `.submitting`).
    var submittingApprovals: Set<String> = []
    /// The last submit error per approval (drives `.failed`).
    var approvalFailures: [String: String] = [:]
    /// Tasks whose cancel request was sent but not yet confirmed by the host ("正在取消…").
    var cancellingTaskIds: Set<String> = []
    /// Tasks the host removed (`task.remove`). Later events about them (or their sessions) are ignored, and cards
    /// that point at them can say "任务已清除" instead of loading forever.
    var removedTaskIds: Set<String> = []
    /// Bumped when an approval's expiry time passes so derived values are re-read.
    var expiryTick = 0

    // MARK: Settings, memory, devices

    var settings = Settings()
    var settingsSync: SettingsSyncState = .idle
    var models: ModelsList?
    var memories: [Memory] = []
    /// Bumped on every `memory.changed` event; screens observe it (`.task(id:)`) to reload.
    var memoryRevision = 0
    var devices: [PairedDevice] = []
    var imports: [ImportRecord] = []

    // MARK: Notifications

    /// What the system lets Orbit do with notifications; nil until first read (see `refreshPushPermission`).
    var pushPermission: NotificationPermission?

    // MARK: Navigation & global presentation

    /// Drives the root `TabView`.
    var selectedTab: AppTab = .chat
    /// Task detail push stack of the tasks tab (task ids).
    var tasksPath: [String] = []
    /// The global confirm sheet, mounted by the root view.
    var presentedApprovalId: String?
    /// The "活动与权限" sheet.
    var showActivity = false
    /// The connection details sheet.
    var showConnection = false

    // MARK: Bookkeeping (not observed)

    @ObservationIgnored var lastSeq: Int64 = 0
    /// Counter for the sort keys of items shown before the host has numbered them (see `TimelineStore`).
    @ObservationIgnored var localOrderCounter = 0
    @ObservationIgnored var isReplaying = false
    /// Task ids removed by events while replaying the stored log (their Live Activities are ended once, afterwards).
    @ObservationIgnored var replayRemovedTaskIds: Set<String> = []
    @ObservationIgnored var inFlightDeliveries: Set<String> = []
    /// Incremented at each accepted chat clear so completions from older `chat.send` requests are inert.
    @ObservationIgnored var chatGeneration = 0
    /// Late echoes/finals from work that was pending at a clear barrier must not restore erased history.
    @ObservationIgnored var clearedClientIds: Set<String> = []
    @ObservationIgnored var clearedStreamIds: Set<String> = []
    @ObservationIgnored var lastChatClearSeq: Int64 = 0
    @ObservationIgnored var chatClearPersistencePending = false
    /// Bumped on every stream delta / start; the "idle and quiet for 3 s" check compares it.
    @ObservationIgnored var streamActivityToken = 0
    @ObservationIgnored var streamIdleTask: Task<Void, Never>?
    /// Replies we closed ourselves (connection lost, bot idle) rather than because their final message arrived.
    /// More deltas for one of them mean it is still being written, so it streams again.
    @ObservationIgnored var streamsClosedLocally: Set<String> = []
    @ObservationIgnored var expiryTask: Task<Void, Never>?
    @ObservationIgnored var memoryReloadTask: Task<Void, Never>?
    @ObservationIgnored var savedResetTask: Task<Void, Never>?
    /// The settings the host last confirmed. `settings` is this plus the still-unconfirmed optimistic patches.
    @ObservationIgnored var serverSettings = Settings()
    @ObservationIgnored var pendingSettingsPatches: [(id: Int, patch: JSONValue)] = []
    @ObservationIgnored var settingsPatchCounter = 0
    @ObservationIgnored var settingsBatchError: String?
    /// Mac clock minus phone clock, from `ping` round trips. Approval expiry is a host timestamp.
    @ObservationIgnored var hostClockOffsetMs: Int64 = 0
    /// Injectable clock (Unix ms) for tests.
    @ObservationIgnored var nowMs: () -> Int64 = { Clock.nowMs }
    /// How long a reply may sit "streaming" after the bot went idle before it is closed.
    @ObservationIgnored var streamIdleGrace: Duration = .seconds(3)
    /// How long "正在取消…" may stay up while the Mac has not confirmed a cancel.
    @ObservationIgnored var cancelConfirmationGrace: Duration = .seconds(45)
    /// Tests inject a fake host here.
    @ObservationIgnored var backendOverride: (any HostBackend)?
    @ObservationIgnored var demo: MockHost?
    /// The last alert / pushToStart token by kind. The Mac gets them again after every reconnect: it may have lost them.
    @ObservationIgnored var pushTokens: [String: String] = [:]
    /// The first-connection permission prompt (and token upload) that is under way.
    @ObservationIgnored var pushSetupTask: Task<Void, Never>?
    /// A tapped confirm notification waiting for the request's details to arrive (see `handleNotificationTap`).
    @ObservationIgnored var approvalTapTask: Task<Void, Never>?
    /// How long such a tap waits for the Mac before the sheet opens anyway.
    @ObservationIgnored var approvalTapGrace: Duration = .seconds(6)
    /// Bumped each time the catch-up sync after (re)connecting is done.
    @ObservationIgnored var syncCompletions = 0

    var deviceName: String {
        didSet {
            defaults.set(deviceName, forKey: "opa.deviceName")
            connectionManager.deviceName = deviceName
        }
    }

    var canUseHost: Bool { isDemo || connection.isConnected }

    // MARK: Dependencies

    let identity: DeviceIdentity
    let persistence: Persistence
    let connectionManager: ConnectionManager
    let liveActivities: any TaskActivityControlling
    let context = DeviceContextService()
    let attachmentCache: AttachmentCache
    let pushNotifications: any PushNotificationControlling
    let defaults: UserDefaults

    enum DefaultsKey {
        static let demo = "opa.demo"
        static let lastSeq = "opa.lastSeq"
        static let settings = "opa.settings"
        static let deviceName = "opa.deviceName"
        static let lastConnectedAt = "opa.lastConnectedAt"
        static let lastSeenOnlineAt = "opa.lastSeenOnlineAt"
        static let chatClearSeq = "opa.chatClearSeq"
        static let chatClearPersistencePending = "opa.chatClearPersistencePending"
        static let clearedChatClientIds = "opa.clearedChatClientIds"
        static let clearedChatStreamIds = "opa.clearedChatStreamIds"
    }

    init(inMemory: Bool = false, defaults: UserDefaults = .standard, backend: (any HostBackend)? = nil,
         liveActivities: (any TaskActivityControlling)? = nil, pushNotifications: (any PushNotificationControlling)? = nil) {
        self.defaults = defaults
        self.pushNotifications = pushNotifications ?? SystemPushNotifications()
        let identity = IdentityStore.loadOrCreate()
        self.identity = identity
        persistence = Persistence(inMemory: inMemory)
        attachmentCache = AttachmentCache(inMemory: inMemory)
        let name = defaults.string(forKey: DefaultsKey.deviceName) ?? "iPhone"
        deviceName = name
        connectionManager = ConnectionManager(identity: identity, deviceName: name)
        self.liveActivities = liveActivities ?? LiveActivityController()
        backendOverride = backend
        lastSeq = Int64(defaults.integer(forKey: DefaultsKey.lastSeq))
        lastChatClearSeq = Int64(defaults.integer(forKey: DefaultsKey.chatClearSeq))
        chatClearPersistencePending = defaults.bool(forKey: DefaultsKey.chatClearPersistencePending)
        clearedClientIds = Set(defaults.stringArray(forKey: DefaultsKey.clearedChatClientIds) ?? [])
        clearedStreamIds = Set(defaults.stringArray(forKey: DefaultsKey.clearedChatStreamIds) ?? [])
        if let data = defaults.data(forKey: DefaultsKey.settings), let s = try? JSONDecoder().decode(Settings.self, from: data) {
            settings = s
            serverSettings = s
        }
        lastConnectedAt = (defaults.object(forKey: DefaultsKey.lastConnectedAt) as? Double).map(Date.init(timeIntervalSince1970:))
        lastSeenOnlineAt = (defaults.object(forKey: DefaultsKey.lastSeenOnlineAt) as? Double).map(Date.init(timeIntervalSince1970:))
        // Launch argument for automated screenshots: `-OPATab tasks|settings`.
        if let raw = UserDefaults.standard.string(forKey: "OPATab"), let tab = AppTab(rawValue: raw) { selectedTab = tab }
        wireConnection()
        self.liveActivities.onPushToken = { [weak self] kind, token, activityId, taskId in
            self?.registerPush(kind: kind, token: token, activityId: activityId, taskId: taskId)
        }
    }

    // MARK: Lifecycle

    func bootstrap() {
        if defaults.bool(forKey: DefaultsKey.demo) {
            enterDemo()
            return
        }
        pairedHost = PairedHost.load(from: defaults)
        hostName = pairedHost?.hostName
        replayStoredEvents()
        refreshOutboxCount()
        showOutboxMessages()
        imports = persistence.imports()
        liveActivities.reconcile(tasks: Array(tasks.values))
        rescheduleExpiry()
        if let host = pairedHost { connectionManager.start(host: host) }
        liveActivities.observePushToStart()
    }

    func scenePhaseChanged(_ phase: ScenePhase) {
        switch phase {
        case .active:
            expiryTick += 1
            rescheduleExpiry()
            // Notifications may have been switched on in the system settings while we were away.
            Task { await refreshPushPermission() }
            if isDemo { return }
            connectionManager.kick()
            Task { await sendContext() }
        case .background:
            persistence.saveNow()
            persistConnectionTimes()
        default: break
        }
    }

    private func wireConnection() {
        connectionManager.onState = { [weak self] s in self?.connectionStateChanged(s) }
        connectionManager.onMessage = { [weak self] m in self?.handle(m) }
        connectionManager.onPaired = { [weak self] host in
            guard let self else { return }
            withAnimation(.spring(response: 0.45, dampingFraction: 0.85)) {
                self.pairedHost = host
                self.hostName = host.hostName
                self.pairingSAS = nil
                self.pairingError = nil
            }
        }
        connectionManager.onSessionReady = { [weak self] in await self?.sessionReady() }
        connectionManager.onPong = { [weak self] sample in self?.recordPong(sample) }
    }

    /// After every successful handshake: end replies that were cut off by the drop, calibrate the Mac's clock,
    /// catch up on missed events, push tokens and notification permission, then send what was queued while offline.
    private func sessionReady() async {
        finishAllStreaming()
        butlerState = .idle
        butlerDetail = nil
        butlerTool = nil
        await calibrateHostClock()
        await sync()
        syncCompletions += 1
        startPushSetup()
        await flushOutbox()
        await sendContext()
        async let s: Void = loadSettings()
        async let m: Void = loadModels()
        _ = await (s, m)
        liveActivities.reconcile(tasks: Array(tasks.values))
        rescheduleExpiry()
    }

    // MARK: Pairing

    func pair(with link: String) {
        pairingError = nil
        do {
            let p = try PairingPayload.parse(link)
            if let existing = pairedHost, existing.hostId != p.hostId { resetLocalData() }
            hostName = p.hostName
            connectionManager.startPairing(p)
        } catch {
            pairingError = error.localizedDescription
        }
    }

    func cancelPairing() {
        connectionManager.stop()
        pairingSAS = nil
        if let host = pairedHost { connectionManager.start(host: host) }
    }

    func unpair() {
        connectionManager.stop()
        PairedHost.clear(from: defaults)
        resetLocalData()
        liveActivities.endAll()
        exitDemo()
        defaults.removeObject(forKey: DefaultsKey.lastConnectedAt)
        defaults.removeObject(forKey: DefaultsKey.lastSeenOnlineAt)
        lastConnectedAt = nil
        lastSeenOnlineAt = nil
        selectedTab = .chat
        withAnimation { pairedHost = nil; hostName = nil }
    }

    private func resetLocalData() {
        persistence.wipe()
        clearState()
        lastSeq = 0
        lastChatClearSeq = 0
        chatClearPersistencePending = false
        clearedClientIds = []
        clearedStreamIds = []
        defaults.set(0, forKey: DefaultsKey.lastSeq)
        defaults.removeObject(forKey: DefaultsKey.chatClearSeq)
        defaults.removeObject(forKey: DefaultsKey.chatClearPersistencePending)
        defaults.removeObject(forKey: DefaultsKey.clearedChatClientIds)
        defaults.removeObject(forKey: DefaultsKey.clearedChatStreamIds)
        imports = []
        attachmentCache.wipe()
        refreshOutboxCount()
    }

    /// Forgets everything derived from host events (timeline, tasks, approvals, live state).
    func clearState() {
        timelineStore.removeAll()
        streamingIds = []
        streamsClosedLocally = []
        localOrderCounter = 0
        streamIdleTask?.cancel()
        expiryTask?.cancel()
        tasks = [:]; sessions = [:]; approvals = [:]; resolvedApprovals = [:]; sessionProgress = [:]
        submittingApprovals = []; approvalFailures = [:]; cancellingTaskIds = []; removedTaskIds = []
        butlerState = .idle; butlerDetail = nil; butlerTool = nil
        presentedApprovalId = nil
        showActivity = false
        showConnection = false
        tasksPath = []
        hostClockOffsetMs = 0
    }

    // MARK: Demo mode

    func enterDemo() {
        connectionManager.stop()
        defaults.set(true, forKey: DefaultsKey.demo)
        clearState()
        lastSeq = 0   // demo uses its own sequence space; the real lastSeq stays in UserDefaults
        lastChatClearSeq = 0
        chatClearPersistencePending = false
        clearedClientIds = []
        clearedStreamIds = []
        isDemo = true
        let mock = MockHost(model: self)
        demo = mock
        hostName = "演示 Mac"
        connection = .connected(.lan)
        lastConnectedAt = Date()
        lastSeenOnlineAt = Date()
        mock.start()
    }

    func exitDemo() {
        guard isDemo else { return }
        defaults.set(false, forKey: DefaultsKey.demo)
        demo?.stop()
        demo = nil
        isDemo = false
        liveActivities.endAll()
        clearState()
        lastSeq = Int64(defaults.integer(forKey: DefaultsKey.lastSeq))
        lastChatClearSeq = Int64(defaults.integer(forKey: DefaultsKey.chatClearSeq))
        chatClearPersistencePending = defaults.bool(forKey: DefaultsKey.chatClearPersistencePending)
        clearedClientIds = Set(defaults.stringArray(forKey: DefaultsKey.clearedChatClientIds) ?? [])
        clearedStreamIds = Set(defaults.stringArray(forKey: DefaultsKey.clearedChatStreamIds) ?? [])
        connection = .idle
        bootstrap()
    }

    // MARK: Requests

    var backend: (any HostBackend)? {
        if let backendOverride { return backendOverride }
        return isDemo ? demo : connectionManager
    }

    @discardableResult
    func request(_ m: String, _ d: JSONValue = [:], timeout: Duration = .seconds(20)) async throws -> JSONValue {
        guard let backend else { throw OPAError.notConnected }
        return try await backend.request(m, d, timeout: timeout)
    }

    func showToast(_ text: String) {
        withAnimation(.spring(response: 0.35, dampingFraction: 0.85)) { toast = text }
        Task {
            try? await Task.sleep(for: .seconds(2.5))
            withAnimation(.easeOut(duration: 0.25)) { if self.toast == text { self.toast = nil } }
        }
    }

    // MARK: Sync

    func sync() async {
        do {
            let res = try await request("sync", ["lastSeq": .number(Double(lastSeq))], timeout: .seconds(30))
            let barrier = res["chatCleared"]
            let barrierSeq = barrier?["seq"]?.int64
            let barrierClearedAt = barrier?["clearedAt"]?.int64
            let resetAttachmentIds: Set<String>
            if res["reset"]?.bool == true, let barrierSeq, barrierSeq > 0, let barrierClearedAt {
                resetAttachmentIds = chatAttachmentClientIds(through: barrierSeq, clearedAt: barrierClearedAt)
            } else {
                resetAttachmentIds = []
            }
            if res["reset"]?.bool == true {
                persistence.clearEvents()
                clearState()
                lastSeq = 0
                defaults.set(0, forKey: DefaultsKey.lastSeq)
            }
            if barrier != nil, let seq = barrierSeq, seq > 0, let clearedAt = barrierClearedAt {
                _ = applyChatClear(seq: seq, ts: clearedAt,
                                   payload: ["clearedAt": .number(Double(clearedAt))], animated: false,
                                   additionalAttachmentClientIds: resetAttachmentIds)
            }
            // The host answers first and then streams the missed events. Wait (briefly) until they are in, so that the
            // outbox flush that follows does not resend a message whose echo is still on its way, and so that messages
            // still waiting in the outbox are placed *after* the history (their sort key is relative to `lastSeq`).
            if let top = res["toSeq"]?.int64, top > lastSeq { await waitForSeq(top, timeout: .seconds(3)) }
        } catch {
            // Sync failure is not fatal; next reconnect retries.
        }
        showOutboxMessages()
    }

    func waitForSeq(_ seq: Int64, timeout: Duration) async {
        let deadline = ContinuousClock.now + timeout
        while lastSeq < seq, ContinuousClock.now < deadline {
            try? await Task.sleep(for: .milliseconds(25))
        }
    }

    func replayStoredEvents() {
        isReplaying = true
        defer { isReplaying = false }
        var echoed: Set<String> = []
        for e in persistence.allEvents() {
            guard let d = try? JSONValue(data: e.payload) else { continue }
            if e.seq <= lastChatClearSeq, Self.isChatHistoryEvent(e.k) { continue }
            apply(k: e.k, d: d, ts: e.ts, seq: e.seq, animated: false)
            if e.k == "msg.user", let clientId = Self.clientId(of: d) { echoed.insert(clientId) }
        }
        // A message the host already echoed no longer belongs in the outbox (one pass instead of one fetch per event).
        if !echoed.isEmpty {
            for item in persistence.outbox() where echoed.contains(item.clientId) { persistence.removeOutbox(clientId: item.clientId) }
        }
        // Tasks removed while the app was not running may still have a Live Activity on the lock screen: one call, not one per event.
        if !replayRemovedTaskIds.isEmpty {
            liveActivities.end(taskIds: Array(replayRemovedTaskIds), immediately: true)
            replayRemovedTaskIds = []
        }
        rescheduleExpiry()
    }

    // MARK: Context & push

    func sendContext() async {
        guard canUseHost else { return }
        let ctx = await context.snapshot(deviceName: deviceName)
        if let v = try? JSONValue(encoding: ctx) { _ = try? await request("context.update", v) }
    }

    /// Tells the Mac a push token of this phone (`push.register`): "alert" (from `AppDelegate`), "pushToStart" and
    /// "liveactivity" (from `LiveActivityController`). `env` and `bundleId` tell it which APNs and topic to use.
    func registerPush(kind: String, token: String, activityId: String?, taskId: String?) {
        // Alert and push-to-start tokens: the Mac keeps one per phone, and needs it again whenever it may have lost it.
        if kind == "alert" || kind == "pushToStart" { pushTokens[kind] = token }
        var o: [String: JSONValue] = ["kind": .string(kind), "token": .string(token), "env": .string(PushRegistrar.environment)]
        if let bundleId = PushRegistrar.bundleId { o["bundleId"] = .string(bundleId) }
        if let activityId { o["activityId"] = .string(activityId) }
        if let taskId { o["taskId"] = .string(taskId) }
        Task { _ = try? await request("push.register", .object(o)) }
    }

    // MARK: Import

    func importItems(_ items: [ImportItem]) async -> Bool {
        guard !items.isEmpty else { return false }
        let delivered: Bool
        do {
            try await request("import.add", ["items": try JSONValue(encoding: items)], timeout: .seconds(60))
            delivered = true
        } catch {
            showToast("导入失败：\(error.localizedDescription)")
            delivered = false
        }
        for item in items {
            let r = ImportRecord(id: ShortID.make(), kind: item.kind.rawValue,
                                 title: item.title ?? item.url ?? String((item.text ?? "").prefix(40)),
                                 detail: item.kind == .photo ? (item.mime ?? "image/jpeg") : (item.text ?? item.url ?? ""),
                                 createdAt: Clock.nowMs, delivered: delivered)
            if isDemo { imports.insert(r, at: 0) } else { persistence.addImport(r) }
        }
        if !isDemo { withAnimation(spring) { imports = persistence.imports() } }
        return delivered
    }

    // MARK: Helpers

    nonisolated static func isChatHistoryEvent(_ kind: String) -> Bool {
        ["msg.user", "msg.assistant", "ui.render", "ui.patch"].contains(kind)
    }

    var spring: Animation { .spring(response: 0.4, dampingFraction: 0.85) }

    static func nonEmpty(_ s: String?) -> String? {
        guard let s, !s.isEmpty else { return nil }
        return s
    }

    /// The client id of a `msg.user` payload (falls back to the host message id, then nil).
    static func clientId(of d: JSONValue) -> String? {
        nonEmpty(d["clientId"]?.string) ?? nonEmpty(d["id"]?.string)
    }
}
