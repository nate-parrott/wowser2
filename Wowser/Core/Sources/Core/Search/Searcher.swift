import Combine
import Foundation

struct SearchableItem: Equatable {
    enum Content: Equatable {
        case searchWhatYouTyped(String)
        case urlYouTyped(URL)
        case searchSuggestion(String, Int /* source index */)
        case imFeelingLucky(String) // navigates to the first search result for this
        case historyItem(HistoryItem)
        case chatbot(String)
    }
    
    var id: ID<SearchableItem>
    var content: Content
    var urlMatchStrings: [NormalizedSearchableString] = []
    var titleMatchStr: NormalizedSearchableString?
    var dedupeKey: String {
        switch content {
        case .searchWhatYouTyped(let string): return URL.googleSearch(string).historyKey
        case .urlYouTyped(let url): return url.historyKey
        case .searchSuggestion(let string, _): return URL.googleSearch(string).historyKey
        case .imFeelingLucky(let string): return "lucky:\(string)"
        case .historyItem(let historyItem): return historyItem.key
        case .chatbot(let query): return "chat:\(query)"
        }
    }
}

struct SearchResult: Equatable, Identifiable {
    enum MatchQuality: Int {
        case prefixMatchURL = 3
        case prefixMatchTitle = 2
        case substringMatchTitle = 1
        case none = 0
    }
    var item: SearchableItem
    var matchQuality: MatchQuality
    
    var id: String {
        item.id.raw
    }
    
    var score: Double {
        switch item.content {
        case .searchWhatYouTyped:
            return 10
        case .urlYouTyped:
            return 100
        case .searchSuggestion(_, let int):
            if matchQuality == .prefixMatchTitle || matchQuality == .prefixMatchURL {
                return 1 - Double(int) * 0.1
            }
            return 0
        case .imFeelingLucky:
            if matchQuality == .prefixMatchTitle {
                return 12
            }
            return 0
        case .chatbot:
            if matchQuality == .prefixMatchTitle {
                return 11
            }
            return 0
        case .historyItem(let historyItem):
            print("\(historyItem.url): \(historyItem.score)")
            // `historyItem.score` is decayed visit count, where half-life = 5 days
            let topSite = historyItem.score >= 4
            let recentSite = historyItem.score >= 0.6
            switch matchQuality {
            case .prefixMatchURL:
                return topSite ? 30 : (recentSite ? 12 : 5)
            case .prefixMatchTitle:
                return topSite ? 15 : (recentSite ? 8 : 3)
            case .substringMatchTitle:
                return topSite ? 9 : (recentSite ? 4 : 2)
            case .none:
                return 0
            }
        }
//        var k: Double = 0
//        
//        switch item.content {
//        case .searchWhatYouTyped: k += 5
//        case .urlYouTyped: k += 10
//        case .searchSuggestion(_, let index): k += 2 - Double(index) * 0.1
//        case .imFeelingLucky: k += 10
//        case .historyItem(let item):
//            if item.score > 10 {
//                k += 10
//            } else if item.score >= 2 {
//                k += 5
//            } else if item.score >= 0.5 {
//                k += 1
//            }
//            k += item.score * 0.001 // tiebreaker
//        }
//        return k
    }
}

struct NormalizedSearchableString: Equatable {
    var unnormalized: String
    var normalizedWithLeadingSpace: String
    
    init(text: String) {
        self.unnormalized = text
        self.normalizedWithLeadingSpace = " " + text.lowercased().components(separatedBy: .tokenSplits).filter({ $0 != "" }).joined(separator: " ")
    }
    
    func prefixMatches(query: NormalizedSearchableString) -> Bool {
        return normalizedWithLeadingSpace.hasPrefix(query.normalizedWithLeadingSpace)
    }
    
    func wordBoundarySubstringMatches(query: NormalizedSearchableString) -> Bool {
        return normalizedWithLeadingSpace.contains(query.normalizedWithLeadingSpace)
    }
}

extension CharacterSet {
    static var tokenSplits = CharacterSet.whitespacesAndNewlines.union(CharacterSet(charactersIn: "-:/–—.\"“”'‘’"))
}

@MainActor class Searcher: ObservableObject {
    @Published var results = [SearchResult]()
    var n = 5
    
    init() {
        
    }
    
    init(forTestingWithHistoryStore historyStore: HistoryStore?) {
        self.historyStore = historyStore
    }
    
    var profileID: ID<Profile>? {
        didSet {
            if profileID != oldValue {
                setupHistoryObservers()
            }
        }
    }
    
    private var historyStore: HistoryStore?
    
    @Published var query = "" {
        didSet {
            let prevQuery = oldValue
            let prevResults = query.hasPrefix(prevQuery) ?  results : [] // prev results are only relevant if typing forwards
            let query = self.query
            
            if query == "" {
                self.results = []
                return
            }
            
            // First run a fast path search
            let fastPath = fastPathSearch(query: query, prevResults: prevResults)
            
            var showNow = fastPath
            // Append items from OLD array that were at same index to showNow (dont thrash them yet)
            for oldItem in prevResults.dropFirst(fastPath.count) {
                showNow.append(oldItem)
            }
            self.results = showNow.deduplicate({ $0.item.dedupeKey })
            
            // Now do slow path:
            Task {
                // Run more comprehensive slow path search
                let slowResults = await slowPathSearch(query: query, fastPath: fastPath)
                if self.query != query {
                    return
                }
                self.results = slowResults.deduplicate({ $0.item.dedupeKey })
            }
        }
    }
    
    private var subscriptions = Set<AnyCancellable>()
    
    private func setupHistoryObservers() {
        subscriptions.removeAll()
        historyStore = nil
        
        guard let profileId = self.profileID else { return }
        Queue.historyQueue.run {
            let store = profileId.historyStore_historyQueueOnly
            DispatchQueue.main.async {
                self.historyStore = store
                store.publisher.throttle(for: .seconds(2), scheduler: Queue.historyQueue.queue, latest: true)
                    .removeDuplicates()
                    .map { $0.historyTopHitCandidates }
                    .removeDuplicates()
                    .map { $0.map(\.searchableItem) }
                    .receive(on: DispatchQueue.main)
                    .sink { [weak self] cands in
                        self?.historyTopHitCandidates = cands
                    }
                    .store(in: &self.subscriptions)
            }
        }
        

    }
    
    // We cache, on the main queue, our top candidates
    private var historyTopHitCandidates = [SearchableItem]()
    
    func fastPathSearch(query: String, prevResults: [SearchResult]) -> [SearchResult] {
        let normQuery = NormalizedSearchableString(text: query)
        var results = [SearchResult]()
        
        let classification = classifyQuery(query)
        
        if classification == .nav {
            results.append(.navItem(query))
        }
        
        // If typed a literal URL, include it:
        if let url = URL.withNaturalString(query) {
            results.append(.urlYouTyped(url))
        }
        
        if classification == .chat {
            results.append(.chatbot(query))
        }
        results.append(.searchYouTyped(query))
        
        // Filter the highest-ranking URLs from historyTopHitCandidates, and any from the prev search
        let prevHistoryItems = prevResults.filter({ $0.item.historyItem != nil }).map { $0.item }
        if let topHistoryItem = (historyTopHitCandidates + prevHistoryItems).compactMap({ $0.match(query: normQuery) }).max(by: { $0.score < $1.score }) {
            if let insertBefore = results.firstIndex(where: { topHistoryItem.score > $0.score }) {
                results.insert(topHistoryItem, at: insertBefore)
            } else {
                results.append(topHistoryItem)
            }
        }
        
        // Sort THESE first 3 according to rank. Don't sort the whole set, because we don't want URL-you-typed and search-you-typed moving out of top 3
//        results.sort(by: { $0.score > $1.score })
        
        
        let dedupeKeys = Set(results.map({ $0.item.dedupeKey }))
        let matchesFromPrevResults = prevResults
            .filter({ !dedupeKeys.contains($0.item.dedupeKey) })
            .compactMap({ $0.item.match(query: normQuery) })
        for item in matchesFromPrevResults {
            if results.count >= n { break }
            results.append(item)
        }
        
//        results = results.sorted(by: { $0.score > $1.score })
        
        return results
    }
    
    func slowPathSearch(query: String, fastPath: [SearchResult]) async -> [SearchResult] {
        // filter all fast-path items PLUS slow-path items (all of history store) and google queries, async.
        // 2s timeout
        let q = NormalizedSearchableString(text: query)
        async let historyMatches_ = self.historyMatches(query: q, limit: n)
        async let searchSuggestions_ = googleSuggestions(query: query)
        let historyMatches = await historyMatches_
        let searchSuggestions = (try? await searchSuggestions_) ?? []
        let newResults = (historyMatches + searchSuggestions)
            .sorted(by: { $0.score > $1.score })
            .prefix(n)
        var results = fastPath
        for result in newResults {
            if results.count >= n { break }
            results.append(result)
        }
        return results
    }
    
    private func historyMatches(query: NormalizedSearchableString, limit: Int) async -> [SearchResult] {
        guard let historyStore else { return [] }
        return await historyStore.readAsync { state in
            return state.items.values.compactMap({ $0.searchableItem.match(query: query) })
                .sorted(by: { $0.score > $1.score })
                .prefix(limit)
                .asArray
        }
    }
    
//    private func generatedResults(query: String) -> [SearchableItem] {
//        guard !query.isEmpty else { return [] }
//        
//        var items = [SearchableItem]()
//        
//        // Create a search-what-you-typed result
//        let searchItem = SearchableItem(
//            id: .init(raw: "search:\(query)"),
//            content: .searchWhatYouTyped,
//            titleMatchStr: NormalizedSearchableString(text: "Search for: \(query)")
//        )
//        items.append(searchItem)
//        
//        // Create a URL-you-typed result if the query might be a URL
//        if let url = URL.withNaturalString(query) {
//            let urlItem = SearchableItem(
//                id: .init(raw: "url:\(query)"),
//                content: .urlYouTyped,
//                urlMatchStrings: url.searchStrings
//            )
//            items.append(urlItem)
//        }
//        
//        // Create an I'm Feeling Lucky result
//        let luckyItem = SearchableItem(
//            id: .init(raw: "lucky:\(query)"),
//            content: .imFeelingLucky,
//            titleMatchStr: NormalizedSearchableString(text: "I'm Feeling Lucky: \(query)")
//        )
//        items.append(luckyItem)
//        
//        return items
//    }
}

private extension SearchResult {
    static func urlYouTyped(_ url: URL) -> SearchResult {
        return .init(item: SearchableItem(id: .init(raw: "typed:\(url.historyKey)"), content: .urlYouTyped(url)), matchQuality: .prefixMatchURL)
    }
    
    static func searchYouTyped(_ query: String) -> SearchResult {
        return .init(item: SearchableItem(id: .init(raw: "typed:\(query)"), content: .searchWhatYouTyped(query)), matchQuality: .prefixMatchTitle)
    }
    
    static func chatbot(_ query: String) -> SearchResult {
        return .init(item: SearchableItem(id: .init(raw: "chat:\(query)"), content: .chatbot(query)), matchQuality: .prefixMatchTitle)
    }
    
    static func navItem(_ query: String) -> SearchResult {
        return .init(item: SearchableItem(id: .init(raw: "nav:\(query)"), content: .imFeelingLucky(query)), matchQuality: .prefixMatchTitle)
    }
}

func googleSuggestions(query: String, timeout: TimeInterval = 2) async throws -> [SearchResult] {
    guard !query.isEmpty else { return [] }
    
    // Format for Google's suggestion API: https://suggestqueries.google.com/complete/search?client=firefox&q={QUERY}
    // Returns JSON array where second element is an array of suggestion strings
    var components = URLComponents(string: "https://suggestqueries.google.com/complete/search")!
    components.queryItems = [
        URLQueryItem(name: "client", value: "firefox"),
        URLQueryItem(name: "q", value: query)
    ]
    
    guard let url = components.url else { return [] }
    
    let request = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: timeout)
    
    let (data, _) = try await URLSession.shared.data(for: request)
    
    // Parse the JSON response
    guard let jsonArray = try JSONSerialization.jsonObject(with: data) as? [Any],
          jsonArray.count > 1,
          let suggestions = jsonArray[1] as? [String] else {
        return []
    }
    
    // Convert suggestions to SearchableItem objects
    return suggestions.enumerated().map { tuple in
        let (i, suggestion) = tuple
        let item = SearchableItem(
            id: .init(raw: "suggestion:\(suggestion)"),
            content: .searchSuggestion(suggestion, i),
            titleMatchStr: NormalizedSearchableString(text: suggestion)
        )
        return SearchResult(item: item, matchQuality: .prefixMatchTitle)
    }
}

extension HistoryState {
    var historyTopHitCandidates: [HistoryItem] {
        let topItems = self.items.values
            .filter({ $0.score >= 1.5 })
            .sorted(by: { $0.score > $1.score })
            .prefix(50)
            .asArray
        return topItems
    }
}

extension HistoryItem {
    var searchableItem: SearchableItem {
        return SearchableItem(
            id: .init(raw: key),
            content: .historyItem(self),
            urlMatchStrings: url.searchStrings,
            titleMatchStr: title != nil ? NormalizedSearchableString(text: title!) : nil
        )
    }
}

extension SearchableItem {
    func match(query: NormalizedSearchableString) -> SearchResult? {
        let quality = self.matchQuality(query: query)
        if quality == .none {
            return nil
        }
        return SearchResult(item: self, matchQuality: quality)
    }
    
    func matchQuality(query: NormalizedSearchableString) -> SearchResult.MatchQuality {
        for urlMatchString in self.urlMatchStrings {
            if urlMatchString.prefixMatches(query: query) {
                return .prefixMatchURL
            }
        }
        if titleMatchStr?.prefixMatches(query: query) ?? false {
            return .prefixMatchTitle
        }
        if titleMatchStr?.wordBoundarySubstringMatches(query: query) ?? false {
            return .substringMatchTitle
        }
        return .none
    }
    
    var historyItem: HistoryItem? {
        if case .historyItem(let item) = content {
            return item
        }
        return nil
    }
}

extension URL {
    var searchStrings: [NormalizedSearchableString] {
        var abs = self.absoluteString
        var strings = [abs]
        if abs.hasPrefix("https://") {
            abs = abs.withoutPrefix("https://")
        } else if abs.hasPrefix("http://") {
            abs = abs.withoutPrefix("http://")
        }
        strings.append(abs)
        if abs.hasPrefix("www.") {
            strings.append(abs.withoutPrefix("www."))
        }
        return strings.map { NormalizedSearchableString(text: $0) }
    }
}

enum OmniboxClassifierLabel: String, Equatable {
    case nav
    case chat
    case search
    
    @available(macOS 14.0, *)
    static let sharedModel: OmniboxClassifier? = try? OmniboxClassifier()
    
    static func preheat() {
        if #available(macOS 14.0, *) {
            _ = OmniboxClassifierLabel.sharedModel
        }
    }
}

func classifyQuery(_ query: String) -> OmniboxClassifierLabel? {
    if query.count > 1 && query.hasSuffix("?") {
        return .chat
    }
    if query.count < 3 {
        return nil
    }
    if #available(macOS 14.0, *) {
        guard let model = OmniboxClassifierLabel.sharedModel else { return nil }
        let label = try! model.prediction(input: .init(text: query.lowercased())).label
        return OmniboxClassifierLabel(rawValue: label)
    } else {
        return nil
    }
}
