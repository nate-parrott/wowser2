import Foundation

/// What a source's local data looks like in sync terms: collection → key →
/// fields, plus (for ordered collections) the ordered key lists per parent.
/// Sources build these from scratch; they're cheap value types and the engine
/// diffs them against the previous one and the merged document.
public struct SyncProjection: Equatable, Codable, Sendable {
    public var records: [String: [String: SyncFields]] = [:]
    /// collection → parent → item keys in local order. Every listed key must
    /// also be in `records[collection]`.
    public var lists: [String: [String: [String]]] = [:]

    public init() {}

    public subscript(col: String, key: String) -> SyncFields? {
        get { records[col]?[key] }
        set { records[col, default: [:]][key] = newValue }
    }

    public mutating func append(_ key: String, to parent: String, in col: String) {
        lists[col, default: [:]][parent, default: []].append(key)
    }

    /// Ensure a collection appears (even when empty) so the engine knows the
    /// source vouched for it: a missing collection is "unknown", not "empty".
    public mutating func declare(_ col: String) {
        if records[col] == nil { records[col] = [:] }
    }
}

/// Remote changes for one source to fold into its local data. Sources apply
/// these inside their own transaction, comparing against what they hold right
/// then (`fieldsToApply`, `shouldDelete`, `desiredOrder`) so a local edit made
/// after the engine last looked is never clobbered: it'll be emitted next
/// round with a newer clock and win anyway.
public struct SyncUpdate {
    /// Merged state of everything (read-only lookup).
    public var doc: SyncDocument
    /// collection → keys whose merged value changed (or is out of step locally).
    public var changed: [String: Set<String>]
    /// collection → parents whose child order may need rewriting.
    public var changedParents: [String: Set<String>]
    /// The engine's last view of local data. Values here are what the source
    /// held when the engine last diffed; if the source still holds them, it
    /// hasn't edited since and the remote value can be applied.
    public var expected: SyncProjection

    public init(doc: SyncDocument, changed: [String: Set<String>], changedParents: [String: Set<String>], expected: SyncProjection) {
        self.doc = doc
        self.changed = changed
        self.changedParents = changedParents
        self.expected = expected
    }

    public var isEmpty: Bool {
        changed.values.allSatisfy(\.isEmpty) && changedParents.values.allSatisfy(\.isEmpty)
    }

    public func changedKeys(_ col: String) -> [String] {
        (changed[col] ?? []).sorted()
    }

    /// Fields of `col/key` the source should overwrite with the merged value,
    /// given what it holds now (`current`, nil if it doesn't have the record).
    /// `.null` in the result means "clear". Empty when nothing to do. Returns
    /// nil if the record is dead in the merged doc (see `shouldDelete`).
    public func fieldsToApply(_ col: String, _ key: String, current: SyncFields?) -> SyncFields? {
        guard doc.isAlive(col, key) else { return nil }
        let merged = doc.fields(col, key) ?? [:]
        let expect = expected[col, key]
        var out = SyncFields()
        let names = Set(merged.keys).union(current.map { Array($0.keys) } ?? []).subtracting(SyncReservedField.all)
        for f in names {
            let want = merged[f] ?? .null
            let have = current?[f] ?? .null
            if want == have { continue }
            if let expect, current != nil {
                // Locally edited since the engine looked: keep the local value.
                guard (expect[f] ?? .null) == have else { continue }
            }
            out[f] = want
        }
        return out
    }

    /// True when the merged doc says `col/key` is deleted and the source
    /// still has it. (Delete wins over concurrent edits.)
    public func shouldDelete(_ col: String, _ key: String, current: SyncFields?) -> Bool {
        current != nil && doc.isDeleted(col, key) && expected[col, key] != nil
    }

    /// The order the source's list for `parent` should take, or nil if it's
    /// already right or the user reordered it locally since the engine looked.
    /// `local` is the source's current list (keys may include local-only items
    /// not yet synced; they keep their position relative to their neighbors).
    public func desiredOrder(_ col: String, parent: String, local: [String]) -> [String]? {
        let synced = doc.children(col, parent: parent)
        let syncedSet = Set(synced)
        if let expect = expected.lists[col]?[parent] {
            // CAS: compare only items both sides know about.
            let localSet = Set(local)
            let expectSet = Set(expect)
            let localKnown = local.filter { expectSet.contains($0) }
            let expectStillHere = expect.filter { localSet.contains($0) }
            guard localKnown == expectStillHere else { return nil }
        }
        // Local items the doc doesn't know (new, unsynced) stay put; known
        // items the doc places elsewhere (or deleted) leave.
        let docKnows: (String) -> Bool = { doc.hasRecord(col, $0) }
        var result = [String]()
        var pendingSynced = synced[...]
        for item in local {
            if docKnows(item) {
                // Slot taken by a synced item: emit the next one in doc order.
                if syncedSet.contains(item), let next = pendingSynced.first {
                    result.append(next)
                    pendingSynced = pendingSynced.dropFirst()
                }
            } else {
                result.append(item)
            }
        }
        result.append(contentsOf: pendingSynced)
        return result == local ? nil : result
    }
}
