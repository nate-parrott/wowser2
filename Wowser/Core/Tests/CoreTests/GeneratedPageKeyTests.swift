import XCTest
@testable import Core

final class GeneratedPageKeyTests: XCTestCase {
    
    func testHomepageKeyRoundtrip() {
        let key = GeneratedPageKey.homepage
        let url = key.url
        print("HP URL: \(url)")
        
        XCTAssertEqual(url.scheme, "about")
        
        if let decodedKey = GeneratedPageKey(url: url) {
            switch decodedKey {
            case .homepage:
                // Success
                break
            default:
                XCTFail("Expected homepage key, got \(decodedKey)")
            }
        } else {
            XCTFail("Failed to decode URL back to key")
        }
    }
    
    func testAnswerKeyRoundtrip() {
        let testQueries = [
            "How does SwiftUI work?",
            "What's the meaning of life?",
            "Complex query with special characters: !@#$%^&*()",
            "Query with emoji 🚀🔥👾",
            "Multiple words with spaces and punctuation!"
        ]
        
        for query in testQueries {
            let key = GeneratedPageKey.webSearch(q: query)
            let url = key.url
            
            XCTAssertEqual(url.scheme, "about")
            
            if let decodedKey = GeneratedPageKey(url: url) {
                switch decodedKey {
                case .webSearch(let q):
                    XCTAssertEqual(q, query, "Query didn't match after roundtrip")
                default:
                    XCTFail("Expected answer key, got \(decodedKey)")
                }
            } else {
                XCTFail("Failed to decode URL back to key for query: \(query)")
            }
        }
    }
    
    func testInvalidURLs() {
        let invalidURLs = [
            URL(string: "https://example.com")!,
            URL(string: "about:blank")!,
            URL(string: "about:blank#invalidBase64")!,
            URL(string: "about:blank#")!
        ]
        
        for url in invalidURLs {
            XCTAssertNil(GeneratedPageKey(url: url), "URL \(url) should not decode to a valid key")
        }
    }
}
