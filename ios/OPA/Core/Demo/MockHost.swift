import Foundation

/// Offline stand-in for the Mac host. Feeds sample events that cover every GenUI component and every task /
/// approval / connection state of the app, and answers requests with plausible data, so the UI can be exercised
/// without a Mac.
///
/// Things to try in demo mode:
/// - a pending approval (restaurant booking, with detail lines and a Face ID requirement) and an expired one;
/// - running tasks with live `session.progress`, a task waiting for you (a question), a blocked task, three finished
///   tasks (clear them with `tasks.clear`), cancel a running task (the host confirms ~1 s later);
/// - approve the booking: its task resumes and completes (deny: it is cancelled);
/// - send a message containing `[失败]` → the first attempt is refused (shows "没有送达 · 重试"; retry succeeds);
///   containing `[离线]` → the first attempt is queued and goes out ~2.5 s later ("待发送");
/// - change a setting to a persona containing `[失败]` → `settings.set` is refused and the value rolls back.
@MainActor
final class MockHost: HostBackend {
    private weak var model: AppModel?
    private var seq: Int64 = 0
    private var job: Task<Void, Never>?
    private var streamJob: Task<Void, Never>?
    private var followUps: [Task<Void, Never>] = []
    private var settings = Settings()
    private var memories: [Memory] = []
    private let base = Clock.nowMs - 3_600_000

    /// Current status and execution sessions of every demo task (so requests can be answered consistently).
    private var taskStatus: [String: String] = [:]
    private var taskSessionIds: [String: [String]] = [:]
    private var taskOrder: [String] = []
    private var sessionDocs: [String: JSONValue] = [:]
    /// chat.send idempotency: clientId → msgId.
    private var sentMessages: [String: String] = [:]
    private var refusedOnce: Set<String> = []
    private var queuedOnce: Set<String> = []

    init(model: AppModel) {
        self.model = model
        settings.butler.name = "Orbit"
        settings.butler.avatar = nil
        settings.butler.userTitle = "Herry"
        settings.butler.persona = "温和、靠谱，说话简洁，偶尔幽默。"
        settings.models = .init()
        settings.models.butler = ""
        settings.models.heartbeat = "gpt-5-mini"
        settings.models.codexDefault = "gpt-5-codex"
        settings.models.butlerEffort = ""
        settings.models.heartbeatEffort = "low"
        settings.models.codexEffort = ""
        memories = [
            Memory(id: "m1", text: "Herry 不吃香菜", kind: .preference, source: "explicit", confidence: 1, createdAt: base, updatedAt: base),
            Memory(id: "m2", text: "公司在望京 SOHO", kind: .place, source: "inferred", confidence: 0.8, createdAt: base, updatedAt: base),
            Memory(id: "m3", text: "妈妈生日是 11 月 3 日", kind: .date, source: "explicit", confidence: 1, createdAt: base, updatedAt: base),
            Memory(id: "m4", text: "出差优先订高铁二等座，靠窗", kind: .preference, source: "inferred", confidence: 0.7, createdAt: base, updatedAt: base),
        ]
    }

    func start() {
        guard let model else { return }
        model.handle(.ev(seq: 0, ts: base, k: "settings.changed", d: (try? JSONValue(encoding: settings)) ?? [:]))
        for (i, e) in Self.script(base: base).enumerated() {
            seq += 1
            track(e.k, e.d)
            model.handle(.ev(seq: seq, ts: base + Int64(i) * 1000, k: e.k, d: e.d))
        }
        job = Task { [weak self] in await self?.liveLoop() }
    }

    func stop() {
        job?.cancel()
        streamJob?.cancel()
        followUps.forEach { $0.cancel() }
        followUps = []
    }

    private func emit(_ k: String, _ d: JSONValue) {
        seq += 1
        track(k, d)
        model?.handle(.ev(seq: seq, ts: Clock.nowMs, k: k, d: d))
    }

    private func live(_ k: String, _ d: JSONValue) { model?.handle(.live(k: k, d: d)) }

    /// Remembers task / session state from the events we emit.
    private func track(_ k: String, _ d: JSONValue) {
        switch k {
        case "task.upsert":
            guard let id = d["id"]?.string else { return }
            if taskStatus[id] == nil { taskOrder.append(id) }
            taskStatus[id] = d["status"]?.string ?? "planning"
            let sids = d["steps"]?.items.compactMap { $0["sessionId"]?.string } ?? []
            var all = taskSessionIds[id] ?? []
            for s in sids where !all.contains(s) { all.append(s) }
            taskSessionIds[id] = all
        case "session.upsert":
            if let id = d["id"]?.string {
                sessionDocs[id] = d
                if let tid = d["taskId"]?.string {
                    var all = taskSessionIds[tid] ?? []
                    if !all.contains(id) { all.append(id) }
                    taskSessionIds[tid] = all
                }
            }
        case "task.remove":
            for id in d["ids"]?.items.compactMap(\.string) ?? [] {
                taskStatus[id] = nil
                taskSessionIds[id] = nil
                taskOrder.removeAll { $0 == id }
            }
        default:
            break
        }
    }

    private func later(_ seconds: Double, _ work: @escaping @MainActor () -> Void) {
        let t = Task { [weak self] in
            try? await Task.sleep(for: .seconds(seconds))
            guard !Task.isCancelled, self != nil else { return }
            work()
        }
        followUps.append(t)
    }

    /// Animates the running tasks, the ticket card and the booking card to show ui.patch / task.upsert transitions.
    private func liveLoop() async {
        try? await Task.sleep(for: .seconds(2))
        live("session.progress", ["sessionId": "s1", "text": "正在比较 3 家酒店的退改政策…"])
        live("session.progress", ["sessionId": "s5", "text": "正在把发票金额填进报销表（已填 9 / 14 张）"])
        try? await Task.sleep(for: .seconds(2.5))
        emit("ui.patch", ["id": "card-ticket", "props": ["status": "holding", "seat": "07 车 12F"]])
        try? await Task.sleep(for: .seconds(2.5))
        emit("task.upsert", Self.task(status: "running", doneThrough: 2, base: base))
        live("session.progress", ["sessionId": "s1", "text": "正在填写入住人信息"])
        try? await Task.sleep(for: .seconds(3))
        emit("ui.patch", ["id": "card-order", "props": ["status": "delivering", "eta": "约 18 分钟送达"]])
        live("session.progress", ["sessionId": "s5", "text": "已填 12 / 14 张，正在核对金额"])
    }

    // MARK: Requests

    func request(_ m: String, _ d: JSONValue, timeout: Duration) async throws -> JSONValue {
        try? await Task.sleep(for: .milliseconds(180))
        switch m {
        case "chat.send":
            return try chatSend(d)
        case "chat.interrupt":
            streamJob?.cancel()
            return [:]
        case "ui.action":
            let cardId = d["cardId"]?.string ?? ""
            let action = d["actionId"]?.string ?? ""
            if action == "undo" { emit("ui.patch", ["id": .string(cardId), "props": ["undone": true]]) }
            if cardId == "card-order", action == "confirm" { emit("ui.patch", ["id": "card-order", "props": ["status": "placed"]]) }
            if cardId == "card-ticket", action == "book" { emit("ui.patch", ["id": "card-ticket", "props": ["status": "booked", "code": "E12345678"]]) }
            if action == "select" || action == "submit" {
                emit("ui.patch", ["id": .string(cardId), "props": ["submitted": true]])
            }
            return [:]
        case "approval.respond":
            approvalRespond(d)
            return [:]
        case "task.cmd":
            taskCommand(d)
            return [:]
        case "tasks.clear":
            return tasksClear(d)
        case "session.detail":
            let sid = d["sessionId"]?.string ?? "s1"
            return [
                "session": sessionDocs[sid] ?? Self.session(id: sid, base: base),
                "items": [
                    ["kind": "plan", "text": "1. 搜索 4 晚上海外滩附近酒店\n2. 比较价格和退改\n3. 预订", "ts": .number(Double(base))],
                    ["kind": "command", "text": "curl -s https://api.example.com/hotels?city=sh", "ts": .number(Double(base + 60_000))],
                    ["kind": "message", "text": "找到 12 家符合条件的酒店，正在筛选评分 4.6 以上。", "ts": .number(Double(base + 120_000))],
                    ["kind": "fileChange", "text": "写入 notes/trip-shanghai.md", "ts": .number(Double(base + 180_000))],
                ],
            ]
        case "settings.get":
            return try JSONValue(encoding: settings)
        case "settings.set":
            if d.compactJSON.contains("[失败]") { throw OPAError.remote("演示：Mac 没有接受这项设置") }
            let merged = try JSONValue(encoding: settings).deepMerging(d)
            settings = try merged.decode(Settings.self)
            return merged
        case "models.list":
            // Every model supports a different set of efforts, so the picker's choices change with the model.
            return [
                "butler": [["id": "gpt-5", "displayName": "GPT-5", "isDefault": true, "description": "最强推理，适合复杂规划",
                            "efforts": ["minimal", "low", "medium", "high"], "defaultEffort": "medium"],
                           ["id": "gpt-5-mini", "displayName": "GPT-5 mini", "isDefault": false, "description": "更快、更省",
                            "efforts": ["minimal", "low", "medium"], "defaultEffort": "low"],
                           ["id": "gpt-6.1-sol", "displayName": "GPT-6.1 Sol", "isDefault": false,
                            "efforts": ["low", "medium", "high", "xhigh", "max"], "defaultEffort": "medium"]],
                "codex": [["id": "gpt-5-codex", "displayName": "GPT-5 Codex", "isDefault": true,
                           "efforts": ["low", "medium", "high"], "defaultEffort": "medium"],
                          ["id": "gpt-5", "displayName": "GPT-5", "isDefault": false,
                           "efforts": ["minimal", "low", "medium", "high"], "defaultEffort": "medium"],
                          ["id": "gpt-6.1-sol", "displayName": "GPT-6.1 Sol", "isDefault": false,
                           "efforts": ["low", "medium", "high", "xhigh", "max"], "defaultEffort": "medium"]],
            ]
        case "memory.list":
            return ["items": try JSONValue(encoding: memories)]
        case "memory.add":
            let mem = Memory(id: ShortID.make(), text: d["text"]?.string ?? "", kind: Memory.Kind(rawValue: d["kind"]?.string ?? "") ?? .fact,
                             source: "explicit", confidence: 1, createdAt: Clock.nowMs, updatedAt: Clock.nowMs)
            memories.insert(mem, at: 0)
            emit("memory.changed", [:])
            return try JSONValue(encoding: mem)
        case "memory.delete":
            memories.removeAll { $0.id == d["id"]?.string }
            emit("memory.changed", [:])
            return [:]
        case "devices.list":
            return ["devices": [["id": .string(model?.identity.deviceId ?? "this"), "name": .string(model?.deviceName ?? "iPhone"),
                                 "pairedAt": .number(Double(base)), "lastSeen": .number(Double(Clock.nowMs))],
                                ["id": "ipad-1", "name": "Herry 的 iPad", "pairedAt": .number(Double(base - 86_400_000 * 9)), "lastSeen": .number(Double(base - 86_400_000))]]]
        case "import.add":
            return ["ids": .array(d["items"]?.items.map { _ in .string(ShortID.make()) } ?? [])]
        case "sync":
            return ["fromSeq": 0, "toSeq": .number(Double(seq)), "reset": false]
        case "ping":
            return ["ts": .number(Double(Clock.nowMs))]
        default:
            return [:]
        }
    }

    // MARK: chat.send

    private func chatSend(_ d: JSONValue) throws -> JSONValue {
        let clientId = d["clientId"]?.string ?? ""
        // Idempotent: a repeated clientId gets the existing msgId and is not handed to the bot again.
        if !clientId.isEmpty, let existing = sentMessages[clientId] { return ["msgId": .string(existing)] }
        let text = d["text"]?.string ?? ""
        if !clientId.isEmpty {
            if text.contains("[离线]"), queuedOnce.insert(clientId).inserted {
                // Simulates "Mac offline": this attempt is not delivered; the connection "comes back" shortly.
                later(2.5) { [weak self] in Task { await self?.model?.flushOutbox() } }
                throw OPAError.notConnected
            }
            if text.contains("[失败]"), refusedOnce.insert(clientId).inserted {
                throw OPAError.remote("演示：Mac 暂时没法处理这条消息（再试一次会成功）")
            }
        }
        let msgId = "msg-" + ShortID.make()
        if !clientId.isEmpty { sentMessages[clientId] = msgId }
        var echo = d
        if case .object(var o) = echo { o["id"] = .string(msgId); o["ts"] = .number(Double(Clock.nowMs)); echo = .object(o) }
        emit("msg.user", echo)
        streamReply(to: text)
        return ["msgId": .string(msgId)]
    }

    /// How long the demo "thinks" before the reply starts. Debug builds can stretch it with `-OPAThinkingHold 30` to look at
    /// (or screenshot) the waiting screen.
    private static var thinkingSeconds: Double {
        #if DEBUG
        let hold = UserDefaults.standard.double(forKey: "OPAThinkingHold")
        if hold > 0 { return hold }
        #endif
        return 0.9
    }

    private func streamReply(to text: String) {
        streamJob?.cancel()
        streamJob = Task { [weak self] in
            guard let self else { return }
            let id = "a-" + ShortID.make()
            self.live("butler.status", ["state": "thinking"])
            try? await Task.sleep(for: .seconds(Self.thinkingSeconds))
            self.live("msg.start", ["id": .string(id)])
            self.live("butler.status", ["state": "acting"])
            let reply = "好的，Herry。我已经记下「\(text.prefix(24))」。这是演示模式，我会模拟真实 bot的流式输出：先思考，再逐字回复，必要时插入卡片。"
            var acc = ""
            var interrupted = false
            for ch in reply {
                if Task.isCancelled { interrupted = true; break }
                acc.append(ch)
                self.live("msg.delta", ["id": .string(id), "text": .string(String(ch))])
                try? await Task.sleep(for: .milliseconds(28))
            }
            self.emit("msg.assistant", ["id": .string(id), "text": .string(acc), "interrupted": .bool(interrupted), "ts": .number(Double(Clock.nowMs))])
            self.live("butler.status", ["state": "idle"])
        }
    }

    // MARK: Approvals, tasks

    private func approvalRespond(_ d: JSONValue) {
        let id = d["approvalId"]?.string ?? ""
        let approve = d["decision"]?.string != "deny"
        emit("approval.resolved", ["id": .string(id), "decision": approve ? "approve" : "deny", "by": "user"])
        guard id == "ap1" else { return }
        // The booking approval belongs to task t8: approved → it resumes and completes; denied → it is cancelled.
        if approve {
            later(1.2) { [weak self] in
                guard let self else { return }
                self.emit("task.upsert", Self.bookingTask(status: "running", doneThrough: 3, now: Clock.nowMs))
                self.live("session.progress", ["sessionId": "s8", "text": "正在提交预订…"])
            }
            later(3.6) { [weak self] in
                guard let self else { return }
                self.emit("task.upsert", Self.bookingTask(status: "done", doneThrough: 4, now: Clock.nowMs,
                                                          summary: "已预订：鮨 · 静安店，10 月 18 日周六 19:00，2 人，吧台位。"))
                self.emit("ui.patch", ["id": "card-booking", "props": ["status": "confirmed", "confirmation": "HT-82731"]])
            }
        } else {
            later(1.0) { [weak self] in
                guard let self else { return }
                self.emit("task.upsert", Self.bookingTask(status: "cancelled", doneThrough: 3, now: Clock.nowMs, summary: "你拒绝了这次预订。"))
            }
        }
    }

    private func taskCommand(_ d: JSONValue) {
        switch d["cmd"]?.string {
        case "cancel":
            guard let id = d["taskId"]?.string, let status = taskStatus[id],
                  ["planning", "running", "waiting_user", "blocked"].contains(status) else { return }
            // The host confirms a moment later, so the app can show "正在取消…" in between.
            later(1.0) { [weak self] in
                guard let self, var task = Self.demoTasks(now: Clock.nowMs).first(where: { $0.id == id }) else { return }
                task.status = "cancelled"
                task.updatedAt = Clock.nowMs
                self.emit("task.upsert", task.json)
                for sid in self.taskSessionIds[id] ?? [] {
                    if case .object(var o)? = self.sessionDocs[sid] {
                        o["status"] = "idle"
                        self.emit("session.upsert", .object(o))
                    }
                }
            }
        case "archive":
            if let sid = d["sessionId"]?.string, case .object(var o)? = sessionDocs[sid] {
                o["status"] = "archived"
                emit("session.upsert", .object(o))
            }
        default:
            break
        }
    }

    /// `tasks.clear {ids?}`: removes finished tasks (done / failed / cancelled), archives their sessions,
    /// broadcasts `task.remove` and answers `{removed}`.
    private func tasksClear(_ d: JSONValue) -> JSONValue {
        let finished = ["done", "failed", "cancelled"]
        let requested = d["ids"]?.array?.compactMap(\.string)
        let ids = taskOrder.filter { id in
            guard let status = taskStatus[id], finished.contains(status) else { return false }
            return requested?.contains(id) ?? true
        }
        guard !ids.isEmpty else { return ["removed": []] }
        for id in ids {
            for sid in taskSessionIds[id] ?? [] {
                if case .object(var o)? = sessionDocs[sid] {
                    o["status"] = "archived"
                    emit("session.upsert", .object(o))
                }
            }
        }
        emit("task.remove", ["ids": .array(ids.map(JSONValue.string))])
        return ["removed": .array(ids.map(JSONValue.string))]
    }
}

// MARK: - Sample script

extension MockHost {
    struct E { var k: String; var d: JSONValue }

    static func card(_ id: String, _ component: String, _ props: JSONValue, actions: [JSONValue] = [], ts: Int64) -> E {
        E(k: "ui.render", d: ["card": ["id": .string(id), "component": .string(component), "props": props,
                                       "actions": .array(actions), "ts": .number(Double(ts))]])
    }

    static func act(_ id: String, _ label: String, _ style: String = "secondary", approval: Bool = false) -> JSONValue {
        ["id": .string(id), "label": .string(label), "style": .string(style), "requiresApproval": .bool(approval)]
    }

    /// A demo task as plain data, so it can be emitted again with another status.
    struct DemoTask {
        var id: String
        var title: String
        var goal: String
        var status: String
        /// (title, status, sessionId)
        var steps: [(String, String, String?)]
        var summary: String?
        var createdAt: Int64
        var updatedAt: Int64

        var json: JSONValue {
            var o: [String: JSONValue] = [
                "id": .string(id), "title": .string(title), "goal": .string(goal), "status": .string(status),
                "steps": .array(steps.enumerated().map { i, s in
                    var step: [String: JSONValue] = ["id": .string("\(id)-st\(i)"), "title": .string(s.0), "status": .string(s.1)]
                    if let sid = s.2 { step["sessionId"] = .string(sid) }
                    return .object(step)
                }),
                "createdAt": .number(Double(createdAt)), "updatedAt": .number(Double(updatedAt)),
            ]
            if let summary { o["summary"] = .string(summary) }
            return .object(o)
        }
    }

    private static func steps(_ titles: [String], doneThrough: Int, session: String?) -> [(String, String, String?)] {
        titles.enumerated().map { i, t in
            (t, i < doneThrough ? "done" : (i == doneThrough ? "running" : "pending"), session)
        }
    }

    /// t1 — the hotel task of the chat script (kept: `liveLoop` re-emits it with more steps done).
    static func task(status: String, doneThrough: Int, base: Int64) -> JSONValue {
        let titles = ["搜索外滩附近酒店", "比较价格与退改政策", "填写入住信息", "提交预订"]
        return DemoTask(id: "t1", title: "预订上海出差酒店", goal: "10 月 20–24 日，外滩附近，预算 ¥900/晚", status: status,
                        steps: steps(titles, doneThrough: doneThrough, session: "s1"), summary: nil,
                        createdAt: base, updatedAt: Clock.nowMs).json
    }

    /// t8 — the restaurant booking whose session waits for approval `ap1`.
    static func bookingTask(status: String, doneThrough: Int, now: Int64, summary: String? = "预订已准备好，等你批准后提交") -> JSONValue {
        DemoTask(id: "t8", title: "订周六晚的日料",
                 goal: "找 3 家评分 4.5+、人均 ¥300 内的店", status: status,
                 steps: steps(["理解需求", "搜索附近的日料店", "核对周六 19:00 的空位", "你选定后提交预订"], doneThrough: doneThrough, session: "s8"),
                 summary: summary, createdAt: now - 25 * 60_000, updatedAt: now - 60_000).json
    }

    static func demoTasks(now: Int64) -> [DemoTask] {
        let min: Int64 = 60_000
        return [
            DemoTask(id: "t1", title: "预订上海出差酒店", goal: "10 月 20–24 日，外滩附近，预算 ¥900/晚", status: "running",
                     steps: steps(["搜索外滩附近酒店", "比较价格与退改政策", "填写入住信息", "提交预订"], doneThrough: 1, session: "s1"),
                     summary: nil, createdAt: now - 58 * min, updatedAt: now - 2 * min),
            DemoTask(id: "t5", title: "整理 9 月发票做报销表", goal: "把邮箱里的 PDF 发票金额填进报销表", status: "running",
                     steps: steps(["找出邮箱里的 PDF 发票", "识别金额和日期", "填进报销表模板", "检查并保存"], doneThrough: 2, session: "s5"),
                     summary: nil, createdAt: now - 40 * min, updatedAt: now - 3 * min),
            // Running: the execution session is blocked on approval `ap1` (the task itself is not "waiting for you").
            DemoTask(id: "t8", title: "订周六晚的日料",
                     goal: "找 3 家评分 4.5+、人均 ¥300 内的店", status: "running",
                     steps: steps(["理解需求", "搜索附近的日料店", "核对周六 19:00 的空位", "你选定后提交预订"], doneThrough: 3, session: "s8"),
                     summary: "预订已准备好，等你批准后提交", createdAt: now - 25 * min, updatedAt: now - 1 * min),
            DemoTask(id: "t2", title: "比较两款降噪耳机", goal: "想先确认预算：在 ¥2000 以内吗？", status: "waiting_user",
                     steps: steps(["收集两款耳机的参数", "确认预算", "整理对比"], doneThrough: 1, session: nil),
                     summary: nil, createdAt: now - 18 * min, updatedAt: now - 6 * min),
            DemoTask(id: "t3", title: "查询本月社保缴费", goal: "在微信小程序里查本月社保缴费明细", status: "blocked",
                     steps: steps(["打开微信小程序", "完成微信登录验证", "读取缴费明细"], doneThrough: 1, session: "s3"),
                     summary: "需要你在安卓手机上完成微信登录验证，完成后告诉我。", createdAt: now - 30 * min, updatedAt: now - 12 * min),
            DemoTask(id: "t4", title: "在桌面创建 orbit-test.txt", goal: "创建文件，写入今天的日期", status: "done",
                     steps: [("创建文件", "done", "s4"), ("写入今天的日期", "done", "s4"), ("重新打开核对", "done", "s4")],
                     summary: "已在桌面创建 orbit-test.txt，内容是今天的日期。", createdAt: now - 70 * min, updatedAt: now - 40 * min),
            DemoTask(id: "t6", title: "同步旧手机通讯录", goal: "把旧手机导出的通讯录导入 Mac", status: "failed",
                     steps: [("找到通讯录导出文件", "failed", "s6"), ("导入到 Mac 通讯录", "pending", "s6")],
                     summary: "Mac 上没有找到导出的通讯录文件。", createdAt: now - 3 * 60 * min, updatedAt: now - 2 * 60 * min),
            DemoTask(id: "t7", title: "订周日的电影票", goal: "周日下午的场次，两张连座", status: "cancelled",
                     steps: [("查询场次", "done", "s7"), ("选座", "skipped", "s7")],
                     summary: nil, createdAt: now - 4 * 60 * min, updatedAt: now - 3 * 60 * min),
        ]
    }

    static func session(id: String, base: Int64) -> JSONValue {
        ["id": .string(id), "taskId": "t1", "title": "酒店搜索与预订", "model": "gpt-5-codex", "status": "running",
         "permission": "manual", "lastActivity": "比较退改政策", "createdAt": .number(Double(base)), "updatedAt": .number(Double(base + 200_000))]
    }

    private static func sessionDoc(_ id: String, task: String, title: String, status: String, activity: String?, now: Int64, ageMin: Int64) -> JSONValue {
        var o: [String: JSONValue] = [
            "id": .string(id), "taskId": .string(task), "title": .string(title), "model": "gpt-5-codex", "status": .string(status),
            "permission": "manual", "createdAt": .number(Double(now - ageMin * 60_000)), "updatedAt": .number(Double(now - 60_000)),
        ]
        if let activity { o["lastActivity"] = .string(activity) }
        return .object(o)
    }

    /// Two everyday requests, answered the way the Mac would: places on a map (`map_place`: name, address, rating, phone) and a
    /// reading list of saved links (`link_preview`, one-sentence summary each). Everything here is made up: the shops, the
    /// pages (they point at example.com) and the phone numbers (they are not dialable).
    private static func placeAndLinkScript(base: Int64) -> [E] {
        let t = { (i: Int64) in base + i * 60_000 }
        return [
            E(k: "msg.user", d: ["id": "u2", "clientId": "c2", "text": "周六想在徐汇找个安静的咖啡店谈事，晚饭也顺路找一家", "ts": .number(Double(t(19) + 20_000))]),
            E(k: "msg.assistant", d: ["id": "a3", "text": "找到两家：下午去这家咖啡店，晚饭就在附近。", "ts": .number(Double(t(19) + 30_000))]),
            card("card-place-cafe", "map_place", ["name": "梧桐咖啡 · 安福路店", "address": "上海市徐汇区安福路 218 号",
                                                  "lat": 31.2127, "lon": 121.4418, "rating": 4.7, "phone": "+86 21 1043 2078"], ts: t(19) + 40_000),
            card("card-place-dinner", "map_place", ["name": "弄堂里 · 本帮小馆", "address": "上海市徐汇区武康路 118 号",
                                                    "lat": 31.2092, "lon": 121.4381, "rating": 4.6, "phone": "+86 21 1058 3316"], ts: t(19) + 50_000),
            E(k: "msg.user", d: ["id": "u3", "clientId": "c3", "text": "这周收藏的几个链接，帮我整理成摘要，周末看", "ts": .number(Double(t(19) + 55_000))]),
            E(k: "msg.assistant", d: ["id": "a4", "text": "整理好了，一共 5 条，每条一句话摘要：", "ts": .number(Double(t(19) + 58_000))]),
            card("card-link-coffee", "link_preview", [
                "url": "https://example.com/reading/pour-over-basics", "siteName": "慢读周刊",
                "title": "手冲咖啡入门：研磨、水温、注水先调哪个",
                "description": "新手最容易忽略的是研磨粗细：先固定水温和粉水比，只调研磨，几杯之内就能找到合口味的那一档。"], ts: t(19) + 59_000),
            card("card-link-travel", "link_preview", [
                "url": "https://example.com/travel/japan-first-trip", "siteName": "出行笔记",
                "title": "第一次去日本自由行，行程怎么排才不累",
                "description": "每天只排一个主要目的地，其余留给临时起意；交通卡和网络提前备好，酒店尽量住在同一个区。"], ts: t(19) + 59_100),
            card("card-link-desk", "link_preview", [
                "url": "https://example.com/goods/standing-desk", "siteName": "好物清单",
                "title": "实木升降电脑桌 双电机 可调节高度 家用书桌",
                "description": "价格 ¥1,299，桌面 120×60 cm；评价里提到安装需要两个人，升到最高时桌面略有晃动。"], ts: t(19) + 59_200),
            card("card-link-recipe", "link_preview", [
                "url": "https://example.com/recipes/tomato-beef-stew", "siteName": "家常菜谱",
                "title": "番茄炖牛腩：先煎后炖，汤更清爽",
                "description": "牛腩先焯水再煎香，番茄炒出汁后小火慢炖，出锅前再加盐；整个过程大约一个半小时。"], ts: t(19) + 59_300),
            card("card-link-reading", "link_preview", [
                "url": "https://example.com/reading/how-to-finish-a-book", "siteName": "读书笔记",
                "title": "怎么读完一本书：先看目录，再带着问题读",
                "description": "先花十分钟翻目录和结论，带着两三个问题去读；读到哪里记到哪里，一周之内回看一次最有效。"], ts: t(19) + 59_400),
        ]
    }

    static func script(base: Int64) -> [E] {
        let now = Clock.nowMs
        let t = { (i: Int64) in base + i * 60_000 }
        let day = Calendar.current.startOfDay(for: Date())
        let ms = { (h: Double, dayOffset: Double) in Double(Clock.ms(day.addingTimeInterval(dayOffset * 86400 + h * 3600))) }
        var events: [E] = [
            E(k: "msg.assistant", d: ["id": "a0", "text": "早上好 Herry ☀️ 今天北京晴，16–24°C。你 10 点有一个产品评审，我已经把相关文档放在下面了。", "proactive": true, "ts": .number(Double(t(0)))]),
            card("card-text", "text_card", ["title": "今日要点", "icon": "sun.max",
                                             "markdown": "- **10:00** 产品评审（3 号会议室）\n- 下午 *15:30* 前回复张总邮件\n- 记得给妈妈订生日蛋糕 🎂\n\n详情见 [日历](https://calendar.apple.com)"], ts: t(1)),
            card("card-cal", "calendar_events", ["title": "接下来的日程", "events": [
                ["title": "产品评审", "start": .number(ms(10, 0)), "end": .number(ms(11, 30)), "location": "3 号会议室", "calendar": "工作", "color": "#E07B53"],
                ["title": "午餐 · 和 Lily", "start": .number(ms(12, 0)), "end": .number(ms(13, 0)), "location": "望京 SOHO", "color": "#4F9D69"],
                ["title": "健身", "start": .number(ms(19, 0)), "end": .number(ms(20, 0)), "calendar": "个人", "color": "#5B7FDB"],
                ["title": "飞上海", "start": .number(ms(8, 1)), "end": .number(ms(10.5, 1)), "location": "首都机场 T3", "color": "#9B6BD3"],
            ]], ts: t(2)),
            E(k: "msg.user", d: ["id": "u1", "clientId": "c1", "text": "帮我订下周去上海出差的酒店和高铁，顺便点个午饭", "ts": .number(Double(t(3)))]),
        ]

        // Execution sessions and tasks (every task state of the app).
        events += [
            E(k: "session.upsert", d: session(id: "s1", base: base)),
            E(k: "session.upsert", d: sessionDoc("s5", task: "t5", title: "报销表整理", status: "running", activity: "填进报销表模板", now: now, ageMin: 40)),
            E(k: "session.upsert", d: sessionDoc("s8", task: "t8", title: "大众点评查询空位", status: "waiting_approval", activity: "等待你的确认", now: now, ageMin: 25)),
            E(k: "session.upsert", d: sessionDoc("s3", task: "t3", title: "微信小程序查询", status: "idle", activity: "等待登录验证", now: now, ageMin: 30)),
            E(k: "session.upsert", d: sessionDoc("s4", task: "t4", title: "创建桌面文件", status: "idle", activity: "已完成", now: now, ageMin: 70)),
            E(k: "session.upsert", d: sessionDoc("s6", task: "t6", title: "导入通讯录", status: "error", activity: "找不到导出文件", now: now, ageMin: 180)),
            E(k: "session.upsert", d: sessionDoc("s7", task: "t7", title: "电影票查询", status: "idle", activity: "已取消", now: now, ageMin: 240)),
        ]
        events += demoTasks(now: now).map { E(k: "task.upsert", d: $0.json) }
        events += [
            E(k: "msg.assistant", d: ["id": "a1", "text": "收到。我开了一个任务去订酒店，进度在这里：", "ts": .number(Double(t(4)))]),
            card("card-progress", "task_progress", ["taskId": "t1"], ts: t(5)),
            card("card-compare", "comparison", ["title": "酒店对比", "recommendedId": "h2", "items": [
                ["id": "h1", "title": "外滩茂悦", "subtitle": "黄浦江景 · 4.7 分", "price": "¥1,180/晚", "pros": ["江景", "早餐丰富"], "cons": ["超预算"],
                 "imageUrl": "https://picsum.photos/seed/hotel1/600/400"],
                ["id": "h2", "title": "璞丽酒店", "subtitle": "静安 · 4.8 分", "price": "¥880/晚", "pros": ["安静", "离客户近", "可免费取消"], "cons": ["无江景"],
                 "highlight": "最划算", "imageUrl": "https://picsum.photos/seed/hotel2/600/400"],
                ["id": "h3", "title": "全季酒店", "subtitle": "南京东路 · 4.5 分", "price": "¥420/晚", "pros": ["便宜"], "cons": ["房间小", "隔音一般"],
                 "imageUrl": "https://picsum.photos/seed/hotel3/600/400"],
            ]], actions: [act("pick_h2", "就订璞丽", "primary")], ts: t(6)),
            card("card-booking", "booking_card", ["kind": "hotel", "name": "璞丽酒店 · 豪华大床房", "time": "10/20 入住 · 4 晚", "partySize": 1,
                                                   "address": "上海市静安区常德路 1 号", "status": "pending", "note": "已备注高楼层、安静房间"], ts: t(7)),
            card("card-ticket", "ticket_card", ["kind": "train", "title": "G7 次 · 二等座", "from": "北京南", "to": "上海虹桥",
                                                 "departAt": .number(ms(8, 6)), "arriveAt": .number(ms(12.6, 6)), "price": 662, "currency": "CNY", "status": "options"],
                 actions: [act("book", "锁座并支付", "primary", approval: true), act("other", "看看其他车次")], ts: t(8)),
            // Pending approval for task t8: `标签：内容` lines + a closing `批准后：` line, 29 minutes left, Face ID required.
            E(k: "approval.request", d: ["id": "ap1", "title": "提交这家餐厅的预订",
                                         "detail": "餐厅：鮨 · 静安店（大众点评 4.8）\n时间：10 月 18 日 周六 19:00\n人数：2 人 · 吧台位\n费用：人均 ¥280，到店付款\n批准后：我会在安卓手机上用大众点评提交预订，餐厅可能会发确认短信。不会在线付款。",
                                         "risk": "medium", "kind": "action", "requireBiometric": true,
                                         "createdAt": .number(Double(now - 1 * 60_000)), "expiresAt": .number(Double(now + 29 * 60_000))]),
            card("card-approval", "approval_card", ["approvalId": "ap1"], ts: t(9)),
            // An approval that already timed out: its card must show "已过期" and offer no buttons.
            // A request that comes out of an execution, as the host writes it: the title is just "执行命令"; the command and
            // the directory are technical and sit behind "技术详情"; only the reason is shown in the open.
            E(k: "approval.request", d: ["id": "ap2", "title": "执行命令",
                                         "detail": "npm publish\n原因：发布 v0.3.1 到 npm\n目录：~/code/opa-skill\n批准后：Orbit 会把新版本发布出去，发布后无法撤回。",
                                         "risk": "high", "sessionId": "s1", "kind": "command", "requireBiometric": true,
                                         "createdAt": .number(Double(now - 40 * 60_000)), "expiresAt": .number(Double(now - 10 * 60_000))]),
            card("card-approval-expired", "approval_card", ["approvalId": "ap2"], ts: t(10)),
            card("card-order", "order_card", ["merchant": "和府捞面（望京店）", "imageUrl": "https://picsum.photos/seed/noodle/600/300",
                                               "items": [["name": "草本汤牛肉面", "qty": 1, "price": 39, "note": "不要香菜"], ["name": "卤蛋", "qty": 2, "price": 4]],
                                               "fees": [["label": "配送费", "amount": 5], ["label": "优惠", "amount": -8]], "total": 44, "currency": "CNY", "status": "draft"],
                 actions: [act("confirm", "确认下单 ¥44", "primary", approval: true), act("change", "换一家")], ts: t(11)),
            card("card-choice", "choice_list", ["question": "高铁座位偏好？", "multi": false, "options": [
                ["id": "window", "label": "靠窗", "detail": "A / F 座"], ["id": "aisle", "label": "靠过道", "detail": "C / D 座"], ["id": "any", "label": "都可以"]]], ts: t(12)),
            card("card-budget", "choice_list", ["question": "降噪耳机预算上限？", "multi": false, "options": [
                ["id": "1000", "label": "¥1000 以内"], ["id": "2000", "label": "¥2000 以内"], ["id": "any", "label": "不限"]]], ts: t(13)),
            card("card-form", "form", ["title": "出差信息确认", "submitLabel": "提交", "fields": [
                ["key": "name", "label": "入住人", "type": "text", "value": "Herry", "required": true],
                ["key": "guests", "label": "人数", "type": "number", "value": 1],
                ["key": "date", "label": "入住日期", "type": "date"],
                ["key": "arrive", "label": "预计到店", "type": "time"],
                ["key": "bed", "label": "床型", "type": "select", "options": ["大床", "双床"], "value": "大床"],
                ["key": "invoice", "label": "需要发票", "type": "toggle", "value": true],
            ]], ts: t(14)),
            card("card-table", "table", ["title": "本月开销", "columns": [["key": "cat", "label": "类别"], ["key": "amt", "label": "金额", "align": "right"], ["key": "pct", "label": "占比", "align": "right"]],
                                          "rows": [["cat": "餐饮", "amt": 2380, "pct": "34%"], ["cat": "交通", "amt": 960, "pct": "14%"],
                                                   ["cat": "购物", "amt": 2210, "pct": "32%"], ["cat": "其他", "amt": 1400, "pct": "20%"]],
                                          "footnote": "数据来自你导入的账单截图"], ts: t(15)),
            card("card-link", "link_preview", ["url": "https://www.apple.com/newsroom/", "title": "Apple Newsroom", "siteName": "apple.com",
                                                "description": "你上周收藏的文章已整理好，这是原文链接。", "imageUrl": "https://picsum.photos/seed/news/800/400"], ts: t(16)),
            card("card-doc", "document", ["title": "产品评审纪要（草稿）", "markdown": "## 结论\n1. Q4 先做 **iOS 端**\n2. Relay 用 Cloudflare\n\n## 待办\n- 设计稿 — 周五\n- 协议冻结 — 下周一\n\n> 以上由 Orbit 根据录音整理。",
                                           "attachments": [["name": "评审录音.m4a", "url": "https://example.com/a.m4a"]]], ts: t(17)),
            card("card-gallery", "image_gallery", ["title": "上次去上海的照片", "images": [
                ["url": "https://picsum.photos/seed/sh1/800/600", "caption": "外滩夜景"], ["url": "https://picsum.photos/seed/sh2/800/600", "caption": "武康路"],
                ["url": "https://picsum.photos/seed/sh3/800/600", "caption": "新天地"]]], ts: t(18)),
            card("card-map", "map_place", ["name": "璞丽酒店", "address": "上海市静安区常德路 1 号", "lat": 31.2235, "lon": 121.4498, "rating": 4.8, "phone": "+86 21 3203 9999"], ts: t(19)),
        ]
        events += placeAndLinkScript(base: base)
        events += [
            card("card-video", "video", ["url": "https://devstreaming-cdn.apple.com/videos/streaming/examples/img_bipbop_adv_example_fmp4/master.m3u8",
                                          "title": "示例视频", "posterUrl": "https://picsum.photos/seed/poster/800/450"], ts: t(20)),
            E(k: "memory.changed", d: [:]),
            card("card-mem", "memory_saved", ["memoryId": "m1", "text": "Herry 不吃香菜"], ts: t(21)),
            card("card-unknown", "weather_widget", ["city": "北京", "temp": 22], ts: t(22)),
            E(k: "msg.assistant", d: ["id": "a2", "text": "以上都是演示数据。试着发一句话，看看流式回复和打断按钮；消息里写上 [失败] 或 [离线] 可以看到“没有送达”和“待发送”。", "ts": .number(Double(t(23)))]),
        ]
        return events
    }
}
