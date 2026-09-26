import Foundation

// MARK: - Browser import
//
// Pulls passwords, autofill identity, history and bookmarks out of another
// browser and folds them into one of our profiles:
//
//   ImportSourceDetector  → which browsers/profiles exist on this Mac
//   Chromium/Safari readers → `ImportBundle` (plain values, nothing applied)
//   ImportApplier          → writes the chosen categories into a profile
//
// Readers never modify the other browser's files: SQLite databases are copied
// to a temp dir first (Chromium keeps them locked while running).

/// Where to import from.
public enum ImportSourceKind: Hashable, Sendable {
    /// A Chromium-family browser profile directory (Chrome, Brave, Edge, Arc…).
    case chromium(ChromiumBrowser, profileDir: URL)
    /// Safari's own files in ~/Library/Safari (needs Full Disk Access).
    case safariLive
    /// The folder or .zip from Safari's File › Export Browsing Data to File….
    case safariExport(URL)
    /// A passwords CSV (Chrome, Safari, the Passwords app, 1Password, Firefox…).
    case passwordsCSV(URL)
}

public struct ImportSource: Identifiable, Hashable, Sendable {
    public var kind: ImportSourceKind
    /// "Google Chrome — Work", "Safari", "Passwords.csv"…
    public var title: String
    public var subtitle: String?
    /// SF Symbol.
    public var systemImage: String
    /// Categories this source can provide at all.
    public var available: Set<ImportCategory>

    public var id: String {
        switch kind {
        case .chromium(let b, let dir): return "chromium:\(b.rawValue):\(dir.path)"
        case .safariLive: return "safari"
        case .safariExport(let url): return "safari-export:\(url.path)"
        case .passwordsCSV(let url): return "csv:\(url.path)"
        }
    }
}

public enum ImportCategory: String, CaseIterable, Hashable, Codable, Sendable {
    case passwords
    case autofill
    case history
    case bookmarks

    public var title: String {
        switch self {
        case .passwords: return "Passwords"
        case .autofill: return "Names, emails, phones & addresses"
        case .history: return "History"
        case .bookmarks: return "Bookmarks"
        }
    }

    public var systemImage: String {
        switch self {
        case .passwords: return "key.fill"
        case .autofill: return "person.text.rectangle"
        case .history: return "clock"
        case .bookmarks: return "bookmark"
        }
    }
}

// MARK: - Imported values

public struct ImportedLogin: Equatable, Sendable {
    public var url: URL
    public var username: String
    public var password: String
    public var lastUsed: Date?
    public var timesUsed: Int
}

public struct ImportedIdentity: Equatable, Sendable {
    public var names: [AutofillName.Parts] = []
    public var emails: [String] = []
    public var phones: [String] = []
    public var organizations: [String] = []
    public var addresses: [AutofillAddress] = []

    public var count: Int { names.count + emails.count + phones.count + organizations.count + addresses.count }
}

extension AutofillName {
    public struct Parts: Equatable, Sendable {
        public var given: String
        public var family: String
    }
}

public struct ImportedHistoryEntry: Equatable, Sendable {
    public var url: URL
    public var title: String?
    /// Visit times, oldest first (already capped — see `ImportLimits`).
    public var visits: [Date]
}

public struct ImportedBookmark: Equatable, Sendable {
    public var url: URL
    public var title: String?
    public var added: Date?
}

/// Everything read from one source. Categories that weren't requested (or
/// aren't available) are empty.
public struct ImportBundle: Equatable, Sendable {
    public var logins: [ImportedLogin] = []
    public var identity = ImportedIdentity()
    public var history: [ImportedHistoryEntry] = []
    public var bookmarks: [ImportedBookmark] = []
    /// Human-readable problems ("History: couldn't open …"). Shown after
    /// importing; never fatal.
    public var warnings: [String] = []

    /// Folds in a second input for the same import (e.g. the password CSV
    /// exported from the Chromium browser whose profile is being imported).
    public mutating func merge(_ other: ImportBundle) {
        logins += other.logins
        identity.names += other.identity.names
        identity.emails += other.identity.emails
        identity.phones += other.identity.phones
        identity.organizations += other.identity.organizations
        identity.addresses += other.identity.addresses
        history += other.history
        bookmarks += other.bookmarks
        warnings += other.warnings
    }
}

/// Counts shown before importing. `nil` = unknown / not provided by the source.
public struct ImportPreview: Equatable, Sendable {
    /// For Chromium sources this is only a count of saved logins: they're
    /// imported from the browser's own password CSV export, not read directly.
    public var passwords: Int?
    public var autofill: Int?
    public var historySites: Int?
    public var historyVisits: Int?
    public var bookmarks: Int?
    public var warnings: [String] = []
    /// Set when the source can't be read without the user doing something
    /// (grant Full Disk Access, export from Safari…).
    public var blocker: ImportBlocker?

    public func count(_ c: ImportCategory) -> Int? {
        switch c {
        case .passwords: return passwords
        case .autofill: return autofill
        case .history: return historySites
        case .bookmarks: return bookmarks
        }
    }
}

public enum ImportBlocker: Equatable, Sendable {
    /// Safari's files are protected; the app needs Full Disk Access.
    case needsFullDiskAccess
    case unreadable(String)
}

public enum ImportLimits {
    /// History older than this isn't worth replaying — it would decay to ~0
    /// (5-day half-life) and just fight trimming.
    public static let historyWindow: TimeInterval = 120 * 24 * 60 * 60
    /// Per-URL visits kept for replay (most recent).
    public static let visitsPerURL = 60
    /// URLs handed to the applier (by recency-weighted visit count); the
    /// history store trims further to its own cap.
    public static let historyURLs = 3000
}

public enum ImportError: LocalizedError {
    case unreadable(String)
    case needsFullDiskAccess

    public var errorDescription: String? {
        switch self {
        case .unreadable(let s): return s
        case .needsFullDiskAccess: return "Wowser needs Full Disk Access to read Safari's data."
        }
    }
}
