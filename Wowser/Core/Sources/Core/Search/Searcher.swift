import Combine
import Foundation

struct SearchableItem: Equatable {
    enum Content: Equatable {
        case searchWhatYouTyped(String)
        case urlYouTyped(URL)
        case searchSuggestion(String, Int /* source index */)
        case imFeelingLucky(String) // navigates to the first search result for this
        case historyItem(HistoryItem)
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
        }
    }
}

struct SearchResult: Equatable {
    enum MatchQuality: Int {
        case prefixMatchURL = 3
        case prefixMatchTitle = 2
        case substringMatchTitle = 1
        case none = 0
    }
    var item: SearchableItem
    var matchQuality: MatchQuality
    
    var score: Double {
        var k: Double = 0
        
        switch item.content {
        case .searchWhatYouTyped: k += 5
        case .urlYouTyped: k += 10
        case .searchSuggestion(_, let index): k += 2 - Double(index) * 0.1
        case .imFeelingLucky: k += 10
        case .historyItem(let item):
            if item.score > 10 {
                k += 10
            } else if item.score >= 2 {
                k += 5
            } else if item.score >= 0.5 {
                k += 1
            }
            k += item.score * 0.001 // tiebreaker
        }
        return k
    }
    
    var topHitCandidate: Bool {
        switch item.content {
        case .searchWhatYouTyped, .urlYouTyped, .imFeelingLucky:
            return true
        case .searchSuggestion:
            return false
        case .historyItem(let historyItem):
            switch matchQuality {
            case .prefixMatchURL, .prefixMatchTitle: return historyItem.score >= 1.5
            case .substringMatchTitle: return false // maybe change?
            case .none: return false
            }
        }
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
    let historyStore: HistoryStore
    
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
    
    var subscriptions = Set<AnyCancellable>()
    
    init(historyStore: HistoryStore) {
        self.historyStore = historyStore
        historyStore.publisher.throttle(for: .seconds(2), scheduler: Queue.historyQueue.queue, latest: true)
            .removeDuplicates()
            .map { $0.historyTopHitCandidates }
            .removeDuplicates()
            .map { $0.map(\.searchableItem) }
            .receive(on: DispatchQueue.main)
            .sink { [weak self] cands in
                self?.historyTopHitCandidates = cands
            }
            .store(in: &subscriptions)
    }
    
    // We cache, on the main queue, our top candidates
    private var historyTopHitCandidates = [SearchableItem]()
    
    func fastPathSearch(query: String, prevResults: [SearchResult]) -> [SearchResult] {
        let normQuery = NormalizedSearchableString(text: query)
        var results = [SearchResult]()
        if let url = URL.withNaturalString(query) {
            results.append(.urlYouTyped(url))
        }
        if let hit = historyTopHitCandidates.compactMap({ $0.match(query: normQuery) }).max(by: { $0.score < $1.score }) {
            results.append(hit)
        }
        results.append(.searchYouTyped(query))
        
        let dedupeKeys = Set(results.map({ $0.item.dedupeKey }))
        let matchesFromPrevResults = prevResults
            .filter({ !dedupeKeys.contains($0.item.dedupeKey) })
            .compactMap({ $0.item.match(query: normQuery) })
        for item in matchesFromPrevResults {
            if results.count >= n { break }
            results.append(item)
        }
        
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
