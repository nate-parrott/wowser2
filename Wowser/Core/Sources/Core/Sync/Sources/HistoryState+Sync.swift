import Foundation

// History sync: each login group's most-visited pages (the ones that power
// omnibox suggestions and top sites), not the full visit log. Grow-only:
// a page dropping out of the top N doesn't delete it elsewhere.

public enum HistorySyncSchema {
    public static let collection = "history"
    /// Pages per login group that sync.
    public static let topCount = 200

    public static var collections: [SyncCollectionSpec] {
        [SyncCollectionSpec(name: collection, growOnly: true, policy: FieldMergePolicy([
            "lastVisit": FieldMergePolicy.maxNumber,
            "visits": strongerVisitCount,
        ]))]
    }

    static func key(group: String, historyKey: String) -> String { "\(group)|\(historyKey)" }

    static func parse(_ key: String) -> (group: String, historyKey: String)? {
        guard let bar = key.firstIndex(of: "|") else { return nil }
        return (String(key[..<bar]), String(key[key.index(after: bar)...]))
    }

    /// `visits` is a decayed counter `{n, t}` (count as of time t, halving
    /// every half-life). Comparing log2(n) + t/halfLife ranks two counters
    /// the same way at any moment, so "keep the stronger" is time-independent
    /// and therefore a valid merge. Devices' counts aren't summed: the
    /// busiest device's count wins.
    static func strongerVisitCount(_ a: SyncField, _ b: SyncField) -> SyncField {
        let sa = strength(a.v), sb = strength(b.v)
        if sa != sb { return sa > sb ? a : b }
        return LastWriterWins().merge(field: "visits", current: a, incoming: b)
    }

    static func strength(_ v: SyncValue) -> Double {
        guard let o = v.objectValue, let n = o["n"]?.doubleValue, n > 0 else { return -.infinity }
        return log2(n) + (o["t"]?.doubleValue ?? 0) / TimeInterval.decayedVisitCounterHalfLife
    }
}

extension HistoryState {
    /// The top pages as records keyed under `group`.
    func syncRecords(group: String) -> [String: SyncFields] {
        var out = [String: SyncFields]()
        for item in items.values.sorted(by: { $0.score > $1.score }).prefix(HistorySyncSchema.topCount) {
            out[HistorySyncSchema.key(group: group, historyKey: item.key)] = item.syncFields
        }
        return out
    }

    /// Apply merged fields for one page.
    mutating func applySync(historyKey: String, fields: SyncFields, all: SyncFields) {
        guard let url = all["url"]?.urlValue else { return }
        var item = items[historyKey] ?? HistoryItem(key: historyKey, title: nil, url: url, lastVisit: .distantPast)
        if fields["url"] != nil { item.url = url }
        if let t = fields["title"] { item.title = t.stringValue }
        if let d = fields["lastVisit"]?.dateValue { item.lastVisit = d }
        if let v = fields["visits"]?.objectValue {
            item.decayedVisitCount = DecayedCounter(lastCount: v["n"]?.doubleValue ?? 0, lastUpdateDate: v["t"]?.dateValue)
        }
        items[historyKey] = item
    }
}

extension HistoryItem {
    var syncFields: SyncFields {
        var f: SyncFields = [
            "url": .string(url.absoluteString),
            "lastVisit": SyncValue(lastVisit),
        ]
        if let title { f["title"] = .string(title) }
        if let at = decayedVisitCount.lastUpdateDate {
            f["visits"] = .object(["n": .number(decayedVisitCount.lastCount), "t": SyncValue(at)])
        }
        return f
    }
}
