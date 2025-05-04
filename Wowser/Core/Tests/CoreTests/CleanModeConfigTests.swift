import XCTest
@testable import Core

final class CleanModeConfigTests: XCTestCase {
    func testAddPathToAutoReaderRegexesForRootURL() throws {
        // Create a clean mode config with empty regexes
        var config = CleanModeConfig(autoReaderRegexes: [])
                
        // Test with a root URL
        let rootURL = URL(string: "https://example.com")!
        XCTAssertFalse(config.autoReader(forURL: rootURL))
        config.addPathToAutoReaderRegexes(url: rootURL)
        XCTAssertTrue(config.autoReader(forURL: rootURL))
        
        // Verify that a pattern for any path was added
        XCTAssertEqual(config.autoReaderRegexes.count, 1, "Should add one regex pattern")
        XCTAssertEqual(config.autoReaderRegexes[0], "/.*", "Should add a pattern for any path on the domain")
        
        // Test that adding the same pattern doesn't duplicate
        config.addPathToAutoReaderRegexes(url: rootURL)
        XCTAssertEqual(config.autoReaderRegexes.count, 1, "Should not add duplicate patterns")
    }
    
    func testAddPathToAutoReaderRegexesForNonRootURL() throws {
        // Create a clean mode config with empty regexes
        var config = CleanModeConfig(autoReaderRegexes: [])
        
        // Test with a URL that has a path
        let articleURL = URL(string: "https://example.com/article/123")!
        XCTAssertFalse(config.autoReader(forURL: articleURL))
        config.addPathToAutoReaderRegexes(url: articleURL)
        XCTAssertTrue(config.autoReader(forURL: articleURL))
        
        // Verify that a generic non-root path pattern was added
        XCTAssertEqual(config.autoReaderRegexes.count, 1, "Should add one regex pattern")
        XCTAssertEqual(config.autoReaderRegexes[0], "/.+$", "Should add a pattern for non-root paths")
        
        // Test that the pattern matches the path
        XCTAssertTrue(config.autoReader(forURL: articleURL), "Pattern should match the article URL")
        
        // Test that it also matches other paths
        let otherArticleURL = URL(string: "https://example.com/different/path")!
        XCTAssertTrue(config.autoReader(forURL: otherArticleURL), "Pattern should match other non-root paths")
    }
}
