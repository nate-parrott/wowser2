import Foundation

/// In-memory scratch state for native pages (drafts, scroll offsets, …) that
/// should survive view remounts — tab switches, unloads, splits — but isn't
/// worth persisting in `BrowserState`. Entries are keyed by an id (e.g. an
/// agent session key) plus the value's type, and the least recently used are
/// evicted past `capacity`. Main thread only.
public final class NativeRenderCache {
    public static let shared = NativeRenderCache(capacity: 64)

    private struct Key: Hashable {
        var id: String
        var type: ObjectIdentifier
    }

    private let capacity: Int
    private var entries: [Key: Any] = [:]
    /// Least recently used first.
    private var order: [Key] = []

    init(capacity: Int) {
        self.capacity = capacity
    }

    public func get<T>(_ type: T.Type, id: String) -> T? {
        let key = Key(id: id, type: ObjectIdentifier(type))
        guard let value = entries[key] as? T else { return nil }
        touch(key)
        return value
    }

    /// Setting nil removes the entry.
    public func set<T>(_ value: T?, id: String) {
        let key = Key(id: id, type: ObjectIdentifier(T.self))
        guard let value else {
            entries[key] = nil
            order.removeAll { $0 == key }
            return
        }
        entries[key] = value
        touch(key)
        while order.count > capacity {
            entries[order.removeFirst()] = nil
        }
    }

    /// Drops every entry for `id`, e.g. when its page closes for good.
    public func removeAll(id: String) {
        order.removeAll { $0.id == id }
        entries = entries.filter { $0.key.id != id }
    }

    private func touch(_ key: Key) {
        if order.last == key { return }
        order.removeAll { $0 == key }
        order.append(key)
    }
}
