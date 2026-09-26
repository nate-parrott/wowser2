import Foundation
import SQLite3

/// Minimal SQLite wrapper for one memory scope (one `dataStoreUUID`). Not
/// thread-safe by itself: `MemoryStore` only touches an instance from its own
/// serial queue. Read-only queries from BrowserJS go through `readOnly`, a
/// second connection opened with `SQLITE_OPEN_READONLY` plus an authorizer
/// that rejects anything but reads, so agent SQL can't mutate the log.
final class MemoryDB {
    enum DBError: Error, LocalizedError {
        case open(String)
        case prepare(String, String)
        case step(String)
        case readOnlyViolation
        var errorDescription: String? {
            switch self {
            case .open(let m): return "sqlite open: \(m)"
            case .prepare(let m, let sql): return "sqlite prepare: \(m) — \(sql.prefix(200))"
            case .step(let m): return "sqlite: \(m)"
            case .readOnlyViolation: return "Only read-only SELECT queries are allowed."
            }
        }
    }

    let path: String
    private var db: OpaquePointer?
    private var readOnlyDB: OpaquePointer?

    static let schemaVersion = 2

    static let schemaSQL = """
    CREATE TABLE IF NOT EXISTS events (
        id INTEGER PRIMARY KEY,
        ts REAL NOT NULL,
        kind TEXT NOT NULL,
        page_type TEXT NOT NULL,
        pane_id TEXT,
        tab_id TEXT,
        url TEXT,
        domain TEXT,
        title TEXT,
        description TEXT,
        text TEXT,
        parent_pane_id TEXT,
        parent_url TEXT,
        parent_title TEXT,
        extra TEXT,
        space_id TEXT,
        space TEXT
    );
    CREATE INDEX IF NOT EXISTS idx_events_ts ON events(ts);
    CREATE INDEX IF NOT EXISTS idx_events_kind_ts ON events(kind, ts);
    CREATE INDEX IF NOT EXISTS idx_events_page_type_ts ON events(page_type, ts);
    CREATE INDEX IF NOT EXISTS idx_events_domain_ts ON events(domain, ts);
    CREATE INDEX IF NOT EXISTS idx_events_pane_ts ON events(pane_id, ts);
    CREATE INDEX IF NOT EXISTS idx_events_space_ts ON events(space_id, ts);
    CREATE VIRTUAL TABLE IF NOT EXISTS events_fts USING fts5(
        title, description, text, url,
        content='events', content_rowid='id', tokenize='unicode61'
    );
    CREATE TRIGGER IF NOT EXISTS events_ai AFTER INSERT ON events BEGIN
        INSERT INTO events_fts(rowid, title, description, text, url)
        VALUES (new.id, new.title, new.description, new.text, new.url);
    END;
    CREATE TRIGGER IF NOT EXISTS events_ad AFTER DELETE ON events BEGIN
        INSERT INTO events_fts(events_fts, rowid, title, description, text, url)
        VALUES ('delete', old.id, old.title, old.description, old.text, old.url);
    END;
    CREATE TRIGGER IF NOT EXISTS events_au AFTER UPDATE ON events BEGIN
        INSERT INTO events_fts(events_fts, rowid, title, description, text, url)
        VALUES ('delete', old.id, old.title, old.description, old.text, old.url);
        INSERT INTO events_fts(rowid, title, description, text, url)
        VALUES (new.id, new.title, new.description, new.text, new.url);
    END;
    CREATE TABLE IF NOT EXISTS meta (
        key TEXT PRIMARY KEY,
        value TEXT
    );
    """

    /// Human-readable schema handed to agents via `browser.memory.schema()`.
    static let schemaDescription = """
    Memory store: one SQLite database per browser data store (a "scope"; several spaces/profiles may share one). Every significant thing that happened in the browser is a row in `events`.

    TABLE events
      id            INTEGER PRIMARY KEY (monotonic; higher = later)
      ts            REAL — unix time in seconds (use datetime(ts,'unixepoch','localtime') to format)
      kind          TEXT — what happened:
                      'visit'    a page was navigated to (incl. in-page URL changes). title/description filled in as the page loads.
                      'screen'   text visible on screen in a web tab (OCR of the rendered page, ~every 5s). `text` holds only lines that were NOT on screen at the previous capture, so reading a pane's screen rows in order reconstructs what the user saw.
                      'terminal' new lines that appeared in a terminal tab (line diff of the scrollback).
                      'agent'    new messages in an AI chat (agent tab or chat-mode space thread). `text` is "role: message" lines.
                      'download' a file finished downloading. url = file source, text = destination path; extra has size/filename/sourceUrl.
                      'typed'    text the user typed into a web page field (never password/credit-card/OTP fields). `text` is the reconstructed field contents.
                      'click'    the user clicked something on a web page. `text` is a one-line description ("link \"Sign in\" → https://…", "button \"Add to cart\""); extra has tag, role, ariaLabel, text, href, name, id, inputType, x/y.
                      'form'     the user submitted an HTML form. `text` is "label: value" lines (password, card, CVV, SSN, OTP and file fields are omitted; values that look like card numbers are redacted); extra has action, method, fields[].
      page_type     TEXT — kind of tab: 'web' | 'terminal' | 'agent' | 'files' | 'vscode' | 'chat' | 'other'
      space_id      TEXT — id of the space (profile) the tab lived in when this was recorded; `space` is its display name at the time. Several spaces can share one memory database, so filter on space_id = ? for "this space".
      pane_id       TEXT — id of the pane (tab content) this came from; groups rows from the same tab over time.
      tab_id        TEXT — id of the tab holding that pane.
      url           TEXT — page URL (or download source URL)
      domain        TEXT — host of url without "www." (indexed; e.g. domain = 'github.com')
      title         TEXT — page title at the time (for 'visit' rows it's updated as the page loads)
      description   TEXT — page <meta name=description>/og:description (visit rows)
      text          TEXT — the content (see kind)
      parent_pane_id, parent_url, parent_title — for 'visit' rows in a tab that was opened FROM another tab: where it came from.
      extra         TEXT — JSON with kind-specific details.
    Indexes: ts, (kind,ts), (page_type,ts), (domain,ts), (pane_id,ts), (space_id,ts).

    VIRTUAL TABLE events_fts (FTS5 over events: title, description, text, url; rowid = events.id)
      Full-text search:  SELECT e.* FROM events_fts f JOIN events e ON e.id = f.rowid WHERE events_fts MATCH 'search terms' ORDER BY rank LIMIT 50;
      Use FTS5 syntax: "exact phrase", term1 AND term2, prefix*, column filters like title:foo.

    TABLE meta (key TEXT PRIMARY KEY, value TEXT)
      'overview' — the human/agent-maintained memory overview (markdown). Also 'overview_updated_at' (ISO-8601), 'overview_status'.

    Text columns are capped (title 500, description 2k, text 30k chars); rows older than 180 days or beyond the newest 300k are pruned.
    Tips: rows are large — always LIMIT and prefer substr(text,1,400). Group by domain or date(ts,'unixepoch','localtime') for summaries. Recent-first: ORDER BY ts DESC.
    """

    init(path: String) throws {
        self.path = path
        var handle: OpaquePointer?
        let flags = SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE | SQLITE_OPEN_FULLMUTEX
        guard sqlite3_open_v2(path, &handle, flags, nil) == SQLITE_OK else {
            let msg = handle.map { String(cString: sqlite3_errmsg($0)) } ?? "unknown"
            if let handle { sqlite3_close(handle) }
            throw DBError.open(msg)
        }
        db = handle
        try exec("PRAGMA journal_mode=WAL;")
        try exec("PRAGMA synchronous=NORMAL;")
        try exec("PRAGMA busy_timeout=2000;")
        try migrateIfNeeded()
        try exec(Self.schemaSQL)
    }

    /// Additive migrations for databases created by older schema versions.
    /// `schemaSQL` is all IF NOT EXISTS, so it's safe to run after this.
    private func migrateIfNeeded() throws {
        let hasEvents = (try? scalar("SELECT name FROM sqlite_master WHERE type='table' AND name='events'")) != nil
        guard hasEvents else { return }
        let cols = Set(try query("PRAGMA table_info(events)").compactMap { $0["name"] as? String })
        if !cols.contains("space_id") { try exec("ALTER TABLE events ADD COLUMN space_id TEXT;") }
        if !cols.contains("space") { try exec("ALTER TABLE events ADD COLUMN space TEXT;") }
    }

    deinit {
        if let db { sqlite3_close(db) }
        if let readOnlyDB { sqlite3_close(readOnlyDB) }
    }

    // MARK: - Writes

    func exec(_ sql: String) throws {
        var err: UnsafeMutablePointer<CChar>?
        if sqlite3_exec(db, sql, nil, nil, &err) != SQLITE_OK {
            let msg = err.map { String(cString: $0) } ?? "unknown"
            sqlite3_free(err)
            throw DBError.step(msg)
        }
    }

    @discardableResult
    func run(_ sql: String, _ params: [Any?] = []) throws -> Int64 {
        let stmt = try Self.prepare(db, sql)
        defer { sqlite3_finalize(stmt) }
        try Self.bind(stmt, params)
        let rc = sqlite3_step(stmt)
        guard rc == SQLITE_DONE || rc == SQLITE_ROW else {
            throw DBError.step(String(cString: sqlite3_errmsg(db)))
        }
        return sqlite3_last_insert_rowid(db)
    }

    func scalar(_ sql: String, _ params: [Any?] = []) throws -> Any? {
        try query(sql, params, maxRows: 1).first?.values.first ?? nil
    }

    func query(_ sql: String, _ params: [Any?] = [], maxRows: Int = 1000) throws -> [[String: Any]] {
        try Self.query(on: db, sql, params, maxRows: maxRows)
    }

    // MARK: - Read-only access (agent SQL)

    /// Runs `sql` on a read-only connection. Any statement that isn't a pure
    /// read is rejected by the authorizer. Returns rows as dictionaries.
    func readOnlyQuery(_ sql: String, _ params: [Any?] = [], maxRows: Int = 500, timeoutMs: Int = 5000) throws -> [[String: Any]] {
        let trimmed = sql.trimmingCharacters(in: .whitespacesAndNewlines)
        let head = trimmed.prefix(8).uppercased()
        guard head.hasPrefix("SELECT") || head.hasPrefix("WITH") || head.hasPrefix("EXPLAIN") else {
            throw DBError.readOnlyViolation
        }
        let conn = try readOnlyConnection()
        // Cheap runaway-query guard: abort after ~timeoutMs. The progress
        // handler is invoked every N VM ops; we check the clock there.
        let deadline = Date().addingTimeInterval(Double(timeoutMs) / 1000)
        let box = Unmanaged.passRetained(DeadlineBox(deadline: deadline))
        sqlite3_progress_handler(conn, 2000, { ctx in
            guard let ctx else { return 0 }
            let box = Unmanaged<DeadlineBox>.fromOpaque(ctx).takeUnretainedValue()
            return Date() > box.deadline ? 1 : 0
        }, box.toOpaque())
        defer {
            sqlite3_progress_handler(conn, 0, nil, nil)
            box.release()
        }
        return try Self.query(on: conn, trimmed, params, maxRows: maxRows, singleStatement: true)
    }

    private final class DeadlineBox {
        let deadline: Date
        init(deadline: Date) { self.deadline = deadline }
    }

    private func readOnlyConnection() throws -> OpaquePointer {
        if let readOnlyDB { return readOnlyDB }
        var handle: OpaquePointer?
        guard sqlite3_open_v2(path, &handle, SQLITE_OPEN_READONLY | SQLITE_OPEN_FULLMUTEX, nil) == SQLITE_OK, let handle else {
            let msg = handle.map { String(cString: sqlite3_errmsg($0)) } ?? "unknown"
            if let handle { sqlite3_close(handle) }
            throw DBError.open(msg)
        }
        sqlite3_busy_timeout(handle, 2000)
        // Belt and braces: even on a READONLY connection, refuse every write
        // or schema action. (PRAGMA stays allowed: FTS5 reads data_version.)
        sqlite3_set_authorizer(handle, { _, action, _, _, _, _ in
            switch action {
            case SQLITE_INSERT, SQLITE_UPDATE, SQLITE_DELETE, SQLITE_DROP_TABLE, SQLITE_DROP_INDEX, SQLITE_DROP_TRIGGER,
                 SQLITE_DROP_VIEW, SQLITE_DROP_VTABLE, SQLITE_DROP_TEMP_TABLE, SQLITE_DROP_TEMP_INDEX, SQLITE_DROP_TEMP_TRIGGER,
                 SQLITE_DROP_TEMP_VIEW, SQLITE_CREATE_TABLE, SQLITE_CREATE_INDEX, SQLITE_CREATE_TRIGGER, SQLITE_CREATE_VIEW,
                 SQLITE_CREATE_VTABLE, SQLITE_CREATE_TEMP_TABLE, SQLITE_CREATE_TEMP_INDEX, SQLITE_CREATE_TEMP_TRIGGER,
                 SQLITE_CREATE_TEMP_VIEW, SQLITE_ALTER_TABLE, SQLITE_ATTACH, SQLITE_DETACH, SQLITE_TRANSACTION,
                 SQLITE_SAVEPOINT, SQLITE_REINDEX, SQLITE_ANALYZE:
                return SQLITE_DENY
            default:
                return SQLITE_OK
            }
        }, nil)
        readOnlyDB = handle
        return handle
    }

    // MARK: - Statement helpers

    private static func query(on conn: OpaquePointer?, _ sql: String, _ params: [Any?], maxRows: Int, singleStatement: Bool = false) throws -> [[String: Any]] {
        let stmt = try prepare(conn, sql, singleStatement: singleStatement)
        defer { sqlite3_finalize(stmt) }
        try bind(stmt, params)
        let colCount = Int(sqlite3_column_count(stmt))
        let names: [String] = (0..<colCount).map { String(cString: sqlite3_column_name(stmt, Int32($0))) }
        var rows: [[String: Any]] = []
        while rows.count < maxRows {
            let rc = sqlite3_step(stmt)
            if rc == SQLITE_ROW {
                var row: [String: Any] = [:]
                for i in 0..<colCount {
                    let c = Int32(i)
                    switch sqlite3_column_type(stmt, c) {
                    case SQLITE_INTEGER: row[names[i]] = sqlite3_column_int64(stmt, c)
                    case SQLITE_FLOAT: row[names[i]] = sqlite3_column_double(stmt, c)
                    case SQLITE_TEXT: row[names[i]] = String(cString: sqlite3_column_text(stmt, c))
                    case SQLITE_BLOB:
                        if let bytes = sqlite3_column_blob(stmt, c) {
                            row[names[i]] = Data(bytes: bytes, count: Int(sqlite3_column_bytes(stmt, c))).base64EncodedString()
                        } else { row[names[i]] = NSNull() }
                    default: row[names[i]] = NSNull()
                    }
                }
                rows.append(row)
            } else if rc == SQLITE_DONE {
                break
            } else {
                throw DBError.step(String(cString: sqlite3_errmsg(conn)))
            }
        }
        return rows
    }

    /// With `singleStatement`, anything after the first statement (e.g.
    /// "SELECT 1; DELETE …") is rejected instead of silently ignored.
    private static func prepare(_ conn: OpaquePointer?, _ sql: String, singleStatement: Bool = false) throws -> OpaquePointer {
        var stmt: OpaquePointer?
        var remainder = ""
        // The tail pointer points into the C string we pass, so read it
        // before that buffer goes away.
        let rc: Int32 = sql.withCString { cstr in
            var tail: UnsafePointer<CChar>?
            let rc = sqlite3_prepare_v2(conn, cstr, -1, &stmt, &tail)
            if let tail { remainder = String(cString: tail) }
            return rc
        }
        guard rc == SQLITE_OK, let stmt else {
            throw DBError.prepare(String(cString: sqlite3_errmsg(conn)), sql)
        }
        if singleStatement, !remainder.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            sqlite3_finalize(stmt)
            throw DBError.readOnlyViolation
        }
        return stmt
    }

    private static let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)

    private static func bind(_ stmt: OpaquePointer, _ params: [Any?]) throws {
        for (i, p) in params.enumerated() {
            let idx = Int32(i + 1)
            switch p {
            case nil: sqlite3_bind_null(stmt, idx)
            case let v as String: sqlite3_bind_text(stmt, idx, v, -1, transient)
            case let v as Int: sqlite3_bind_int64(stmt, idx, Int64(v))
            case let v as Int64: sqlite3_bind_int64(stmt, idx, v)
            case let v as Int32: sqlite3_bind_int64(stmt, idx, Int64(v))
            case let v as Double: sqlite3_bind_double(stmt, idx, v)
            case let v as Float: sqlite3_bind_double(stmt, idx, Double(v))
            case let v as Bool: sqlite3_bind_int64(stmt, idx, v ? 1 : 0)
            case let v as Date: sqlite3_bind_double(stmt, idx, v.timeIntervalSince1970)
            case let v as URL: sqlite3_bind_text(stmt, idx, v.absoluteString, -1, transient)
            case let v as NSNumber: sqlite3_bind_double(stmt, idx, v.doubleValue)
            case is NSNull: sqlite3_bind_null(stmt, idx)
            default: sqlite3_bind_text(stmt, idx, String(describing: p!), -1, transient)
            }
        }
    }
}
