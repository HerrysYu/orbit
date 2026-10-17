import Foundation

extension Data {
    /// base64url without padding (used in relay query parameters and pairing links).
    func base64URLEncodedString() -> String {
        base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }

    /// Accepts base64url (with or without padding) and also plain base64.
    init?(base64URLEncoded string: String) {
        var s = string
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .replacingOccurrences(of: "-", with: "+")
            .replacingOccurrences(of: "_", with: "/")
        let rem = s.count % 4
        if rem > 0 { s += String(repeating: "=", count: 4 - rem) }
        self.init(base64Encoded: s)
    }

    var hexString: String { map { String(format: "%02x", $0) }.joined() }

    init?(hex: String) {
        let chars = Array(hex.utf8)
        guard chars.count % 2 == 0 else { return nil }
        var out = Data(capacity: chars.count / 2)
        var i = 0
        while i < chars.count {
            guard let b = UInt8(String(bytes: chars[i..<i + 2], encoding: .ascii) ?? "", radix: 16) else { return nil }
            out.append(b)
            i += 2
        }
        self = out
    }
}

enum Clock {
    /// Unix milliseconds.
    static var nowMs: Int64 { Int64((Date().timeIntervalSince1970 * 1000).rounded()) }

    static func date(ms: Int64) -> Date { Date(timeIntervalSince1970: TimeInterval(ms) / 1000) }
    static func ms(_ date: Date) -> Int64 { Int64((date.timeIntervalSince1970 * 1000).rounded()) }
}

enum ShortID {
    static func make() -> String {
        UUID().uuidString.replacingOccurrences(of: "-", with: "").prefix(16).lowercased()
    }
}
