import Foundation

/// Safari, two ways:
///
/// - **Live files** in ~/Library/Safari (`History.db`, `Bookmarks.plist`).
///   Protected by macOS privacy; needs Full Disk Access. No passwords.
/// - **Export** from Safari 18+ (File › Export Browsing Data to File…): a .zip
///   (or its unzipped folder) with `Bookmarks.html`, `Passwords.csv` and
///   per-profile `History*.json`. File names are localized, so JSON files are
///   recognized by `metadata.data_type` and the CSV by its header.
///
/// Safari keeps contact autofill in the Contacts "My Card", not in files.
enum SafariImporter {
    static var safariDir: URL {
        FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Safari")
    }

    /// Opens System Settings › Privacy & Security › Full Disk Access.
    static let fullDiskAccessSettingsURL = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_AllFiles")!

    static var liveSource: ImportSource {
        ImportSource(kind: .safariLive, title: "Safari", subtitle: "History and bookmarks (needs Full Disk Access)", systemImage: "safari", available: [.history, .bookmarks])
    }

    static func exportSource(_ url: URL) -> ImportSource {
        ImportSource(kind: .safariExport(url), title: "Safari export", subtitle: url.lastPathComponent, systemImage: "safari", available: [.passwords, .history, .bookmarks])
    }

    // MARK: - Live

    static func previewLive() -> ImportPreview {
        var p = ImportPreview()
        do {
            let history = try readLiveHistory()
            p.historySites = history.count
            p.historyVisits = history.reduce(0) { $0 + $1.visits.count }
            p.bookmarks = try readLiveBookmarks().count
        } catch ImportError.needsFullDiskAccess {
            p.blocker = .needsFullDiskAccess
        } catch {
            p.blocker = .unreadable(error.localizedDescription)
        }
        return p
    }

    static func readLive(categories: Set<ImportCategory>) -> ImportBundle {
        var b = ImportBundle()
        if categories.contains(.history) {
            do { b.history = try readLiveHistory() } catch { b.warnings.append("History: \(error.localizedDescription)") }
        }
        if categories.contains(.bookmarks) {
            do { b.bookmarks = try readLiveBookmarks() } catch { b.warnings.append("Bookmarks: \(error.localizedDescription)") }
        }
        return b
    }

    /// `history_visits.visit_time` is seconds since 2001-01-01 (CFAbsoluteTime).
    static func readLiveHistory(now: Date = Date()) throws -> [ImportedHistoryEntry] {
        let db = try ImportSQLite(copying: safariDir.appendingPathComponent("History.db"))
        let since = now.addingTimeInterval(-ImportLimits.historyWindow).timeIntervalSinceReferenceDate
        var byURL: [String: ImportedHistoryEntry] = [:]
        let cols = db.columns(of: "history_visits")
        // Skip failed loads and visits that immediately redirected elsewhere.
        var filters = ["v.visit_time > ?"]
        if cols.contains("load_successful") { filters.append("v.load_successful = 1") }
        if cols.contains("redirect_destination") { filters.append("v.redirect_destination IS NULL") }
        try db.forEachRow("""
            SELECT i.url, v.title, v.visit_time FROM history_visits v JOIN history_items i ON i.id = v.history_item
            WHERE \(filters.joined(separator: " AND ")) ORDER BY v.visit_time
            """, [since]) { row in
            guard let s = row.string(0) else { return }
            if byURL[s] == nil {
                guard let u = URL(string: s) else { return }
                byURL[s] = ImportedHistoryEntry(url: u, title: nil, visits: [])
            }
            if let t = row.string(1)?.nilIfEmpty { byURL[s]?.title = t }
            byURL[s]?.visits.append(Date(timeIntervalSinceReferenceDate: row.double(2)))
        }
        return ImportHistoryRanking.top(Array(byURL.values), now: now)
    }

    static func readLiveBookmarks() throws -> [ImportedBookmark] {
        let url = safariDir.appendingPathComponent("Bookmarks.plist")
        let data: Data
        do { data = try Data(contentsOf: url) } catch {
            if ImportSQLite.isPermissionError(error) { throw ImportError.needsFullDiskAccess }
            throw ImportError.unreadable("Couldn't read Safari bookmarks: \(error.localizedDescription)")
        }
        guard let root = try PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any] else { return [] }
        return plistBookmarks(root)
    }

    static func plistBookmarks(_ root: [String: Any]) -> [ImportedBookmark] {
        var out: [ImportedBookmark] = []
        func walk(_ node: [String: Any]) {
            let type = node["WebBookmarkType"] as? String
            if type == "WebBookmarkTypeList", node["Title"] as? String == "com.apple.ReadingList" { return }
            if type == "WebBookmarkTypeLeaf", let s = node["URLString"] as? String, let u = URL(string: s) {
                let title = (node["URIDictionary"] as? [String: Any])?["title"] as? String
                out.append(ImportedBookmark(url: u, title: title?.nilIfEmpty, added: nil))
            }
            for child in node["Children"] as? [[String: Any]] ?? [] { walk(child) }
        }
        walk(root)
        return out
    }

    // MARK: - Export (.zip or folder)

    /// Unzips if needed; returns the folder holding the export's files and a
    /// cleanup closure.
    static func openExport(_ url: URL) throws -> (dir: URL, cleanup: () -> Void) {
        var isDir: ObjCBool = false
        guard FileManager.default.fileExists(atPath: url.path, isDirectory: &isDir) else {
            throw ImportError.unreadable("\(url.lastPathComponent) doesn't exist.")
        }
        if isDir.boolValue { return (url, {}) }
        #if os(macOS)
        let dest = FileManager.default.temporaryDirectory.appendingPathComponent("wowser-safari-export-\(UUID().uuidString)")
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/ditto")
        p.arguments = ["-x", "-k", url.path, dest.path]
        try p.run()
        p.waitUntilExit()
        guard p.terminationStatus == 0 else {
            try? FileManager.default.removeItem(at: dest)
            throw ImportError.unreadable("Couldn't unzip \(url.lastPathComponent).")
        }
        return (dest, { try? FileManager.default.removeItem(at: dest) })
        #else
        throw ImportError.unreadable("Choose the unzipped export folder.")
        #endif
    }

    static func previewExport(_ url: URL) -> ImportPreview {
        var p = ImportPreview()
        do {
            let b = try readExport(url, categories: Set(ImportCategory.allCases))
            p.passwords = b.logins.count
            p.historySites = b.history.count
            p.historyVisits = b.history.reduce(0) { $0 + $1.visits.count }
            p.bookmarks = b.bookmarks.count
            p.warnings = b.warnings
        } catch ImportError.needsFullDiskAccess {
            p.blocker = .needsFullDiskAccess
        } catch {
            p.blocker = .unreadable(error.localizedDescription)
        }
        return p
    }

    static func readExport(_ url: URL, categories: Set<ImportCategory>) throws -> ImportBundle {
        let (dir, cleanup) = try openExport(url)
        defer { cleanup() }
        var bundle = ImportBundle()
        let files = FileManager.default.enumerator(at: dir, includingPropertiesForKeys: nil)?.compactMap { $0 as? URL } ?? []
        for file in files where !file.lastPathComponent.hasPrefix(".") && !file.path.contains("__MACOSX") {
            switch file.pathExtension.lowercased() {
            case "json" where categories.contains(.history):
                guard let data = try? Data(contentsOf: file),
                      let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                      (json["metadata"] as? [String: Any])?["data_type"] as? String == "history" else { continue }
                bundle.history += historyFromExport(json)
            case "csv" where categories.contains(.passwords):
                if let logins = try? PasswordsCSV.read(file) { bundle.logins += logins }
            case "html" where categories.contains(.bookmarks):
                if let html = try? String(contentsOf: file, encoding: .utf8), html.contains("NETSCAPE-Bookmark-file") {
                    bundle.bookmarks += NetscapeBookmarks.parse(html)
                }
            default:
                continue
            }
        }
        bundle.history = ImportHistoryRanking.top(bundle.history)
        return bundle
    }

    /// History.json only has each URL's latest visit (`time_usec`, µs since
    /// 1970) and a `visits_count`. Reconstruct plausible visit times: the
    /// latest one, and the rest spread evenly back through the import window.
    static func historyFromExport(_ json: [String: Any], now: Date = Date()) -> [ImportedHistoryEntry] {
        let earliest = now.addingTimeInterval(-ImportLimits.historyWindow)
        var byURL: [String: ImportedHistoryEntry] = [:]
        for item in json["history"] as? [[String: Any]] ?? [] {
            guard let s = item["url"] as? String, let u = URL(string: s),
                  let usec = (item["time_usec"] as? NSNumber)?.doubleValue else { continue }
            if item["latest_visit_was_load_failure"] as? Bool == true { continue }
            // A redirect source: its destination is the page actually seen.
            if item["destination_url"] != nil { continue }
            let latest = Date(timeIntervalSince1970: usec / 1_000_000)
            guard latest > earliest else { continue }
            let count = max(1, min(ImportLimits.visitsPerURL, (item["visits_count"] as? NSNumber)?.intValue ?? 1))
            let span = latest.timeIntervalSince(earliest)
            let visits = (0..<count).map { i in latest.addingTimeInterval(-span * Double(i) / Double(count)) }
            if var existing = byURL[s] {
                existing.visits = Array((existing.visits + visits).sorted().suffix(ImportLimits.visitsPerURL))
                byURL[s] = existing
            } else {
                byURL[s] = ImportedHistoryEntry(url: u, title: (item["title"] as? String)?.nilIfEmpty, visits: visits.sorted())
            }
        }
        return Array(byURL.values)
    }
}

/// Netscape bookmark HTML (Safari, Firefox, Chrome "Export bookmarks").
enum NetscapeBookmarks {
    static func parse(_ html: String) -> [ImportedBookmark] {
        guard let re = try? NSRegularExpression(pattern: #"<A\s+([^>]*)>(.*?)</A>"#, options: [.caseInsensitive, .dotMatchesLineSeparators]),
              let hrefRe = try? NSRegularExpression(pattern: #"HREF\s*=\s*"([^"]*)""#, options: .caseInsensitive),
              let addRe = try? NSRegularExpression(pattern: #"ADD_DATE\s*=\s*"(\d+)""#, options: .caseInsensitive)
        else { return [] }
        let ns = html as NSString
        var out: [ImportedBookmark] = []
        for m in re.matches(in: html, range: NSRange(location: 0, length: ns.length)) {
            let attrs = ns.substring(with: m.range(at: 1))
            let attrsNS = attrs as NSString
            guard let h = hrefRe.firstMatch(in: attrs, range: NSRange(location: 0, length: attrsNS.length)),
                  let url = URL(string: decodeEntities(attrsNS.substring(with: h.range(at: 1)))), url.scheme != nil else { continue }
            var added: Date?
            if let a = addRe.firstMatch(in: attrs, range: NSRange(location: 0, length: attrsNS.length)),
               let secs = Double(attrsNS.substring(with: a.range(at: 1))), secs > 0 {
                added = Date(timeIntervalSince1970: secs)
            }
            let title = decodeEntities(ns.substring(with: m.range(at: 2))).trimmingCharacters(in: .whitespacesAndNewlines)
            out.append(ImportedBookmark(url: url, title: title.nilIfEmpty, added: added))
        }
        return out
    }

    static func decodeEntities(_ s: String) -> String {
        s.replacingOccurrences(of: "&amp;", with: "&")
            .replacingOccurrences(of: "&lt;", with: "<")
            .replacingOccurrences(of: "&gt;", with: ">")
            .replacingOccurrences(of: "&quot;", with: "\"")
            .replacingOccurrences(of: "&#39;", with: "'")
    }
}
