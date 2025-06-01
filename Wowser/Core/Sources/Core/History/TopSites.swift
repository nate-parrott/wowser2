import Combine
import Foundation

class TopSitesFetcher: ObservableObject {
    @Published var topSites = [TopSiteItem]()
    private var subscriptions = Set<AnyCancellable>()
    
    var profileID: ID<Profile>? {
        didSet {
            if oldValue != profileID {
                subscriptions.removeAll()
                if let profileID {
                    Queue.historyQueue.queue.async {
                        let historyStore = profileID.historyStore_historyQueueOnly
                        DispatchQueue.main.async {
                            historyStore.topSites(n: 5)
                                .receive(on: DispatchQueue.main)
                                .sink { [weak self] sites in
                                    self?.topSites = sites
                                }
                                .store(in: &self.subscriptions)
                        }
                    }
                }
            }
        }
    }
}

extension HistoryStore {
    func topSites(n: Int) -> AnyPublisher<[TopSiteItem], Never> {
        return uiPublisher
            .throttle(for: .seconds(5), scheduler: DispatchQueue.main, latest: true)
            .map { state -> [TopSiteItem] in
                let topItems = state.historyTopHitCandidates.prefix(n)
                let otherItems = Self.baseHistoryItems
                let scored = (topItems + otherItems).sorted(key: { $0.score }).reversed()
                return scored.prefix(n).map({ TopSiteItem(title: $0.title ?? $0.url.hostWithoutWWW, url: $0.url) }).asArray
            }
            .removeDuplicates()
            .eraseToAnyPublisher()
    }
    
    static private let baseHistoryItems: [HistoryItem] = {
        let wiki = URL(string: "https://en.wikipedia.org")!
        let youtube = URL(string: "https://youtube.com")!
        let nyt = URL(string: "https://nytimes.com")!
        let reddit = URL(string: "https://reddit.com")!
        let baseScore = DecayedCounter(lastCount: 1.5, lastUpdateDate: nil)
        let baseItems: [HistoryItem] = [
            HistoryItem(key: wiki.historyKey, title: "Wikipedia", url: wiki, decayedVisitCount: DecayedCounter(lastCount: 1.53, lastUpdateDate: Date()), lastVisit: Date()),
            HistoryItem(key: youtube.historyKey, title: "YouTube", url: youtube, decayedVisitCount: DecayedCounter(lastCount: 1.52, lastUpdateDate: Date()), lastVisit: Date()),
            HistoryItem(key: nyt.historyKey, title: "New York Times", url: nyt, decayedVisitCount: DecayedCounter(lastCount: 1.51, lastUpdateDate: Date()), lastVisit: Date()),
            HistoryItem(key: reddit.historyKey, title: "Reddit", url: reddit, decayedVisitCount: DecayedCounter(lastCount: 1.5, lastUpdateDate: Date()), lastVisit: Date()),
        ]
        return baseItems
    }()
}

struct TopSiteItem: Equatable, Codable, Identifiable {
    var title: String
    var url: URL
    var id: URL { url }
    
    // hacky casts
    var asSearchResult: SearchResult {
        SearchResult(item: .init(id: .init(raw: url.absoluteString), content: .historyItem(asHistoryItem)), matchQuality: .none)
    }
    
    var asHistoryItem: HistoryItem {
        HistoryItem(key: url.historyKey, title: title, url: url, lastVisit: Date.distantPast)
    }
}
