import XCTest
@testable import OPA

@MainActor
final class ApprovalTests: XCTestCase {
    // MARK: Detail parsing

    private func parse(_ detail: String) -> (rows: [(String, String)], note: String?) {
        let a = Payload.approvalValue(id: "a", detail: detail)
        return (a.detailRows, a.detailNote)
    }

    private func assertRows(_ rows: [(String, String)], _ expected: [(String, String)], file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertEqual(rows.count, expected.count, "\(rows)", file: file, line: line)
        for (r, e) in zip(rows, expected) {
            XCTAssertEqual(r.0, e.0, file: file, line: line)
            XCTAssertEqual(r.1, e.1, file: file, line: line)
        }
    }

    func testTheHostsFormatBecomesATableAndANote() {
        let p = parse("""
        餐厅：鮨 · 静安店（大众点评 4.8）
        时间：10 月 18 日 周六 19:00
        人数：2 人 · 吧台位
        费用：人均 ¥280，到店付款
        批准后：我会在你的安卓手机上用大众点评提交预订，餐厅可能会给你发确认短信。
        """)
        assertRows(p.rows, [("餐厅", "鮨 · 静安店（大众点评 4.8）"), ("时间", "10 月 18 日 周六 19:00"),
                            ("人数", "2 人 · 吧台位"), ("费用", "人均 ¥280，到店付款")])
        XCTAssertEqual(p.note, "批准后：我会在你的安卓手机上用大众点评提交预订，餐厅可能会给你发确认短信。")
    }

    func testBothColonsAreAccepted() {
        let p = parse("标签:内容\n另一个：值\nKey: value")
        assertRows(p.rows, [("标签", "内容"), ("另一个", "值"), ("Key", "value")])
        XCTAssertNil(p.note)
    }

    func testTheValueMayContainMoreColons() {
        assertRows(parse("时间：今天 19:30，改到 20:00").rows, [("时间", "今天 19:30，改到 20:00")])
        assertRows(parse("网址：https://example.com/a").rows, [("网址", "https://example.com/a")])
    }

    func testLabelsLongerThanEightCharactersAreNotLabels() {
        let p = parse("一二三四五六七八：刚好八个字\n一二三四五六七八九：九个字的标签")
        assertRows(p.rows, [("一二三四五六七八", "刚好八个字")])
        XCTAssertEqual(p.note, "一二三四五六七八九：九个字的标签")
    }

    func testOtherLinesBecomeTheNote() {
        let p = parse("Codex 想在目录中发布新版本\n原因：需要写入 npm registry\n目录：~/code/opa-skill\n发布后无法撤回")
        assertRows(p.rows, [("原因", "需要写入 npm registry"), ("目录", "~/code/opa-skill")])
        XCTAssertEqual(p.note, "Codex 想在目录中发布新版本\n发布后无法撤回")
    }

    func testTheApprovalLineGoesToTheNoteInBothSpellingsAndIsNeverATableRow() {
        let p = parse("金额：¥96\n批准后：我会下单\n批准后:并通知你")
        assertRows(p.rows, [("金额", "¥96")])
        XCTAssertEqual(p.note, "批准后：我会下单\n批准后:并通知你")
    }

    func testThingsThatMerelyContainAColonAreNotRows() {
        let p = parse("https://example.com/path\n10:30 开始\necho \"a: b\"\n： 没有标签\n标签：")
        XCTAssertTrue(p.rows.isEmpty, "\(p.rows)")
        XCTAssertEqual(p.note, "https://example.com/path\n10:30 开始\necho \"a: b\"\n： 没有标签\n标签：")
    }

    func testBulletsAndNumbersInFrontOfALabelAreIgnored() {
        let p = parse("- 餐厅：鮨 · 静安店\n• 时间：周六 19:00\n· 人数：2 人\n* 费用：到店付款\n1. 地址：常德路 1 号\n2、电话：021-1234\n3) 备注：靠窗")
        assertRows(p.rows, [("餐厅", "鮨 · 静安店"), ("时间", "周六 19:00"), ("人数", "2 人"), ("费用", "到店付款"),
                            ("地址", "常德路 1 号"), ("电话", "021-1234"), ("备注", "靠窗")])
        XCTAssertNil(p.note)
        XCTAssertEqual(ApprovalDetailParser.strippingListMarker("-没有空格"), "-没有空格", "a dash glued to the text is not a bullet")
        XCTAssertEqual(ApprovalDetailParser.strippingListMarker("12345. 太长的编号"), "12345. 太长的编号")
        XCTAssertEqual(ApprovalDetailParser.strippingListMarker("3.5：不是编号"), "3.5：不是编号")
        XCTAssertEqual(ApprovalDetailParser.strippingListMarker("1）金额：5"), "金额：5")
    }

    func testLabelsMayContainSlashesParenthesesAndSpaces() {
        let p = parse("人数/房型：2 人 · 大床\n金额（元）：880\nMac 命令：npm publish\n收件人&抄送：Lily")
        assertRows(p.rows, [("人数/房型", "2 人 · 大床"), ("金额（元）", "880"), ("Mac 命令", "npm publish"), ("收件人&抄送", "Lily")])
    }

    func testCommandsWithColonsStayInTheNote() {
        let p = parse("docker run -p 8080:80 nginx\nssh me@host:~/dir\nFOO=bar: baz\nnpm run build:prod")
        XCTAssertTrue(p.rows.isEmpty, "\(p.rows)")
    }

    func testBlankLinesAreIgnoredAndWhitespaceIsTrimmed() {
        let p = parse("\n  地点 ：  望京 SOHO  \r\n\r\n   \n时间：  明天\n")
        assertRows(p.rows, [("地点", "望京 SOHO"), ("时间", "明天")])
        XCTAssertNil(p.note)
    }

    func testEmptyDetail() {
        let p = parse("")
        XCTAssertTrue(p.rows.isEmpty)
        XCTAssertNil(p.note)
        XCTAssertNil(parse("   \n  ").note)
    }

    func testPlainTextOnlyIsAllNote() {
        let p = parse("Codex 想在 ~/code 中发布 v0.3.1 到 npm。")
        XCTAssertTrue(p.rows.isEmpty)
        XCTAssertEqual(p.note, "Codex 想在 ~/code 中发布 v0.3.1 到 npm。")
    }

    // MARK: Expiry

    func testExpiryBoundaries() {
        let a = Payload.approvalValue(id: "a", expiresAt: 10_000)
        XCTAssertFalse(a.isExpired(now: 9_999))
        XCTAssertTrue(a.isExpired(now: 10_000))
        XCTAssertTrue(a.isExpired(now: 10_001))
        XCTAssertFalse(Payload.approvalValue(id: "b", expiresAt: nil).isExpired(now: .max), "no expiry never expires")
        XCTAssertTrue(a.isExpired(now: Date(timeIntervalSince1970: 11)))
        XCTAssertFalse(a.isExpired(now: Date(timeIntervalSince1970: 9)))
    }

    func testPendingApprovalsExcludeExpiredAndAnsweredOnes() {
        let h = Harness()
        h.model.nowMs = { 100_000 }
        h.model.ev(1, "approval.request", Payload.approval(id: "open-old", createdAt: 1_000, expiresAt: 500_000))
        h.model.ev(2, "approval.request", Payload.approval(id: "open-new", createdAt: 3_000))
        h.model.ev(3, "approval.request", Payload.approval(id: "expired", createdAt: 2_000, expiresAt: 99_999))
        h.model.ev(4, "approval.request", Payload.approval(id: "answered", createdAt: 4_000))
        h.model.ev(5, "approval.resolved", ["id": "answered", "decision": "approve", "by": "user"])
        XCTAssertEqual(h.model.pendingApprovals.map(\.id), ["open-new", "open-old"], "newest first, no expired, no answered")
    }

    func testStatusPendingApprovedDeniedExpired() {
        let h = Harness()
        h.model.nowMs = { 100_000 }
        h.model.ev(1, "approval.request", Payload.approval(id: "p", expiresAt: 500_000))
        h.model.ev(2, "approval.request", Payload.approval(id: "yes"))
        h.model.ev(3, "approval.request", Payload.approval(id: "no"))
        h.model.ev(4, "approval.request", Payload.approval(id: "late", expiresAt: 50_000))
        h.model.ev(5, "approval.request", Payload.approval(id: "timeout"))
        h.model.ev(6, "approval.resolved", ["id": "yes", "decision": "approve", "by": "user"])
        h.model.ev(7, "approval.resolved", ["id": "no", "decision": "deny", "by": "user"])
        h.model.ev(8, "approval.resolved", ["id": "timeout", "decision": "deny", "by": "timeout"])
        XCTAssertEqual(h.model.approvalStatus("p"), .pending)
        XCTAssertEqual(h.model.approvalStatus("yes"), .approved)
        XCTAssertEqual(h.model.approvalStatus("no"), .denied)
        XCTAssertEqual(h.model.approvalStatus("late"), .expired, "past expiresAt without any event")
        XCTAssertEqual(h.model.approvalStatus("timeout"), .expired, "the host resolved it by timeout")
        XCTAssertEqual(h.model.approvalStatus("unknown"), .pending)
        XCTAssertTrue(ApprovalStatus.pending.isActionable)
        XCTAssertTrue(ApprovalStatus.failed("x").isActionable)
        XCTAssertFalse(ApprovalStatus.expired.isActionable)
        XCTAssertFalse(ApprovalStatus.submitting.isActionable)
    }

    func testExpiryIsJudgedOnTheMacsClock() {
        let h = Harness()
        h.model.nowMs = { 100_000 }       // phone
        h.model.ev(1, "approval.request", Payload.approval(id: "a", expiresAt: 130_000))   // Mac time
        XCTAssertEqual(h.model.approvalStatus("a"), .pending)
        // The Mac's clock is 60 s ahead of the phone's: in Mac time it is already 160 000, so it has expired.
        h.model.hostClockOffsetMs = 60_000
        XCTAssertEqual(h.model.approvalStatus("a"), .expired)
        XCTAssertTrue(h.model.pendingApprovals.isEmpty)
    }

    func testPingSamplesCalibrateTheMacsClock() {
        let h = Harness()
        h.model.recordClockSample(hostTs: 1_060_000, sentAt: 1_000_000, receivedAt: 1_000_200)
        XCTAssertEqual(h.model.hostClockOffsetMs, 59_900)
        h.model.recordClockSample(hostTs: 1_060_100, sentAt: 1_000_000, receivedAt: 1_000_200)   // jitter: ignored
        XCTAssertEqual(h.model.hostClockOffsetMs, 59_900)
        h.model.recordClockSample(hostTs: 1_000_000, sentAt: 1_000_000, receivedAt: 1_010_000)   // 10 s round trip: useless
        XCTAssertEqual(h.model.hostClockOffsetMs, 59_900)
        h.model.recordClockSample(hostTs: nil, sentAt: 1, receivedAt: 2)
        XCTAssertEqual(h.model.hostClockOffsetMs, 59_900)
    }

    func testAnApprovalExpiringWhileTheAppIsOpenUpdatesByItself() async {
        let h = Harness()
        let soon = Clock.nowMs + 250
        h.model.ev(1, "approval.request", Payload.approval(id: "a", expiresAt: soon))
        XCTAssertEqual(h.model.pendingApprovals.count, 1)
        let tick = h.model.expiryTick
        // The timer must bump the tick (that is what makes views re-read), not merely let the clock pass.
        let ticked = await waitUntil(timeout: 3) { h.model.expiryTick > tick }
        XCTAssertTrue(ticked, "views re-read when the expiry passes")
        XCTAssertTrue(h.model.pendingApprovals.isEmpty)
        XCTAssertEqual(h.model.approvalStatus("a"), .expired)
    }

    // MARK: respond

    func testRespondSendsTheDecisionAndMarksItAnswered() async {
        let h = Harness()
        h.model.ev(1, "approval.request", Payload.approval(id: "a"))
        let a = h.model.approvals["a"]!
        let ok = await h.model.respond(approval: a, approve: true, note: "好的")
        XCTAssertTrue(ok)
        let call = h.host.calls("approval.respond").first
        XCTAssertEqual(call?.params["approvalId"]?.string, "a")
        XCTAssertEqual(call?.params["decision"]?.string, "approve")
        XCTAssertEqual(call?.params["note"]?.string, "好的")
        XCTAssertEqual(h.model.approvalStatus("a"), .approved)
        XCTAssertTrue(h.model.pendingApprovals.isEmpty)
        // The host's own resolution event changes nothing.
        h.model.ev(2, "approval.resolved", ["id": "a", "decision": "approve", "by": "user"])
        XCTAssertEqual(h.model.approvalStatus("a"), .approved)
    }

    func testDenyIsSentAsDeny() async {
        let h = Harness()
        h.model.ev(1, "approval.request", Payload.approval(id: "a"))
        let ok = await h.model.respond(approval: h.model.approvals["a"]!, approve: false)
        XCTAssertTrue(ok)
        XCTAssertEqual(h.host.calls("approval.respond").first?.params["decision"]?.string, "deny")
        XCTAssertEqual(h.model.approvalStatus("a"), .denied)
    }

    func testAnImpatientDoubleTapSubmitsOnlyOnce() async {
        let h = Harness()
        h.host.handler = { m, _ in
            if m == "approval.respond" { try? await Task.sleep(for: .milliseconds(150)) }
            return [:]
        }
        h.model.ev(1, "approval.request", Payload.approval(id: "a"))
        let a = h.model.approvals["a"]!
        async let first = h.model.respond(approval: a, approve: true)
        try? await Task.sleep(for: .milliseconds(30))
        XCTAssertEqual(h.model.approvalStatus("a"), .submitting)
        let second = await h.model.respond(approval: a, approve: true)   // the second tap
        let deny = await h.model.respond(approval: a, approve: false)    // even the opposite button
        XCTAssertFalse(second)
        XCTAssertFalse(deny)
        let firstOk = await first
        XCTAssertTrue(firstOk)
        XCTAssertEqual(h.host.calls("approval.respond").count, 1)
        XCTAssertEqual(h.model.approvalStatus("a"), .approved)
    }

    func testAnAnsweredApprovalIsNotSentAgain() async {
        let h = Harness()
        h.model.ev(1, "approval.request", Payload.approval(id: "a"))
        h.model.ev(2, "approval.resolved", ["id": "a", "decision": "deny", "by": "user"])   // answered on another device
        let ok = await h.model.respond(approval: h.model.approvals["a"]!, approve: true)
        XCTAssertFalse(ok)
        XCTAssertTrue(h.host.calls("approval.respond").isEmpty)
    }

    func testAnExpiredApprovalCannotBeAnswered() async {
        let h = Harness()
        h.model.nowMs = { 100_000 }
        h.model.ev(1, "approval.request", Payload.approval(id: "a", expiresAt: 99_000))
        let ok = await h.model.respond(approval: h.model.approvals["a"]!, approve: true)
        XCTAssertFalse(ok)
        XCTAssertTrue(h.host.calls("approval.respond").isEmpty, "buttons are disabled; and even a late tap sends nothing")
        XCTAssertNotNil(h.model.toast)
        XCTAssertEqual(h.model.approvalStatus("a"), .expired)
    }

    func testAFailedSubmitKeepsTheApprovalOpenAndCanBeRetried() async {
        let h = Harness()
        var fail = true
        h.host.handler = { m, _ in
            if m == "approval.respond", fail { throw OPAError.remote("Mac 暂时没有响应") }
            return [:]
        }
        h.model.ev(1, "approval.request", Payload.approval(id: "a", title: "提交预订"))
        let a = h.model.approvals["a"]!
        let first = await h.model.respond(approval: a, approve: true)
        XCTAssertFalse(first)
        XCTAssertEqual(h.model.approvalStatus("a"), .failed("Mac 暂时没有响应"))
        XCTAssertEqual(h.model.pendingApprovals.map(\.id), ["a"], "still open, content kept")
        fail = false
        let second = await h.model.respond(approval: a, approve: true)
        XCTAssertTrue(second)
        XCTAssertEqual(h.model.approvalStatus("a"), .approved)
    }

    // MARK: Presentation

    func testOpenApprovalReplacesOtherGlobalSheets() {
        let h = Harness()
        h.model.showActivity = true
        h.model.openApproval("a1")
        XCTAssertEqual(h.model.presentedApprovalId, "a1")
        XCTAssertFalse(h.model.showActivity)
        h.model.openApproval("a1")   // same id again: nothing changes, no second presentation
        XCTAssertEqual(h.model.presentedApprovalId, "a1")
        h.model.dismissGlobalSheets()
        XCTAssertNil(h.model.presentedApprovalId)
    }
}
