import Foundation

/// A hybrid logical clock timestamp: wall-clock millis, a counter that breaks
/// ties within one millisecond (and absorbs skew from devices whose clocks run
/// ahead), and the writing device as the final tie-break. Totally ordered, so
/// "last writer wins" is well defined.
public struct HLC: Hashable, Comparable, Codable, Sendable, CustomStringConvertible {
    public var millis: Int64
    public var counter: Int32
    public var device: String

    public init(millis: Int64, counter: Int32, device: String) {
        self.millis = millis
        self.counter = counter
        self.device = device
    }

    public static func < (a: HLC, b: HLC) -> Bool {
        if a.millis != b.millis { return a.millis < b.millis }
        if a.counter != b.counter { return a.counter < b.counter }
        return a.device < b.device
    }

    public var date: Date { Date(timeIntervalSince1970: Double(millis) / 1000) }

    public var description: String { "\(millis).\(counter)@\(device)" }

    // Compact on the wire: "millis.counter@device". Logs are mostly clocks.
    public init(from decoder: Decoder) throws {
        let s = try decoder.singleValueContainer().decode(String.self)
        guard let parsed = HLC(string: s) else {
            throw DecodingError.dataCorrupted(.init(codingPath: decoder.codingPath, debugDescription: "Bad HLC \(s)"))
        }
        self = parsed
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.singleValueContainer()
        try c.encode(description)
    }

    public init?(string: String) {
        guard let at = string.firstIndex(of: "@") else { return nil }
        let time = string[..<at].split(separator: ".")
        guard time.count == 2, let millis = Int64(time[0]), let counter = Int32(time[1]) else { return nil }
        self.init(millis: millis, counter: counter, device: String(string[string.index(after: at)...]))
    }
}

/// Issues monotonically increasing HLC timestamps for one device.
public struct HLCClock: Codable, Equatable, Sendable {
    public var device: String
    public private(set) var last: HLC

    public init(device: String) {
        self.device = device
        self.last = HLC(millis: 0, counter: 0, device: device)
    }

    /// A fresh timestamp, later than every timestamp issued or observed so far.
    public mutating func tick(now: Date = Date()) -> HLC {
        let wall = Int64((now.timeIntervalSince1970 * 1000).rounded(.down))
        if wall > last.millis {
            last = HLC(millis: wall, counter: 0, device: device)
        } else {
            last = HLC(millis: last.millis, counter: last.counter + 1, device: device)
        }
        return last
    }

    /// Fold in a remote timestamp so later local writes sort after it.
    public mutating func observe(_ remote: HLC) {
        if remote.millis > last.millis || (remote.millis == last.millis && remote.counter > last.counter) {
            last = HLC(millis: remote.millis, counter: remote.counter, device: device)
        }
    }
}
