import XCTest
@testable import Core

final class HistoryStoreTests: XCTestCase {
    
    func testBasicHistoryOperations() {
        // Create a test store
        let store = HistoryStore(persistenceKey: nil, defaultModel: .init(), queue: .historyQueue)
        
        // Test URLs
        let url1 = URL(string: "https://example.com")!
        
        // Track a visit
        store.trackVisitDebounced(url: url1, title: "Example Website")
        
        // Verify the item was added correctly
        let model = store.model
        XCTAssertEqual(model.items.count, 1)
        XCTAssertEqual(model.items[url1.historyKey]?.title, "Example Website")
        XCTAssertEqual(model.items[url1.historyKey]?.url, url1)
        XCTAssertGreaterThan(model.items[url1.historyKey]?.decayedVisitCount.lastCount ?? 0, 0)
    }
    
    func testUpdatePageInfo() {
        // Create a test store
        let store = HistoryStore(persistenceKey: nil, defaultModel: .init(), queue: .historyQueue)
        
        // Test URL
        let url = URL(string: "https://example.com")!
        
        // First add with initial title
        store.trackVisitDebounced(url: url, title: "Initial Title")
        
        // Then update the title
        store.updatePageInfo(url: url, title: "Updated Title")
        
        // Verify the title was updated
        let model = store.model
        XCTAssertEqual(model.items[url.historyKey]?.title, "Updated Title")
    }
    
    func testHistoryTrimming() {
        // Create state with many items
        var state = HistoryState()
        
        // Add more items than the default trim threshold
        for i in 0..<700 {
            let url = URL(string: "https://example\(i).com")!
            var item = HistoryItem(
                key: url.historyKey,
                title: "Example \(i)",
                url: url,
                lastVisit: Date()
            )
            // Add varying scores
            item.decayedVisitCount.add(count: Double(i % 10), interval: .decayedVisitCounterHalfLife)
            state.items[item.id] = item
        }
        
        // Before trimming
        XCTAssertEqual(state.items.count, 700)
        
        // After trimming with default max (400)
        state.trim()
        XCTAssertEqual(state.items.count, 400)
        
        // After trimming with custom max
        state.trim(maxCount: 200)
        XCTAssertEqual(state.items.count, 200)
    }
    
    func testURLNormalization() {
        // Test that different URL formats are normalized to the same history key
        let httpsURL = URL(string: "https://example.com")!
        let httpURL = URL(string: "http://example.com")!
        let wwwURL = URL(string: "https://www.example.com")!
        let trailingSlashURL = URL(string: "https://example.com/")!
        
        // They should all have the same history key
        XCTAssertEqual(httpsURL.historyKey, httpURL.historyKey)
        XCTAssertEqual(httpsURL.historyKey, wwwURL.historyKey)
        XCTAssertEqual(httpsURL.historyKey, trailingSlashURL.historyKey)
        
        // Create a store to test that the URLs are treated as the same
        let store = HistoryStore(persistenceKey: nil, defaultModel: .init(), queue: .historyQueue)
        
        // Add with one URL format
        store.trackVisitDebounced(url: httpsURL, title: "HTTPS Version")
        
        // Update with a different URL format
        store.updatePageInfo(url: wwwURL, title: "WWW Version")
        
        // Check that there's only one entry and it has the updated title
        let model = store.model
        XCTAssertEqual(model.items.count, 1)
        XCTAssertEqual(model.items[httpURL.historyKey]?.title, "WWW Version")
    }
}
