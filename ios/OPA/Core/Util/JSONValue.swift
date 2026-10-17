import Foundation

/// Dynamic JSON value used for GenUI props, request/response payloads and anything
/// whose shape is not fixed by the protocol.
enum JSONValue: Sendable, Hashable {
    case null
    case bool(Bool)
    case number(Double)
    case string(String)
    case array([JSONValue])
    case object([String: JSONValue])
}

// MARK: - Codable

extension JSONValue: Codable {
    init(from decoder: any Decoder) throws {
        let c = try decoder.singleValueContainer()
        if c.decodeNil() {
            self = .null
        } else if let b = try? c.decode(Bool.self) {
            self = .bool(b)
        } else if let d = try? c.decode(Double.self) {
            self = .number(d)
        } else if let s = try? c.decode(String.self) {
            self = .string(s)
        } else if let a = try? c.decode([JSONValue].self) {
            self = .array(a)
        } else if let o = try? c.decode([String: JSONValue].self) {
            self = .object(o)
        } else {
            throw DecodingError.dataCorruptedError(in: c, debugDescription: "Unsupported JSON value")
        }
    }

    func encode(to encoder: any Encoder) throws {
        var c = encoder.singleValueContainer()
        switch self {
        case .null: try c.encodeNil()
        case .bool(let b): try c.encode(b)
        case .number(let d):
            // Emit integers without a fractional part ("1", not "1.0").
            if d.rounded() == d, abs(d) < 9.0e15 {
                try c.encode(Int64(d))
            } else {
                try c.encode(d)
            }
        case .string(let s): try c.encode(s)
        case .array(let a): try c.encode(a)
        case .object(let o): try c.encode(o)
        }
    }
}

// MARK: - Literals

extension JSONValue: ExpressibleByNilLiteral, ExpressibleByBooleanLiteral, ExpressibleByIntegerLiteral,
    ExpressibleByFloatLiteral, ExpressibleByStringLiteral, ExpressibleByArrayLiteral, ExpressibleByDictionaryLiteral
{
    init(nilLiteral: ()) { self = .null }
    init(booleanLiteral value: Bool) { self = .bool(value) }
    init(integerLiteral value: Int) { self = .number(Double(value)) }
    init(floatLiteral value: Double) { self = .number(value) }
    init(stringLiteral value: String) { self = .string(value) }
    init(arrayLiteral elements: JSONValue...) { self = .array(elements) }
    init(dictionaryLiteral elements: (String, JSONValue)...) {
        self = .object(Dictionary(elements, uniquingKeysWith: { _, new in new }))
    }
}

// MARK: - Accessors

extension JSONValue {
    subscript(key: String) -> JSONValue? {
        if case .object(let o) = self { return o[key] }
        return nil
    }

    subscript(index: Int) -> JSONValue? {
        if case .array(let a) = self, a.indices.contains(index) { return a[index] }
        return nil
    }

    var isNull: Bool { if case .null = self { return true } else { return false } }

    var string: String? { if case .string(let s) = self { return s } else { return nil } }
    var double: Double? {
        switch self {
        case .number(let d): return d
        case .string(let s): return Double(s)
        default: return nil
        }
    }
    var int: Int? { double.map { Int($0) } }
    var int64: Int64? { double.map { Int64($0) } }
    var bool: Bool? { if case .bool(let b) = self { return b } else { return nil } }
    var array: [JSONValue]? { if case .array(let a) = self { return a } else { return nil } }
    var object: [String: JSONValue]? { if case .object(let o) = self { return o } else { return nil } }

    /// Array accessor that treats missing / non-array as empty.
    var items: [JSONValue] { array ?? [] }

    /// A human readable rendering of scalars (used by tables and form defaults).
    var displayString: String {
        switch self {
        case .null: return ""
        case .bool(let b): return b ? "是" : "否"
        case .number(let d):
            if d.rounded() == d, abs(d) < 9.0e15 { return String(Int64(d)) }
            return String(format: "%.2f", d)
        case .string(let s): return s
        case .array, .object: return compactJSON
        }
    }

    /// Shallow merge (used by `ui.patch`). Non-object receivers are replaced.
    func merging(_ other: JSONValue) -> JSONValue {
        guard case .object(var base) = self, case .object(let patch) = other else { return other }
        for (k, v) in patch { base[k] = v }
        return .object(base)
    }

    /// Deep merge (used for optimistic `settings.set`).
    func deepMerging(_ other: JSONValue) -> JSONValue {
        guard case .object(var base) = self, case .object(let patch) = other else { return other }
        for (k, v) in patch {
            if let existing = base[k], case .object = existing, case .object = v {
                base[k] = existing.deepMerging(v)
            } else {
                base[k] = v
            }
        }
        return .object(base)
    }
}

// MARK: - Conversion

extension JSONValue {
    private static let encoder: JSONEncoder = {
        let e = JSONEncoder()
        e.outputFormatting = [.withoutEscapingSlashes]
        return e
    }()

    init(data: Data) throws {
        self = try JSONDecoder().decode(JSONValue.self, from: data)
    }

    init(jsonString: String) throws {
        try self.init(data: Data(jsonString.utf8))
    }

    /// Converts any Encodable into a JSONValue.
    init<T: Encodable>(encoding value: T) throws {
        let data = try Self.encoder.encode(value)
        self = try JSONDecoder().decode(JSONValue.self, from: data)
    }

    /// Decodes the value into a concrete Decodable type.
    func decode<T: Decodable>(_ type: T.Type = T.self) throws -> T {
        try JSONDecoder().decode(T.self, from: data())
    }

    func data(sorted: Bool = false) throws -> Data {
        if sorted {
            let e = JSONEncoder()
            e.outputFormatting = [.withoutEscapingSlashes, .sortedKeys]
            return try e.encode(self)
        }
        return try Self.encoder.encode(self)
    }

    var compactJSON: String {
        (try? data(sorted: true)).flatMap { String(data: $0, encoding: .utf8) } ?? "null"
    }

    var prettyJSON: String {
        let e = JSONEncoder()
        e.outputFormatting = [.withoutEscapingSlashes, .sortedKeys, .prettyPrinted]
        return (try? e.encode(self)).flatMap { String(data: $0, encoding: .utf8) } ?? "null"
    }
}
