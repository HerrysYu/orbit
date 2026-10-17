import UserNotifications
import XCTest
@testable import OPA

/// Answers for the notification system and counts what the model asks of it.
@MainActor
final class SpyPushNotifications: PushNotificationControlling {
    var status: UNAuthorizationStatus
    /// What the person answers when the system prompt appears.
    var allows: Bool
    private(set) var prompts = 0
    private(set) var registrations = 0

    init(status: UNAuthorizationStatus, allows: Bool = true) {
        self.status = status
        self.allows = allows
    }

    func authorizationStatus() async -> UNAuthorizationStatus { status }

    func requestAuthorization() async -> Bool {
        prompts += 1
        status = allows ? .authorized : .denied
        return allows
    }

    func registerForRemoteNotifications() { registrations += 1 }
}

/// Push tokens (which APNs, which topic, sent again after reconnecting), notification permission, taps on notifications.
@MainActor
final class PushTests: XCTestCase {
    // MARK: Helpers

    /// The bytes of an `embedded.mobileprovision`: binary CMS junk around an XML property list, as in the real file.
    private func profile(aps: String?, outerAps: String? = nil) -> Data {
        var entitlements = "<key>application-identifier</key><string>6K6QZX2QN7.com.haoyuanyu.orbit</string>"
        if let aps { entitlements += "<key>aps-environment</key><string>\(aps)</string>" }
        let outer = outerAps.map { "<key>aps-environment</key><string>\($0)</string>" } ?? ""
        let xml = """
        <?xml version="1.0" encoding="UTF-8"?>
        <!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
        <plist version="1.0"><dict>
        <key>Name</key><string>iOS Team Provisioning Profile: com.haoyuanyu.orbit</string>
        <key>ProvisionedDevices</key><array><string>00008140-001A2B3C4D5E6F70</string></array>
        <key>Entitlements</key><dict>\(entitlements)</dict>
        \(outer)
        </dict></plist>
        """
        var data = Data([0x30, 0x80, 0x06, 0x09, 0x2a, 0x86, 0x48, 0x86, 0xf7, 0x0d, 0x01, 0x07, 0x02, 0xa0, 0x80, 0x30, 0x82, 0xff, 0xfe])
        data.append(Data(xml.utf8))
        data.append(Data([0x31, 0x82, 0x01, 0x00, 0xde, 0xad, 0xbe, 0xef, 0x00, 0xff, 0x80]))
        return data
    }

    private func pairedHost() -> PairedHost {
        PairedHost(payload: PairingPayload(v: 1, hostId: "h", hostPub: "", hostName: "Mac", lan: [], relay: nil, pairToken: nil, exp: nil))
    }

    private func makeModel(_ push: SpyPushNotifications = SpyPushNotifications(status: .authorized), host: FakeHost = FakeHost(),
                           paired: Bool = true) -> AppModel {
        let defaults = UserDefaults(suiteName: "opa.tests." + UUID().uuidString)!
        let model = AppModel(inMemory: true, defaults: defaults, backend: host, liveActivities: SpyActivities(), pushNotifications: push)
        model.connection = .connected(.lan)
        if paired { model.pairedHost = pairedHost() }
        return model
    }

    // MARK: APNs environment

    func testADevelopmentProfileMeansSandbox() {
        XCTAssertEqual(PushRegistrar.environment(provisioningProfile: profile(aps: "development"), isSimulator: false), "sandbox")
    }

    func testAProductionProfileMeansProduction() {
        XCTAssertEqual(PushRegistrar.environment(provisioningProfile: profile(aps: "production"), isSimulator: false), "production")
    }

    func testNoProfileMeansProduction() {
        // App Store and TestFlight builds carry no embedded.mobileprovision.
        XCTAssertEqual(PushRegistrar.environment(provisioningProfile: nil, isSimulator: false), "production")
    }

    func testTheSimulatorIsAlwaysSandbox() {
        XCTAssertEqual(PushRegistrar.environment(provisioningProfile: nil, isSimulator: true), "sandbox")
        XCTAssertEqual(PushRegistrar.environment(provisioningProfile: profile(aps: "production"), isSimulator: true), "sandbox")
    }

    func testAProfileWeCannotReadCountsAsProduction() {
        let noEntry = profile(aps: nil)
        let truncated = Data(String(decoding: profile(aps: "development"), as: UTF8.self).dropLast(120).utf8)
        let notAPlist = Data("junk <?xml version=\"1.0\"?> not a plist </plist> junk".utf8)
        for bad in [Data(), Data([0x30, 0x82, 0x00]), noEntry, truncated, notAPlist] {
            XCTAssertEqual(PushRegistrar.environment(provisioningProfile: bad, isSimulator: false), "production")
        }
    }

    func testOnlyTheEntitlementsDecide() {
        // An `aps-environment` key outside `Entitlements` means nothing.
        let data = profile(aps: "production", outerAps: "development")
        XCTAssertEqual(PushRegistrar.apsEnvironment(inProvisioningProfile: data), "production")
        XCTAssertEqual(PushRegistrar.environment(provisioningProfile: data, isSimulator: false), "production")
    }

    func testTheRunningBuildAnswersForItself() {
        #if targetEnvironment(simulator)
        XCTAssertEqual(PushRegistrar.environment, "sandbox")
        #endif
        XCTAssertEqual(PushRegistrar.bundleId, Bundle.main.bundleIdentifier)
        XCTAssertNotNil(PushRegistrar.bundleId)
    }

    // MARK: Payload and foreground presentation

    func testThePayloadCarriesTheApprovalId() {
        let confirm = PushPayload(userInfo: ["aps": ["alert": ["title": "t"], "category": "OPA_APPROVAL"], "approvalId": "ap1"])
        XCTAssertEqual(confirm.approvalId, "ap1")
        XCTAssertNil(PushPayload(userInfo: ["aps": ["alert": ["title": "t"]]]).approvalId)
        XCTAssertNil(PushPayload(userInfo: ["approvalId": ""]).approvalId)
        XCTAssertNil(PushPayload(userInfo: ["approvalId": 7]).approvalId)
    }

    func testAConfirmRequestIsNotShownAsABannerWhileConnected() {
        let confirm = PushPayload(approvalId: "ap1")
        XCTAssertEqual(confirm.foregroundPresentation(connected: true), [])
        XCTAssertEqual(confirm.foregroundPresentation(connected: false), [.banner, .list, .sound])
        XCTAssertEqual(PushPayload().foregroundPresentation(connected: true), [.banner, .list, .sound])
        XCTAssertEqual(PushPayload().foregroundPresentation(connected: false), [.banner, .list, .sound])
    }

    func testPermissionMapping() {
        let expected: [(UNAuthorizationStatus, NotificationPermission, Bool)] = [
            (.notDetermined, .notDetermined, false), (.denied, .denied, false),
            (.authorized, .authorized, true), (.provisional, .provisional, true), (.ephemeral, .ephemeral, true),
        ]
        for (status, permission, allowed) in expected {
            XCTAssertEqual(NotificationPermission(status), permission)
            XCTAssertEqual(permission.isAllowed, allowed)
        }
    }

    // MARK: push.register

    func testEveryRegistrationCarriesTheEnvironmentAndTheBundleId() async {
        let host = FakeHost()
        let model = makeModel(host: host)
        model.registerPush(kind: "alert", token: "ab12", activityId: nil, taskId: nil)
        model.registerPush(kind: "liveactivity", token: "cd34", activityId: "act1", taskId: "t1")
        let sent = await waitUntil { host.calls("push.register").count == 2 }
        XCTAssertTrue(sent)
        for call in host.calls("push.register") {
            XCTAssertEqual(call.params["env"]?.string, PushRegistrar.environment)
            XCTAssertEqual(call.params["bundleId"]?.string, Bundle.main.bundleIdentifier)
        }
        let alert = host.calls("push.register")[0].params
        XCTAssertEqual(alert["kind"]?.string, "alert")
        XCTAssertEqual(alert["token"]?.string, "ab12")
        XCTAssertNil(alert["activityId"])
        let live = host.calls("push.register")[1].params
        XCTAssertEqual(live["activityId"]?.string, "act1")
        XCTAssertEqual(live["taskId"]?.string, "t1")
    }

    func testTheAlertAndPushToStartTokensAreSentAgainAfterReconnecting() async {
        let host = FakeHost()
        var reachable = false
        host.handler = { m, _ in
            if m == "push.register", !reachable { throw OPAError.notConnected }
            return [:]
        }
        let model = makeModel(host: host)
        model.registerPush(kind: "alert", token: "a1", activityId: nil, taskId: nil)
        model.registerPush(kind: "pushToStart", token: "p1", activityId: nil, taskId: nil)
        model.registerPush(kind: "liveactivity", token: "l1", activityId: "act", taskId: "t")
        var attempted = await waitUntil { host.calls("push.register").count == 3 }
        XCTAssertTrue(attempted, "all three were tried, none arrived")

        // The Mac is reachable again (possibly with a new database): what it needs again goes out once more.
        reachable = true
        model.registerPush(kind: "alert", token: "a2", activityId: nil, taskId: nil)   // the token rotated meanwhile
        attempted = await waitUntil { host.calls("push.register").count == 4 }
        XCTAssertTrue(attempted)
        model.startPushSetup()
        let resent = await waitUntil { host.calls("push.register").count == 6 }
        XCTAssertTrue(resent)
        let again = host.calls("push.register").suffix(2).map { ($0.params["kind"]?.string ?? "", $0.params["token"]?.string ?? "") }
        XCTAssertEqual(Set(again.map { $0.0 }), ["alert", "pushToStart"], "the Live Activity token is per activity: not replayed")
        XCTAssertEqual(again.first { $0.0 == "alert" }?.1, "a2", "the latest alert token")
        XCTAssertEqual(again.first { $0.0 == "pushToStart" }?.1, "p1")
        await model.pushSetupTask?.value
    }

    // MARK: Permission

    func testTheFirstConnectionAsksForPermissionAndThenRegisters() async {
        let push = SpyPushNotifications(status: .notDetermined, allows: true)
        let model = makeModel(push)
        model.startPushSetup()
        await model.pushSetupTask?.value
        XCTAssertEqual(push.prompts, 1)
        XCTAssertEqual(push.registrations, 1)
        XCTAssertEqual(model.pushPermission, .authorized)
        XCTAssertNil(model.pushSetupTask, "done")

        model.startPushSetup()   // the next reconnect: already decided, nothing more to ask
        await model.pushSetupTask?.value
        XCTAssertEqual(push.prompts, 1)
        XCTAssertEqual(push.registrations, 1)
    }

    func testRefusingThePromptDoesNotRegister() async {
        let push = SpyPushNotifications(status: .notDetermined, allows: false)
        let model = makeModel(push)
        model.startPushSetup()
        await model.pushSetupTask?.value
        XCTAssertEqual(push.prompts, 1)
        XCTAssertEqual(push.registrations, 0)
        XCTAssertEqual(model.pushPermission, .denied)
    }

    func testAnAlreadyDecidedPermissionIsNotAskedAgain() async {
        for status in [UNAuthorizationStatus.denied, .authorized, .provisional] {
            let push = SpyPushNotifications(status: status)
            let model = makeModel(push)
            model.startPushSetup()
            await model.pushSetupTask?.value
            XCTAssertEqual(push.prompts, 0, "\(status.rawValue)")
            XCTAssertEqual(push.registrations, 0, "AppDelegate registered at launch")
            XCTAssertEqual(model.pushPermission, NotificationPermission(status))
        }
    }

    func testTheDemoNeverShowsThePrompt() {
        let push = SpyPushNotifications(status: .notDetermined)
        let model = makeModel(push)
        model.isDemo = true
        model.startPushSetup()
        XCTAssertNil(model.pushSetupTask)
        XCTAssertEqual(push.prompts, 0)
    }

    func testTheSettingsButtonAsksOnlyWhenAsked() async {
        let push = SpyPushNotifications(status: .notDetermined, allows: true)
        let model = makeModel(push)
        let read = await model.refreshPushPermission()
        XCTAssertEqual(read, .notDetermined, "only looking")
        XCTAssertEqual(push.prompts, 0)
        let asked = await model.refreshPushPermission(ask: true)
        XCTAssertEqual(asked, .authorized)
        XCTAssertEqual(push.prompts, 1)
        XCTAssertEqual(push.registrations, 1)
    }

    func testSwitchingNotificationsOnInTheSystemSettingsRegisters() async {
        let push = SpyPushNotifications(status: .denied)
        let model = makeModel(push)
        await model.refreshPushPermission()   // the app came to the front: refused, as before
        XCTAssertEqual(model.pushPermission, .denied)
        XCTAssertEqual(push.registrations, 0)

        push.status = .authorized             // the person switched it on in the system settings
        await model.refreshPushPermission()
        XCTAssertEqual(model.pushPermission, .authorized)
        XCTAssertEqual(push.registrations, 1)

        await model.refreshPushPermission()   // nothing changed since: no second registration
        XCTAssertEqual(push.registrations, 1)
    }

    // MARK: Taps

    func testTappingAConfirmRequestOpensItsSheet() {
        let model = makeModel()
        model.ev(1, "approval.request", Payload.approval(id: "a1"))
        model.selectedTab = .tasks
        model.handleNotificationTap(PushPayload(approvalId: "a1"))
        XCTAssertEqual(model.presentedApprovalId, "a1")
    }

    func testTappingAnyOtherNotificationOpensTheChat() {
        let model = makeModel()
        model.selectedTab = .settings
        model.handleNotificationTap(PushPayload())
        XCTAssertEqual(model.selectedTab, .chat)
        XCTAssertNil(model.presentedApprovalId)
    }

    func testATapBeforePairingOpensNothing() {
        let model = makeModel(paired: false)
        model.ev(1, "approval.request", Payload.approval(id: "a1"))
        model.selectedTab = .settings
        model.handleNotificationTap(PushPayload(approvalId: "a1"))
        model.handleNotificationTap(PushPayload())
        XCTAssertNil(model.presentedApprovalId)
        XCTAssertEqual(model.selectedTab, .settings)
    }

    func testATapOnAConfirmRequestThatHasNotArrivedWaitsForIt() async {
        let model = makeModel()
        model.handleNotificationTap(PushPayload(approvalId: "a2"))
        XCTAssertNil(model.presentedApprovalId, "not before the Mac has said what it is: the sheet would read 已失效")
        model.ev(1, "approval.request", Payload.approval(id: "a2"))
        let opened = await waitUntil { model.presentedApprovalId == "a2" }
        XCTAssertTrue(opened)
    }

    func testATapStopsWaitingWhenTheSyncIsDoneWithoutIt() async {
        let model = makeModel()
        model.handleNotificationTap(PushPayload(approvalId: "gone"))
        try? await Task.sleep(for: .milliseconds(120))
        XCTAssertNil(model.presentedApprovalId, "still waiting")
        model.syncCompletions += 1   // the catch-up sync after reconnecting finished; the request is not among the events
        let opened = await waitUntil { model.presentedApprovalId == "gone" }
        XCTAssertTrue(opened, "then the sheet opens and says it is no longer valid")
    }

    func testATapStopsWaitingAfterTheGracePeriod() async {
        let model = makeModel()
        model.approvalTapGrace = .milliseconds(150)
        model.handleNotificationTap(PushPayload(approvalId: "slow"))
        XCTAssertNil(model.presentedApprovalId)
        let opened = await waitUntil { model.presentedApprovalId == "slow" }
        XCTAssertTrue(opened)
    }

    func testANewerTapReplacesAWaitingOne() async {
        let model = makeModel()
        model.approvalTapGrace = .milliseconds(100)
        model.handleNotificationTap(PushPayload(approvalId: "late"))
        model.selectedTab = .tasks
        model.handleNotificationTap(PushPayload())   // the person tapped another notification meanwhile
        XCTAssertEqual(model.selectedTab, .chat)
        try? await Task.sleep(for: .milliseconds(300))
        XCTAssertNil(model.presentedApprovalId, "the first tap no longer opens anything")
    }

    // MARK: Before the model exists (cold start)

    func testATokenThatArrivesBeforeTheModelIsHandedOverLater() async {
        let host = FakeHost()
        let model = makeModel(host: host)
        let delegate = AppDelegate()
        delegate.receive(deviceToken: Data([0xab, 0xcd, 0x01]))
        try? await Task.sleep(for: .milliseconds(50))
        XCTAssertTrue(host.calls("push.register").isEmpty, "nobody to tell yet")

        delegate.attach(model)
        let sent = await waitUntil { host.calls("push.register").count == 1 }
        XCTAssertTrue(sent)
        let call = host.calls("push.register")[0].params
        XCTAssertEqual(call["kind"]?.string, "alert")
        XCTAssertEqual(call["token"]?.string, "abcd01")
        XCTAssertEqual(call["bundleId"]?.string, Bundle.main.bundleIdentifier)

        delegate.attach(model)   // a second attach hands nothing over twice
        try? await Task.sleep(for: .milliseconds(50))
        XCTAssertEqual(host.calls("push.register").count, 1)
    }

    func testATapThatLaunchedTheAppIsHandedOverLater() {
        let model = makeModel()
        model.ev(1, "approval.request", Payload.approval(id: "a1"))
        let delegate = AppDelegate()
        delegate.receive(tap: PushPayload(approvalId: "a1"))
        XCTAssertNil(model.presentedApprovalId, "the model is not attached yet")

        delegate.attach(model)
        XCTAssertEqual(model.presentedApprovalId, "a1")

        model.dismissGlobalSheets()
        delegate.attach(model)
        XCTAssertNil(model.presentedApprovalId, "a tap is acted on once")
    }

    func testOnceAttachedTokensAndTapsGoStraightThrough() async {
        let host = FakeHost()
        let model = makeModel(host: host)
        let delegate = AppDelegate()
        delegate.attach(model)
        delegate.receive(deviceToken: Data([0x0f]))
        delegate.receive(tap: PushPayload())
        model.selectedTab = .tasks
        delegate.receive(tap: PushPayload())
        XCTAssertEqual(model.selectedTab, .chat)
        let sent = await waitUntil { host.calls("push.register").count == 1 }
        XCTAssertTrue(sent)
        XCTAssertEqual(host.calls("push.register")[0].params["token"]?.string, "0f")
    }

    func testTheForegroundBannerFollowsTheConnection() {
        let model = makeModel()
        let delegate = AppDelegate()
        let confirm = PushPayload(approvalId: "a1")
        XCTAssertEqual(delegate.foregroundPresentation(for: confirm), [.banner, .list, .sound], "no model yet: show it")
        delegate.attach(model)
        XCTAssertEqual(delegate.foregroundPresentation(for: confirm), [], "connected: the confirm sheet is in the app")
        XCTAssertEqual(delegate.foregroundPresentation(for: PushPayload()), [.banner, .list, .sound])
        model.connection = .hostOffline
        XCTAssertEqual(delegate.foregroundPresentation(for: confirm), [.banner, .list, .sound])
    }
}
