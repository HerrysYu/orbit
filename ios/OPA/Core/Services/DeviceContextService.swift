import CoreLocation
import EventKit
import Foundation
import Network

/// Collects the `DeviceContext` (section 4.5) using only system frameworks that do not need UIKit.
@MainActor
final class DeviceContextService {
    private let monitor = NWPathMonitor()
    private(set) var network: String = "none"
    let eventStore = EKEventStore()
    private let locationManager = CLLocationManager()

    init() {
        monitor.pathUpdateHandler = { [weak self] path in
            let value: String
            if path.status != .satisfied { value = "none" }
            else if path.usesInterfaceType(.wifi) || path.usesInterfaceType(.wiredEthernet) { value = "wifi" }
            else if path.usesInterfaceType(.cellular) { value = "cellular" }
            else { value = "wifi" }
            Task { @MainActor in self?.network = value }
        }
        monitor.start(queue: DispatchQueue(label: "opa.path"))
    }

    var locationAuthorized: Bool {
        let s = locationManager.authorizationStatus
        return s == .authorizedWhenInUse || s == .authorizedAlways
    }

    func requestLocation() { locationManager.requestWhenInUseAuthorization() }

    func requestCalendar() async -> Bool { (try? await eventStore.requestFullAccessToEvents()) ?? false }
    func requestReminders() async -> Bool { (try? await eventStore.requestFullAccessToReminders()) ?? false }

    var calendarAuthorized: Bool { EKEventStore.authorizationStatus(for: .event) == .fullAccess }
    var remindersAuthorized: Bool { EKEventStore.authorizationStatus(for: .reminder) == .fullAccess }

    func snapshot(deviceName: String) async -> DeviceContext {
        var ctx = DeviceContext(timezone: TimeZone.current.identifier,
                                locale: Locale.current.identifier,
                                now: Clock.nowMs,
                                network: network,
                                deviceName: deviceName)
        if locationAuthorized, let loc = await coarseLocation() {
            ctx.location = .init(lat: (loc.coordinate.latitude * 100).rounded() / 100,
                                 lon: (loc.coordinate.longitude * 100).rounded() / 100,
                                 accuracy: max(loc.horizontalAccuracy, 1000))
        }
        if calendarAuthorized {
            let start = Date()
            let end = start.addingTimeInterval(24 * 3600)
            let pred = eventStore.predicateForEvents(withStart: start, end: end, calendars: nil)
            ctx.upcomingEvents = eventStore.events(matching: pred).prefix(20).map {
                .init(title: $0.title ?? "", start: Clock.ms($0.startDate), end: Clock.ms($0.endDate), location: $0.location)
            }
        }
        if remindersAuthorized {
            let reminders = await incompleteReminders()
            ctx.reminders = reminders.prefix(30).map {
                .init(title: $0.title, due: $0.due.map(Clock.ms), done: false)
            }
        }
        return ctx
    }

    private func coarseLocation() async -> CLLocation? {
        if let cached = locationManager.location, cached.timestamp.timeIntervalSinceNow > -15 * 60 { return cached }
        let box = ResumeOnce<CLLocation?>()
        return await withCheckedContinuation { (c: CheckedContinuation<CLLocation?, Never>) in
            box.set(c)
            Task {
                do {
                    for try await update in CLLocationUpdate.liveUpdates(.default) {
                        if let l = update.location { box.resume(l); break }
                    }
                } catch {}
                box.resume(nil)
            }
            Task {
                try? await Task.sleep(for: .seconds(4))
                box.resume(nil)
            }
        }
    }

    struct ReminderSummary: Sendable, Hashable, Identifiable {
        var id: String
        var title: String
        var due: Date?
        var notes: String?
        var list: String
    }

    func incompleteReminders() async -> [ReminderSummary] {
        let pred = eventStore.predicateForIncompleteReminders(withDueDateStarting: nil, ending: nil, calendars: nil)
        let box = ResumeOnce<[ReminderSummary]>()
        return await withCheckedContinuation { (c: CheckedContinuation<[ReminderSummary], Never>) in
            box.set(c)
            // EventKit calls back on its own search queue. `@Sendable` keeps the closure from inheriting this
            // class's @MainActor isolation, which Swift 6 checks at runtime and traps on (crash after granting access).
            eventStore.fetchReminders(matching: pred) { @Sendable reminders in
                let out = (reminders ?? []).map {
                    ReminderSummary(id: $0.calendarItemIdentifier, title: $0.title ?? "",
                                    due: $0.dueDateComponents?.date, notes: $0.notes, list: $0.calendar?.title ?? "")
                }
                box.resume(out)
            }
        }
    }
}
