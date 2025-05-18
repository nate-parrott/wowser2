import XCTest
@testable import Core

final class URLHelpersTests: XCTestCase {
    func testIsRootOfDomain() {
        let urlNoSlash = URL(string: "https://example.com")!
        let urlWithSlash = URL(string: "https://example.com/")!
        let urlPath = URL(string: "https://example.com/page")!

        XCTAssertTrue(urlNoSlash.isRootOfDomain)
        XCTAssertTrue(urlWithSlash.isRootOfDomain)
        XCTAssertFalse(urlPath.isRootOfDomain)
    }
}
