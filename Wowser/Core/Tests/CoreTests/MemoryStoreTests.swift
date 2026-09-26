import XCTest
@testable import Core

final class MemoryStoreTests: XCTestCase {

    private func makeDB() throws -> MemoryDB {
        let path = FileManager.default.temporaryDirectory
            .appendingPathComponent("memory-test-\(UUID().uuidString).sqlite").path
        return try MemoryDB(path: path)
    }

    func testInsertAndFullTextSearch() throws {
        let db = try makeDB()
        let store = MemoryStore.shared
        store.insert(MemoryEvent(kind: "visit", pageType: "web", paneID: "p1", tabID: "t1",
                                 url: URL(string: "https://www.example.com/docs")!, title: "Example Docs",
                                 description: "A page about widgets"), into: db)
        store.insert(MemoryEvent(kind: "screen", pageType: "web", paneID: "p1", tabID: "t1",
                                 url: URL(string: "https://www.example.com/docs")!, title: "Example Docs",
                                 text: "Widgets are configured with the sprocket panel"), into: db)

        let count = try db.scalar("SELECT COUNT(*) FROM events") as? Int64
        XCTAssertEqual(count, 2)

        let domain = try db.scalar("SELECT domain FROM events WHERE kind = 'visit'") as? String
        XCTAssertEqual(domain, "example.com")

        let hits = try db.readOnlyQuery("SELECT e.kind FROM events_fts f JOIN events e ON e.id = f.rowid WHERE events_fts MATCH 'sprocket'")
        XCTAssertEqual(hits.count, 1)
        XCTAssertEqual(hits.first?["kind"] as? String, "screen")

        // Bound params work on the read-only connection.
        let byDomain = try db.readOnlyQuery("SELECT title FROM events WHERE domain = ? AND kind = ?", ["example.com", "visit"])
        XCTAssertEqual(byDomain.first?["title"] as? String, "Example Docs")
    }

    func testReadOnlyConnectionRejectsWrites() throws {
        let db = try makeDB()
        XCTAssertThrowsError(try db.readOnlyQuery("DELETE FROM events"))
        XCTAssertThrowsError(try db.readOnlyQuery("INSERT INTO meta (key, value) VALUES ('x', 'y')"))
        // A read wrapped in WITH is fine.
        XCTAssertNoThrow(try db.readOnlyQuery("WITH t AS (SELECT 1 AS n) SELECT n FROM t"))
        // Sneaky: SELECT syntax that would still write is denied by the authorizer.
        XCTAssertThrowsError(try db.readOnlyQuery("SELECT * FROM events; DELETE FROM events"))
    }

    func testVisitMetaBackfill() throws {
        let db = try makeDB()
        let url = URL(string: "https://news.site/story")!
        MemoryStore.shared.insert(MemoryEvent(kind: "visit", pageType: "web", paneID: "p9", url: url), into: db)
        try db.run("""
        UPDATE events SET title = COALESCE(?, title), description = COALESCE(?, description)
        WHERE id = (SELECT id FROM events WHERE kind = 'visit' AND pane_id = ? AND url = ? ORDER BY id DESC LIMIT 1)
        """, ["Story Title", nil, "p9", url.absoluteString])
        let row = try db.query("SELECT title, description FROM events").first
        XCTAssertEqual(row?["title"] as? String, "Story Title")
        XCTAssertTrue(row?["description"] is NSNull)
        // FTS index follows the update.
        let hits = try db.readOnlyQuery("SELECT rowid FROM events_fts WHERE events_fts MATCH 'title:story'")
        XCTAssertEqual(hits.count, 1)
    }

    func testLineDiffReturnsOnlyNewLines() {
        let store = MemoryStore.shared
        let key = "test:\(UUID().uuidString)"
        let exp = expectation(description: "diff")
        store.queue.async {
            let first = store.diffLines(key: key, lines: ["Header", "line one", "line two", " ", "x"])
            XCTAssertEqual(first, ["Header", "line one", "line two"]) // blank + 1-char lines dropped
            let second = store.diffLines(key: key, lines: ["Header", "line two", "line three", "line three"])
            XCTAssertEqual(second, ["line three", "line three"])
            let third = store.diffLines(key: key, lines: ["Header", "line two", "line three", "line three"])
            XCTAssertEqual(third, [])
            exp.fulfill()
        }
        wait(for: [exp], timeout: 5)
    }

    func testStableLineDiffDropsOneTickLines() {
        let store = MemoryStore.shared
        let key = "term:\(UUID().uuidString)"
        let exp = expectation(description: "stable")
        store.queue.async {
            // First capture: nothing is stable yet.
            XCTAssertEqual(store.diffStableLines(key: key, lines: ["$ ls", "✳ Working… (1s)"]), [])
            // Spinner frame changed; "$ ls" survived → recorded once.
            XCTAssertEqual(store.diffStableLines(key: key, lines: ["$ ls", "✳ Working… (2s)", "file.txt"]), ["$ ls"])
            // "file.txt" survived; spinner frames never do.
            XCTAssertEqual(store.diffStableLines(key: key, lines: ["$ ls", "✳ Working… (3s)", "file.txt"]), ["file.txt"])
            // Nothing new.
            XCTAssertEqual(store.diffStableLines(key: key, lines: ["$ ls", "✳ Working… (4s)", "file.txt"]), [])
            exp.fulfill()
        }
        wait(for: [exp], timeout: 5)
    }

    func testTextCapsAndSpaceColumns() throws {
        let db = try makeDB()
        let long = String(repeating: "x", count: MemoryStore.maxTextChars + 100)
        var e = MemoryEvent(kind: "form", pageType: "web", paneID: "p1", url: URL(string: "https://a.b/c")!, title: "T", text: long,
                            extra: ["blob": String(repeating: "y", count: MemoryStore.maxExtraChars + 10)])
        e.spaceID = "space-1"; e.spaceName = "Work"
        MemoryStore.shared.insert(e, into: db)
        let row = try db.query("SELECT LENGTH(text) AS n, extra, space_id, space FROM events").first
        XCTAssertLessThan(row?["n"] as? Int64 ?? 0, Int64(MemoryStore.maxTextChars + 20))
        XCTAssertTrue((row?["extra"] as? String ?? "").contains("truncated"))
        XCTAssertEqual(row?["space_id"] as? String, "space-1")
        XCTAssertEqual(row?["space"] as? String, "Work")
    }

    func testSchemaMigrationAddsSpaceColumns() throws {
        let path = FileManager.default.temporaryDirectory.appendingPathComponent("memory-v1-\(UUID().uuidString).sqlite").path
        // Simulate a v1 database (no space columns).
        do {
            let db = try MemoryDB(path: path)
            try db.exec("DROP TABLE events; CREATE TABLE events (id INTEGER PRIMARY KEY, ts REAL NOT NULL, kind TEXT NOT NULL, page_type TEXT NOT NULL, pane_id TEXT, tab_id TEXT, url TEXT, domain TEXT, title TEXT, description TEXT, text TEXT, parent_pane_id TEXT, parent_url TEXT, parent_title TEXT, extra TEXT);")
        }
        let db = try MemoryDB(path: path)
        let cols = Set(try db.query("PRAGMA table_info(events)").compactMap { $0["name"] as? String })
        XCTAssertTrue(cols.contains("space_id"))
        XCTAssertTrue(cols.contains("space"))
        MemoryStore.shared.insert(MemoryEvent(kind: "visit", pageType: "web", url: URL(string: "https://x.y")!), into: db)
        XCTAssertEqual(try db.scalar("SELECT COUNT(*) FROM events") as? Int64, 1)
    }

    func testFormFieldFiltering() {
        XCTAssertTrue(MemoryStore.isSensitiveField(name: "cc-number", label: "", type: "text"))
        XCTAssertTrue(MemoryStore.isSensitiveField(name: "q", label: "Card number", type: "text"))
        XCTAssertTrue(MemoryStore.isSensitiveField(name: "x", label: "", type: "password"))
        XCTAssertTrue(MemoryStore.isSensitiveField(name: "upload", label: "", type: "file"))
        XCTAssertFalse(MemoryStore.isSensitiveField(name: "email", label: "Email address", type: "email"))
        XCTAssertEqual(MemoryStore.redactCardNumbers("pay with 4111 1111 1111 1111 now"), "pay with [number redacted] now")
        XCTAssertEqual(MemoryStore.redactCardNumbers("call 555-1234"), "call 555-1234")
    }

    func testBriefHelpers() {
        let now = Date()
        XCTAssertEqual(MemoryStore.ago(now.timeIntervalSince1970 - 30, now: now), "just now")
        XCTAssertEqual(MemoryStore.ago(now.timeIntervalSince1970 - 300, now: now), "5m ago")
        XCTAssertEqual(MemoryStore.ago(Int64(now.timeIntervalSince1970 - 7200), now: now), "2h ago")
        XCTAssertEqual(MemoryStore.overviewHead("  # Hi\nthere  ", maxChars: 100), "# Hi there")
        XCTAssertNil(MemoryStore.overviewHead("  ", maxChars: 10))
    }

    func testPageTypeClassification() {
        XCTAssertEqual(MemoryStore.pageType(for: URL(string: "https://a.b/c")!), "web")
        XCTAssertEqual(MemoryStore.pageType(for: NativePageKey.terminal(cwd: nil).url), "terminal")
        XCTAssertEqual(MemoryStore.pageType(for: NativePageKey.agent(key: "k").url), "agent")
        XCTAssertEqual(MemoryStore.pageType(for: nil), "other")
    }
}
