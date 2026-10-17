import CryptoKit
import XCTest
@testable import OPA

final class CryptoTests: XCTestCase {
    // Fixed keys shared with the host implementation (see VECTORS.md).
    let deviceSign = try! Curve25519.Signing.PrivateKey(rawRepresentation: Data(repeating: 0x01, count: 32))
    let hostSign = try! Curve25519.Signing.PrivateKey(rawRepresentation: Data(repeating: 0x02, count: 32))
    let deviceEph = try! Curve25519.KeyAgreement.PrivateKey(rawRepresentation: Data(repeating: 0x03, count: 32))
    let hostEph = try! Curve25519.KeyAgreement.PrivateKey(rawRepresentation: Data(repeating: 0x04, count: 32))
    let samplePlaintext = #"{"t":"req","id":"1","m":"ping","d":{}}"#

    var ephD: Data { deviceEph.publicKey.rawRepresentation }
    var ephH: Data { hostEph.publicKey.rawRepresentation }

    func testVectorsAndPrint() throws {
        let devKeys = try OPACrypto.deriveSessionKeys(myEph: deviceEph, peerEphRaw: ephH, ephDRaw: ephD, ephHRaw: ephH)
        let hostKeys = try OPACrypto.deriveSessionKeys(myEph: hostEph, peerEphRaw: ephD, ephDRaw: ephD, ephHRaw: ephH)
        XCTAssertEqual(devKeys.d2h.rawData, hostKeys.d2h.rawData)
        XCTAssertEqual(devKeys.h2d.rawData, hostKeys.h2d.rawData)
        XCTAssertNotEqual(devKeys.d2h.rawData, devKeys.h2d.rawData)
        XCTAssertEqual(devKeys.sas, hostKeys.sas)

        let c0 = try OPACrypto.seal(Data(samplePlaintext.utf8), key: devKeys.d2h, n: 0)
        let shared = try deviceEph.sharedSecretFromKeyAgreement(with: hostEph.publicKey).withUnsafeBytes { Data($0) }

        let devPub = deviceSign.publicKey.rawRepresentation
        let hostPub = hostSign.publicKey.rawRepresentation
        let hostId = OPACrypto.id(ofPublicKey: hostPub)
        let deviceId = OPACrypto.id(ofPublicKey: devPub)
        let ts: Int64 = 1760000000000
        let helloSig = try deviceSign.signature(for: OPACrypto.helloMessage(hostId: hostId, ephPubB64: ephD.base64EncodedString(), ts: ts))
        let welcomeSig = try hostSign.signature(for: OPACrypto.welcomeMessage(deviceId: deviceId, ephPubDB64: ephD.base64EncodedString(), ephPubHB64: ephH.base64EncodedString()))

        let lines = [
            "devicePub(b64)=\(devPub.base64EncodedString())",
            "hostPub(b64)=\(hostPub.base64EncodedString())",
            "deviceId=\(deviceId)",
            "hostId=\(hostId)",
            "ephPubD(b64)=\(ephD.base64EncodedString())",
            "ephPubH(b64)=\(ephH.base64EncodedString())",
            "shared(hex)=\(shared.hexString)",
            "kD2H(hex)=\(devKeys.d2h.rawData.hexString)",
            "kH2D(hex)=\(devKeys.h2d.rawData.hexString)",
            "kD2H[0..8](hex)=\(devKeys.d2h.rawData.prefix(8).hexString)",
            "kH2D[0..8](hex)=\(devKeys.h2d.rawData.prefix(8).hexString)",
            "SAS=\(devKeys.sas)",
            "c(n=0,kD2H)=\(c0)",
            "helloSig(ts=\(ts))(b64)=\(helloSig.base64EncodedString())",
            "welcomeSig(b64)=\(welcomeSig.base64EncodedString())",
        ]
        print("OPA-VECTORS-BEGIN\n" + lines.joined(separator: "\n") + "\nOPA-VECTORS-END")

        // Ed25519 is deterministic (RFC 8032), so signatures must match the host too; verify them anyway.
        XCTAssertTrue(OPACrypto.verify(signatureB64: helloSig.base64EncodedString(),
                                       message: OPACrypto.helloMessage(hostId: hostId, ephPubB64: ephD.base64EncodedString(), ts: ts),
                                       publicKeyRaw: devPub))
        XCTAssertTrue(OPACrypto.verify(signatureB64: welcomeSig.base64EncodedString(),
                                       message: OPACrypto.welcomeMessage(deviceId: deviceId, ephPubDB64: ephD.base64EncodedString(), ephPubHB64: ephH.base64EncodedString()),
                                       publicKeyRaw: hostPub))

        // Pin values so accidental changes are caught (fill from VECTORS.md).
        if let expected = Self.pinned {
            XCTAssertEqual(devKeys.sas, expected.sas)
            XCTAssertEqual(devKeys.d2h.rawData.prefix(8).hexString, expected.d2h8)
            XCTAssertEqual(devKeys.h2d.rawData.prefix(8).hexString, expected.h2d8)
            XCTAssertEqual(c0, expected.c0)
        }
    }

    static let pinned: (sas: String, d2h8: String, h2d8: String, c0: String)? =
        ("992060", "29b39576079cf30b", "38a420dd3edb9d5c", "ke7I6qDOionHPT2dUGYIoRLcPetw47x2/WLaqd5lwuuC9YM4YTcfQRZHNqdXY2PxzWuije+9")

    /// Deterministic RFC 8032 signature produced by Node (host side) must verify with CryptoKit.
    func testVerifiesHostLibrarySignature() {
        let hostId = OPACrypto.id(ofPublicKey: hostSign.publicKey.rawRepresentation)
        let msg = OPACrypto.helloMessage(hostId: hostId, ephPubB64: ephD.base64EncodedString(), ts: 1760000000000)
        let nodeSig = "B3yvm9/O3V8uL7sfGHg/8cglfscV1eqOXIoSaNHxO45HGwqW/qF4SUMqfLa/b1rcjtijqEH6y5Qp5ARVXtJZBg=="
        XCTAssertTrue(OPACrypto.verify(signatureB64: nodeSig, message: msg, publicKeyRaw: deviceSign.publicKey.rawRepresentation))
    }

    func testRoundTripAndCounters() throws {
        let devKeys = try OPACrypto.deriveSessionKeys(myEph: deviceEph, peerEphRaw: ephH, ephDRaw: ephD, ephHRaw: ephH)
        let hostKeys = try OPACrypto.deriveSessionKeys(myEph: hostEph, peerEphRaw: ephD, ephDRaw: ephD, ephHRaw: ephH)
        var device = SecureChannel(keys: devKeys, isDevice: true)
        var host = SecureChannel(keys: hostKeys, isDevice: false)

        for i in 0..<3 {
            let frame = try device.sealFrame(Data("msg\(i)".utf8))
            let v = try JSONValue(jsonString: frame)
            XCTAssertEqual(v["t"]?.string, "x")
            XCTAssertEqual(v["n"]?.int, i)
            XCTAssertFalse(frame.contains("\"n\":\(i).0"), "n must be an integer in JSON")
            let plain = try host.openFrame(n: UInt64(v["n"]!.int!), c: v["c"]!.string!)
            XCTAssertEqual(String(decoding: plain, as: UTF8.self), "msg\(i)")
        }
        // Replay must fail.
        let frame = try device.sealFrame(Data("x".utf8))
        let v = try JSONValue(jsonString: frame)
        _ = try host.openFrame(n: 3, c: v["c"]!.string!)
        XCTAssertThrowsError(try host.openFrame(n: 3, c: v["c"]!.string!))
        XCTAssertThrowsError(try host.openFrame(n: 1, c: v["c"]!.string!))

        // Reverse direction uses kH2D.
        let back = try host.sealFrame(Data("hi".utf8))
        let bv = try JSONValue(jsonString: back)
        XCTAssertEqual(String(decoding: try device.openFrame(n: 0, c: bv["c"]!.string!), as: UTF8.self), "hi")
    }

    func testTamperFails() throws {
        let keys = try OPACrypto.deriveSessionKeys(myEph: deviceEph, peerEphRaw: ephH, ephDRaw: ephD, ephHRaw: ephH)
        let c = try OPACrypto.seal(Data("hello".utf8), key: keys.d2h, n: 5)
        XCTAssertThrowsError(try OPACrypto.open(c, key: keys.d2h, n: 6))
        XCTAssertThrowsError(try OPACrypto.open(c, key: keys.h2d, n: 5))
        var raw = Data(base64Encoded: c)!
        raw[0] ^= 0xFF
        XCTAssertThrowsError(try OPACrypto.open(raw.base64EncodedString(), key: keys.d2h, n: 5))
        // ciphertext||tag: plaintext length + 16
        XCTAssertEqual(Data(base64Encoded: c)!.count, 5 + 16)
    }

    func testNonceFormat() {
        XCTAssertEqual(OPACrypto.nonceBytes(0).hexString, "000000000000000000000000")
        XCTAssertEqual(OPACrypto.nonceBytes(1).hexString, "000000000000000000000001")
        XCTAssertEqual(OPACrypto.nonceBytes(0x0102030405060708).hexString, "000000000102030405060708")
        XCTAssertEqual(OPACrypto.nonceBytes(.max).count, 12)
    }

    func testSASFormatting() {
        // SAS is always 6 digits.
        for i in 0..<50 {
            let s = OPACrypto.sas(ephDRaw: Data(repeating: UInt8(i), count: 32), ephHRaw: Data(repeating: 0xAA, count: 32))
            XCTAssertEqual(s.count, 6)
            XCTAssertTrue(s.allSatisfy(\.isNumber))
        }
        // Independent recomputation.
        let d = Data(repeating: 0x11, count: 32), h = Data(repeating: 0x22, count: 32)
        let digest = Array(SHA256.hash(data: Data("opa-sas".utf8) + d + h))
        let v = (UInt32(digest[0]) << 24 | UInt32(digest[1]) << 16 | UInt32(digest[2]) << 8 | UInt32(digest[3])) % 1_000_000
        XCTAssertEqual(OPACrypto.sas(ephDRaw: d, ephHRaw: h), String(format: "%06u", v))
    }

    func testSignatureStrings() {
        XCTAssertEqual(String(decoding: OPACrypto.helloMessage(hostId: "abc", ephPubB64: "AAA=", ts: 1760000000000), as: UTF8.self),
                       "opa-hello-v1|abc|AAA=|1760000000000")
        XCTAssertEqual(String(decoding: OPACrypto.welcomeMessage(deviceId: "dev", ephPubDB64: "D=", ephPubHB64: "H="), as: UTF8.self),
                       "opa-welcome-v1|dev|D=|H=")
        XCTAssertEqual(String(decoding: OPACrypto.relayDeviceMessage(hostId: "h", deviceId: "d", ts: 5), as: UTF8.self),
                       "opa-relay-device-v1|h|d|5")
        XCTAssertEqual(String(decoding: OPACrypto.relayHostMessage(hostId: "h", ts: 5), as: UTF8.self),
                       "opa-relay-host-v1|h|5")
    }

    func testIdDerivation() {
        let pub = Data(repeating: 0, count: 32)
        let full = Data(SHA256.hash(data: pub)).hexString
        XCTAssertEqual(OPACrypto.id(ofPublicKey: pub), String(full.prefix(32)))
        XCTAssertEqual(OPACrypto.id(ofPublicKey: pub).count, 32)
    }

    func testBase64URL() {
        let d = Data([0xFB, 0xFF, 0xBF, 0x00])
        XCTAssertEqual(d.base64EncodedString(), "+/+/AA==")
        XCTAssertEqual(d.base64URLEncodedString(), "-_-_AA")
        XCTAssertEqual(Data(base64URLEncoded: "-_-_AA"), d)
    }

    func testPairingPayloadParse() throws {
        let hostPub = hostSign.publicKey.rawRepresentation
        let json: JSONValue = ["v": 1, "hostId": .string(OPACrypto.id(ofPublicKey: hostPub)), "hostPub": .string(hostPub.base64EncodedString()),
                               "hostName": "Mac", "lan": [["host": "192.168.1.5", "port": 7420]], "relay": "wss://r.example",
                               "pairToken": "tok", "exp": .number(Double(Clock.nowMs + 60_000))]
        let link = "opa://pair?d=" + (try json.data()).base64URLEncodedString()
        let p = try PairingPayload.parse(link)
        XCTAssertEqual(p.lan.first?.port, 7420)
        XCTAssertEqual(p.pairToken, "tok")

        var bad = json
        if case .object(var o) = bad { o["hostId"] = "0000"; bad = .object(o) }
        XCTAssertThrowsError(try PairingPayload.parse("opa://pair?d=" + (try bad.data()).base64URLEncodedString()))
    }
}
