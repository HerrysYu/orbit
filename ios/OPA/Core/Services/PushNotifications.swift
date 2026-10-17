import Foundation
import UIKit
import UserNotifications
import os

private let log = Logger(subsystem: "com.haoyuanyu.orbit", category: "push")

// Push notifications: the "alert" token the Mac needs to reach this phone when the app is closed (confirm requests and
// Orbit's own messages), and what happens when one is tapped. The Live Activity tokens live in `LiveActivityController`.
//
// Flow: `AppDelegate` registers with APNs (when notifications are allowed) → the token arrives in `AppDelegate` →
// `AppModel.registerPush` sends it to the Mac (`push.register`) and sends it again after every reconnect.

// MARK: - APNs environment and topic

/// Facts about this build that `push.register` carries to the Mac, so it can reach this phone through the right APNs.
enum PushRegistrar {
    /// The APNs service this build's device tokens belong to: "sandbox" or "production".
    ///
    /// It follows what the app was *signed* with, not the build configuration. A Release build installed from Xcode
    /// carries a development profile, so its tokens are sandbox tokens; APNs answers a sandbox token sent to the
    /// production service (and the other way round) with BadDeviceToken.
    static let environment = environment(provisioningProfile: embeddedProfile, isSimulator: runsInSimulator)

    /// What the Mac uses as the APNs topic.
    static var bundleId: String? { Bundle.main.bundleIdentifier }

    /// "sandbox" or "production" for an app signed with `provisioningProfile` (the bytes of its
    /// `embedded.mobileprovision`, nil when the app has none).
    ///
    /// - The simulator always gets sandbox tokens.
    /// - No embedded profile: App Store and TestFlight builds are re-signed without one, and use production.
    /// - Otherwise the profile's `aps-environment` decides: development → sandbox, production → production. A profile
    ///   that cannot be read, or has no such entry, counts as production (a development build always has one).
    static func environment(provisioningProfile: Data?, isSimulator: Bool) -> String {
        if isSimulator { return "sandbox" }
        guard let provisioningProfile else { return "production" }
        return apsEnvironment(inProvisioningProfile: provisioningProfile) == "development" ? "sandbox" : "production"
    }

    /// The `aps-environment` entitlement ("development" or "production") of an `embedded.mobileprovision`.
    ///
    /// The file is a CMS (PKCS#7) envelope around an XML property list, and the list sits in it as plain text: cut out
    /// the part from `<?xml` to `</plist>` and parse that. The signature around it is not checked here.
    static func apsEnvironment(inProvisioningProfile profile: Data) -> String? {
        guard let start = profile.range(of: Data("<?xml".utf8)),
              let end = profile.range(of: Data("</plist>".utf8), in: start.upperBound..<profile.endIndex),
              let root = try? PropertyListSerialization.propertyList(from: profile.subdata(in: start.lowerBound..<end.upperBound),
                                                                     options: [], format: nil) as? [String: Any],
              let entitlements = root["Entitlements"] as? [String: Any] else { return nil }
        return entitlements["aps-environment"] as? String
    }

    private static var embeddedProfile: Data? {
        guard let url = Bundle.main.url(forResource: "embedded", withExtension: "mobileprovision") else { return nil }
        return try? Data(contentsOf: url)
    }

    private static var runsInSimulator: Bool {
        #if targetEnvironment(simulator)
        true
        #else
        false
        #endif
    }
}

// MARK: - Payload

/// Where a notification leads, read from its payload. For a confirm request the Mac puts `approvalId` next to `aps`.
struct PushPayload: Equatable, Sendable {
    var approvalId: String?

    init(approvalId: String? = nil) {
        self.approvalId = approvalId
    }

    init(userInfo: [AnyHashable: Any]) {
        let id = userInfo["approvalId"] as? String
        approvalId = (id?.isEmpty ?? true) ? nil : id
    }

    /// How a notification that arrives while the app is open is shown. A confirm request is already on screen inside the
    /// app while the Mac is connected (the confirm sheet), so no banner on top of it; everything else is shown as usual.
    func foregroundPresentation(connected: Bool) -> UNNotificationPresentationOptions {
        if approvalId != nil, connected { return [] }
        return [.banner, .list, .sound]
    }
}

// MARK: - Permission

/// The system's decision on notifications for Orbit.
enum NotificationPermission: Equatable, Sendable {
    case notDetermined, denied, authorized, provisional, ephemeral

    init(_ status: UNAuthorizationStatus) {
        switch status {
        case .notDetermined: self = .notDetermined
        case .authorized: self = .authorized
        case .provisional: self = .provisional
        case .ephemeral: self = .ephemeral
        case .denied: self = .denied
        @unknown default: self = .denied
        }
    }

    /// Alerts can reach the phone (a provisional permission delivers them quietly, to the notification list only).
    var isAllowed: Bool {
        switch self {
        case .authorized, .provisional, .ephemeral: true
        case .notDetermined, .denied: false
        }
    }
}

/// What `AppModel` needs from the notification system. A protocol so tests can answer for it.
@MainActor
protocol PushNotificationControlling: AnyObject {
    func authorizationStatus() async -> UNAuthorizationStatus
    /// Shows the system prompt (the first time only) and returns whether notifications are allowed now.
    func requestAuthorization() async -> Bool
    func registerForRemoteNotifications()
}

@MainActor
final class SystemPushNotifications: PushNotificationControlling {
    func authorizationStatus() async -> UNAuthorizationStatus {
        await UNUserNotificationCenter.current().notificationSettings().authorizationStatus
    }

    func requestAuthorization() async -> Bool {
        do {
            return try await UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound, .badge])
        } catch {
            log.error("notification permission request failed: \(error.localizedDescription, privacy: .public)")
            return false
        }
    }

    func registerForRemoteNotifications() {
        UIApplication.shared.registerForRemoteNotifications()
    }
}

// MARK: - App delegate

/// Receives what only UIKit hands out: the APNs device token, taps on notifications and notifications that arrive while
/// the app is open. SwiftUI's `App` has no hook for them, so `OPAApp` adopts this class with `@UIApplicationDelegateAdaptor`.
///
/// It can be woken before the SwiftUI side has built the `AppModel` (tapping a notification launches the app, and the
/// token arrives a moment after launch). Whatever comes early is kept until `attach(_:)`.
@MainActor
final class AppDelegate: NSObject, UIApplicationDelegate, UNUserNotificationCenterDelegate {
    /// `aps.category` of confirm requests (set by the Mac's notifier).
    nonisolated static let approvalCategory = "OPA_APPROVAL"

    private weak var model: AppModel?
    private var pendingToken: String?
    private var pendingTap: PushPayload?

    // MARK: UIApplicationDelegate

    func application(_ application: UIApplication,
                     didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]? = nil) -> Bool {
        // The delegate must be in place before launch finishes, or the tap that launched the app is lost.
        let center = UNUserNotificationCenter.current()
        center.delegate = self
        center.setNotificationCategories([
            // No buttons: a confirm request is answered inside the app (it needs Face ID for sensitive ones).
            UNNotificationCategory(identifier: Self.approvalCategory, actions: [], intentIdentifiers: [],
                                   hiddenPreviewsBodyPlaceholder: "Orbit 需要你确认一件事", options: []),
        ])
        // Already allowed: get this launch's token. (Not decided yet: `AppModel` asks after the first connection.)
        Task {
            if NotificationPermission(await SystemPushNotifications().authorizationStatus()).isAllowed {
                application.registerForRemoteNotifications()
            }
        }
        return true
    }

    func application(_ application: UIApplication, didRegisterForRemoteNotificationsWithDeviceToken deviceToken: Data) {
        receive(deviceToken: deviceToken)
    }

    func application(_ application: UIApplication, didFailToRegisterForRemoteNotificationsWithError error: any Error) {
        log.error("APNs registration failed: \(error.localizedDescription, privacy: .public)")
    }

    // MARK: UNUserNotificationCenterDelegate

    nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter,
                                            willPresent notification: UNNotification) async -> UNNotificationPresentationOptions {
        let payload = PushPayload(userInfo: notification.request.content.userInfo)
        return await foregroundPresentation(for: payload)
    }

    nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter,
                                            didReceive response: UNNotificationResponse) async {
        guard response.actionIdentifier == UNNotificationDefaultActionIdentifier else { return }
        let payload = PushPayload(userInfo: response.notification.request.content.userInfo)
        await receive(tap: payload)
    }

    // MARK: Hand-over to the model

    /// Called once the model exists (`OPAApp`, after `bootstrap`): hands over what arrived before that.
    func attach(_ model: AppModel) {
        self.model = model
        if let token = pendingToken {
            pendingToken = nil
            model.registerPush(kind: "alert", token: token, activityId: nil, taskId: nil)
        }
        if let tap = pendingTap {
            pendingTap = nil
            model.handleNotificationTap(tap)
        }
    }

    func receive(deviceToken: Data) {
        let token = deviceToken.hexString
        if let model {
            model.registerPush(kind: "alert", token: token, activityId: nil, taskId: nil)
        } else {
            pendingToken = token
        }
    }

    func receive(tap payload: PushPayload) {
        if let model {
            model.handleNotificationTap(payload)
        } else {
            pendingTap = payload
        }
    }

    func foregroundPresentation(for payload: PushPayload) -> UNNotificationPresentationOptions {
        payload.foregroundPresentation(connected: model?.connection.isConnected ?? false)
    }
}

// MARK: - AppModel: push

extension AppModel {
    /// After connecting: sends the push tokens the Mac may have lost (it can have started over with a new database), and
    /// asks for notification permission the first time. Does not wait for the answer, which can take as long as the
    /// person likes to read the prompt.
    func startPushSetup() {
        for (kind, token) in pushTokens { registerPush(kind: kind, token: token, activityId: nil, taskId: nil) }
        guard pushSetupTask == nil, !isDemo else { return }
        pushSetupTask = Task {
            await refreshPushPermission(ask: true)
            pushSetupTask = nil
        }
    }

    /// Reads the system's decision on notifications and acts on it.
    /// - Not decided yet and `ask`: shows the system prompt (it appears once); on yes, registers with APNs.
    /// - Turned on since we last looked (in the system settings): registers with APNs. `AppDelegate` already did that at
    ///   launch when notifications were on.
    @discardableResult
    func refreshPushPermission(ask: Bool = false) async -> NotificationPermission {
        var permission = NotificationPermission(await pushNotifications.authorizationStatus())
        let before = pushPermission
        pushPermission = permission
        if permission == .notDetermined, ask {
            let granted = await pushNotifications.requestAuthorization()
            permission = granted ? .authorized : .denied
            pushPermission = permission
            if granted { pushNotifications.registerForRemoteNotifications() }
        } else if permission.isAllowed, let before, !before.isAllowed {
            pushNotifications.registerForRemoteNotifications()
        }
        return permission
    }

    /// Where a tapped notification leads: a confirm request opens its confirm sheet, anything else lands in the chat.
    func handleNotificationTap(_ payload: PushPayload) {
        guard pairedHost != nil || isDemo else { return }   // before pairing there is nothing to open
        approvalTapTask?.cancel()
        guard let id = payload.approvalId else {
            selectedTab = .chat
            return
        }
        if approvals[id] != nil || resolvedApprovals[id] != nil {
            openApproval(id)
        } else {
            approvalTapTask = Task { await openApprovalWhenKnown(id) }
        }
    }

    /// The tap came before the confirm request did (the app was asleep, or is still connecting): the sheet would say
    /// "这个确认已失效" for a moment. Give the Mac's answer a little time — until it has told us, or a sync finished
    /// without it, or `approvalTapGrace` ran out — and open the sheet then.
    private func openApprovalWhenKnown(_ id: String) async {
        let syncs = syncCompletions
        let deadline = ContinuousClock.now + approvalTapGrace
        while !Task.isCancelled, approvals[id] == nil, resolvedApprovals[id] == nil,
              syncCompletions == syncs, ContinuousClock.now < deadline {
            try? await Task.sleep(for: .milliseconds(50))
        }
        guard !Task.isCancelled else { return }
        openApproval(id)
    }
}
