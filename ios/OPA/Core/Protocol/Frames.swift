import Foundation

// MARK: - Pairing payload (QR / opa://pair?d=…)

struct PairingPayload: Codable, Sendable, Hashable {
    struct LanAddr: Codable, Sendable, Hashable { var host: String; var port: Int }
    var v: Int
    var hostId: String
    var hostPub: String
    var hostName: String
    var lan: [LanAddr]
    var relay: String?
    var pairToken: String?
    var exp: Int64?

    enum ParseError: Error, LocalizedError {
        case notOPALink, badEncoding, badPayload, hostIdMismatch, expired
        var errorDescription: String? {
            switch self {
            case .notOPALink: "这不是有效的配对链接（应以 opa://pair?d= 开头）"
            case .badEncoding: "配对链接编码无效"
            case .badPayload: "配对信息无法解析"
            case .hostIdMismatch: "配对信息校验失败（hostId 与公钥不符）"
            case .expired: "配对码已过期，请在 Mac 上重新执行 opa pair"
            }
        }
    }

    /// Parses `opa://pair?d=<base64url(json)>`. Also tolerates a bare base64url string.
    static func parse(_ input: String, now: Int64 = Clock.nowMs) throws -> PairingPayload {
        let trimmed = input.trimmingCharacters(in: .whitespacesAndNewlines)
        var encoded: String?
        if let comps = URLComponents(string: trimmed), comps.scheme == "opa" {
            guard comps.host == "pair" || comps.path.contains("pair") else { throw ParseError.notOPALink }
            encoded = comps.queryItems?.first(where: { $0.name == "d" })?.value
        } else if !trimmed.contains("://") {
            encoded = trimmed
        }
        guard let encoded, !encoded.isEmpty else { throw ParseError.notOPALink }
        guard let data = Data(base64URLEncoded: encoded) else { throw ParseError.badEncoding }
        guard var p = try? JSONDecoder().decode(PairingPayload.self, from: data) else { throw ParseError.badPayload }
        guard let pub = Data(base64Encoded: p.hostPub), OPACrypto.id(ofPublicKey: pub) == p.hostId else {
            throw ParseError.hostIdMismatch
        }
        if let exp = p.exp, exp < now, p.pairToken != nil { throw ParseError.expired }
        // Drop addresses that can never be the Mac (proxy fake-IPs, link-local) and put private ranges first.
        p.lan = LANCandidates.ordered(p.lan)
        return p
    }

    var hostPubRaw: Data { Data(base64Encoded: hostPub) ?? Data() }
}

// MARK: - Handshake frames (plaintext)

struct HelloFrame: Codable, Sendable {
    var t = "hello"
    var v = 1
    var deviceId: String
    var devicePub: String
    var deviceName: String
    var ephPub: String
    var ts: Int64
    var pairToken: String?
    var sig: String
}

struct WelcomeFrame: Codable, Sendable {
    var t: String
    var v: Int?
    var ephPub: String
    var sig: String
    var paired: Bool
    var hostName: String?
}

// MARK: - App messages (inside encrypted frames)

/// Decoded app-level frame from the host.
enum InboundMessage: Sendable {
    case res(id: String, ok: Bool, d: JSONValue?, err: String?)
    case ev(seq: Int64, ts: Int64, k: String, d: JSONValue)
    case live(k: String, d: JSONValue)
    case pairResult(ok: Bool)
    case unknown(JSONValue)

    init(_ v: JSONValue) {
        switch v["t"]?.string {
        case "res":
            let err: String? = v["err"]?.string ?? v["err"]?["message"]?.string ?? (v["err"].map { $0.isNull ? nil : $0.compactJSON } ?? nil)
            self = .res(id: v["id"]?.string ?? "", ok: v["ok"]?.bool ?? false, d: v["d"], err: err)
        case "ev":
            self = .ev(seq: v["seq"]?.int64 ?? 0, ts: v["ts"]?.int64 ?? Clock.nowMs, k: v["k"]?.string ?? "", d: v["d"] ?? .null)
        case "live":
            self = .live(k: v["k"]?.string ?? "", d: v["d"] ?? .null)
        case "pair.result":
            self = .pairResult(ok: v["d"]?["ok"]?.bool ?? false)
        default:
            self = .unknown(v)
        }
    }
}

enum OPAError: Error, LocalizedError {
    case notConnected, timeout, remote(String), rejected(String), protocolViolation(String), cancelled
    var errorDescription: String? {
        switch self {
        case .notConnected: "未连接到 Mac"
        case .timeout: "请求超时"
        case .remote(let m): m
        case .rejected(let r): "Mac 拒绝了连接：\(r)"
        case .protocolViolation(let m): "协议错误：\(m)"
        case .cancelled: "已取消"
        }
    }
}
