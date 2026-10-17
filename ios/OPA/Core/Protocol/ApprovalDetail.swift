import Foundation

// MARK: - Expiry

extension Approval {
    /// True once `expiresAt` has passed. Approvals without an expiry never expire on their own.
    func isExpired(now: Int64 = Clock.nowMs) -> Bool {
        guard let expiresAt else { return false }
        return expiresAt <= now
    }

    func isExpired(now: Date) -> Bool { isExpired(now: Clock.ms(now)) }
}

// MARK: - Detail parsing (display layer only)

/// The host writes `Approval.detail` as several `标签：内容` lines plus a closing `批准后：…` line
/// (see the `request_approval` tool). The app only parses it for display; the wire format is unchanged.
///
/// - `标签：内容` / `标签:内容` with a label of at most 8 characters becomes a table row (a leading bullet or number is ignored).
/// - A line starting with `批准后：` (or `批准后:`) goes to the note, as does every other line.
enum ApprovalDetailParser {
    static let maxLabelLength = 8
    private static let notePrefixes = ["批准后：", "批准后:"]
    /// Besides letters and digits a label may contain these (`Mac 命令`, `金额（元）`, `人数/房型`, `用户-ID`).
    /// Quotes, `=`, `@`, `~`, `$`, `\` … never occur in a label but do in commands and paths, so such lines stay notes.
    private static let labelExtras: Set<Character> = [" ", "·", "-", "_", "(", ")", "（", "）", "/", "、", "&", "+"]

    struct Result {
        var rows: [(String, String)]
        var note: String?
    }

    static func parse(_ detail: String) -> Result {
        var rows: [(String, String)] = []
        var notes: [String] = []
        for raw in detail.split(omittingEmptySubsequences: true, whereSeparator: \.isNewline) {
            let line = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            if line.isEmpty { continue }
            if notePrefixes.contains(where: { line.hasPrefix($0) }) {
                notes.append(line)
            } else if let row = labeledRow(strippingListMarker(line)) {
                rows.append(row)
            } else {
                notes.append(line)
            }
        }
        return Result(rows: rows, note: notes.isEmpty ? nil : notes.joined(separator: "\n"))
    }

    /// Models sometimes bullet or number the lines (`- 餐厅：…`, `• 餐厅：…`, `1. 餐厅：…`); the marker is not part of the label.
    static func strippingListMarker(_ line: String) -> String {
        var rest = Substring(line)
        if let first = rest.first, "-*•·".contains(first), rest.dropFirst().first?.isWhitespace == true {
            rest = rest.dropFirst().drop(while: \.isWhitespace)
        } else {
            let digits = rest.prefix(while: { $0.isASCII && $0.isNumber })
            if (1...2).contains(digits.count) {
                let after = rest.dropFirst(digits.count)
                // `1、…` and `1）…` are written without a space; `1. …` and `1) …` need one (so `3.5：…` is left alone).
                if let sep = after.first {
                    let glued = "、）".contains(sep)
                    let spaced = ".)".contains(sep) && after.dropFirst().first?.isWhitespace == true
                    if glued || spaced { rest = after.dropFirst().drop(while: \.isWhitespace) }
                }
            }
        }
        return String(rest)
    }

    /// Splits at the first full-width or ASCII colon; rejects things that merely contain a colon
    /// (URLs, clock times, shell commands).
    private static func labeledRow(_ line: String) -> (String, String)? {
        guard let colon = line.firstIndex(where: { $0 == "：" || $0 == ":" }) else { return nil }
        let label = line[..<colon].trimmingCharacters(in: .whitespaces)
        let value = line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces)
        guard !label.isEmpty, label.count <= maxLabelLength, !value.isEmpty else { return nil }
        guard label.contains(where: \.isLetter) else { return nil }                       // "10:30 开始"
        guard label.allSatisfy({ $0.isLetter || $0.isNumber || labelExtras.contains($0) }) else { return nil }   // `echo "a: b"`
        if line[colon] == ":", value.hasPrefix("//") { return nil }                       // https://…
        return (label, value)
    }
}

extension Approval {
    /// `标签：内容` lines of `detail`, in order, as a table.
    var detailRows: [(String, String)] { ApprovalDetailParser.parse(detail).rows }

    /// Everything in `detail` that is not a table row (including the `批准后：…` line), or nil when empty.
    var detailNote: String? { ApprovalDetailParser.parse(detail).note }
}

// MARK: - Status

/// What the UI should show for one approval. Derived from the approval itself, the resolution the host sent
/// (or the one we recorded locally after a successful `approval.respond`) and the local submit state.
enum ApprovalStatus: Equatable, Sendable {
    case pending
    /// `approval.respond` is in flight (this includes the Face ID prompt).
    case submitting
    case approved
    case denied
    /// Past `expiresAt`, or the host resolved it with `by: "timeout"`. Buttons must be disabled.
    case expired
    /// The last submit failed; the approval is still open and can be retried.
    case failed(String)

    /// True while the buttons should be usable.
    var isActionable: Bool {
        switch self {
        case .pending, .failed: true
        default: false
        }
    }
}
