import Foundation

struct HistoryItem: Equatable, Codable, Identifiable {
    var key: String // URL.historyKey
    
    var title: String?
    var url: URL
    var decayedVisitCount = DecayedCounter()
    var lastVisit: Date
    
    var id: String { key }
    
    var score: TimeInterval {
        decayedVisitCount.decayedCount(interval: .decayedVisitCounterHalfLife)
    }
}


struct HistoryState: Equatable, Codable {
    var items = [HistoryItem.ID: HistoryItem]()
    
    mutating func trim(maxCount: Int = 400) {
        if items.count > Int(Double(maxCount) * 1.3) {
            let ranked = self.items.values.sorted(by: { $0.score > $1.score })
            self.items = [:]
            for item in ranked.prefix(maxCount) {
                self.items[item.id] = item
            }
        }
    }
    
    mutating func modify(url: URL, block: (inout HistoryItem) -> Void) {
        if var existing = items[url.historyKey] {
            block(&existing)
            self.items[existing.id] = existing
        } else {
            var item = HistoryItem(key: url.historyKey, title: nil, url: url, lastVisit: .distantPast)
            block(&item)
            self.items[item.id] = item
        }
    }
}

extension Queue {
    static let historyQueue = Queue(id: "HistoryQueue", queue: DispatchQueue(label: "HistoryQueue", qos: .default))
}

extension ID<Profile> {
    var historyStore_historyQueueOnly: HistoryStore {
        assert(Queue.historyQueue.isCurrent)
        if let existing = HistoryStore.stores[self] {
            return existing
        }
        let store = HistoryStore(persistenceKey: "HistoryStore_\(self.raw)", defaultModel: .init(), queue: .historyQueue)
        HistoryStore.stores[self] = store
        return store
    }
}

class HistoryStore: DataStore<HistoryState> {
//    static let shared = HistoryStore(persistenceKey: "HistoryStore", defaultModel: .init(), queue: .historyQueue)
    
    // only access on historyqueue
    fileprivate static var stores = [ID<Profile>: HistoryStore]()
    
    override func processModelAfterLoad(model: inout HistoryState) {
        // TODO: Periodically trim
        model.trim()
    }
    
    func trackVisitDebounced(url: URL, title: String?) {
        modify { state in
            state.modify(url: url) { item in
                item.url = url // b/c multiple history keys may resolve to different urls
                item.title = title ?? item.title
                if !item.lastVisit.isWithinPast(minutes: 5) {
                    item.decayedVisitCount.add(count: 1, interval: .decayedVisitCounterHalfLife)
                    item.lastVisit = Date()
                }
            }
        }
    }
    
    func updatePageInfo(url: URL, title: String?) {
        modify { state in
            state.modify(url: url) { item in
                item.url = url
                item.title = title ?? item.title
            }
        }
    }
}

extension TimeInterval {
    static var decayedVisitCounterHalfLife: TimeInterval = 24 * 60 * 60 * 5 // 5 days
}
