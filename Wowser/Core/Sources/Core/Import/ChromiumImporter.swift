import Foundation

/// Chromium-family browsers on macOS. All share Chrome's profile layout
/// (`Local State` + one directory per profile) and file formats.
public enum ChromiumBrowser: String, CaseIterable, Codable, Sendable {
    case chrome, chromeBeta, chromeCanary, chromium, brave, edge, arc, dia, vivaldi, opera

    public var displayName: String {
        switch self {
        case .chrome: return "Google Chrome"
        case .chromeBeta: return "Chrome Beta"
        case .chromeCanary: return "Chrome Canary"
        case .chromium: return "Chromium"
        case .brave: return "Brave"
        case .edge: return "Microsoft Edge"
        case .arc: return "Arc"
        case .dia: return "Dia"
        case .vivaldi: return "Vivaldi"
        case .opera: return "Opera"
        }
    }

    /// Under ~/Library/Application Support.
    var supportPath: String {
        switch self {
        case .chrome: return "Google/Chrome"
        case .chromeBeta: return "Google/Chrome Beta"
        case .chromeCanary: return "Google/Chrome Canary"
        case .chromium: return "Chromium"
        case .brave: return "BraveSoftware/Brave-Browser"
        case .edge: return "Microsoft Edge"
        case .arc: return "Arc/User Data"
        case .dia: return "Dia/User Data"
        case .vivaldi: return "Vivaldi"
        case .opera: return "com.operasoftware.Opera"
        }
    }

    /// Where the browser's "Export passwords" button lives, when we know a
    /// URL for it (typed into that browser's address bar).
    public var passwordSettingsURL: String? {
        switch self {
        case .chrome, .chromeBeta, .chromeCanary, .chromium, .arc, .dia: return "chrome://password-manager/settings"
        case .brave: return "brave://password-manager/settings"
        case .edge, .vivaldi, .opera: return nil
        }
    }

    var baseDir: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support")
            .appendingPathComponent(supportPath)
    }
}

enum ChromiumImporter {
    // MARK: - Discovery

    /// Profiles of every installed Chromium browser. A browser whose data is
    /// present but unreadable (macOS privacy protection) is listed once with
    /// its base dir so the sheet can explain Full Disk Access.
    static func detectSources() -> [ImportSource] {
        var sources: [ImportSource] = []
        let fm = FileManager.default
        for browser in ChromiumBrowser.allCases {
            let base = browser.baseDir
            guard fm.fileExists(atPath: base.path) else { continue }
            let profiles = profileDirs(browser: browser, base: base)
            if profiles.isEmpty {
                // Installed but empty, or unreadable. Only list it if unreadable.
                if (try? fm.contentsOfDirectory(atPath: base.path)) == nil {
                    sources.append(ImportSource(kind: .chromium(browser, profileDir: base), title: browser.displayName, subtitle: nil, systemImage: "globe", available: [.autofill, .history, .bookmarks]))
                }
                continue
            }
            for (dir, name) in profiles {
                let title = profiles.count > 1 ? "\(browser.displayName) — \(name)" : browser.displayName
                sources.append(ImportSource(kind: .chromium(browser, profileDir: dir), title: title, subtitle: profiles.count > 1 ? nil : (name == "Default" ? nil : name), systemImage: "globe", available: [.autofill, .history, .bookmarks]))
            }
        }
        return sources
    }

    /// (profile dir, display name), from `Local State` → `profile.info_cache`,
    /// falling back to scanning for `Default` / `Profile N` directories.
    static func profileDirs(browser: ChromiumBrowser, base: URL) -> [(URL, String)] {
        let fm = FileManager.default
        func hasData(_ dir: URL) -> Bool {
            ["History", "Login Data", "Bookmarks", "Web Data"].contains { fm.fileExists(atPath: dir.appendingPathComponent($0).path) }
        }
        var result: [(URL, String)] = []
        if let data = try? Data(contentsOf: base.appendingPathComponent("Local State")),
           let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
           let profile = json["profile"] as? [String: Any],
           let cache = profile["info_cache"] as? [String: Any] {
            let order = (profile["profiles_order"] as? [String]) ?? cache.keys.sorted()
            for key in order {
                guard let info = cache[key] as? [String: Any] else { continue }
                let dir = base.appendingPathComponent(key)
                guard hasData(dir) else { continue }
                let name = (info["name"] as? String)?.nilIfEmpty ?? (info["gaia_name"] as? String)?.nilIfEmpty ?? key
                result.append((dir, name))
            }
        }
        if result.isEmpty {
            // Opera keeps its single profile at the root.
            if hasData(base) { return [(base, "Default")] }
            let names = (try? fm.contentsOfDirectory(atPath: base.path)) ?? []
            for n in names.sorted() where n == "Default" || n.hasPrefix("Profile ") {
                let dir = base.appendingPathComponent(n)
                if hasData(dir) { result.append((dir, n)) }
            }
        }
        return result
    }

    // MARK: - Preview

    static func preview(profileDir dir: URL) -> ImportPreview {
        var p = ImportPreview()
        let fm = FileManager.default
        if (try? fm.contentsOfDirectory(atPath: dir.path)) == nil, fm.fileExists(atPath: dir.path) {
            p.blocker = .needsFullDiskAccess
            return p
        }
        do {
            // Only a count: passwords are imported from the browser's own CSV
            // export, never decrypted from here.
            var logins = 0
            for file in ["Login Data", "Login Data For Account"] {
                let url = dir.appendingPathComponent(file)
                guard fm.fileExists(atPath: url.path) else { continue }
                let db = try ImportSQLite(copying: url)
                logins += try db.scalarInt("SELECT COUNT(*) FROM logins WHERE blacklisted_by_user = 0 AND length(password_value) > 0")
            }
            p.passwords = logins
        } catch ImportError.needsFullDiskAccess {
            p.blocker = .needsFullDiskAccess
            return p
        } catch {
            p.warnings.append("Passwords: \(error.localizedDescription)")
        }
        if let identity = try? readIdentity(dir: dir) { p.autofill = identity.count }
        do {
            let history = try readHistory(dir: dir)
            p.historySites = history.count
            p.historyVisits = history.reduce(0) { $0 + $1.visits.count }
        } catch {
            p.warnings.append("History: \(error.localizedDescription)")
        }
        p.bookmarks = (try? readBookmarks(dir: dir).count) ?? 0
        return p
    }

    // MARK: - Read

    static func read(browser: ChromiumBrowser, profileDir dir: URL, categories: Set<ImportCategory>) -> ImportBundle {
        var bundle = ImportBundle()
        if categories.contains(.autofill) {
            do { bundle.identity = try readIdentity(dir: dir) }
            catch { bundle.warnings.append("Autofill: \(error.localizedDescription)") }
        }
        if categories.contains(.history) {
            do { bundle.history = try readHistory(dir: dir) }
            catch { bundle.warnings.append("History: \(error.localizedDescription)") }
        }
        if categories.contains(.bookmarks) {
            do { bundle.bookmarks = try readBookmarks(dir: dir) }
            catch { bundle.warnings.append("Bookmarks: \(error.localizedDescription)") }
        }
        return bundle
    }

    // MARK: Autofill

    static func readIdentity(dir: URL) throws -> ImportedIdentity {
        let url = dir.appendingPathComponent("Web Data")
        guard FileManager.default.fileExists(atPath: url.path) else { return ImportedIdentity() }
        let db = try ImportSQLite(copying: url)
        var identity = ImportedIdentity()
        // Current Chrome: `addresses` + `address_type_tokens`; some versions
        // split into `local_addresses` / `contact_info` with the same layout.
        for (parent, tokens) in [("addresses", "address_type_tokens"), ("local_addresses", "local_addresses_type_tokens"), ("contact_info", "contact_info_type_tokens")]
        where db.tableExists(parent) && db.tableExists(tokens) {
            var byGUID: [String: [Int: String]] = [:]
            try db.forEachRow("SELECT guid, type, value FROM \(tokens)") { row in
                guard let guid = row.string(0), let value = row.string(2)?.trimmingCharacters(in: .whitespacesAndNewlines), !value.isEmpty else { return }
                byGUID[guid, default: [:]][Int(row.int64(1))] = value
            }
            for fields in byGUID.values {
                ChromiumAddressTokens.apply(fields, to: &identity)
            }
        }
        // Emails typed into free-form fields (`autofill` table), most used first.
        if db.tableExists("autofill") {
            try db.forEachRow("SELECT value FROM autofill WHERE lower(name) LIKE '%mail%' ORDER BY count DESC LIMIT 20") { row in
                guard let v = row.string(0)?.trimmingCharacters(in: .whitespaces), ChromiumAddressTokens.looksLikeEmail(v),
                      !identity.emails.contains(where: { $0.lowercased() == v.lowercased() }) else { return }
                identity.emails.append(v)
            }
        }
        return identity
    }

    // MARK: History

    /// Visits in the import window, skipping subframes and redirect hops,
    /// grouped per URL; the most-visited `ImportLimits.historyURLs` URLs.
    static func readHistory(dir: URL, now: Date = Date()) throws -> [ImportedHistoryEntry] {
        let url = dir.appendingPathComponent("History")
        guard FileManager.default.fileExists(atPath: url.path) else { return [] }
        let db = try ImportSQLite(copying: url)
        let since = Int64((now.timeIntervalSince1970 - ImportLimits.historyWindow + 11_644_473_600) * 1_000_000)
        var byURL: [String: ImportedHistoryEntry] = [:]
        // core type 3/4 = subframes; 0x40000000/0x80000000 = client/server
        // redirect, 0x20000000 = chain end (keep the redirect's destination).
        try db.forEachRow("""
            SELECT u.url, u.title, v.visit_time FROM visits v JOIN urls u ON u.id = v.url
            WHERE v.visit_time > ? AND u.hidden = 0
              AND (v.transition & 255) NOT IN (3, 4)
              AND ((v.transition & 3221225472) = 0 OR (v.transition & 536870912) != 0)
            ORDER BY v.visit_time
            """, [since]) { row in
            guard let s = row.string(0), let date = chromeTime(row.int64(2)) else { return }
            if byURL[s] == nil {
                guard let u = URL(string: s) else { return }
                byURL[s] = ImportedHistoryEntry(url: u, title: row.string(1)?.nilIfEmpty, visits: [])
            }
            byURL[s]?.visits.append(date)
        }
        return ImportHistoryRanking.top(Array(byURL.values), now: now)
    }

    /// Chrome time: microseconds since 1601-01-01 UTC. 0 = unset.
    static func chromeTime(_ v: Int64) -> Date? {
        guard v > 0 else { return nil }
        return Date(timeIntervalSince1970: Double(v) / 1_000_000 - 11_644_473_600)
    }

    // MARK: Bookmarks

    static func readBookmarks(dir: URL) throws -> [ImportedBookmark] {
        let url = dir.appendingPathComponent("Bookmarks")
        guard FileManager.default.fileExists(atPath: url.path) else { return [] }
        let data = try Data(contentsOf: url)
        guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let roots = json["roots"] as? [String: Any] else { return [] }
        var out: [ImportedBookmark] = []
        func walk(_ node: [String: Any]) {
            if node["type"] as? String == "url", let s = node["url"] as? String, let u = URL(string: s) {
                let added = (node["date_added"] as? String).flatMap(Int64.init).flatMap(chromeTime)
                out.append(ImportedBookmark(url: u, title: (node["name"] as? String)?.nilIfEmpty, added: added))
            }
            for child in node["children"] as? [[String: Any]] ?? [] { walk(child) }
        }
        for (_, root) in roots { if let r = root as? [String: Any] { walk(r) } }
        return out
    }
}

/// Chrome's autofill field-type codes (components/autofill/core/browser/field_types.h).
enum ChromiumAddressTokens {
    static let nameFirst = 3, nameMiddle = 4, nameLast = 5, nameFull = 7
    static let email = 9, phoneWhole = 14, phoneCityAndNumber = 13, phoneNumber = 10
    static let line1 = 30, line2 = 31, line3 = 83, city = 33, state = 34, zip = 35, country = 36, streetAddress = 77
    static let company = 60

    static func apply(_ f: [Int: String], to identity: inout ImportedIdentity) {
        let given = f[nameFirst] ?? ""
        let family = f[nameLast] ?? ""
        if !given.isEmpty || !family.isEmpty {
            identity.names.append(.init(given: given, family: family))
        } else if let full = f[nameFull] {
            let p = AutofillName.parse(full: full)
            identity.names.append(.init(given: p.given, family: p.family))
        }
        if let e = f[email], looksLikeEmail(e) { identity.emails.append(e) }
        if let p = f[phoneWhole] ?? f[phoneCityAndNumber] ?? f[phoneNumber] { identity.phones.append(p) }
        if let c = f[company] { identity.organizations.append(c) }

        var line1Value = f[line1] ?? ""
        var line2Value = [f[line2], f[line3]].compactMap { $0 }.joined(separator: ", ")
        if line1Value.isEmpty, let street = f[streetAddress] {
            let lines = street.components(separatedBy: .newlines).map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
            line1Value = lines.first ?? ""
            line2Value = lines.dropFirst().joined(separator: ", ")
        }
        let address = AutofillAddress(line1: line1Value, line2: line2Value, city: f[city] ?? "", state: f[state] ?? "", postalCode: f[zip] ?? "", country: f[country] ?? "")
        if !address.line1.isEmpty || !address.city.isEmpty { identity.addresses.append(address) }
    }

    static func looksLikeEmail(_ s: String) -> Bool {
        let parts = s.split(separator: "@")
        return parts.count == 2 && parts[1].contains(".") && !s.contains(" ")
    }
}

/// Picks which imported URLs are worth replaying.
enum ImportHistoryRanking {
    /// Keeps the `ImportLimits.historyURLs` URLs with the highest
    /// recency-weighted visit counts, each with its most recent visits.
    static func top(_ entries: [ImportedHistoryEntry], now: Date = Date()) -> [ImportedHistoryEntry] {
        let halfLife = TimeInterval.decayedVisitCounterHalfLife
        func score(_ e: ImportedHistoryEntry) -> Double {
            e.visits.reduce(0) { $0 + pow(2, -max(0, now.timeIntervalSince($1)) / halfLife) }
        }
        return entries
            .map { e -> (ImportedHistoryEntry, Double) in
                var e = e
                e.visits = Array(e.visits.sorted().suffix(ImportLimits.visitsPerURL))
                return (e, score(e))
            }
            .sorted { $0.1 > $1.1 }
            .prefix(ImportLimits.historyURLs)
            .map(\.0)
    }
}
