import CryptoKit
import Foundation

/// Byte-exact implementation of docs/protocol.md section 1 and 2.
enum OPACrypto {
    static let aad = Data("opa-v1".utf8)
    static let infoD2H = Data("opa-v1-d2h".utf8)
    static let infoH2D = Data("opa-v1-h2d".utf8)

    enum CryptoError: Error, LocalizedError {
        case badKey, badSignature, badCiphertext, replay(UInt64)
        var errorDescription: String? {
            switch self {
            case .badKey: "密钥格式无效"
            case .badSignature: "签名校验失败"
            case .badCiphertext: "解密失败"
            case .replay(let n): "检测到重放帧 n=\(n)"
            }
        }
    }

    // MARK: Identity

    /// `hex(sha256(pub))[0..32]`
    static func id(ofPublicKey raw: Data) -> String {
        String(Data(SHA256.hash(data: raw)).hexString.prefix(32))
    }

    // MARK: Signature messages (exact strings from the spec)

    static func helloMessage(hostId: String, ephPubB64: String, ts: Int64) -> Data {
        Data("opa-hello-v1|\(hostId)|\(ephPubB64)|\(ts)".utf8)
    }

    static func welcomeMessage(deviceId: String, ephPubDB64: String, ephPubHB64: String) -> Data {
        Data("opa-welcome-v1|\(deviceId)|\(ephPubDB64)|\(ephPubHB64)".utf8)
    }

    static func relayDeviceMessage(hostId: String, deviceId: String, ts: Int64) -> Data {
        Data("opa-relay-device-v1|\(hostId)|\(deviceId)|\(ts)".utf8)
    }

    static func relayHostMessage(hostId: String, ts: Int64) -> Data {
        Data("opa-relay-host-v1|\(hostId)|\(ts)".utf8)
    }

    static func verify(signatureB64: String, message: Data, publicKeyRaw: Data) -> Bool {
        guard let sig = Data(base64Encoded: signatureB64),
              let pub = try? Curve25519.Signing.PublicKey(rawRepresentation: publicKeyRaw)
        else { return false }
        return pub.isValidSignature(sig, for: message)
    }

    // MARK: Session keys

    struct SessionKeys {
        let d2h: SymmetricKey
        let h2d: SymmetricKey
        let sas: String
    }

    /// Derives both directional keys. `myEph` is our ephemeral private key; `ephD`/`ephH` are the raw
    /// 32-byte device/host ephemeral public keys (salt order is always device || host).
    static func deriveSessionKeys(myEph: Curve25519.KeyAgreement.PrivateKey, peerEphRaw: Data,
                                  ephDRaw: Data, ephHRaw: Data) throws -> SessionKeys {
        guard let peer = try? Curve25519.KeyAgreement.PublicKey(rawRepresentation: peerEphRaw) else {
            throw CryptoError.badKey
        }
        let shared = try myEph.sharedSecretFromKeyAgreement(with: peer)
        let salt = ephDRaw + ephHRaw
        let d2h = shared.hkdfDerivedSymmetricKey(using: SHA256.self, salt: salt, sharedInfo: infoD2H, outputByteCount: 32)
        let h2d = shared.hkdfDerivedSymmetricKey(using: SHA256.self, salt: salt, sharedInfo: infoH2D, outputByteCount: 32)
        return SessionKeys(d2h: d2h, h2d: h2d, sas: sas(ephDRaw: ephDRaw, ephHRaw: ephHRaw))
    }

    /// `u32be(sha256("opa-sas" || ephD || ephH)[0..4]) mod 1_000_000`, zero-padded to 6 digits.
    static func sas(ephDRaw: Data, ephHRaw: Data) -> String {
        let digest = Data(SHA256.hash(data: Data("opa-sas".utf8) + ephDRaw + ephHRaw))
        let v = digest.prefix(4).reduce(UInt32(0)) { ($0 << 8) | UInt32($1) }
        let s = String(v % 1_000_000)
        return String(repeating: "0", count: 6 - s.count) + s
    }

    // MARK: AEAD

    /// `0x00000000 || u64be(n)`
    static func nonceBytes(_ n: UInt64) -> Data {
        var out = Data(count: 4)
        withUnsafeBytes(of: n.bigEndian) { out.append(contentsOf: $0) }
        return out
    }

    /// Returns base64(ciphertext || tag16).
    static func seal(_ plaintext: Data, key: SymmetricKey, n: UInt64) throws -> String {
        let nonce = try ChaChaPoly.Nonce(data: nonceBytes(n))
        let box = try ChaChaPoly.seal(plaintext, using: key, nonce: nonce, authenticating: aad)
        return (box.ciphertext + box.tag).base64EncodedString()
    }

    static func open(_ cB64: String, key: SymmetricKey, n: UInt64) throws -> Data {
        guard let raw = Data(base64Encoded: cB64), raw.count >= 16 else { throw CryptoError.badCiphertext }
        let ct = raw.prefix(raw.count - 16)
        let tag = raw.suffix(16)
        do {
            let box = try ChaChaPoly.SealedBox(nonce: ChaChaPoly.Nonce(data: nonceBytes(n)), ciphertext: ct, tag: tag)
            return try ChaChaPoly.open(box, using: key, authenticating: aad)
        } catch {
            throw CryptoError.badCiphertext
        }
    }
}

extension SymmetricKey {
    var rawData: Data { withUnsafeBytes { Data($0) } }
}

/// Per-connection encrypted channel with independent counters per direction.
struct SecureChannel {
    let sendKey: SymmetricKey
    let recvKey: SymmetricKey
    let sas: String
    private(set) var sendN: UInt64 = 0
    private var lastRecvN: UInt64?

    init(keys: OPACrypto.SessionKeys, isDevice: Bool = true) {
        sendKey = isDevice ? keys.d2h : keys.h2d
        recvKey = isDevice ? keys.h2d : keys.d2h
        sas = keys.sas
    }

    /// Produces the outer `{"t":"x","n":…,"c":"…"}` text frame.
    mutating func sealFrame(_ plaintext: Data) throws -> String {
        let n = sendN
        let c = try OPACrypto.seal(plaintext, key: sendKey, n: n)
        sendN += 1
        let frame: JSONValue = ["t": "x", "n": .number(Double(n)), "c": .string(c)]
        return String(decoding: try frame.data(), as: UTF8.self)
    }

    /// Opens a decoded `x` frame. Throws on replay (`n <= lastN`) — caller must disconnect.
    mutating func openFrame(n: UInt64, c: String) throws -> Data {
        if let last = lastRecvN, n <= last { throw OPACrypto.CryptoError.replay(n) }
        let plain = try OPACrypto.open(c, key: recvKey, n: n)
        lastRecvN = n
        return plain
    }
}
