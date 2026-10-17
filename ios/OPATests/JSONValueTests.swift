import XCTest
@testable import OPA

final class JSONValueTests: XCTestCase {
    func testDecodeAndAccessors() throws {
        let v = try JSONValue(jsonString: #"{"a":1,"b":"x","c":[true,null,2.5],"d":{"e":"f"}}"#)
        XCTAssertEqual(v["a"]?.int, 1)
        XCTAssertEqual(v["b"]?.string, "x")
        XCTAssertEqual(v["c"]?[0]?.bool, true)
        XCTAssertEqual(v["c"]?[1]?.isNull, true)
        XCTAssertEqual(v["c"]?[2]?.double, 2.5)
        XCTAssertEqual(v["d"]?["e"]?.string, "f")
        XCTAssertNil(v["missing"])
        XCTAssertEqual(v["c"]?.items.count, 3)
    }

    func testBoolNotNumber() throws {
        let v = try JSONValue(jsonString: #"[true, 1, 0]"#)
        XCTAssertEqual(v[0], .bool(true))
        XCTAssertEqual(v[1], .number(1))
        XCTAssertEqual(v[2], .number(0))
    }

    func testIntegerEncoding() throws {
        let v: JSONValue = ["n": 3, "f": 1.5, "big": .number(1760000000000)]
        let s = v.compactJSON
        XCTAssertTrue(s.contains(#""n":3"#))
        XCTAssertTrue(s.contains(#""f":1.5"#))
        XCTAssertTrue(s.contains(#""big":1760000000000"#))
    }

    func testMerge() {
        let a: JSONValue = ["status": "draft", "items": [1, 2], "nested": ["x": 1, "y": 2]]
        let shallow = a.merging(["status": "placed", "nested": ["x": 9]])
        XCTAssertEqual(shallow["status"]?.string, "placed")
        XCTAssertEqual(shallow["items"]?.items.count, 2)
        XCTAssertNil(shallow["nested"]?["y"])   // shallow replaces nested objects
        let deep = a.deepMerging(["nested": ["x": 9]])
        XCTAssertEqual(deep["nested"]?["x"]?.int, 9)
        XCTAssertEqual(deep["nested"]?["y"]?.int, 2)
    }

    func testCardDecode() throws {
        let v = try JSONValue(jsonString: #"{"id":"c1","component":"order_card","props":{"total":44,"status":"draft"},"actions":[{"id":"ok","label":"OK","style":"primary","requiresApproval":true}],"ts":1}"#)
        let card = try v.decode(Card.self)
        XCTAssertEqual(card.component, "order_card")
        XCTAssertEqual(card.props["total"]?.double, 44)
        XCTAssertEqual(card.actions?.first?.style, .primary)
        XCTAssertEqual(card.actions?.first?.requiresApproval, true)
    }

    func testLenientEnumsAndInbound() throws {
        let t = try JSONValue(jsonString: #"{"id":"t","title":"x","goal":"","status":"weird","steps":[{"id":"s","title":"a","status":"running"}],"createdAt":1,"updatedAt":2}"#)
        let task = try t.decode(OPATask.self)
        XCTAssertEqual(task.status, .planning)
        XCTAssertEqual(task.steps.first?.status, .running)

        if case .ev(let seq, _, let k, _) = InboundMessage(try JSONValue(jsonString: #"{"t":"ev","seq":7,"ts":1,"k":"memory.changed","d":{}}"#)) {
            XCTAssertEqual(seq, 7); XCTAssertEqual(k, "memory.changed")
        } else { XCTFail() }
        if case .res(let id, let ok, _, let err) = InboundMessage(try JSONValue(jsonString: #"{"t":"res","id":"a","ok":false,"err":"boom"}"#)) {
            XCTAssertEqual(id, "a"); XCTAssertFalse(ok); XCTAssertEqual(err, "boom")
        } else { XCTFail() }
        if case .pairResult(let ok) = InboundMessage(try JSONValue(jsonString: #"{"t":"pair.result","d":{"ok":true}}"#)) {
            XCTAssertTrue(ok)
        } else { XCTFail() }
    }

    func testSettingsDefaults() throws {
        let s = try JSONValue(jsonString: #"{"butler":{"name":"阿福"},"models":{"butler":"","heartbeat":""}}"#).decode(Settings.self)
        XCTAssertEqual(s.butler.name, "阿福")
        XCTAssertEqual(s.models.butler, "")
        XCTAssertEqual(s.proactivity, .normal)
        XCTAssertEqual(s.quietHours.start, "23:00")
    }
}
