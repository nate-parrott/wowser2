import Foundation
import SQLite3

/// Read-only access to another app's SQLite database. The file (plus any
/// -wal/-shm sidecars, so recent writes are included) is copied to a temp
/// directory first: Chromium holds its databases locked while running, and we
/// must never touch the originals.
final class ImportSQLite {
    private var db: OpaquePointer?
    private let tempDir: URL

    /// Throws `ImportError.needsFullDiskAccess` when the file exists but the
    /// OS won't let us read it (TCC-protected locations like ~/Library/Safari).
    init(copying url: URL) throws {
        let fm = FileManager.default
        tempDir = fm.temporaryDirectory.appendingPathComponent("wowser-import-\(UUID().uuidString)")
        try fm.createDirectory(at: tempDir, withIntermediateDirectories: true)
        let dest = tempDir.appendingPathComponent(url.lastPathComponent)
        do {
            try fm.copyItem(at: url, to: dest)
        } catch {
            try? fm.removeItem(at: tempDir)
            if Self.isPermissionError(error) { throw ImportError.needsFullDiskAccess }
            throw ImportError.unreadable("Couldn't read \(url.lastPathComponent): \(error.localizedDescription)")
        }
        for suffix in ["-wal", "-shm"] {
            let side = URL(fileURLWithPath: url.path + suffix)
            if fm.fileExists(atPath: side.path) {
                try? fm.copyItem(at: side, to: URL(fileURLWithPath: dest.path + suffix))
            }
        }
        guard sqlite3_open_v2(dest.path, &db, SQLITE_OPEN_READWRITE, nil) == SQLITE_OK else {
            // Read-write on the *copy* so SQLite can replay the WAL.
            let msg = db.map { String(cString: sqlite3_errmsg($0)) } ?? "unknown error"
            sqlite3_close(db)
            db = nil
            try? fm.removeItem(at: tempDir)
            throw ImportError.unreadable("Couldn't open \(url.lastPathComponent): \(msg)")
        }
    }

    deinit {
        sqlite3_close(db)
        try? FileManager.default.removeItem(at: tempDir)
    }

    static func isPermissionError(_ error: Error) -> Bool {
        let ns = error as NSError
        if ns.domain == NSCocoaErrorDomain, ns.code == NSFileReadNoPermissionError { return true }
        if let underlying = ns.userInfo[NSUnderlyingErrorKey] as? NSError, underlying.domain == NSPOSIXErrorDomain,
           underlying.code == Int(EPERM) || underlying.code == Int(EACCES) { return true }
        return false
    }

    func tableExists(_ name: String) -> Bool {
        (try? scalarInt("SELECT COUNT(*) FROM sqlite_master WHERE type='table' AND name=?", [name])) ?? 0 > 0
    }

    func columns(of table: String) -> Set<String> {
        var cols = Set<String>()
        try? forEachRow("PRAGMA table_info(\(table))") { row in
            if let name = row.string(1) { cols.insert(name) }
        }
        return cols
    }

    func scalarInt(_ sql: String, _ params: [Any] = []) throws -> Int {
        var value = 0
        try forEachRow(sql, params) { value = Int($0.int64(0)) }
        return value
    }

    /// Runs `sql`, calling `body` for each row.
    func forEachRow(_ sql: String, _ params: [Any] = [], _ body: (Row) throws -> Void) throws {
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else {
            throw ImportError.unreadable(String(cString: sqlite3_errmsg(db)))
        }
        defer { sqlite3_finalize(stmt) }
        let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)
        for (i, p) in params.enumerated() {
            let idx = Int32(i + 1)
            switch p {
            case let v as Int: sqlite3_bind_int64(stmt, idx, Int64(v))
            case let v as Int64: sqlite3_bind_int64(stmt, idx, v)
            case let v as Double: sqlite3_bind_double(stmt, idx, v)
            case let v as String: sqlite3_bind_text(stmt, idx, v, -1, transient)
            default: sqlite3_bind_null(stmt, idx)
            }
        }
        while true {
            let rc = sqlite3_step(stmt)
            if rc == SQLITE_DONE { break }
            guard rc == SQLITE_ROW else { throw ImportError.unreadable(String(cString: sqlite3_errmsg(db))) }
            try body(Row(stmt: stmt))
        }
    }

    struct Row {
        fileprivate let stmt: OpaquePointer?

        func string(_ i: Int32) -> String? {
            guard let c = sqlite3_column_text(stmt, i) else { return nil }
            return String(cString: c)
        }
        func int64(_ i: Int32) -> Int64 { sqlite3_column_int64(stmt, i) }
        func double(_ i: Int32) -> Double { sqlite3_column_double(stmt, i) }
        func data(_ i: Int32) -> Data? {
            guard let p = sqlite3_column_blob(stmt, i) else { return nil }
            return Data(bytes: p, count: Int(sqlite3_column_bytes(stmt, i)))
        }
    }
}
