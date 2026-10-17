import Foundation

/// What we remember about the paired Mac (public info only; nothing secret).
struct PairedHost: Codable, Sendable, Hashable {
    var hostId: String
    var hostPub: String
    var hostName: String
    var lan: [PairingPayload.LanAddr]
    var relay: String?
    var pairedAt: Int64

    init(payload p: PairingPayload) {
        hostId = p.hostId
        hostPub = p.hostPub
        hostName = p.hostName
        lan = LANCandidates.ordered(p.lan)
        relay = p.relay
        pairedAt = Clock.nowMs
    }

    var hostPubRaw: Data { Data(base64Encoded: hostPub) ?? Data() }

    private static let key = "opa.pairedHost"

    static func load(from defaults: UserDefaults = .standard) -> PairedHost? {
        guard let d = defaults.data(forKey: key), var host = try? JSONDecoder().decode(PairedHost.self, from: d) else { return nil }
        // Hosts paired by an older build may have stored proxy / link-local addresses; never dial those.
        host.lan = LANCandidates.ordered(host.lan)
        return host
    }

    func save(to defaults: UserDefaults = .standard) {
        if let d = try? JSONEncoder().encode(self) { defaults.set(d, forKey: Self.key) }
    }

    static func clear(from defaults: UserDefaults = .standard) { defaults.removeObject(forKey: key) }
}

enum TransportPath: String, Sendable {
    case lan, relay
    var label: String { self == .lan ? "局域网直连" : "Relay 中转" }
    var symbol: String { self == .lan ? "wifi" : "cloud" }
}

enum ConnectionState: Equatable, Sendable {
    case idle
    case connecting
    case handshaking(TransportPath)
    case awaitingPairConfirm(sas: String, path: TransportPath)
    case connected(TransportPath)
    case hostOffline
    case waitingRetry(seconds: Int, reason: String)
    case failed(String)

    var isConnected: Bool { if case .connected = self { return true } else { return false } }

    var label: String {
        switch self {
        case .idle: "未连接"
        case .connecting: "连接中…"
        case .handshaking: "握手中…"
        case .awaitingPairConfirm: "等待 Mac 确认"
        case .connected(let p): "已连接 · \(p.label)"
        case .hostOffline: "Mac 离线"
        case .waitingRetry(let s, _): "\(s) 秒后重连"
        case .failed(let m): m
        }
    }

    var symbol: String {
        switch self {
        case .connected(let p): p.symbol
        case .hostOffline: "moon.zzz"
        case .failed: "exclamationmark.triangle"
        default: "arrow.triangle.2.circlepath"
        }
    }
}
