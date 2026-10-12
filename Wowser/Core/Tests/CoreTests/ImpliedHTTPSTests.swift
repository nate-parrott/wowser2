import XCTest
@testable import Core

final class ImpliedHTTPSTests: XCTestCase {
    func testTypedBareDomainFallsBackOnce() {
        let url = URL.withNaturalString("delta.com")!
        XCTAssertEqual(url.absoluteString, "https://delta.com")
        // WebKit reports the failing URL with a trailing slash.
        let failing = URL(string: "https://delta.com/")!
        XCTAssertEqual(failing.consumeImpliedHTTPSFallback()?.absoluteString, "http://delta.com/")
        XCTAssertNil(failing.consumeImpliedHTTPSFallback())
    }

    func testExplicitHTTPSDoesNotFallBack() {
        let url = URL.withNaturalString("https://explicit-https-only.example")!
        XCTAssertNil(url.consumeImpliedHTTPSFallback())
    }
}
