import Foundation

/// A JSON value. Every synced field holds one of these, so the engine can
/// diff, merge and log fields without knowing what they mean.
public enum SyncValue: Hashable, Codable, Sendable {
    case null
    case bool(Bool)
    case number(Double)
    case string(String)
    case array([SyncValue])
    case object([String: SyncValue])

    public init(from decoder: Decoder) throws {
        let c = try decoder.singleValueContainer()
        if c.decodeNil() { self = .null }
        else if let b = try? c.decode(Bool.self) { self = .bool(b) }
        else if let n = try? c.decode(Double.self) { self = .number(n) }
        else if let s = try? c.decode(String.self) { self = .string(s) }
        else if let a = try? c.decode([SyncValue].self) { self = .array(a) }
        else { self = .object(try c.decode([String: SyncValue].self)) }
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.singleValueContainer()
        switch self {
        case .null: try c.encodeNil()
        case .bool(let b): try c.encode(b)
        case .number(let n): try c.encode(n)
        case .string(let s): try c.encode(s)
        case .array(let a): try c.encode(a)
        case .object(let o): try c.encode(o)
        }
    }

    public var isNull: Bool { self == .null }

    public var stringValue: String? {
        if case .string(let s) = self { return s }
        return nil
    }

    public var doubleValue: Double? {
        if case .number(let n) = self { return n }
        return nil
    }

    public var boolValue: Bool? {
        if case .bool(let b) = self { return b }
        return nil
    }

    public var objectValue: [String: SyncValue]? {
        if case .object(let o) = self { return o }
        return nil
    }

    public var urlValue: URL? { stringValue.flatMap(URL.init(string:)) }
}

public extension SyncValue {
    init(_ string: String?) { self = string.map(SyncValue.string) ?? .null }
    init(_ url: URL?) { self = url.map { .string($0.absoluteString) } ?? .null }
    init(_ bool: Bool?) { self = bool.map(SyncValue.bool) ?? .null }
    init(_ number: Double?) { self = number.map(SyncValue.number) ?? .null }
    /// Dates sync as seconds since the reference date (2001), which is how
    /// Date stores them, so they round-trip exactly.
    init(_ date: Date?) { self = date.map { .number($0.timeIntervalSinceReferenceDate) } ?? .null }

    var dateValue: Date? { doubleValue.map(Date.init(timeIntervalSinceReferenceDate:)) }

    /// Round-trips any Codable through JSON. Use for small nested structs
    /// (e.g. a space's theme) that sync as one opaque field.
    static func encoding<T: Encodable>(_ value: T?) -> SyncValue {
        guard let value, let data = try? JSONEncoder().encode(value),
              let decoded = try? JSONDecoder().decode(SyncValue.self, from: data) else { return .null }
        return decoded
    }

    func decoded<T: Decodable>(as type: T.Type) -> T? {
        guard !isNull, let data = try? JSONEncoder().encode(self) else { return nil }
        return try? JSONDecoder().decode(T.self, from: data)
    }
}

/// The fields of one synced record, e.g. one tab: `["title": "Foo", ...]`.
/// A missing field and a `.null` field mean the same thing.
public typealias SyncFields = [String: SyncValue]
