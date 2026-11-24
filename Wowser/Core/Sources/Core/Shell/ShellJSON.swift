import Foundation

/// A JSON value. Everything that crosses the JS ↔ Swift bridge of the shell
/// (node props, events, call arguments) is one of these.
public indirect enum ShellJSON: Equatable, Sendable {
    case null
    case bool(Bool)
    case number(Double)
    case string(String)
    case array([ShellJSON])
    case object([String: ShellJSON])

    // MARK: Parsing

    public static func parse(_ json: String) -> ShellJSON? {
        guard let data = json.data(using: .utf8),
              let any = try? JSONSerialization.jsonObject(with: data, options: [.fragmentsAllowed])
        else { return nil }
        return ShellJSON(any: any)
    }

    /// Wraps a `JSONSerialization`-style value.
    public init(any: Any) {
        switch any {
        case let s as String:
            self = .string(s)
        case let n as NSNumber:
            // JSONSerialization hands booleans back as NSNumber too; tell them
            // apart by the underlying type so `1` stays a number.
            if ShellJSON.isBoolean(n) {
                self = .bool(n.boolValue)
            } else {
                self = .number(n.doubleValue)
            }
        case let a as [Any]:
            self = .array(a.map { ShellJSON(any: $0) })
        case let d as [String: Any]:
            var out = [String: ShellJSON](minimumCapacity: d.count)
            for (k, v) in d { out[k] = ShellJSON(any: v) }
            self = .object(out)
        default:
            self = .null
        }
    }

    private static func isBoolean(_ n: NSNumber) -> Bool {
        #if canImport(Darwin)
        return CFGetTypeID(n) == CFBooleanGetTypeID()
        #else
        return String(cString: n.objCType) == "c"
        #endif
    }

    // MARK: Serialising

    public var any: Any {
        switch self {
        case .null: return NSNull()
        case .bool(let b): return b
        case .number(let n): return n
        case .string(let s): return s
        case .array(let a): return a.map(\.any)
        case .object(let o): return o.mapValues(\.any)
        }
    }

    public func jsonString() -> String {
        guard let data = try? JSONSerialization.data(withJSONObject: any, options: [.fragmentsAllowed, .sortedKeys]),
              let s = String(data: data, encoding: .utf8)
        else { return "null" }
        return s
    }

    // MARK: Accessors

    public subscript(key: String) -> ShellJSON? {
        if case .object(let o) = self { return o[key] }
        return nil
    }

    public var isNull: Bool {
        if case .null = self { return true }
        return false
    }

    public var string: String? {
        if case .string(let s) = self { return s }
        return nil
    }

    public var double: Double? {
        if case .number(let n) = self { return n }
        return nil
    }

    public var int: Int? {
        if case .number(let n) = self, n.isFinite { return Int(n) }
        return nil
    }

    public var bool: Bool? {
        if case .bool(let b) = self { return b }
        return nil
    }

    public var array: [ShellJSON]? {
        if case .array(let a) = self { return a }
        return nil
    }

    public var object: [String: ShellJSON]? {
        if case .object(let o) = self { return o }
        return nil
    }

    /// `true` for the boolean `true` only (an attached JS handler is sent as `true`).
    public var isTrue: Bool { self == .bool(true) }
}

extension ShellJSON: ExpressibleByStringLiteral, ExpressibleByBooleanLiteral, ExpressibleByFloatLiteral, ExpressibleByIntegerLiteral, ExpressibleByNilLiteral, ExpressibleByArrayLiteral, ExpressibleByDictionaryLiteral {
    public init(stringLiteral value: String) { self = .string(value) }
    public init(booleanLiteral value: Bool) { self = .bool(value) }
    public init(floatLiteral value: Double) { self = .number(value) }
    public init(integerLiteral value: Int) { self = .number(Double(value)) }
    public init(nilLiteral: ()) { self = .null }
    public init(arrayLiteral elements: ShellJSON...) { self = .array(elements) }
    public init(dictionaryLiteral elements: (String, ShellJSON)...) {
        self = .object(Dictionary(elements, uniquingKeysWith: { _, last in last }))
    }
}

extension ShellJSON {
    /// Encode any `Encodable` as a compact JSON string with stable key order.
    static func encode<T: Encodable>(_ value: T) -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        guard let data = try? encoder.encode(value), let s = String(data: data, encoding: .utf8) else { return "null" }
        return s
    }

    /// A JSON string literal for `s` (quotes and escapes included).
    static func quote(_ s: String) -> String {
        ShellJSON.string(s).jsonString()
    }
}
