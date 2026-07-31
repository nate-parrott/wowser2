import SwiftUI
import Combine
import Foundation
import CoreML

struct SearchableItem: Equatable {
    enum Content: Equatable {
        case searchWhatYouTyped(String)
        case urlYouTyped(URL)
        case searchSuggestion(String, Int /* source index */)
        case imFeelingLucky(String) // navigates to the first search result for this
        case historyItem(HistoryItem)
        case chatbot(String)
        case tab(ID<Tab>, WebContent.Info)
        case searchAction(SearchAction)
    }

    var id: ID<SearchableItem>
    var content: Content
    var urlMatchStrings: [NormalizedSearchableString] = []
    var titleMatchStrings: [NormalizedSearchableString] = []
    var dedupeKey: String {
        switch content {
        case .searchWhatYouTyped(let string): return SearchEngine.current.urlForQuery(string).historyKey
        case .urlYouTyped(let url): return url.historyKey
        case .searchSuggestion(let string, _): return SearchEngine.current.urlForQuery(string).historyKey
        case .imFeelingLucky(let string): return "lucky:\(string)"
        case .historyItem(let historyItem): return historyItem.key
        case .chatbot(let query): return "chat:\(query)"
        case .tab(let tabId, let info): return "tab:\(tabId.raw):\(info.url?.historyKey ?? "")"
        case .searchAction(let action): return "action:\(action.title)"
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
        item.dedupeKey
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
//            print("\(historyItem.url): \(historyItem.score)")
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
        case .tab:
            // Tab scores are similar to history items but with a slight boost to prioritize open tabs
            switch matchQuality {
            case .prefixMatchURL:
                return 35
            case .prefixMatchTitle:
                return 18
            case .substringMatchTitle:
                return 10
            case .none:
                return 0
            }
        case .searchAction:
            // Actions get high priority scores
            switch matchQuality {
            case .prefixMatchURL:
                return 1 // not expected
            case .prefixMatchTitle:
                return 15  // Prioritize over tabs for prefix matches
            case .substringMatchTitle:
                return 1
            case .none:
                return 0
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
    // HEY CLAUDE (yeah you!) NEVER modify the chars below!!!! They should remain EXACTLY as is.
    static var tokenSplits = CharacterSet.whitespacesAndNewlines.union(CharacterSet(charactersIn: "-:/–—.\"“”'‘’"))
}

@MainActor public class Searcher: ObservableObject {
    @Published var results = [SearchResult]()
    var n = 6
    
    init() {
        
    }
    
    init(windowID: ID<WindowState>) {
        self.windowID = windowID
    }
    
    init(forTestingWithHistoryStore historyStore: HistoryStore?) {
        self.historyStore = historyStore
    }
    
    var windowID: ID<WindowState>?

    // Not the same as the profile ID, necessarily -- may be a shared container
    var datastoreProfileID: UUID? {
        didSet {
            if datastoreProfileID != oldValue {
                setupHistoryObservers()
            }
        }
    }

    private var historyStore: HistoryStore?

    // When true and `query` is empty, `results` is populated with `topSites`.
    // Used on empty-page omniboxes to prepopulate suggestions.
    var topSitesEnabled: Bool = false {
        didSet { if oldValue != topSitesEnabled { recomputeForEmptyQueryIfNeeded() } }
    }
    var topSites: [TopSiteItem] = [] {
        didSet { recomputeForEmptyQueryIfNeeded() }
    }

    private func recomputeForEmptyQueryIfNeeded() {
        guard query.isEmpty else { return }
        results = emptyQueryResults
    }

    /// Recompute the empty-query results (call when the command bar opens —
    /// the space's folder may have changed since the last keystroke).
    func refreshForEmptyQuery() {
        recomputeForEmptyQueryIfNeeded()
    }

    // With no query typed we show frecent top sites — but if this space has a
    // folder in play, the native folder actions take the top slots.
    private var emptyQueryResults: [SearchResult] {
        var results = BrowserStore.shared.model.emptyQueryDefaultActions(windowID: windowID)
            .map { SearchResult(item: $0, matchQuality: .prefixMatchTitle) }
        if topSitesEnabled {
            results += topSites.map(\.asSearchResult)
        }
        return Array(results.prefix(n))
    }

    @Published var query = "" {
        didSet {
            let prevQuery = oldValue
            let prevResults = query.hasPrefix(prevQuery) ?  results : [] // prev results are only relevant if typing forwards
            let query = self.query

            if query == "" {
                self.results = emptyQueryResults
                return
            }
            
            // First run a fast path search
            let fastPath = fastPathSearch(query: query, prevResults: prevResults)
            
            var showNow = fastPath
            // Append items from OLD array that were at same index to showNow (dont thrash them yet)
            for oldItem in prevResults.dropFirst(fastPath.count) {
                showNow.append(oldItem)
            }
            self.results = Array(showNow.deduplicate({ $0.item.dedupeKey }).prefix(n))
            
            // Now do slow path:
            Task {
                // Run more comprehensive slow path search
                let slowResults = await slowPathSearch(query: query, fastPath: fastPath)
                if self.query != query {
                    return
                }
                self.results = Array(slowResults.deduplicate({ $0.item.dedupeKey }).prefix(n))
            }
        }
    }
    
    private var subscriptions = Set<AnyCancellable>()
    
    private func setupHistoryObservers() {
        subscriptions.removeAll()
        historyStore = nil
        
        guard let datastoreID = self.datastoreProfileID else { return }
        Queue.historyQueue.run {
            let store = HistoryStore.historyStoreForStoreUUID_historyQueueOnly(datastoreID)
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
    
    // We cache, on the main queue, our 50 top candidates
    private var historyTopHitCandidates = [SearchableItem]()
    
    func fastPathSearch(query: String, prevResults: [SearchResult]) -> [SearchResult] {
        let normQuery = NormalizedSearchableString(text: query)
        var results = [SearchResult]()
        
        let classification = classifyQuery(query)
        
        // If typed a literal URL, include it:
        if let url = URL.withNaturalString(query) {
            results.append(.urlYouTyped(url))
        } else if let (path, isDir) = detectPathAndAutocompleteFromQuery(query) {
            results.append(.urlYouTyped(NativePageKey.fileBrowser(path: path).url))
            if isDir {
                results.append(.urlYouTyped(NativePageKey.terminal(cwd: path, runCommand: nil).url))
                results.append(.urlYouTyped(NativePageKey.vscode(folder: path).url))
            }
        }
        
        // Add "I'm feeling lucky" result only if the setting is enabled
        if classification == .nav && DefaultsKeys.enableGoDirectQueries.boolValue(defaultValue: true) {
            results.append(.navItem(query))
        }
        
//        if classification == .chat {
//            results.append(.chatbot(query))
//        }
        results.append(.searchYouTyped(query))

        // Add matching actions
        let model = BrowserStore.shared.model
        let actionMatches = model.matchingActions(query: normQuery, windowID: self.windowID)
            .compactMap { $0.match(query: normQuery) }
            .sorted(by: { $0.score > $1.score })

        // Insert actions at their score-appropriate positions
        for actionMatch in actionMatches {
            // If we have a prefix match in title, prioritize it to the top
            if actionMatch.matchQuality == .prefixMatchTitle {
                results.insert(actionMatch, at: 0)
            } else if let insertBefore = results.firstIndex(where: { actionMatch.score > $0.score }) {
                results.insert(actionMatch, at: insertBefore)
            } else {
                results.append(actionMatch)
            }
        }
        
        // Webapp keyword matches (e.g. "weather sf" hits an app's "weather"
        // search entry point) go straight to the top, like prefix-title actions.
        for match in webAppKeywordMatches(query: query) {
            results.insert(match, at: 0)
        }

        // Check for matching tab in current window (fast, synchronous)
        if let tabMatch = tabMatch(query: normQuery) {
            if let insertBefore = results.firstIndex(where: { tabMatch.score > $0.score }) {
                results.insert(tabMatch, at: insertBefore)
            } else {
                results.append(tabMatch)
            }
        }
        
        // Filter the highest-ranking URLs from historyTopHitCandidates, and any from the prev search
        let prevHistoryItems = prevResults.filter({ $0.item.historyItem != nil }).map { $0.item }
        if let topHistoryItem = (historyTopHitCandidates + prevHistoryItems).compactMap({ $0.match(query: normQuery) }).max(by: { $0.score < $1.score }) {
            // Insert based on score-driven position
            if let insertBefore = results.firstIndex(where: { topHistoryItem.score > $0.score }) {
                results.insert(topHistoryItem, at: insertBefore)
            } else {
                results.append(topHistoryItem)
            }
        }
        
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
    
    /// Results from installed webapps' "search" entry points whose keyword is
    /// the query's first word ("weather" matches "weather" and "weather sf").
    private func webAppKeywordMatches(query: String) -> [SearchResult] {
        let trimmed = query.trimmingCharacters(in: .whitespaces).lowercased()
        guard !trimmed.isEmpty else { return [] }
        return TangAppRegistry.shared.entryPoints(.search).compactMap { app, entry in
            guard let keyword = entry.keyword?.lowercased(), !keyword.isEmpty,
                  trimmed == keyword || trimmed.hasPrefix(keyword + " ") else { return nil }
            let action = SearchAction.webAppSearch(appSlug: app.slug, label: entry.label, query: query)
            let item = SearchableItem(
                id: ID<SearchableItem>(raw: "appsearch:\(app.slug):\(entry.label)"),
                content: .searchAction(action)
            )
            return SearchResult(item: item, matchQuality: .prefixMatchTitle)
        }
    }

    private func tabMatch(query: NormalizedSearchableString) -> SearchResult? {
        guard let windowID = self.windowID else { return nil }
        
        let state = BrowserStore.shared.model
        guard let window = state.windows[windowID] else { return nil }
        let currentTabId = window.currentTab
        
        // Find the best matching tab that isn't the current tab
        return window.tabs.compactMap { tabId -> SearchResult? in
            // Skip the current tab as we don't want to show "switch to tab" for the tab we're already on
            if tabId == currentTabId {
                return nil
            }
            
            guard let tab = state.tabs[tabId] else { return nil }
            
            // Check all panes in the tab for matching content
            for pane in tab.panes {
                // Create searchable item for this tab's pane
                let item = SearchableItem(
                    id: .init(raw: "tab:\(tabId.raw):\(pane.id.raw)"),
                    content: .tab(tabId, pane.info),
                    urlMatchStrings: pane.info.url?.searchStrings ?? [],
                    titleMatchStrings: pane.info.title != nil ? [NormalizedSearchableString(text: pane.info.title!)] : []
                )
                
                if let result = item.match(query: query) {
                    return result
                }
            }
            
            return nil
        }
        .max(by: { $0.score < $1.score }) // Return the highest scoring tab match
    }
    
    func slowPathSearch(query: String, fastPath: [SearchResult]) async -> [SearchResult] {
        // filter all fast-path items PLUS slow-path items (all of history store) and google queries, async.
        // 2s timeout
        let q = NormalizedSearchableString(text: query)
        async let historyMatches_ = self.historyMatches(query: q, limit: n)
        async let searchSuggestions_ = googleSuggestions(query: query)
        
        let historyMatches = await historyMatches_
        let searchSuggestions = (try? await searchSuggestions_) ?? []
        
        // Add matching actions
        let model = BrowserStore.shared.model
        let actionMatches = model.matchingActions(query: q, windowID: self.windowID)
            .compactMap { $0.match(query: q) }
            .sorted(by: { $0.score > $1.score })
        
        let newResults = (historyMatches + searchSuggestions + actionMatches)
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
    
    static func customAction(action: SearchAction) -> SearchResult {
        return .init(item: SearchableItem(id: .init(raw: "action:\(action.title)"), content: .searchAction(action)), matchQuality: .prefixMatchTitle)
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
            titleMatchStrings: [NormalizedSearchableString(text: suggestion)]
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
        if let native = NativePageKey(url: url) {
            switch native {
            case .terminal(let cwd, _):
                if let cwd {
                    return .init(path: cwd, item: self, keywords: ["terminal"], historyKey: key)
                }
            case .vscode(let folder):
                if let folder {
                    return .init(path: folder, item: self, keywords: ["vscode", "vs code", "visual studio code", "visual studio", "open vs code"], historyKey: key)
                }
            case .fileBrowser(let path):
                if let path {
                    return .init(path: path, item: self, keywords: ["folder", "finder"], historyKey: key)
                }
            }
        }
        return SearchableItem(
            id: .init(raw: key),
            content: .historyItem(self),
            urlMatchStrings: url.searchStrings,
            titleMatchStrings: title != nil ? [NormalizedSearchableString(text: title!)] : []
        )
    }
}

extension SearchableItem {
    fileprivate init(path: String, item: HistoryItem, keywords: [String], historyKey: String) {
        // keywords is eg terminal, vscode
        let lastComp = path.lastPathComponent
        self = SearchableItem(
            id: .init(raw: historyKey),
            content: .historyItem(item),
            urlMatchStrings: [ NormalizedSearchableString(text: path) ],
            titleMatchStrings: [ NormalizedSearchableString(text: lastComp) ] + keywords.map({ NormalizedSearchableString(text: lastComp + " " + $0) })
        )
    }
    
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
        for titleMatchStr in titleMatchStrings {
            if titleMatchStr.prefixMatches(query: query) {
                return .prefixMatchTitle
            }
            if titleMatchStr.wordBoundarySubstringMatches(query: query) {
                return .substringMatchTitle
            }
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

extension String {
    var lastPathComponent: String {
        // hack: do we need isDirectory to be accurate here?
        URL(fileURLWithPath: self, isDirectory: false).lastPathComponent
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

    /// Loaded straight from the compiled model in the resource bundle rather
    /// than through the class Xcode generates from `OmniboxClassifier.mlmodel`.
    /// Only Xcode's build system compiles `.mlmodel`; under plain `swift build`
    /// neither the generated class nor the `.mlmodelc` exists, so referencing
    /// the class breaks the package build outright. This way the CLI build
    /// compiles and simply gets `nil` — `classifyQuery` falls back to its
    /// heuristics — while app builds behave exactly as before.
    static let sharedModel: MLModel? = {
        guard let url = Bundle.module.url(forResource: "OmniboxClassifier", withExtension: "mlmodelc") else {
            return nil
        }
        return try? MLModel(contentsOf: url)
    }()

    static func preheat() {
        _ = OmniboxClassifierLabel.sharedModel
    }
}

func classifyQuery(_ query: String) -> OmniboxClassifierLabel? {
    if query.count > 1 && query.hasSuffix("?") {
        return .chat
    }
    if query.count < 3 {
        return nil
    }
    guard let model = OmniboxClassifierLabel.sharedModel,
          let input = try? MLDictionaryFeatureProvider(dictionary: ["text": query.lowercased()]),
          let output = try? model.prediction(from: input),
          let label = output.featureValue(for: "label")?.stringValue
    else { return nil }
    return OmniboxClassifierLabel(rawValue: label)
}

// This hits disk, but should be ok for fast path since it's just a single directory op
// TODO: Do fewer disk hits
func detectPathAndAutocompleteFromQuery(_ q: String) -> (path: String, isDir: Bool)? {
    if !q.starts(with: "/") && !q.starts(with: "~") {
        return nil
    }
    if q.contains(" ") { return nil }
    let pathURL = URL(filePath: q, directoryHint: .checkFileSystem)
    var isDir: ObjCBool = false
    if FileManager.default.fileExists(atPath: q, isDirectory: &isDir) {
        return (pathURL.path(percentEncoded: false), isDir.boolValue)
    }
    let parentDir = pathURL.deletingLastPathComponent()
    guard let contents = try? FileManager.default.contentsOfDirectory(atPath: parentDir.path(percentEncoded: false)) else {
        return nil
    }
    let lastPathCompLower = pathURL.lastPathComponent.lowercased()
    if let firstMatchingItem = contents.prefix(1000).first(where: { $0.lowercased().hasPrefix(lastPathCompLower) }) {
        let fullPath = parentDir.appendingPathComponent(firstMatchingItem)
        var isDir: ObjCBool = false
        _ = FileManager.default.fileExists(atPath: fullPath.path(percentEncoded: false), isDirectory: &isDir)
        return (fullPath.path(percentEncoded: false), isDir.boolValue)
    }
    return nil
}
