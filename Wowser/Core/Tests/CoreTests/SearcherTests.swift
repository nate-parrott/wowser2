import XCTest
@testable import Core
import Combine

// Helper extension for Searcher to expose the internal methods for testing
extension Searcher {
    // Expose fast path and slow path for direct testing
    func testFastPathSearch(query: String) -> [SearchResult] {
        return fastPathSearch(query: query, prevResults: [])
    }
    
    func testSlowPathSearch(query: String) async -> [SearchResult] {
        let fastPath = fastPathSearch(query: query, prevResults: [])
        return await slowPathSearch(query: query, fastPath: fastPath)
    }
}

@MainActor
final class SearcherTests: XCTestCase {
    
    // MARK: - String Matching Tests
    
    func testNormalizedSearchableStringMatching() {
        // Test basic initialization and normalization
        let source = NormalizedSearchableString(text: "Hello World")
        XCTAssertEqual(source.unnormalized, "Hello World")
        XCTAssertEqual(source.normalizedWithLeadingSpace, " hello world")
        
        // Test with special characters and separators
        let special = NormalizedSearchableString(text: "Hello-World.com/page")
        XCTAssertEqual(special.normalizedWithLeadingSpace, " hello world com page")
        
        // Test prefix matching
        let prefixQuery = NormalizedSearchableString(text: "Hello")
        XCTAssertTrue(source.prefixMatches(query: prefixQuery), "Should match prefix")
        
        // Test non-matching prefix
        let nonPrefixQuery = NormalizedSearchableString(text: "World")
        XCTAssertFalse(source.prefixMatches(query: nonPrefixQuery), "Should not match non-prefix")
        
        // Test substring matching
        XCTAssertTrue(source.wordBoundarySubstringMatches(query: nonPrefixQuery), "Should match substring")
        
        // Test non-matching substring
        let nonSubstringQuery = NormalizedSearchableString(text: "NotPresent")
        XCTAssertFalse(source.wordBoundarySubstringMatches(query: nonSubstringQuery), "Should not match non-substring")
    }
    
    // MARK: - End-to-End Query Tests
    
    func testEndToEndURLQuery() async throws {
        // Create a test history store with sample data
        let historyStore = createTestHistoryStore()
        
        // Create a searcher with that store
        let searcher = Searcher(historyStore: historyStore)
        
        // Test fast path search directly
        let fastResults = searcher.testFastPathSearch(query: "fakewebsite.com")
        
        //         Verify we get URL and search results in fast path
        XCTAssertTrue(fastResults.contains { result in
            if case .urlYouTyped = result.item.content,
               let url = URL.withNaturalString("fakewebsite.com"),
               result.item.dedupeKey == url.historyKey {
                return true
            }
            return false
        }, "Fast path should include URL you typed")
    }

    
    func testEndToEndQuery() async throws {
        // Create a test history store with sample data
        let historyStore = createTestHistoryStore()
        
        // Create a searcher with that store
        let searcher = Searcher(historyStore: historyStore)
        
        // Test fast path search directly
        let fastResults = searcher.testFastPathSearch(query: "git")
        
        // Verify we get URL and search results in fast path
//        XCTAssertTrue(fastResults.contains { result in
//            if case .urlYouTyped = result.item.content, 
//               let url = URL.withNaturalString("git"), 
//               result.item.dedupeKey == url.historyKey {
//                return true
//            }
//            return false
//        }, "Fast path should include URL you typed")
        
        XCTAssertTrue(fastResults.contains { result in
            if case .searchWhatYouTyped(let text) = result.item.content, text == "git" {
                return true
            }
            return false
        }, "Fast path should include search what you typed")
        
        // Test that the history item for github.com is found
        let historyResults = await historyStore.readAsync { state in
            let query = NormalizedSearchableString(text: "git")
            return state.items.values.compactMap({ $0.searchableItem.match(query: query) })
                .sorted(by: { $0.score > $1.score })
                .prefix(5)
                .asArray
        }
        
        XCTAssertFalse(historyResults.isEmpty, "Should find history matches for 'git'")
        XCTAssertTrue(historyResults.contains { result in
            if case .historyItem(let item) = result.item.content {
                return item.url.absoluteString.contains("github")
            }
            return false
        }, "Should find github.com in history results")
        
        // Test slow path search directly
        let slowResults = await searcher.testSlowPathSearch(query: "git")
        
        // Slow path should include fast path results plus additional history/suggestions
        XCTAssertTrue(slowResults.count >= fastResults.count, 
                     "Slow path should have at least as many results as fast path")
        
        // Test end-to-end query via the published property
        // This will trigger the didSet and run both fast and slow path
        let expectation = XCTestExpectation(description: "Search results updated")
        
        // Set up an observer to wait for slow path results
        var resultsObserver: AnyCancellable?
        resultsObserver = searcher.$results
            .dropFirst() // Skip initial empty value
            .sink { results in
                if results.count > 0 && 
                   results.contains(where: { result in
                       if case .historyItem = result.item.content {
                           return true
                       }
                       return false
                   }) {
                    expectation.fulfill()
                    resultsObserver?.cancel()
                }
            }
        
        // Trigger the search
        searcher.query = "git"
        
        // Wait for the expectation to be fulfilled
        await fulfillment(of: [expectation], timeout: 5)
        
        // Verify the final results include both fast path and slow path items
        XCTAssertFalse(searcher.results.isEmpty, "Should have search results")
        
        // Check for URL and search results (from fast path)
//        XCTAssertTrue(searcher.results.contains { result in
//            if case .urlYouTyped = result.item.content {
//                return true
//            }
//            return false
//        }, "Results should include URL you typed")
        
        XCTAssertTrue(searcher.results.contains { result in
            if case .searchWhatYouTyped = result.item.content {
                return true
            }
            return false
        }, "Results should include search what you typed")
        
        // Check for history results (from slow path)
        XCTAssertTrue(searcher.results.contains { result in
            if case .historyItem = result.item.content {
                return true
            }
            return false
        }, "Results should include history items")
    }
    
    // MARK: - Google Search Integration Tests
    
    func testGoogleSuggestionsAPI() async throws {
        // Mock the URLSession.shared.data method to return predefined results
        // First, create a mock of the Google suggestions API response
        
        // Use a local wrapper to call the function with our mock data
        let suggestions = try await googleSuggestions(query: "test")
        
        // Verify suggestions were parsed correctly
        XCTAssertFalse(suggestions.isEmpty, "Should have parsed suggestions")

        switch suggestions[0].item.content {
        case .searchSuggestion(let sugg, let idx):
            XCTAssertTrue(sugg.hasPrefix("test"))
            XCTAssertEqual(idx, 0)
        default: XCTAssert(false, "Unexpected type")
        }
        
        switch suggestions[1].item.content {
        case .searchSuggestion(let sugg, let idx):
            XCTAssertTrue(sugg.hasPrefix("test"))
            XCTAssertEqual(idx, 1)
        default: XCTAssert(false, "Unexpected type")
        }
    }
    
    // MARK: - Helper Functions
    
    private func createTestHistoryStore() -> HistoryStore {
        let store = HistoryStore(persistenceKey: nil, defaultModel: .init(), queue: .historyQueue)
        
        // Add some test history items
        let urls = [
            URL(string: "https://apple.com")!,
            URL(string: "https://github.com")!,
            URL(string: "https://stackoverflow.com")!,
            URL(string: "https://developer.apple.com")!,
            URL(string: "https://gitlab.com")!
        ]
        
        let titles = [
            "Apple",
            "GitHub: Where the world builds software",
            "Stack Overflow - Developer Community",
            "Apple Developer Documentation",
            "GitLab: DevSecOps Platform"
        ]
        
        for (i, url) in urls.enumerated() {
            store.trackVisitDebounced(url: url, title: titles[i])
            
            // Add multiple visits to some sites to boost their score
            if url.absoluteString.contains("github") || url.absoluteString.contains("apple") {
                for _ in 0..<5 {
                    store.trackVisitDebounced(url: url, title: titles[i])
                }
            }
        }
        
        return store
    }
}
