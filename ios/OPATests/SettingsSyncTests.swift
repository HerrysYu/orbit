import XCTest
@testable import OPA

@MainActor
final class SettingsSyncTests: XCTestCase {
    /// A host that keeps its own settings and merges patches like the real one.
    @MainActor
    private final class SettingsHost {
        var current = Settings()
        var failNext = 0
        /// Refuse any patch whose JSON contains one of these.
        var failIfContains: [String] = []
        var delay: Duration = .zero

        func handler(_ m: String, _ d: JSONValue) async throws -> JSONValue {
            switch m {
            case "settings.get":
                return try JSONValue(encoding: current)
            case "settings.set":
                if delay > .zero { try? await Task.sleep(for: delay) }
                if failNext > 0 {
                    failNext -= 1
                    throw OPAError.remote("Mac 没有接受")
                }
                if failIfContains.contains(where: { d.compactJSON.contains($0) }) { throw OPAError.remote("Mac 没有接受") }
                current = AppModel.settings(current, applying: d)
                return try JSONValue(encoding: current)
            default:
                return [:]
            }
        }
    }

    private func make() -> (Harness, SettingsHost) {
        let h = Harness()
        let s = SettingsHost()
        h.host.handler = { m, d in try await s.handler(m, d) }
        return (h, s)
    }

    func testSuccessfulSaveShowsTheValueImmediatelyThenSaved() async {
        let (h, host) = make()
        host.delay = .milliseconds(80)
        h.model.updateSettings(["heartbeatMinutes": 45])
        XCTAssertEqual(h.model.settings.heartbeatMinutes, 45, "optimistic value shows at once")
        XCTAssertEqual(h.model.settingsSync, .saving)
        let saved = await waitUntil { h.model.settingsSync == .saved }
        XCTAssertTrue(saved)
        XCTAssertEqual(h.model.settings.heartbeatMinutes, 45)
        XCTAssertEqual(host.current.heartbeatMinutes, 45)
    }

    func testFailedSaveRollsBackToTheHostsValue() async {
        let (h, host) = make()
        host.current.heartbeatMinutes = 30
        await h.model.loadSettings()
        XCTAssertEqual(h.model.settings.heartbeatMinutes, 30)

        host.failNext = 1
        host.delay = .milliseconds(60)
        h.model.updateSettings(["heartbeatMinutes": 90])
        XCTAssertEqual(h.model.settings.heartbeatMinutes, 90)
        let failed = await waitUntil { if case .failed = h.model.settingsSync { true } else { false } }
        XCTAssertTrue(failed)
        XCTAssertEqual(h.model.settings.heartbeatMinutes, 30, "no optimistic value may be left on screen")
        XCTAssertEqual(h.model.settingsSync, .failed("Mac 没有接受"))
        XCTAssertNotNil(h.model.toast)
    }

    func testOfflineSaveRollsBackToo() async {
        let (h, host) = make()
        host.current.dailyNotifyBudget = 5
        await h.model.loadSettings()
        h.host.handler = { _, _ in throw OPAError.notConnected }
        h.model.updateSettings(["dailyNotifyBudget": 20])
        let failed = await waitUntil { if case .failed = h.model.settingsSync { true } else { false } }
        XCTAssertTrue(failed)
        XCTAssertEqual(h.model.settings.dailyNotifyBudget, 5)
    }

    func testNestedPatchRollsBackOnlyItsOwnFields() async {
        let (h, host) = make()
        host.current.butler.name = "Orbit"
        host.current.butler.persona = "温和"
        await h.model.loadSettings()
        host.failNext = 1
        h.model.updateSettings(["butler": ["name": "小星"]])
        XCTAssertEqual(h.model.settings.butler.name, "小星")
        XCTAssertEqual(h.model.settings.butler.persona, "温和")
        _ = await waitUntil { if case .failed = h.model.settingsSync { true } else { false } }
        XCTAssertEqual(h.model.settings.butler.name, "Orbit")
        XCTAssertEqual(h.model.settings.butler.persona, "温和")
    }

    func testTwoEditsOneFailingKeepsTheOtherOne() async {
        let (h, host) = make()
        host.current.heartbeatMinutes = 30
        host.current.dailyNotifyBudget = 5
        await h.model.loadSettings()
        host.delay = .milliseconds(60)
        host.failIfContains = ["heartbeatMinutes"]
        h.model.updateSettings(["heartbeatMinutes": 90])
        h.model.updateSettings(["dailyNotifyBudget": 20])
        XCTAssertEqual(h.model.settings.heartbeatMinutes, 90)
        XCTAssertEqual(h.model.settings.dailyNotifyBudget, 20)
        let done = await waitUntil {
            if case .failed = h.model.settingsSync { return true }
            return false
        }
        XCTAssertTrue(done, "the batch ends failed: one of the edits was refused")
        XCTAssertEqual(h.model.settings.heartbeatMinutes, 30, "the refused edit is gone")
        XCTAssertEqual(h.model.settings.dailyNotifyBudget, 20, "the accepted one stays")
        XCTAssertEqual(host.current.dailyNotifyBudget, 20)
    }

    func testHostChangesWinOverAnOldOptimisticValueButNotOverNewerEdits() async {
        let (h, host) = make()
        await h.model.loadSettings()
        host.delay = .milliseconds(120)
        h.model.updateSettings(["heartbeatMinutes": 60])
        // Meanwhile another device changes a different setting.
        var other = host.current
        other.dailyNotifyBudget = 9
        h.model.ev(1, "settings.changed", (try? JSONValue(encoding: other)) ?? [:])
        XCTAssertEqual(h.model.settings.dailyNotifyBudget, 9)
        XCTAssertEqual(h.model.settings.heartbeatMinutes, 60, "our unconfirmed edit is still shown")
    }

    func testSavedFallsBackToIdle() async {
        let (h, _) = make()
        h.model.updateSettings(["heartbeatMinutes": 45])
        _ = await waitUntil { h.model.settingsSync == .saved }
        XCTAssertEqual(h.model.settingsSync, .saved)
        let idle = await waitUntil(timeout: 4) { h.model.settingsSync == .idle }
        XCTAssertTrue(idle)
    }

    func testOnlyConfirmedSettingsArePersisted() async {
        let (h, host) = make()
        host.failNext = 1
        h.model.updateSettings(["heartbeatMinutes": 99])
        _ = await waitUntil { if case .failed = h.model.settingsSync { true } else { false } }
        let data = h.defaults.data(forKey: AppModel.DefaultsKey.settings)
        let stored = data.flatMap { try? JSONDecoder().decode(Settings.self, from: $0) }
        XCTAssertNotEqual(stored?.heartbeatMinutes, 99, "an edit the Mac refused must not come back after a relaunch")
    }

    // MARK: Memory

    func testMemoryChangedBumpsTheRevisionAndRefreshesTheCachedList() async {
        let h = Harness()
        let mem = Memory(id: "m1", text: "不吃香菜", kind: .preference, source: "explicit", confidence: 1, createdAt: 1, updatedAt: 1)
        h.host.handler = { m, _ in m == "memory.list" ? ["items": (try? JSONValue(encoding: [mem])) ?? []] : [:] }
        let rev = h.model.memoryRevision
        h.model.ev(1, "memory.changed", [:])
        XCTAssertEqual(h.model.memoryRevision, rev + 1, "screens observe this to reload")
        let loaded = await waitUntil { h.model.memories.map(\.id) == ["m1"] }
        XCTAssertTrue(loaded, "and the cached list is refreshed even when no screen is open")
    }

    func testReplayedMemoryChangesOnlyBumpTheRevision() async {
        let h = Harness()
        h.model.apply(k: "memory.changed", d: [:], ts: 1, seq: 1, animated: false)
        try? await Task.sleep(for: .milliseconds(450))
        XCTAssertEqual(h.model.memoryRevision, 1)
        XCTAssertTrue(h.host.calls("memory.list").isEmpty, "no request storm when replaying history")
    }
}
