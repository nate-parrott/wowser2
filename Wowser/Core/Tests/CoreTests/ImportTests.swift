import XCTest
import SQLite3
@testable import Core

/// Browser import: parsers, readers (against synthetic fixtures built in a
/// temp dir with the real table layouts), and the pure merge/replay logic.
/// Nothing here reads real browser data.
final class ImportTests: XCTestCase {
    private var tempDir: URL!
    private let day: TimeInterval = 86_400

    override func setUpWithError() throws {
        tempDir = FileManager.default.temporaryDirectory.appendingPathComponent("ImportTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: tempDir)
    }

    // MARK: - CSV

    func testCSVParserHandlesQuotesNewlinesCRLFAndBOM() {
        let text = "\u{FEFF}a,b,c\r\n\"x, y\",\"he said \"\"hi\"\"\",\"multi\nline\"\r\n\r\nlast,,\n"
        let rows = CSV.parse(text)
        XCTAssertEqual(rows, [
            ["a", "b", "c"],
            ["x, y", "he said \"hi\"", "multi\nline"],
            ["last", "", ""],
        ])
    }

    func testCSVParserWithoutTrailingNewline() {
        XCTAssertEqual(CSV.parse("a,b\n1,2"), [["a", "b"], ["1", "2"]])
    }

    // MARK: - Passwords CSV

    func testChromePasswordsCSV() throws {
        let csv = """
        name,url,username,password,note
        github.com,https://github.com/login,octocat,"pa,ss""word",
        example.com,https://example.com/,me@example.com,hunter2,"a note
        over two lines"
        """
        let logins = try PasswordsCSV.parse(csv)
        XCTAssertEqual(logins.count, 2)
        XCTAssertEqual(logins[0].url.host, "github.com")
        XCTAssertEqual(logins[0].username, "octocat")
        XCTAssertEqual(logins[0].password, "pa,ss\"word")
        XCTAssertNil(logins[0].lastUsed)
        XCTAssertEqual(logins[1].password, "hunter2")
    }

    func testSafariPasswordsCSV() throws {
        let csv = """
        Title,URL,Username,Password,Notes,OTPAuth
        Example (me),https://www.example.com/,me,s3cret,,otpauth://totp/x
        Bare host,example.org,you,pw2,,
        """
        let logins = try PasswordsCSV.parse(csv)
        XCTAssertEqual(logins.map(\.username), ["me", "you"])
        XCTAssertEqual(logins[1].url.absoluteString, "https://example.org", "bare hosts get https://")
    }

    func testFirefoxPasswordsCSVReadsTimes() throws {
        let csv = """
        "url","username","password","httpRealm","formActionOrigin","guid","timeCreated","timeLastUsed","timePasswordChanged","timesUsed"
        "https://accounts.example.com","fox","pw","","https://accounts.example.com","{g}","1700000000000","1710000000000","1700000000000","7"
        """
        let logins = try PasswordsCSV.parse(csv)
        XCTAssertEqual(logins.count, 1)
        XCTAssertEqual(logins[0].lastUsed, Date(timeIntervalSince1970: 1_710_000_000))
        XCTAssertEqual(logins[0].timesUsed, 7)
    }

    func testNonPasswordCSVThrows() {
        XCTAssertThrowsError(try PasswordsCSV.parse("name,age\nbob,3\n"))
    }

    // MARK: - Bookmarks HTML

    func testNetscapeBookmarks() {
        let html = """
        <!DOCTYPE NETSCAPE-Bookmark-file-1>
        <DL><p>
          <DT><H3>Folder</H3>
          <DL><p>
            <DT><A HREF="https://a.example/?x=1&amp;y=2" ADD_DATE="1700000000">A &amp; B</A>
            <DT><a href="https://b.example/">
              B</a>
          </DL><p>
          <DT><A HREF="not a url">Bad</A>
        </DL>
        """
        let marks = NetscapeBookmarks.parse(html)
        XCTAssertEqual(marks.map(\.url.absoluteString), ["https://a.example/?x=1&y=2", "https://b.example/"])
        XCTAssertEqual(marks[0].title, "A & B")
        XCTAssertEqual(marks[0].added, Date(timeIntervalSince1970: 1_700_000_000))
        XCTAssertEqual(marks[1].title, "B")
        XCTAssertNil(marks[1].added)
    }

    // MARK: - Safari export

    private func safariHistoryJSON(now: Date) -> [String: Any] {
        func usec(_ d: Date) -> NSNumber { NSNumber(value: Int64(d.timeIntervalSince1970 * 1_000_000)) }
        return [
            "metadata": ["browser_name": "Safari", "data_type": "history"],
            "history": [
                ["url": "https://news.example/", "title": "News", "time_usec": usec(now.addingTimeInterval(-day)), "visits_count": 10],
                ["url": "https://redirect.example/", "time_usec": usec(now.addingTimeInterval(-day)), "visits_count": 3, "destination_url": "https://news.example/"],
                ["url": "https://failed.example/", "time_usec": usec(now.addingTimeInterval(-day)), "visits_count": 1, "latest_visit_was_load_failure": true],
                ["url": "https://ancient.example/", "time_usec": usec(now.addingTimeInterval(-400 * day)), "visits_count": 50],
                ["url": "https://many.example/", "time_usec": usec(now.addingTimeInterval(-60)), "visits_count": 100_000],
            ],
        ]
    }

    func testSafariHistoryJSONToEntries() throws {
        let now = Date()
        let entries = SafariImporter.historyFromExport(safariHistoryJSON(now: now), now: now)
        let byHost = Dictionary(uniqueKeysWithValues: entries.map { ($0.url.host!, $0) })
        XCTAssertEqual(Set(byHost.keys), ["news.example", "many.example"], "skips redirects, failures and visits outside the window")
        let news = try XCTUnwrap(byHost["news.example"])
        XCTAssertEqual(news.title, "News")
        XCTAssertEqual(news.visits.count, 10)
        XCTAssertEqual(news.visits.last!.timeIntervalSince1970, now.addingTimeInterval(-day).timeIntervalSince1970, accuracy: 0.001)
        XCTAssertEqual(news.visits, news.visits.sorted())
        XCTAssertGreaterThan(news.visits.first!, now.addingTimeInterval(-ImportLimits.historyWindow - 1))
        XCTAssertEqual(byHost["many.example"]?.visits.count, ImportLimits.visitsPerURL, "visits are capped")
    }

    private func writeSafariExport(to dir: URL, now: Date) throws {
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let json = try JSONSerialization.data(withJSONObject: safariHistoryJSON(now: now))
        try json.write(to: dir.appendingPathComponent("History.json"))
        // Another JSON (e.g. extensions list) must be ignored.
        try JSONSerialization.data(withJSONObject: ["metadata": ["data_type": "extensions"], "extensions": []])
            .write(to: dir.appendingPathComponent("Extensions.json"))
        try "Title,URL,Username,Password,Notes,OTPAuth\nEx,https://example.com/,me,pw,,\n"
            .write(to: dir.appendingPathComponent("Passwords.csv"), atomically: true, encoding: .utf8)
        try "<!DOCTYPE NETSCAPE-Bookmark-file-1>\n<DL><DT><A HREF=\"https://bm.example/\">BM</A></DL>"
            .write(to: dir.appendingPathComponent("Bookmarks.html"), atomically: true, encoding: .utf8)
    }

    func testSafariExportFolder() throws {
        let dir = tempDir.appendingPathComponent("Safari Export")
        try writeSafariExport(to: dir, now: Date())
        let bundle = try SafariImporter.readExport(dir, categories: Set(ImportCategory.allCases))
        XCTAssertEqual(bundle.logins.map(\.username), ["me"])
        XCTAssertEqual(bundle.bookmarks.map(\.url.host), ["bm.example"])
        XCTAssertEqual(Set(bundle.history.map { $0.url.host! }), ["news.example", "many.example"])

        let onlyHistory = try SafariImporter.readExport(dir, categories: [.history])
        XCTAssertTrue(onlyHistory.logins.isEmpty)
        XCTAssertTrue(onlyHistory.bookmarks.isEmpty)

        let preview = SafariImporter.previewExport(dir)
        XCTAssertNil(preview.blocker)
        XCTAssertEqual(preview.passwords, 1)
        XCTAssertEqual(preview.bookmarks, 1)
        XCTAssertEqual(preview.historySites, 2)
    }

    #if os(macOS)
    func testSafariExportZip() throws {
        let dir = tempDir.appendingPathComponent("Safari Export")
        try writeSafariExport(to: dir, now: Date())
        let zip = tempDir.appendingPathComponent("Safari Export.zip")
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/ditto")
        p.arguments = ["-c", "-k", "--keepParent", dir.path, zip.path]
        try p.run()
        p.waitUntilExit()
        XCTAssertEqual(p.terminationStatus, 0)

        let bundle = try SafariImporter.readExport(zip, categories: Set(ImportCategory.allCases))
        XCTAssertEqual(bundle.logins.count, 1)
        XCTAssertEqual(bundle.bookmarks.count, 1)
        XCTAssertEqual(bundle.history.count, 2)
    }
    #endif

    // MARK: - Chromium address tokens

    func testChromiumAddressTokens() {
        typealias T = ChromiumAddressTokens
        var identity = ImportedIdentity()
        T.apply([
            T.nameFirst: "Ada", T.nameLast: "Lovelace", T.email: "ada@example.com", T.phoneWhole: "+1 555 0100",
            T.company: "Analytical Engines", T.line1: "1 Main St", T.line2: "Apt 2", T.city: "Springfield",
            T.state: "IL", T.zip: "62701", T.country: "US",
        ], to: &identity)
        T.apply([T.nameFull: "Grace Brewster Hopper", T.email: "not an email", T.streetAddress: "10 Navy Way\nSuite 5\nFloor 2", T.city: "Arlington"], to: &identity)

        XCTAssertEqual(identity.names.map(\.given), ["Ada", "Grace Brewster"])
        XCTAssertEqual(identity.names.map(\.family), ["Lovelace", "Hopper"])
        XCTAssertEqual(identity.emails, ["ada@example.com"])
        XCTAssertEqual(identity.phones, ["+1 555 0100"])
        XCTAssertEqual(identity.organizations, ["Analytical Engines"])
        XCTAssertEqual(identity.addresses.count, 2)
        XCTAssertEqual(identity.addresses[0].line2, "Apt 2")
        XCTAssertEqual(identity.addresses[0].postalCode, "62701")
        XCTAssertEqual(identity.addresses[1].line1, "10 Navy Way")
        XCTAssertEqual(identity.addresses[1].line2, "Suite 5, Floor 2")
    }

    // MARK: - Chromium readers (synthetic SQLite / JSON fixtures)

    private func makeDB(_ url: URL, _ sql: String) throws {
        var db: OpaquePointer?
        XCTAssertEqual(sqlite3_open(url.path, &db), SQLITE_OK)
        defer { sqlite3_close(db) }
        var err: UnsafeMutablePointer<CChar>?
        let rc = sqlite3_exec(db, sql, nil, nil, &err)
        if rc != SQLITE_OK {
            let msg = err.map { String(cString: $0) } ?? "?"
            sqlite3_free(err)
            XCTFail("SQL failed: \(msg)")
        }
    }

    /// Chrome time: µs since 1601-01-01.
    private func chromeTime(_ d: Date) -> Int64 {
        Int64((d.timeIntervalSince1970 + 11_644_473_600) * 1_000_000)
    }

    private func makeChromiumProfile(_ dir: URL, now: Date) throws {
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let recent = chromeTime(now.addingTimeInterval(-day))
        let recent2 = chromeTime(now.addingTimeInterval(-2 * day))
        let old = chromeTime(now.addingTimeInterval(-400 * day))
        let serverRedirect: Int64 = 0x8000_0000
        let chainEnd: Int64 = 0x2000_0000
        try makeDB(dir.appendingPathComponent("History"), """
            CREATE TABLE urls(id INTEGER PRIMARY KEY AUTOINCREMENT, url LONGVARCHAR, title LONGVARCHAR, visit_count INTEGER DEFAULT 0 NOT NULL, typed_count INTEGER DEFAULT 0 NOT NULL, last_visit_time INTEGER NOT NULL, hidden INTEGER DEFAULT 0 NOT NULL);
            CREATE TABLE visits(id INTEGER PRIMARY KEY, url INTEGER NOT NULL, visit_time INTEGER NOT NULL, from_visit INTEGER, transition INTEGER DEFAULT 0 NOT NULL, segment_id INTEGER, visit_duration INTEGER DEFAULT 0 NOT NULL);
            INSERT INTO urls VALUES (1, 'https://news.example/', 'News', 3, 0, \(recent), 0);
            INSERT INTO urls VALUES (2, 'https://frame.example/', 'Frame', 1, 0, \(recent), 0);
            INSERT INTO urls VALUES (3, 'https://hop.example/', 'Hop', 1, 0, \(recent), 0);
            INSERT INTO urls VALUES (4, 'https://dest.example/', 'Dest', 1, 0, \(recent), 0);
            INSERT INTO urls VALUES (5, 'https://hidden.example/', 'Hidden', 1, 0, \(recent), 1);
            INSERT INTO urls VALUES (6, 'https://old.example/', 'Old', 1, 0, \(old), 0);
            INSERT INTO visits(url, visit_time, transition) VALUES (1, \(recent), 0), (1, \(recent2), 1);
            INSERT INTO visits(url, visit_time, transition) VALUES (2, \(recent), 3);
            INSERT INTO visits(url, visit_time, transition) VALUES (3, \(recent), \(serverRedirect));
            INSERT INTO visits(url, visit_time, transition) VALUES (4, \(recent), \(serverRedirect | chainEnd));
            INSERT INTO visits(url, visit_time, transition) VALUES (5, \(recent), 0);
            INSERT INTO visits(url, visit_time, transition) VALUES (6, \(old), 0);
            """)
        try makeDB(dir.appendingPathComponent("Web Data"), """
            CREATE TABLE addresses (guid VARCHAR PRIMARY KEY, use_count INTEGER NOT NULL DEFAULT 0, use_date INTEGER NOT NULL DEFAULT 0, date_modified INTEGER NOT NULL DEFAULT 0, language_code VARCHAR, label VARCHAR, initial_creator_id INTEGER DEFAULT 0, last_modifier_id INTEGER DEFAULT 0, record_type INTEGER);
            CREATE TABLE address_type_tokens (guid VARCHAR, type INTEGER, value VARCHAR, verification_status INTEGER DEFAULT 0, observations BLOB, PRIMARY KEY (guid, type));
            CREATE TABLE autofill (name VARCHAR, value VARCHAR, value_lower VARCHAR, date_created INTEGER DEFAULT 0, date_last_used INTEGER DEFAULT 0, count INTEGER DEFAULT 1, PRIMARY KEY (name, value));
            INSERT INTO addresses(guid) VALUES ('g1');
            INSERT INTO address_type_tokens(guid, type, value) VALUES ('g1', 3, 'Ada'), ('g1', 5, 'Lovelace'), ('g1', 9, 'ada@example.com'), ('g1', 14, '5550100'), ('g1', 77, '1 Main St'), ('g1', 33, 'Springfield'), ('g1', 35, '62701'), ('g1', 36, 'US'), ('g1', 60, '  ');
            INSERT INTO autofill(name, value, value_lower, count) VALUES ('email', 'ADA@example.com', 'ada@example.com', 9), ('user_email', 'other@example.org', 'other@example.org', 3), ('q', 'search', 'search', 50);
            """)
        // Passwords: only counted in preview, never read. Blobs are opaque.
        try makeDB(dir.appendingPathComponent("Login Data"), """
            CREATE TABLE logins (origin_url VARCHAR NOT NULL, action_url VARCHAR, username_element VARCHAR, username_value VARCHAR, password_element VARCHAR, password_value BLOB, signon_realm VARCHAR NOT NULL, blacklisted_by_user INTEGER NOT NULL);
            INSERT INTO logins VALUES ('https://a.example/', '', '', 'u1', '', x'763130AABB', 'https://a.example/', 0);
            INSERT INTO logins VALUES ('https://b.example/', '', '', 'u2', '', x'763130CCDD', 'https://b.example/', 0);
            INSERT INTO logins VALUES ('https://never.example/', '', '', '', '', x'', 'https://never.example/', 1);
            """)
        let bookmarks: [String: Any] = [
            "version": 1,
            "roots": [
                "bookmark_bar": ["type": "folder", "name": "Bar", "children": [
                    ["type": "url", "name": "A", "url": "https://a.example/", "date_added": String(chromeTime(now.addingTimeInterval(-10 * day)))],
                    ["type": "folder", "name": "Nested", "children": [
                        ["type": "url", "name": "B", "url": "https://b.example/", "date_added": "0"],
                    ]],
                ]],
                "other": ["type": "folder", "name": "Other", "children": []],
            ],
        ]
        try JSONSerialization.data(withJSONObject: bookmarks).write(to: dir.appendingPathComponent("Bookmarks"))
    }

    func testChromiumHistory() throws {
        let now = Date()
        let dir = tempDir.appendingPathComponent("Default")
        try makeChromiumProfile(dir, now: now)
        let history = try ChromiumImporter.readHistory(dir: dir, now: now)
        let byHost = Dictionary(uniqueKeysWithValues: history.map { ($0.url.host!, $0) })
        XCTAssertEqual(Set(byHost.keys), ["news.example", "dest.example"], "drops subframes, redirect hops, hidden and out-of-window URLs")
        XCTAssertEqual(byHost["news.example"]?.visits.count, 2)
        XCTAssertEqual(byHost["news.example"]?.title, "News")
        XCTAssertEqual(byHost["news.example"]!.visits.last!.timeIntervalSince1970, now.addingTimeInterval(-day).timeIntervalSince1970, accuracy: 0.01)
        XCTAssertEqual(history.first?.url.host, "news.example", "ranked by recency-weighted visits")
    }

    func testChromiumIdentity() throws {
        let dir = tempDir.appendingPathComponent("Default")
        try makeChromiumProfile(dir, now: Date())
        let identity = try ChromiumImporter.readIdentity(dir: dir)
        XCTAssertEqual(identity.names.map { "\($0.given) \($0.family)" }, ["Ada Lovelace"])
        XCTAssertEqual(identity.emails, ["ada@example.com", "other@example.org"], "free-form emails dedupe case-insensitively")
        XCTAssertEqual(identity.phones, ["5550100"])
        XCTAssertEqual(identity.organizations, [], "blank values are skipped")
        XCTAssertEqual(identity.addresses.map(\.line1), ["1 Main St"])
        XCTAssertEqual(identity.addresses.first?.postalCode, "62701")
    }

    func testChromiumBookmarks() throws {
        let now = Date()
        let dir = tempDir.appendingPathComponent("Default")
        try makeChromiumProfile(dir, now: now)
        let marks = try ChromiumImporter.readBookmarks(dir: dir)
        XCTAssertEqual(Set(marks.map(\.url.host!)), ["a.example", "b.example"])
        let a = try XCTUnwrap(marks.first { $0.url.host == "a.example" })
        XCTAssertEqual(a.added!.timeIntervalSince1970, now.addingTimeInterval(-10 * day).timeIntervalSince1970, accuracy: 0.01)
        XCTAssertNil(marks.first { $0.url.host == "b.example" }?.added)
    }

    func testChromiumPreviewCountsAndRead() throws {
        let dir = tempDir.appendingPathComponent("Default")
        try makeChromiumProfile(dir, now: Date())
        let preview = ChromiumImporter.preview(profileDir: dir)
        XCTAssertNil(preview.blocker)
        XCTAssertEqual(preview.passwords, 2, "counts saved logins, excluding never-save entries")
        XCTAssertEqual(preview.historySites, 2)
        XCTAssertEqual(preview.historyVisits, 3)
        XCTAssertEqual(preview.bookmarks, 2)
        XCTAssertEqual(preview.autofill, 5) // 1 name, 2 emails, 1 phone, 1 address

        let bundle = ChromiumImporter.read(browser: .chrome, profileDir: dir, categories: [.history, .autofill])
        XCTAssertTrue(bundle.logins.isEmpty, "Chromium passwords only come from the user's CSV export")
        XCTAssertTrue(bundle.bookmarks.isEmpty)
        XCTAssertEqual(bundle.history.count, 2)
        XCTAssertEqual(bundle.identity.count, 5)
    }

    func testChromiumProfileDiscoveryFromLocalState() throws {
        let base = tempDir.appendingPathComponent("Chrome")
        let now = Date()
        try makeChromiumProfile(base.appendingPathComponent("Default"), now: now)
        try makeChromiumProfile(base.appendingPathComponent("Profile 2"), now: now)
        try FileManager.default.createDirectory(at: base.appendingPathComponent("Profile 3"), withIntermediateDirectories: true) // no data
        let localState: [String: Any] = ["profile": [
            "profiles_order": ["Profile 2", "Default", "Profile 3"],
            "info_cache": [
                "Default": ["name": "Personal"],
                "Profile 2": ["name": "", "gaia_name": "Work Person"],
                "Profile 3": ["name": "Empty"],
            ],
        ]]
        try JSONSerialization.data(withJSONObject: localState).write(to: base.appendingPathComponent("Local State"))
        let dirs = ChromiumImporter.profileDirs(browser: .chrome, base: base)
        XCTAssertEqual(dirs.map(\.1), ["Work Person", "Personal"])
        XCTAssertEqual(dirs.map { $0.0.lastPathComponent }, ["Profile 2", "Default"])

        // Without Local State: scan for Default / Profile N.
        try FileManager.default.removeItem(at: base.appendingPathComponent("Local State"))
        XCTAssertEqual(ChromiumImporter.profileDirs(browser: .chrome, base: base).map(\.1), ["Default", "Profile 2"])
    }

    // MARK: - History ranking

    func testHistoryRankingCapsVisitsAndPrefersRecent() {
        let now = Date()
        let recent = ImportedHistoryEntry(url: URL(string: "https://recent.example/")!, title: nil,
                                          visits: (0..<5).map { now.addingTimeInterval(-Double($0) * 3600) })
        let stale = ImportedHistoryEntry(url: URL(string: "https://stale.example/")!, title: nil,
                                         visits: (0..<20).map { now.addingTimeInterval(-100 * day - Double($0) * 3600) })
        let busy = ImportedHistoryEntry(url: URL(string: "https://busy.example/")!, title: nil,
                                        visits: (0..<200).map { now.addingTimeInterval(-Double($0) * 600) })
        let top = ImportHistoryRanking.top([stale, recent, busy], now: now)
        XCTAssertEqual(top.map(\.url.host!), ["busy.example", "recent.example", "stale.example"])
        XCTAssertEqual(top[0].visits.count, ImportLimits.visitsPerURL)
        XCTAssertEqual(top[0].visits.last, busy.visits.max(), "keeps the most recent visits")
        XCTAssertEqual(top[0].visits, top[0].visits.sorted())
    }

    // MARK: - History replay

    func testHistoryReplayDecaysAndDebounces() throws {
        let now = Date()
        let url = URL(string: "https://news.example/a")!
        var state = HistoryState()
        let added = state.mergeImported([
            ImportedHistoryEntry(url: url, title: "A", visits: [
                now.addingTimeInterval(-2 * day),
                now.addingTimeInterval(-day),
                now.addingTimeInterval(-day + 60), // within 5 min: debounced
                now.addingTimeInterval(day), // future: ignored
            ]),
            ImportedHistoryEntry(url: URL(string: "file:///etc/hosts")!, title: nil, visits: [now]),
        ], now: now)
        XCTAssertEqual(added, 1)
        let item = try XCTUnwrap(state.items[url.historyKey])
        XCTAssertEqual(item.title, "A")
        XCTAssertEqual(item.lastVisit, now.addingTimeInterval(-day))
        let halfLife = TimeInterval.decayedVisitCounterHalfLife
        let expected = pow(2, -day / halfLife) + pow(2, -2 * day / halfLife)
        XCTAssertEqual(item.decayedVisitCount.decayedCount(interval: halfLife, at: now), expected, accuracy: 1e-9)
    }

    func testHistoryMergeIntoExistingOnlyCountsNewerVisits() throws {
        let now = Date()
        let url = URL(string: "https://news.example/")!
        let halfLife = TimeInterval.decayedVisitCounterHalfLife
        var state = HistoryState()
        state.modify(url: url) { item in
            item.title = "Mine"
            item.lastVisit = now.addingTimeInterval(-3 * day)
            item.decayedVisitCount = DecayedCounter(lastCount: 1, lastUpdateDate: now.addingTimeInterval(-3 * day))
        }
        let before = state.items[url.historyKey]!.decayedVisitCount.decayedCount(interval: halfLife, at: now)
        let added = state.mergeImported([
            ImportedHistoryEntry(url: url, title: "Theirs", visits: [now.addingTimeInterval(-4 * day), now.addingTimeInterval(-day)]),
        ], now: now)
        XCTAssertEqual(added, 0)
        let item = try XCTUnwrap(state.items[url.historyKey])
        XCTAssertEqual(item.title, "Mine", "keeps our title")
        XCTAssertEqual(item.lastVisit, now.addingTimeInterval(-day))
        XCTAssertEqual(item.decayedVisitCount.decayedCount(interval: halfLife, at: now), before + pow(2, -day / halfLife), accuracy: 1e-9,
                       "the visit before our lastVisit isn't counted")
    }

    func testHistoryReimportIsIdempotent() {
        let now = Date()
        let entries = (0..<10).map { i in
            ImportedHistoryEntry(url: URL(string: "https://site\(i).example/")!, title: "S\(i)",
                                 visits: (0..<5).map { now.addingTimeInterval(-Double($0 + i) * day) })
        }
        var state = HistoryState()
        XCTAssertEqual(state.mergeImported(entries, now: now), 10)
        let once = state
        XCTAssertEqual(state.mergeImported(entries, now: now), 0)
        XCTAssertEqual(state, once)
    }

    func testHistoryTrimAfterLargeImport() {
        let now = Date()
        let entries = (0..<1000).map { i in
            ImportedHistoryEntry(url: URL(string: "https://site\(i).example/")!, title: nil,
                                 visits: [now.addingTimeInterval(-Double(i) * 3600)])
        }
        var state = HistoryState()
        _ = state.mergeImported(entries, now: now)
        state.trim()
        XCTAssertEqual(state.items.count, 400)
        XCTAssertNotNil(state.items[URL(string: "https://site0.example/")!.historyKey], "keeps the highest-scoring")
        XCTAssertNil(state.items[URL(string: "https://site999.example/")!.historyKey])
    }

    // MARK: - Top sites → favorites

    private func historyWith(_ visits: [(String, Int)], now: Date = Date()) -> HistoryState {
        var state = HistoryState()
        _ = state.mergeImported(visits.map { url, count in
            ImportedHistoryEntry(url: URL(string: url)!, title: nil, visits: (0..<count).map { now.addingTimeInterval(-Double($0) * 3600) })
        }, now: now)
        return state
    }

    func testTopSiteRootsGroupsByHost() {
        let history = historyWith([
            ("https://www.a.example/x", 3), ("https://a.example/y", 3),
            ("https://b.example/deep/page?q=1", 4),
            ("https://c.example/", 1),
        ])
        let top = history.topSiteRoots(limit: 2)
        XCTAssertEqual(top.map(\.host), ["a.example", "b.example"])
        XCTAssertEqual(top[1].url.absoluteString, "https://b.example/")
        XCTAssertEqual(top[0].url.path, "/")
    }

    func testFavoritesFromTopSitesOnlyWhenEmpty() {
        var state = BrowserState.defaultState
        let profile = ID<Profile>.defaultProfile
        state.profiles[profile]?.removedFavoriteDomains = ["c.example"]
        let history = historyWith([("https://a.example/", 5), ("https://b.example/", 4), ("https://c.example/", 3), ("https://d.example/", 2)])

        let added = state.addFavoritesFromTopSitesIfEmpty(profile: profile, history: history, limit: 3)
        XCTAssertEqual(added, 2, "removed domains are skipped from the limited list")
        let favs = state.profiles[profile]!.manualFavorites.compactMap { state.tabs[$0]?.panes.first?.info.url?.host }
        XCTAssertEqual(favs, ["a.example", "b.example"])

        XCTAssertEqual(state.addFavoritesFromTopSitesIfEmpty(profile: profile, history: history, limit: 3), 0, "already has favorites")
        XCTAssertEqual(state.addFavoritesFromTopSitesIfEmpty(profile: ID(raw: "missing"), history: history, limit: 3), 0)
    }

    // MARK: - Autofill merges

    func testIdentityMergeDedupes() {
        var data = AutofillProfileData()
        data.emails = [AutofillValue(value: "Ada@Example.com")]
        data.phones = [AutofillValue(value: "(555) 010-0000")]
        var identity = ImportedIdentity()
        identity.names = [.init(given: "Ada", family: "Lovelace"), .init(given: "ada", family: "lovelace"), .init(given: "", family: "")]
        identity.emails = ["ada@example.com", " new@example.com ", ""]
        identity.phones = ["555-010-0000", "555 999 0000"]
        identity.organizations = ["Engines", "engines"]
        identity.addresses = [
            AutofillAddress(line1: "1 Main St", city: "Springfield", postalCode: "62701"),
            AutofillAddress(line1: "1 main st.", city: "Springfield", postalCode: "62701"),
            AutofillAddress(),
        ]
        let added = data.mergeImported(identity)
        XCTAssertEqual(added, 5) // 1 name, 1 email, 1 phone, 1 org, 1 address
        XCTAssertEqual(data.names.count, 1)
        XCTAssertEqual(data.emails.map(\.value), ["Ada@Example.com", "new@example.com"])
        XCTAssertEqual(data.phones.count, 2)
        XCTAssertEqual(data.organizations.map(\.value), ["Engines"])
        XCTAssertEqual(data.addresses.count, 1)
        XCTAssertEqual(data.mergeImported(identity), 0, "re-import adds nothing")
    }

    private func login(_ url: String, _ user: String, _ pw: String, lastUsed: Date? = nil) -> ImportedLogin {
        ImportedLogin(url: URL(string: url)!, username: user, password: pw, lastUsed: lastUsed, timesUsed: 0)
    }

    func testLoginMergeDedupesWithinImportLastWins() {
        var data = AutofillProfileData()
        let writes = data.mergeImported([
            login("http://github.com/", "octocat", "old"),
            login("https://www.github.com/login", "OctoCat", "new"),
            login("https://example.com/", "me", ""), // no password: skipped
            login("chrome://settings", "x", "y"), // not fillable: skipped
            login("https://example.com/", "me", "pw"),
        ])
        XCTAssertEqual(data.credentials.count, 2)
        XCTAssertEqual(writes.count, 2, "one write per credential")
        XCTAssertEqual(Set(writes.map(\.0.id)), Set(data.credentials.map(\.id)))
        XCTAssertEqual(writes.first { $0.0.domain == "github.com" }?.1, "new")
    }

    func testLoginMergeDedupeRespectsLastUsed() {
        let now = Date()
        var data = AutofillProfileData()
        let writes = data.mergeImported([
            login("https://a.example/", "u", "newer", lastUsed: now.addingTimeInterval(-day)),
            login("https://a.example/", "u", "older", lastUsed: now.addingTimeInterval(-5 * day)),
        ])
        XCTAssertEqual(writes.map(\.1), ["newer"])
        XCTAssertEqual(data.credentials.first?.lastUsed, now.addingTimeInterval(-day))
    }

    func testLoginMergeWithExistingCredentials() {
        let now = Date()
        var data = AutofillProfileData()
        let existingOld = AutofillCredential(domain: "a.example", host: "a.example", username: "u", lastUsed: now.addingTimeInterval(-10 * day))
        let existingNew = AutofillCredential(domain: "b.example", host: "b.example", username: "u", lastUsed: now)
        data.credentials = [existingOld, existingNew]
        let writes = data.mergeImported([
            login("https://a.example/", "u", "fresher", lastUsed: now.addingTimeInterval(-day)),
            login("https://b.example/", "u", "stale", lastUsed: now.addingTimeInterval(-day)),
            login("https://c.example/", "u", "undated"), // no lastUsed: can't beat anything, but new
            login("https://b.example/", "U", "undated"), // existing, undated: never clobbers
        ])
        XCTAssertEqual(writes.map(\.1), ["fresher", "undated"])
        XCTAssertEqual(writes[0].0.id, existingOld.id)
        XCTAssertEqual(data.credentials.count, 3)
        XCTAssertEqual(data.credentials[0].lastUsed, now.addingTimeInterval(-day))
        XCTAssertEqual(data.credentials[1], existingNew)
    }

    func testRemoveNewCredentialsRollsBackOnlyNewOnes() {
        var data = AutofillProfileData()
        let existing = AutofillCredential(domain: "a.example", host: "a.example", username: "u", lastUsed: .distantPast)
        data.credentials = [existing]
        let before = Set(data.credentials.map(\.id))
        let writes = data.mergeImported([
            login("https://a.example/", "u", "pw", lastUsed: Date()),
            login("https://b.example/", "u", "pw"),
        ])
        XCTAssertEqual(writes.count, 2)
        // Pretend both keychain writes failed.
        data.removeNewCredentials(Set(writes.map(\.0.id)), existingBeforeImport: before)
        XCTAssertEqual(data.credentials.map(\.id), [existing.id])
    }

    func testAutofillOwnerIsDeterministic() {
        var state = BrowserState.defaultState
        let shared = state.profiles[.defaultProfile]!.dataStoreUUID
        let a = state.createNewProfile(sharingLoginsWith: .defaultProfile)
        let b = state.createNewProfile()
        XCTAssertEqual(state.profiles[a]?.dataStoreUUID, shared)
        XCTAssertEqual(state.autofillOwner(ofDataStore: shared), .defaultProfile)
        XCTAssertEqual(state.autofillOwner(ofDataStore: state.profiles[b]!.dataStoreUUID), b)
        XCTAssertNil(state.autofillOwner(ofDataStore: UUID()))
    }

    // MARK: - Bundle merge

    func testBundleMerge() {
        var a = ImportBundle(logins: [login("https://a.example/", "u", "p")], warnings: ["w1"])
        a.identity.emails = ["a@example.com"]
        var b = ImportBundle(logins: [login("https://b.example/", "u", "p")], warnings: ["w2"])
        b.identity.emails = ["b@example.com"]
        a.merge(b)
        XCTAssertEqual(a.logins.count, 2)
        XCTAssertEqual(a.identity.emails, ["a@example.com", "b@example.com"])
        XCTAssertEqual(a.warnings, ["w1", "w2"])
    }
}
