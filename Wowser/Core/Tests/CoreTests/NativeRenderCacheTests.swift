import XCTest
@testable import Core

final class NativeRenderCacheTests: XCTestCase {
    func testEvictsLeastRecentlyUsed() {
        let cache = NativeRenderCache(capacity: 2)
        cache.set("a", id: "1")
        cache.set("b", id: "2")
        _ = cache.get(String.self, id: "1") // 1 is now most recent
        cache.set("c", id: "3")
        XCTAssertEqual(cache.get(String.self, id: "1"), "a")
        XCTAssertNil(cache.get(String.self, id: "2"))
        XCTAssertEqual(cache.get(String.self, id: "3"), "c")
    }

    func testKeyedByTypeAndRemovable() {
        let cache = NativeRenderCache(capacity: 4)
        cache.set("draft", id: "x")
        cache.set(42, id: "x")
        XCTAssertEqual(cache.get(String.self, id: "x"), "draft")
        XCTAssertEqual(cache.get(Int.self, id: "x"), 42)
        cache.removeAll(id: "x")
        XCTAssertNil(cache.get(String.self, id: "x"))
        XCTAssertNil(cache.get(Int.self, id: "x"))
    }
}
