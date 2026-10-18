import Foundation

// MARK: - Log entries

/// One field write: "set `collection/key.field` to `value` at `clock`".
/// The whole sync log is a sequence of these, grouped into batches.
public struct SyncOp: Codable, Equatable, Sendable {
    public var col: String
    public var key: String
    public var f: String
    public var v: SyncValue
    public var c: HLC

    public init(col: String, key: String, f: String, v: SyncValue, c: HLC) {
        self.col = col
        self.key = key
        self.f = f
        self.v = v
        self.c = c
    }
}

/// A run of ops one device appended to its log in one go. `seq` increases by
/// one per batch per device, so readers can skip what they've seen.
public struct SyncBatch: Codable, Equatable, Sendable {
    public var device: String
    public var deviceName: String?
    public var seq: Int
    public var createdAt: Date
    /// True for a compaction snapshot: the writer's entire merged document,
    /// standing in for every batch it wrote before.
    public var snapshot: Bool?
    public var ops: [SyncOp]

    public init(device: String, deviceName: String?, seq: Int, createdAt: Date, snapshot: Bool? = nil, ops: [SyncOp]) {
        self.device = device
        self.deviceName = deviceName
        self.seq = seq
        self.createdAt = createdAt
        self.snapshot = snapshot
        self.ops = ops
    }
}

// MARK: - Schema

/// Engine-owned field names. Sources never project these directly.
public enum SyncReservedField {
    /// true = tombstone. Delete wins over concurrent edits; only an explicit
    /// `false` (a revive) brings a record back.
    public static let deleted = "_del"
    /// Ordered collections: the list this record sits in.
    public static let parent = "_parent"
    /// Ordered collections: fractional order key within `parent`.
    public static let order = "_order"

    public static let all: Set<String> = [deleted, parent, order]
}

/// Decides which of two writes to the same field survives. Implementations
/// MUST be commutative, associative and idempotent (a semilattice join) or
/// replicas won't converge. Default: last writer (highest clock) wins.
public protocol SyncMergePolicy {
    func merge(field: String, current: SyncField, incoming: SyncField) -> SyncField
}

public struct LastWriterWins: SyncMergePolicy {
    public init() {}
    public func merge(field: String, current: SyncField, incoming: SyncField) -> SyncField {
        if incoming.c != current.c { return incoming.c > current.c ? incoming : current }
        // Same clock, different value: can't happen with honest clocks, but
        // pick deterministically so replicas still agree.
        return Self.tiebreak(current.v) >= Self.tiebreak(incoming.v) ? current : incoming
    }

    static func tiebreak(_ v: SyncValue) -> String {
        (try? JSONEncoder().encode(v)).flatMap { String(data: $0, encoding: .utf8) } ?? ""
    }
}

/// Per-field overrides on top of last-writer-wins. Each override must itself
/// be a semilattice join.
public struct FieldMergePolicy: SyncMergePolicy {
    public var overrides: [String: (SyncField, SyncField) -> SyncField]

    public init(_ overrides: [String: (SyncField, SyncField) -> SyncField]) {
        self.overrides = overrides
    }

    public func merge(field: String, current: SyncField, incoming: SyncField) -> SyncField {
        if !SyncReservedField.all.contains(field), let fn = overrides[field] {
            return fn(current, incoming)
        }
        return LastWriterWins().merge(field: field, current: current, incoming: incoming)
    }

    /// Larger number wins (ties/non-numbers fall back to clock order). For
    /// monotonic counters and "last used" dates.
    public static func maxNumber(_ a: SyncField, _ b: SyncField) -> SyncField {
        switch (a.v.doubleValue, b.v.doubleValue) {
        case let (x?, y?) where x != y: return x > y ? a : b
        case (_?, nil): return a
        case (nil, _?): return b
        default: return LastWriterWins().merge(field: "", current: a, incoming: b)
        }
    }
}

/// Static description of one synced collection.
public struct SyncCollectionSpec {
    public var name: String
    /// Records carry `_parent` + `_order` and sources project ordered lists.
    public var ordered: Bool
    /// Records dropped from the local projection are NOT deleted remotely
    /// (e.g. history: only the top N visits are projected at any time).
    public var growOnly: Bool
    public var policy: SyncMergePolicy

    public init(name: String, ordered: Bool = false, growOnly: Bool = false, policy: SyncMergePolicy = LastWriterWins()) {
        self.name = name
        self.ordered = ordered
        self.growOnly = growOnly
        self.policy = policy
    }
}

// MARK: - Document (the CRDT)

public struct SyncField: Codable, Equatable, Sendable {
    public var v: SyncValue
    public var c: HLC
}

public struct SyncRecord: Codable, Equatable, Sendable {
    public var fields: [String: SyncField] = [:]
}

/// The merged state of every synced record: collection → key → field →
/// (value, clock). A state-based CRDT: merging ops in any order, any number
/// of times, yields the same document.
public struct SyncDocument: Codable, Equatable, Sendable {
    public var collections: [String: [String: SyncRecord]] = [:]

    public init() {}

    public enum MergeOutcome: Equatable {
        case unchanged
        /// The field's surviving value changed. `previous` is what it was.
        case changed(previous: SyncField?)
    }

    @discardableResult
    public mutating func merge(_ op: SyncOp, policy: SyncMergePolicy) -> MergeOutcome {
        let incoming = SyncField(v: op.v, c: op.c)
        let current = collections[op.col]?[op.key]?.fields[op.f]
        let winner = current.map { policy.merge(field: op.f, current: $0, incoming: incoming) } ?? incoming
        if winner == current { return .unchanged }
        collections[op.col, default: [:]][op.key, default: SyncRecord()].fields[op.f] = winner
        // Value-equal rewrites (new clock, same value) aren't a visible change.
        return current?.v == winner.v ? .unchanged : .changed(previous: current)
    }

    public func field(_ col: String, _ key: String, _ f: String) -> SyncField? {
        collections[col]?[key]?.fields[f]
    }

    public func value(_ col: String, _ key: String, _ f: String) -> SyncValue {
        field(col, key, f)?.v ?? .null
    }

    public func hasRecord(_ col: String, _ key: String) -> Bool {
        collections[col]?[key] != nil
    }

    public func isDeleted(_ col: String, _ key: String) -> Bool {
        value(col, key, SyncReservedField.deleted) == .bool(true)
    }

    public func isAlive(_ col: String, _ key: String) -> Bool {
        hasRecord(col, key) && !isDeleted(col, key)
    }

    /// Current non-null user fields of a live record (no reserved fields).
    public func fields(_ col: String, _ key: String) -> SyncFields? {
        guard isAlive(col, key), let rec = collections[col]?[key] else { return nil }
        var out = SyncFields()
        for (f, field) in rec.fields where !SyncReservedField.all.contains(f) && !field.v.isNull {
            out[f] = field.v
        }
        return out
    }

    public func aliveKeys(_ col: String) -> [String] {
        (collections[col] ?? [:]).keys.filter { !isDeleted(col, $0) }
    }

    public func parent(_ col: String, _ key: String) -> String? {
        value(col, key, SyncReservedField.parent).stringValue
    }

    /// Live records whose `_parent` is `parent`, in list order.
    public func children(_ col: String, parent: String) -> [String] {
        (collections[col] ?? [:]).compactMap { key, rec -> (OrderSortKey)? in
            guard rec.fields[SyncReservedField.deleted]?.v != .bool(true),
                  rec.fields[SyncReservedField.parent]?.v.stringValue == parent else { return nil }
            return OrderSortKey(order: rec.fields[SyncReservedField.order]?.v.stringValue ?? "", id: key)
        }.sorted().map(\.id)
    }

    /// Every field of every record as ops with their original clocks. Merging
    /// these into an empty document reproduces this one.
    public func allOps() -> [SyncOp] {
        var out = [SyncOp]()
        for (col, records) in collections {
            for (key, rec) in records {
                for (f, field) in rec.fields {
                    out.append(SyncOp(col: col, key: key, f: f, v: field.v, c: field.c))
                }
            }
        }
        return out
    }
}
