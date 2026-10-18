import Foundation

/// Turns "what local data looks like now" into log writes.
///
/// A field is written only if it changed locally since the previous
/// projection AND differs from the merged document. The first condition
/// means remote values that haven't been applied locally yet (or can't be)
/// are never reverted by a stale local snapshot; the second means applying a
/// remote value locally doesn't echo it back as a new write.
public enum SyncDiff {
    public struct Write: Equatable, CustomStringConvertible {
        public var col: String
        public var key: String
        public var f: String
        public var v: SyncValue

        public var description: String { "\(col)/\(key).\(f)=\(v)" }
    }

    /// - Returns: the writes, and `projection` with `_parent`/`_order` filled
    ///   in for ordered collections (keep it as the next `previous`).
    ///   Collections missing from `projection` are left alone (and carried
    ///   over from `previous`).
    public static func diff(specs: [String: SyncCollectionSpec], projection: SyncProjection, previous: SyncProjection?, doc: SyncDocument) -> (writes: [Write], resolved: SyncProjection) {
        var resolved = previous ?? SyncProjection()
        var writes = [Write]()

        for (col, records) in projection.records.sorted(by: { $0.key < $1.key }) {
            let spec = specs[col] ?? SyncCollectionSpec(name: col)
            var newRecords = records
            if spec.ordered {
                resolveOrder(col: col, records: &newRecords, lists: projection.lists[col] ?? [:], previous: previous, doc: doc)
            }
            let oldRecords = previous?.records[col] ?? [:]

            for key in newRecords.keys.sorted() {
                let new = newRecords[key]!
                let old = oldRecords[key]
                if doc.isDeleted(col, key) {
                    // Known locally but tombstoned. If we'd seen it before, the
                    // remote delete just hasn't been applied here yet. If not
                    // (first sync on this device, or it was revived), revive it.
                    guard old == nil else { continue }
                    writes.append(Write(col: col, key: key, f: SyncReservedField.deleted, v: .bool(false)))
                    for (f, v) in new.sorted(by: { $0.key < $1.key }) where !v.isNull {
                        writes.append(Write(col: col, key: key, f: f, v: v))
                    }
                    continue
                }
                if !doc.hasRecord(col, key) {
                    writes.append(Write(col: col, key: key, f: SyncReservedField.deleted, v: .bool(false)))
                }
                let names = Set(new.keys).union(old.map { Array($0.keys) } ?? []).sorted()
                for f in names {
                    let nv = new[f] ?? .null
                    let changedLocally = old == nil || nv != (old?[f] ?? .null)
                    if changedLocally && nv != doc.value(col, key, f) {
                        writes.append(Write(col: col, key: key, f: f, v: nv))
                    }
                }
            }

            if !spec.growOnly {
                for key in oldRecords.keys.sorted() where newRecords[key] == nil && doc.isAlive(col, key) {
                    writes.append(Write(col: col, key: key, f: SyncReservedField.deleted, v: .bool(true)))
                }
            }

            resolved.records[col] = newRecords
            if spec.ordered {
                resolved.lists[col] = projection.lists[col] ?? [:]
            }
        }
        return (writes, resolved)
    }

    /// Fill `_parent` / `_order` for every listed item. A list that's
    /// unchanged since `previous` keeps its keys verbatim (so an unapplied
    /// remote reorder isn't overwritten); a changed list keeps the merged
    /// doc's keys for the longest already-ordered run and mints the rest.
    static func resolveOrder(col: String, records: inout [String: SyncFields], lists: [String: [String]], previous: SyncProjection?, doc: SyncDocument) {
        for (parent, items) in lists {
            let prevItems = previous?.lists[col]?[parent]
            var keys: [String: String]? = nil
            if prevItems == items {
                var reused = [String: String]()
                for item in items {
                    guard let prev = previous?.records[col]?[item],
                          prev[SyncReservedField.parent]?.stringValue == parent,
                          let k = prev[SyncReservedField.order]?.stringValue else { reused = [:]; break }
                    reused[item] = k
                }
                if reused.count == items.count { keys = reused }
            }
            if keys == nil {
                var existing = [String: String]()
                for item in items where doc.isAlive(col, item) && doc.parent(col, item) == parent {
                    if let k = doc.value(col, item, SyncReservedField.order).stringValue {
                        existing[item] = k
                    }
                }
                keys = SyncOrdering.assignKeys(items: items, existing: existing)
            }
            for item in items {
                records[item, default: [:]][SyncReservedField.parent] = .string(parent)
                records[item, default: [:]][SyncReservedField.order] = keys![item].map(SyncValue.string) ?? .null
            }
        }
    }
}
