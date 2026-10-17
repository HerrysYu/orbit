import SwiftUI

// MARK: - Formatting

enum Fmt {
    static func time(_ ms: Int64) -> String {
        Clock.date(ms: ms).formatted(date: .omitted, time: .shortened)
    }

    static func dateTime(_ ms: Int64) -> String {
        let d = Clock.date(ms: ms)
        if Calendar.current.isDateInToday(d) { return "今天 " + time(ms) }
        if Calendar.current.isDateInTomorrow(d) { return "明天 " + time(ms) }
        return d.formatted(.dateTime.month().day().hour().minute())
    }

    static func relative(_ ms: Int64) -> String {
        Clock.date(ms: ms).formatted(.relative(presentation: .named))
    }

    static func money(_ v: Double, currency: String = "CNY") -> String {
        v.formatted(.currency(code: currency).precision(.fractionLength(v.rounded() == v ? 0 : 2)))
    }

    static func bytes(_ n: Int) -> String {
        Int64(n).formatted(.byteCount(style: .file))
    }
}
