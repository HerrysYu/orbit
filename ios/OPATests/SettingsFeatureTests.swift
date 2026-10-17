import XCTest
@testable import OPA

/// WP6: the pure logic behind the settings pages, the memory page and the Live Activity.
@MainActor
final class SettingsFeatureTests: XCTestCase {
    // MARK: phone.status

    func testPhoneStatusParsesAnAvailablePhone() throws {
        let json: JSONValue = ["available": true, "serial": "e7fe2f2a", "adbKeyboard": true,
                               "device": ["serial": "e7fe2f2a", "state": "device", "model": "Redmi_Note_12"]]
        let status = try XCTUnwrap(AndroidPhoneStatus(json: json))
        XCTAssertTrue(status.available)
        XCTAssertNil(status.reason)
        XCTAssertEqual(status.modelName, "Redmi Note 12", "adb writes spaces as underscores")
        XCTAssertEqual(status.displayName, "Redmi Note 12")
        XCTAssertEqual(status.adbKeyboard, true)
        XCTAssertEqual(status.linkLabel, "已连接")
    }

    func testPhoneStatusKeepsTheReasonAndTreatsAMissingKeyboardAnswerAsUnknown() throws {
        let json: JSONValue = ["available": false, "serial": "e7fe2f2a", "reason": "  手机 e7fe2f2a 还没有授权这台 Mac。  ",
                               "device": ["serial": "e7fe2f2a", "state": "unauthorized"]]
        let status = try XCTUnwrap(AndroidPhoneStatus(json: json))
        XCTAssertFalse(status.available)
        XCTAssertEqual(status.reason, "手机 e7fe2f2a 还没有授权这台 Mac。")
        XCTAssertNil(status.adbKeyboard, "an omitted adbKeyboard means unknown, never 'not installed'")
        XCTAssertEqual(status.displayName, "e7fe2f2a", "no model reported: the serial names the phone")
        XCTAssertEqual(status.linkLabel, "未授权这台 Mac")
    }

    func testPhoneStatusWithoutADeviceMeansAdbDoesNotListThePhone() throws {
        let status = try XCTUnwrap(AndroidPhoneStatus(json: ["available": false, "serial": "abc", "reason": "没有发现手机 abc。"]))
        XCTAssertNil(status.device)
        XCTAssertEqual(status.linkLabel, "没有发现")
        XCTAssertEqual(AndroidPhoneStatusStore.State.loaded(status).rowSummary.text, "没有发现手机 abc。")
        XCTAssertTrue(AndroidPhoneStatusStore.State.loaded(status).rowSummary.isWarning)
    }

    func testAnswersThatAreNotPhoneStatusAreRejected() {
        XCTAssertNil(AndroidPhoneStatus(json: [:]))
        XCTAssertNil(AndroidPhoneStatus(json: ["serial": "abc"]))
    }

    func testUnknownMethodErrorsAreRecognised() {
        XCTAssertTrue(AndroidPhoneStatusStore.isUnknownMethod("unknown method phone.status"))
        XCTAssertTrue(AndroidPhoneStatusStore.isUnknownMethod("Unknown Method phone.status"))
        XCTAssertFalse(AndroidPhoneStatusStore.isUnknownMethod("请求超时"))
    }

    func testStoreAsksTheMacAndShowsItsAnswer() async {
        let h = Harness()
        h.host.handler = { method, _ in
            method == "phone.status"
                ? ["available": true, "serial": "s1", "device": ["serial": "s1", "state": "device", "model": "M1"]]
                : [:]
        }
        let store = AndroidPhoneStatusStore()
        await store.refresh(using: h.model)
        guard case .loaded(let status) = store.state else { return XCTFail("expected a loaded answer, got \(store.state)") }
        XCTAssertEqual(status.displayName, "M1")
        XCTAssertEqual(store.state.rowSummary.text, "M1 · 已就绪")
        XCTAssertEqual(h.host.calls("phone.status").count, 1)
    }

    func testStoreSaysTheMacNeedsAnUpdateWhenItDoesNotKnowTheRequest() async {
        let h = Harness()
        h.host.handler = { _, _ in throw OPAError.remote("unknown method phone.status") }
        let store = AndroidPhoneStatusStore()
        await store.refresh(using: h.model)
        XCTAssertEqual(store.state, .unsupported)
        XCTAssertEqual(store.state.rowSummary.text, "需要更新 Mac 端")
    }

    func testStoreIsUnreachableWithoutAConnectionAndFailsVisiblyOnOtherErrors() async {
        let offline = Harness()
        offline.host.handler = { _, _ in throw OPAError.notConnected }
        let store = AndroidPhoneStatusStore()
        await store.refresh(using: offline.model)
        XCTAssertEqual(store.state, .unreachable)

        let broken = Harness()
        broken.host.handler = { _, _ in throw OPAError.timeout }
        let other = AndroidPhoneStatusStore()
        await other.refresh(using: broken.model)
        XCTAssertEqual(other.state, .failed(OPAError.timeout.localizedDescription))
    }

    func testDemoModeFallsBackToASamplePhone() async {
        let h = Harness()
        h.model.isDemo = true
        h.host.handler = { _, _ in [:] }
        let store = AndroidPhoneStatusStore()
        await store.refresh(using: h.model)
        XCTAssertEqual(store.state, .loaded(.demo))
    }

    // MARK: Memory

    private func memory(_ id: String, _ kind: Memory.Kind, source: String = "explicit") -> Memory {
        Memory(id: id, text: id, kind: kind, source: source, confidence: 1, createdAt: 1, updatedAt: 1)
    }

    func testMemoryGroupsFollowTheDesignOrderAndPlacesShareAGroupWithPeople() {
        let list = [memory("date", .date), memory("person", .person), memory("place", .place), memory("pref", .preference),
                    memory("fact", .fact), memory("profile", .profile)]
        let sections = MemoryGrouping.sections(list, filter: .all)
        XCTAssertEqual(sections.map(\.category), [.profile, .preference, .placesPeople, .dates, .facts])
        XCTAssertEqual(sections.first { $0.category == .placesPeople }?.items.map(\.id), ["person", "place"], "order within a group is kept")
    }

    func testMemoryFilterSplitsByWhoSaidIt() {
        let list = [memory("told1", .preference), memory("guess1", .preference, source: "inferred"),
                    memory("told2", .place), memory("guess2", .fact, source: "inferred")]
        let told = MemoryGrouping.sections(list, filter: .explicit).flatMap(\.items).map(\.id)
        let guessed = MemoryGrouping.sections(list, filter: .inferred).flatMap(\.items).map(\.id)
        XCTAssertEqual(Set(told), ["told1", "told2"])
        XCTAssertEqual(Set(guessed), ["guess1", "guess2"])
        XCTAssertEqual(MemoryGrouping.sections(list, filter: .all).flatMap(\.items).count, 4)
        XCTAssertTrue(MemoryGrouping.sections([], filter: .all).isEmpty)
        XCTAssertTrue(MemoryGrouping.sections([memory("only", .fact)], filter: .inferred).isEmpty, "empty groups are omitted")
    }

    // MARK: Quiet hours, permission, persona

    func testQuietTimeRoundTripsAndNeverCrashesOnJunk() {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        let reference = Date(timeIntervalSince1970: 1_760_000_000)
        func roundTrip(_ text: String) -> String {
            QuietTime.text(from: QuietTime.date(from: text, calendar: calendar, reference: reference), calendar: calendar)
        }
        XCTAssertEqual(roundTrip("23:05"), "23:05")
        XCTAssertEqual(roundTrip("08:00"), "08:00")
        XCTAssertEqual(roundTrip("??"), "00:00")
        XCTAssertEqual(roundTrip("25:99"), "23:59", "out-of-range values are clamped")
    }

    func testExecutionAccessMapsTheTwoSwitchesOnTheMac() {
        var settings = Settings()
        XCTAssertEqual(settings.executionAccess, .perItem)
        settings.defaultPermission = .auto
        settings.allowAutoFullAccess = true
        XCTAssertEqual(settings.executionAccess, .full)
        settings.allowAutoFullAccess = false
        XCTAssertEqual(settings.executionAccess, .custom)
        settings.defaultPermission = .manual
        settings.allowAutoFullAccess = true
        XCTAssertEqual(settings.executionAccess, .custom)
        XCTAssertEqual([ExecutionAccess.perItem, .full, .custom].map(\.label), ["逐项确认", "完全访问", "自定义"])
    }

    func testPersonaSummaryIsTheFirstPhrase() {
        XCTAssertEqual(SettingsView.personaSummary("温和、靠谱，说话简洁，偶尔幽默。"), "温和、靠谱")
        XCTAssertEqual(SettingsView.personaSummary("  \n温和 靠谱\n第二行"), "温和 靠谱")
        XCTAssertEqual(SettingsView.personaSummary("   "), "未设置")
        XCTAssertEqual(SettingsView.personaSummary(""), "未设置")
    }

    // MARK: Live Activity

    private typealias Live = TaskActivityAttributes.ContentState

    private func live(_ status: String, done: Int = 1, total: Int = 4, detail: String? = nil, title: String = "订周六晚的日料") -> Live {
        Live(title: title, status: status, done: done, total: total, detail: detail)
    }

    func testTheHostPayloadStillDecodes() throws {
        // `"content-state"` exactly as host/src/butler/butler.ts sends it (detail may be null or absent).
        let withNull = Data(#"{"title":"订周六晚的日料","status":"waiting_user","done":3,"total":4,"detail":null}"#.utf8)
        let state = try JSONDecoder().decode(Live.self, from: withNull)
        XCTAssertEqual(state, live("waiting_user", done: 3, total: 4, detail: nil))
        let withoutDetail = Data(#"{"title":"t","status":"running","done":0,"total":0}"#.utf8)
        XCTAssertNil(try JSONDecoder().decode(Live.self, from: withoutDetail).detail)
    }

    func testPhasesFollowTheTaskStatusAndUnknownStatusesPresentAsRunning() {
        let expected: [(String, Live.Phase, String)] = [
            ("planning", .planning, "规划中"), ("running", .running, "进行中"), ("waiting_user", .waiting, "需要你确认"),
            ("blocked", .blocked, "遇到阻碍"), ("done", .done, "已完成"), ("failed", .failed, "未完成"),
            ("cancelled", .cancelled, "已取消"), ("something-new", .running, "进行中"),
        ]
        for (status, phase, label) in expected {
            XCTAssertEqual(live(status).phase, phase, status)
            XCTAssertEqual(live(status).statusLabel, label, status)
        }
        XCTAssertEqual(Live.Phase.waiting.shortLabel, "待确认")
        XCTAssertTrue(Live.Phase.waiting.needsYou)
        XCTAssertFalse(Live.Phase.running.needsYou)
        XCTAssertTrue(live("done").isFinal)
        XCTAssertFalse(live("waiting_user").isFinal)
    }

    func testStepCopyClampsBadCountsAndFindsTheCurrentStep() {
        XCTAssertEqual(live("running", done: 2).stepsText, "已完成 2 / 4 步")
        XCTAssertEqual(live("running", done: 3).shortStepsText, "3 / 4 步")
        XCTAssertEqual(live("running", done: 2).compactStepsText, "2/4")
        XCTAssertEqual(live("running", done: 9).stepsText, "已完成 4 / 4 步")
        XCTAssertEqual(live("running", done: -3).stepsText, "已完成 0 / 4 步")
        XCTAssertEqual(live("running", done: 2).currentIndex, 2)
        XCTAssertEqual(live("waiting_user", done: 3).currentIndex, 3)
        XCTAssertNil(live("running", done: 4).currentIndex, "every step done: nothing half filled")
        for status in ["done", "failed", "cancelled", "planning"] { XCTAssertNil(live(status, done: 1).currentIndex, status) }
    }

    func testSubtitleIsNeverEmptyAndWaitingIsNotSaidTwice() {
        XCTAssertEqual(live("waiting_user", detail: "提交预订").subtitle(on: .island), "需要你确认：提交预订")
        XCTAssertEqual(live("waiting_user", detail: "需要你确认提交预订").subtitle(on: .island), "需要你确认提交预订")
        XCTAssertEqual(live("waiting_user", detail: "等你批准后提交").subtitle(on: .island), "等你批准后提交")
        XCTAssertEqual(live("waiting_user", detail: "提交预订").subtitle(on: .lockScreen), "提交预订", "the lock screen has the chip")
        XCTAssertEqual(live("waiting_user").subtitle(on: .island), "需要你确认")
        XCTAssertEqual(live("running", detail: "  \n ").subtitle(on: .lockScreen), "正在处理…", "blank detail counts as none")
        for status in ["planning", "running", "waiting_user", "blocked", "done", "failed", "cancelled"] {
            for surface in [Live.Surface.lockScreen, .island] {
                XCTAssertFalse(live(status).subtitle(on: surface).isEmpty, "\(status) / \(surface)")
            }
        }
    }

    func testTitleFallbackAndSpokenSummary() {
        XCTAssertEqual(live("running", title: "  ").displayTitle, "Orbit 的任务")
        let spoken = live("running", done: 2, detail: "核对周六 19:00 的空位").spokenSummary
        XCTAssertEqual(spoken, "订周六晚的日料，进行中，核对周六 19:00 的空位，已完成 2 / 4 步")
        XCTAssertFalse(live("planning", done: 0, total: 0).spokenSummary.contains("步"), "no step count without steps")
    }

    func testLiveLinkPointsAtTheTask() {
        XCTAssertEqual(LiveLink.url(taskId: "t8")?.absoluteString, "opa://task?id=t8")
        XCTAssertEqual(LiveLink.url(taskId: "task-42")?.host, "task")
    }

    // MARK: Models page (模型 and 推理强度)

    private func modelEntry(_ id: String, efforts: [String]? = nil, isDefault: Bool? = nil) -> ModelsList.Entry {
        ModelsList.Entry(id: id, displayName: id, isDefault: isDefault, efforts: efforts)
    }

    /// A Mac whose models support different efforts: `big` is Orbit's default model, `coder` the tasks' one.
    private var sampleModels: ModelsList {
        ModelsList(
            butler: [modelEntry("big", efforts: ["minimal", "low", "medium", "high", "xhigh", "max"], isDefault: true),
                     modelEntry("small", efforts: ["low", "medium"]),
                     modelEntry("bare")],
            codex: [modelEntry("coder", efforts: ["low", "medium", "high"], isDefault: true),
                    modelEntry("wide", efforts: ["low", "medium", "high", "xhigh", "max"]),
                    modelEntry("empty", efforts: [])])
    }

    private func choices(_ configure: (inout Settings.Models) -> Void = { _ in }) -> ModelChoices {
        var models = Settings.Models()
        configure(&models)
        return ModelChoices(settings: models, list: sampleModels)
    }

    func testMissingEffortSettingsDecodeAsAuto() throws {
        let old = try JSONValue(jsonString: #"{"butler":"gpt-5","heartbeat":"","codexDefault":null}"#).decode(Settings.Models.self)
        XCTAssertEqual([old.butlerEffort, old.heartbeatEffort, old.codexEffort], ["", "", ""], "an older Mac sends none of them")
        let odd = try JSONValue(jsonString: #"{"butlerEffort":null,"heartbeatEffort":7,"codexEffort":"high"}"#).decode(Settings.Models.self)
        XCTAssertEqual([odd.butlerEffort, odd.heartbeatEffort, odd.codexEffort], ["", "", "high"], "null and junk mean auto")
        let whole = try JSONValue(jsonString: #"{"models":{"butler":"gpt-5","butlerEffort":"xhigh","heartbeatEffort":"low"}}"#).decode(Settings.self)
        XCTAssertEqual(whole.models.butlerEffort, "xhigh")
        XCTAssertEqual(whole.models.heartbeatEffort, "low")
        XCTAssertEqual(whole.models.codexEffort, "")

        var models = Settings.Models()
        XCTAssertEqual([models.butlerEffort, models.heartbeatEffort, models.codexEffort], ["", "", ""], "the default is auto")
        models.heartbeatEffort = "minimal"
        XCTAssertEqual(try JSONValue(encoding: models).decode(Settings.Models.self), models, "what the app saves, it reads back")
    }

    func testModelListEntriesCarryEffortsAndOlderMacsOmitThem() throws {
        let json = #"""
        {"butler":[{"id":"a","efforts":["low","high"],"defaultEffort":"low"},{"id":"b","created":5},"c",
                   {"id":"d","efforts":null,"defaultEffort":null},{"id":"e","efforts":"oops","defaultEffort":3}],
         "codex":[{"id":"x","displayName":"X","isDefault":true,"efforts":[],"defaultEffort":"medium"}]}
        """#
        let list = try JSONValue(jsonString: json).decode(ModelsList.self)
        XCTAssertEqual(list.butler.map(\.id), ["a", "b", "c", "d", "e"], "no entry is lost for lacking the new fields")
        XCTAssertEqual(list.butler[0].efforts, ["low", "high"])
        XCTAssertEqual(list.butler[0].defaultEffort, "low")
        for older in list.butler.dropFirst() {
            XCTAssertNil(older.efforts, older.id)
            XCTAssertNil(older.defaultEffort, older.id)
        }
        XCTAssertEqual(list.codex[0].efforts, [])
        XCTAssertEqual(list.codex[0].defaultEffort, "medium")
        XCTAssertTrue(list.codex[0].isDefault == true)
    }

    func testEffortChoicesFollowTheModelEachGroupUses() {
        let big = ["minimal", "low", "medium", "high", "xhigh", "max"]
        let fallback = ModelChoices.fallbackEfforts
        // Orbit: no model means the Mac's default one.
        XCTAssertEqual(choices().efforts(for: .orbit), big)
        XCTAssertEqual(choices { $0.butler = "small" }.efforts(for: .orbit), ["low", "medium"])
        XCTAssertEqual(choices { $0.butler = "bare" }.efforts(for: .orbit), fallback, "listed without efforts")
        XCTAssertEqual(choices { $0.butler = "gone" }.efforts(for: .orbit), fallback, "not listed any more")
        // The heartbeat: without a model of its own it is Orbit's model, whatever that resolves to.
        XCTAssertEqual(choices().efforts(for: .heartbeat), big)
        XCTAssertEqual(choices { $0.butler = "small" }.efforts(for: .heartbeat), ["low", "medium"])
        XCTAssertEqual(choices { $0.butler = "small"; $0.heartbeat = "big" }.efforts(for: .heartbeat), big)
        XCTAssertEqual(choices { $0.heartbeat = "coder" }.efforts(for: .heartbeat), fallback, "it picks from the bot models, not the Codex ones")
        // Tasks: the Codex models; no model (or an empty one) is the default one.
        XCTAssertEqual(choices().efforts(for: .task), ["low", "medium", "high"])
        XCTAssertEqual(choices { $0.codexDefault = "" }.efforts(for: .task), ["low", "medium", "high"])
        XCTAssertEqual(choices { $0.codexDefault = "wide" }.efforts(for: .task), ["low", "medium", "high", "xhigh", "max"])
        XCTAssertEqual(choices { $0.codexDefault = "empty" }.efforts(for: .task), fallback, "an empty list counts as unknown")
    }

    func testEffortChoicesFallBackToTheFourCommonOnes() {
        let fallback = ["low", "medium", "high", "xhigh"]
        XCTAssertEqual(ModelChoices.fallbackEfforts, fallback)
        // The models have not been fetched (or the Mac is offline).
        let unknown = ModelChoices(settings: Settings.Models(), list: nil)
        for job in ModelChoices.Job.allCases { XCTAssertEqual(unknown.efforts(for: job), fallback, "\(job)") }
        // Nothing is marked as the default model; the model the app adds on its own lists no efforts.
        XCTAssertEqual(ModelChoices.efforts(ofModel: "", in: [modelEntry("a", efforts: ["max"])]), fallback)
        XCTAssertEqual(choices { $0.butler = ModelsList.Entry.gpt61Sol.id }.efforts(for: .orbit), fallback)
        // Blank and repeated efforts are dropped (they would clash with the automatic row); nothing left means unknown.
        XCTAssertEqual(ModelChoices.efforts(ofModel: "a", in: [modelEntry("a", efforts: [" low ", "", "low", "high"])]), ["low", "high"])
        XCTAssertEqual(ModelChoices.efforts(ofModel: "a", in: [modelEntry("a", efforts: ["", "  "])]), fallback)
    }

    func testChoosingAModelClearsAnEffortItDoesNotSupport() {
        // Orbit: `big` has max, `small` does not. The model and the cleared effort travel in one patch.
        let onBig = choices { $0.butler = "big"; $0.butlerEffort = "max" }
        XCTAssertEqual(onBig.patch(choosingModel: "small", for: .orbit), ["models": ["butler": "small", "butlerEffort": ""]])
        XCTAssertEqual(onBig.patch(choosingModel: "bare", for: .orbit), ["models": ["butler": "bare", "butlerEffort": ""]],
                       "a model without a list offers the four common efforts, not max")
        // An effort the new model also supports, and the automatic one, stay as they are.
        XCTAssertEqual(choices { $0.butler = "big"; $0.butlerEffort = "medium" }.patch(choosingModel: "small", for: .orbit),
                       ["models": ["butler": "small"]])
        XCTAssertEqual(choices { $0.butler = "big" }.patch(choosingModel: "small", for: .orbit), ["models": ["butler": "small"]])
        // Choosing "自动" is judged against the Mac's default model (`big` has max).
        XCTAssertEqual(choices { $0.butler = "small"; $0.butlerEffort = "medium" }.patch(choosingModel: "", for: .orbit),
                       ["models": ["butler": ""]])
        XCTAssertEqual(choices { $0.butler = "bare"; $0.butlerEffort = "max" }.patch(choosingModel: "", for: .orbit),
                       ["models": ["butler": ""]])

        // The heartbeat: following Orbit means Orbit's model (`small`, no max).
        let beat = choices { $0.butler = "small"; $0.heartbeat = "big"; $0.heartbeatEffort = "max" }
        XCTAssertEqual(beat.patch(choosingModel: "", for: .heartbeat), ["models": ["heartbeat": "", "heartbeatEffort": ""]])
        XCTAssertEqual(beat.patch(choosingModel: "wide", for: .heartbeat), ["models": ["heartbeat": "wide", "heartbeatEffort": ""]],
                       "wide is a Codex model, unknown to the bot list")
        // A heartbeat that follows Orbit changes with Orbit's model; one with a model of its own does not.
        let follower = choices { $0.butler = "big"; $0.heartbeatEffort = "max" }
        XCTAssertEqual(follower.patch(choosingModel: "small", for: .orbit), ["models": ["butler": "small", "heartbeatEffort": ""]])
        let own = choices { $0.butler = "big"; $0.heartbeat = "big"; $0.heartbeatEffort = "max" }
        XCTAssertEqual(own.patch(choosingModel: "small", for: .orbit), ["models": ["butler": "small"]])

        // Tasks: auto is saved as null; the other groups' efforts are never touched.
        let task = choices { $0.codexDefault = "wide"; $0.codexEffort = "max"; $0.butlerEffort = "max" }
        XCTAssertEqual(task.patch(choosingModel: "coder", for: .task), ["models": ["codexDefault": "coder", "codexEffort": ""]])
        XCTAssertEqual(task.patch(choosingModel: "", for: .task), ["models": ["codexDefault": .null, "codexEffort": ""]])
        XCTAssertEqual(task.patch(choosingModel: "wide", for: .task), ["models": ["codexDefault": "wide"]])
    }

    func testChoosingAnEffortOnlyWritesThatEffort() {
        let c = choices { $0.butler = "big"; $0.butlerEffort = "max" }
        XCTAssertEqual(c.patch(choosingEffort: "high", for: .orbit), ["models": ["butlerEffort": "high"]])
        XCTAssertEqual(c.patch(choosingEffort: "", for: .orbit), ["models": ["butlerEffort": ""]], "auto is the empty string, not null")
        XCTAssertEqual(c.patch(choosingEffort: "low", for: .heartbeat), ["models": ["heartbeatEffort": "low"]])
        XCTAssertEqual(c.patch(choosingEffort: "xhigh", for: .task), ["models": ["codexEffort": "xhigh"]])
    }

    func testEffortsAreNamedInChinese() {
        let names = ["none", "minimal", "low", "medium", "high", "xhigh", "max"].map(ModelChoices.effortLabel)
        XCTAssertEqual(names, ["关闭", "极低", "低", "中", "高", "超高", "最高"])
        XCTAssertEqual(ModelChoices.effortLabel("turbo"), "turbo", "an effort the app does not know is shown as sent")
        XCTAssertEqual(ModelChoices.Job.allCases.map(\.title), ["Orbit", "定期自查（心跳）", "执行任务"])
        XCTAssertEqual(ModelChoices.Job.allCases.map(\.automaticModelLabel), ["自动（最新）", "跟随 Orbit", "自动（最新）"])
        XCTAssertEqual(ModelChoices.Job.allCases.map(\.automaticEffortLabel), ["默认（中）", "跟随 Orbit", "自动"])
    }

    @MainActor
    private final class MacSettings {
        var current = Settings()
        func handle(_ method: String, _ params: JSONValue) throws -> JSONValue {
            guard method == "settings.set" else { return [:] }
            current = AppModel.settings(current, applying: params)
            return try JSONValue(encoding: current)
        }
    }

    func testAModelAndItsClearedEffortAreSavedInOneRequest() async {
        let mac = MacSettings()
        mac.current.models.butler = "big"
        mac.current.models.butlerEffort = "max"
        let h = Harness()
        h.host.handler = { method, params in try mac.handle(method, params) }
        h.model.acceptServerSettings(mac.current)

        h.model.updateSettings(ModelChoices(settings: h.model.settings.models, list: sampleModels).patch(choosingModel: "small", for: .orbit))
        XCTAssertEqual(h.model.settings.models.butler, "small", "shown at once")
        XCTAssertEqual(h.model.settings.models.butlerEffort, "", "the effort changes with it")
        let saved = await waitUntil { h.model.settingsSync == .saved }
        XCTAssertTrue(saved)
        XCTAssertEqual(h.host.calls("settings.set").count, 1, "one save for both values")
        XCTAssertEqual(mac.current.models.butler, "small")
        XCTAssertEqual(mac.current.models.butlerEffort, "")
    }

    func testARefusedModelChangeBringsBackTheEffortToo() async {
        let h = Harness()
        var seeded = Settings()
        seeded.models.butler = "big"
        seeded.models.butlerEffort = "max"
        h.model.acceptServerSettings(seeded)
        h.host.handler = { _, _ in throw OPAError.remote("Mac 没有接受") }

        h.model.updateSettings(ModelChoices(settings: h.model.settings.models, list: sampleModels).patch(choosingModel: "small", for: .orbit))
        XCTAssertEqual(h.model.settings.models.butlerEffort, "")
        let failed = await waitUntil { if case .failed = h.model.settingsSync { true } else { false } }
        XCTAssertTrue(failed)
        XCTAssertEqual(h.model.settings.models.butler, "big", "no optimistic value is left behind")
        XCTAssertEqual(h.model.settings.models.butlerEffort, "max")
    }

    func testTheDemoMacListsEffortsAndKeepsTheNewSettings() async throws {
        let h = Harness()
        let demo = MockHost(model: h.model)
        let list = try await demo.request("models.list", [:], timeout: .seconds(1)).decode(ModelsList.self)
        let bot = try XCTUnwrap(list.butler.first { $0.isDefault == true })
        XCTAssertEqual(bot.defaultEffort, "medium")
        XCTAssertFalse(try XCTUnwrap(bot.efforts).isEmpty)
        let efforts = (list.butler + list.codex).map { $0.efforts ?? [] }
        XCTAssertTrue(efforts.allSatisfy { !$0.isEmpty }, "every demo model says what it supports")
        XCTAssertGreaterThan(Set(efforts).count, 1, "the choices differ from model to model")

        let before = try await demo.request("settings.get", [:], timeout: .seconds(1)).decode(Settings.self)
        XCTAssertEqual(before.models.heartbeatEffort, "low")
        XCTAssertEqual(before.models.butlerEffort, "")
        let merged = try await demo.request("settings.set", ["models": ["butlerEffort": "high", "codexEffort": "max"]],
                                            timeout: .seconds(1)).decode(Settings.self)
        XCTAssertEqual(merged.models.butlerEffort, "high")
        XCTAssertEqual(merged.models.codexEffort, "max")
        XCTAssertEqual(merged.models.heartbeatEffort, "low", "the rest is kept")
        XCTAssertEqual(merged.models.heartbeat, before.models.heartbeat)
        let after = try await demo.request("settings.get", [:], timeout: .seconds(1)).decode(Settings.self)
        XCTAssertEqual(after.models, merged.models)
    }
}
