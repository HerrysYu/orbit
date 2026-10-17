import XCTest
@testable import OPA

/// A host that records requests and answers with whatever `handler` returns.
@MainActor
final class FakeHost: HostBackend {
    struct Call {
        var method: String
        var params: JSONValue
    }

    var calls: [Call] = []
    var handler: (String, JSONValue) async throws -> JSONValue = { _, _ in [:] }

    func request(_ m: String, _ d: JSONValue, timeout: Duration) async throws -> JSONValue {
        calls.append(Call(method: m, params: d))
        return try await handler(m, d)
    }

    func calls(_ method: String) -> [Call] { calls.filter { $0.method == method } }
}

/// Records what the model asks the Live Activity layer to do.
@MainActor
final class SpyActivities: TaskActivityControlling {
    var onPushToken: (String, String, String?, String?) -> Void = { _, _, _, _ in }
    var updated: [OPATask] = []
    var ended: [(taskId: String, immediately: Bool)] = []
    /// Number of `end(taskIds:)` calls (a batch counts once).
    var endCalls = 0
    var reconciled: [[OPATask]] = []
    var endAllCount = 0

    func observePushToStart() {}
    func update(task: OPATask, butlerName: String) { updated.append(task) }
    func end(taskIds: [String], immediately: Bool) {
        endCalls += 1
        for id in taskIds { ended.append((id, immediately)) }
    }
    func reconcile(tasks: [OPATask]) { reconciled.append(tasks) }
    func endAll() { endAllCount += 1 }
}

/// A model wired to a fake host, an in-memory store and throw-away defaults.
@MainActor
struct Harness {
    let model: AppModel
    let host: FakeHost
    let activities: SpyActivities
    let defaults: UserDefaults

    init(connected: Bool = true) {
        let suite = "opa.tests." + UUID().uuidString
        defaults = UserDefaults(suiteName: suite)!
        host = FakeHost()
        activities = SpyActivities()
        model = AppModel(inMemory: true, defaults: defaults, backend: host, liveActivities: activities)
        if connected { model.connection = .connected(.lan) }
    }

    func disconnect() { model.connectionStateChanged(.hostOffline) }
    func connect() { model.connectionStateChanged(.connected(.lan)) }
}

extension AppModel {
    /// Delivers a durable event as the connection would.
    func ev(_ seq: Int64, _ k: String, _ d: JSONValue, ts: Int64? = nil) {
        handle(.ev(seq: seq, ts: ts ?? seq * 1000, k: k, d: d))
    }

    func live(_ k: String, _ d: JSONValue) { handle(.live(k: k, d: d)) }

    var timelineIds: [String] { timeline.map(\.id) }
}

/// Event payload builders.
enum Payload {
    static func user(id: String = "u_1", clientId: String, text: String = "hi", ts: Int64 = 1) -> JSONValue {
        ["id": .string(id), "clientId": .string(clientId), "text": .string(text), "ts": .number(Double(ts))]
    }

    static func assistant(id: String, text: String = "ok", ts: Int64 = 1, interrupted: Bool = false) -> JSONValue {
        ["id": .string(id), "text": .string(text), "ts": .number(Double(ts)), "interrupted": .bool(interrupted)]
    }

    static func card(id: String, component: String = "text_card", props: JSONValue = ["markdown": "x"]) -> JSONValue {
        ["card": ["id": .string(id), "component": .string(component), "props": props, "ts": 1]]
    }

    static func task(id: String, status: String, title: String = "任务", updatedAt: Int64 = 1_000, steps: [(String, String)] = []) -> JSONValue {
        ["id": .string(id), "title": .string(title), "goal": "g", "status": .string(status),
         "steps": .array(steps.enumerated().map { i, s in ["id": .string("\(id)-\(i)"), "title": .string(s.0), "status": .string(s.1)] }),
         "createdAt": 1, "updatedAt": .number(Double(updatedAt))]
    }

    static func session(id: String, taskId: String?, status: String = "running", updatedAt: Int64 = 1_000) -> JSONValue {
        var o: [String: JSONValue] = ["id": .string(id), "title": "会话", "status": .string(status), "permission": "manual",
                                      "createdAt": 1, "updatedAt": .number(Double(updatedAt))]
        if let taskId { o["taskId"] = .string(taskId) }
        return .object(o)
    }

    static func approval(id: String, title: String = "确认", detail: String = "", createdAt: Int64 = 1_000, expiresAt: Int64? = nil,
                         sessionId: String? = nil, biometric: Bool = false) -> JSONValue {
        var o: [String: JSONValue] = ["id": .string(id), "title": .string(title), "detail": .string(detail), "risk": "medium",
                                      "kind": "action", "requireBiometric": .bool(biometric), "createdAt": .number(Double(createdAt))]
        if let expiresAt { o["expiresAt"] = .number(Double(expiresAt)) }
        if let sessionId { o["sessionId"] = .string(sessionId) }
        return .object(o)
    }

    static func approvalValue(id: String, detail: String = "", expiresAt: Int64? = nil, createdAt: Int64 = 1_000) -> Approval {
        Approval(id: id, title: "t", detail: detail, risk: .medium, sessionId: nil, kind: .action,
                 requireBiometric: false, createdAt: createdAt, expiresAt: expiresAt)
    }
}

/// Polls `condition` (on the main actor) until it holds or `timeout` seconds pass.
@MainActor
func waitUntil(timeout: Double = 2, _ condition: @MainActor () -> Bool) async -> Bool {
    let deadline = ContinuousClock.now + .seconds(timeout)
    while ContinuousClock.now < deadline {
        if condition() { return true }
        try? await Task.sleep(for: .milliseconds(10))
    }
    return condition()
}
