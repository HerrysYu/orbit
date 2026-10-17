import Foundation

/// Which LAN addresses are worth dialing, and in which order.
///
/// The pairing payload lists every address the Mac has. Some of them can never be the Mac:
/// - `198.18.0.0/15` is the benchmark range that proxy / TUN apps (Clash, Surge, …) use for fake IPs. A TCP connect
///   to one of those "succeeds" instantly inside the proxy, so it would win the connection race and then hang;
/// - `169.254.0.0/16` and IPv6 `fe80::/10` are link-local addresses that are useless without a zone.
///
/// Order: Bonjour-resolved endpoints → private ranges (10/8, 172.16/12, 192.168/16) → everything else.
enum LANCandidates {
    // MARK: Classification

    /// Parses a dotted-quad IPv4 literal.
    static func ipv4(_ host: String) -> [UInt8]? {
        let parts = host.split(separator: ".", omittingEmptySubsequences: false)
        guard parts.count == 4 else { return nil }
        var out: [UInt8] = []
        out.reserveCapacity(4)
        for p in parts {
            guard !p.isEmpty, p.count <= 3, p.allSatisfy(\.isASCII), let v = UInt8(p) else { return nil }
            out.append(v)
        }
        return out
    }

    /// Strips IPv6 brackets and a zone id (`[fe80::1%en0]` → `fe80::1`).
    static func bare(_ host: String) -> String {
        var h = host.trimmingCharacters(in: .whitespaces)
        if h.hasPrefix("["), h.hasSuffix("]") { h = String(h.dropFirst().dropLast()) }
        if let pct = h.firstIndex(of: "%") { h = String(h[..<pct]) }
        return h
    }

    /// 198.18.0.0/15 (proxy fake-IP) and 169.254.0.0/16 (link-local).
    static func isExcludedIPv4(_ host: String) -> Bool {
        guard let b = ipv4(bare(host)) else { return false }
        if b[0] == 198, b[1] == 18 || b[1] == 19 { return true }
        if b[0] == 169, b[1] == 254 { return true }
        return false
    }

    /// fe80::/10
    static func isLinkLocalIPv6(_ host: String) -> Bool {
        let h = bare(host).lowercased()
        guard h.contains(":") else { return false }
        return h.hasPrefix("fe8") || h.hasPrefix("fe9") || h.hasPrefix("fea") || h.hasPrefix("feb")
    }

    /// Addresses from the pairing payload that must never be dialed.
    static func isExcluded(_ host: String) -> Bool {
        isExcludedIPv4(host) || isLinkLocalIPv6(host)
    }

    /// 10/8, 172.16/12, 192.168/16.
    static func isPrivate(_ host: String) -> Bool {
        guard let b = ipv4(bare(host)) else { return false }
        switch b[0] {
        case 10: return true
        case 172: return (16...31).contains(b[1])
        case 192: return b[1] == 168
        default: return false
        }
    }

    // MARK: Ordering

    /// Drops unusable addresses and duplicates, then puts private-range addresses first (stable within each group).
    static func ordered(_ addrs: [PairingPayload.LanAddr]) -> [PairingPayload.LanAddr] {
        var seen = Set<String>()
        var priv: [PairingPayload.LanAddr] = []
        var other: [PairingPayload.LanAddr] = []
        for a in addrs {
            let host = a.host.trimmingCharacters(in: .whitespaces)
            guard !host.isEmpty, a.port > 0, a.port < 65_536, !isExcluded(host) else { continue }
            guard seen.insert("\(bare(host).lowercased()):\(a.port)").inserted else { continue }
            let clean = PairingPayload.LanAddr(host: host, port: a.port)
            if isPrivate(host) { priv.append(clean) } else { other.append(clean) }
        }
        return priv + other
    }

    static func url(host: String, port: Int) -> URL? {
        let h = host.contains(":") && !host.hasPrefix("[") ? "[\(host)]" : host
        return URL(string: "ws://\(h):\(port)/v1/ws")
    }

    /// The final dial order: Bonjour-resolved URLs first, then the (filtered, ordered) payload addresses.
    /// Bonjour results may legitimately be scoped IPv6 link-local addresses, so only the IPv4 exclusions apply to them.
    static func candidateURLs(bonjour: [URL], payload: [PairingPayload.LanAddr]) -> [URL] {
        var out: [URL] = []
        var seen = Set<URL>()
        for u in bonjour {
            if let host = u.host(percentEncoded: false), isExcludedIPv4(host) { continue }
            if seen.insert(u).inserted { out.append(u) }
        }
        for a in ordered(payload) {
            if let u = url(host: a.host, port: a.port), seen.insert(u).inserted { out.append(u) }
        }
        return out
    }
}
