import Foundation

/// Which profile an import lands in.
public enum ImportTarget: Hashable {
    case existing(ID<Profile>)
    /// A fresh, isolated space titled `title`.
    case newProfile(title: String)
}

public struct ImportResult: Equatable {
    public var profileID: ID<Profile>
    public var passwords = 0
    public var passwordsFailed = 0
    public var autofill = 0
    public var historySites = 0
    public var bookmarks = 0
    public var favoritesAdded = 0
    public var warnings: [String] = []
}

/// Writes an `ImportBundle` into a profile: autofill identity and logins
/// (passwords into the keychain), history (visits replayed into the decayed
/// counters, then trimmed), bookmarks (into the archive), and — when the
/// profile has no favorites yet — favorites from the imported top sites that
/// are well-known apps (`CuratedFavoriteSites`). Never switches the window to
/// the destination space; callers that want that do it themselves.
public enum ImportApplier {
    public static let favoritesFromTopSites = 3

    @MainActor
    public static func apply(_ bundle: ImportBundle, categories: Set<ImportCategory>, to target: ImportTarget) async -> ImportResult {
        let profileID: ID<Profile>
        switch target {
        case .existing(let id):
            profileID = id
        case .newProfile(let title):
            profileID = await BrowserStore.shared.modifyAsync { state -> ID<Profile> in
                let id = state.createNewProfile()
                state.profiles[id]?.title = title.nilIfEmpty
                return id
            }
            // Emoji + theme from the title (AI; don't hold up the import).
            Task { await BrowserStore.shared.regenerateSpaceTheme(profileID: profileID) }
        }
        var result = ImportResult(profileID: profileID, warnings: bundle.warnings)
        guard let dataStoreUUID = BrowserStore.shared.model.profiles[profileID]?.dataStoreUUID else {
            result.warnings.append("The destination space no longer exists.")
            return result
        }
        // Spaces sharing a data store share autofill: write where the
        // autofill session will look it up.
        let autofillProfile = BrowserStore.shared.model.autofillOwner(ofDataStore: dataStoreUUID) ?? profileID

        if categories.contains(.autofill), bundle.identity.count > 0 {
            let identity = bundle.identity
            result.autofill = await AutofillStore.shared.modifyAsync { state -> Int in
                state[profile: autofillProfile].mergeImported(identity)
            }
        }

        if categories.contains(.passwords), !bundle.logins.isEmpty {
            let logins = bundle.logins
            let (writes, existingIDs) = await AutofillStore.shared.modifyAsync { state -> ([(AutofillCredential, String)], Set<UUID>) in
                let existing = Set(state[profile: autofillProfile].credentials.map(\.id))
                return (state[profile: autofillProfile].mergeImported(logins), existing)
            }
            var failed = Set<UUID>()
            for (credential, password) in writes {
                if await AutofillStore.shared.setPassword(password, for: credential, profile: autofillProfile) {
                    result.passwords += 1
                } else {
                    result.passwordsFailed += 1
                    failed.insert(credential.id)
                }
            }
            if !failed.isEmpty {
                let failedIDs = failed
                await AutofillStore.shared.modifyAsync { state in
                    state[profile: autofillProfile].removeNewCredentials(failedIDs, existingBeforeImport: existingIDs)
                }
                result.warnings.append("\(result.passwordsFailed) passwords couldn't be saved to the keychain.")
            }
        }
        AutofillStore.shared.save()

        if categories.contains(.history), !bundle.history.isEmpty {
            let entries = bundle.history
            let added = await withCheckedContinuation { (cont: CheckedContinuation<Int, Never>) in
                Queue.historyQueue.run {
                    let store = HistoryStore.historyStoreForStoreUUID_historyQueueOnly(dataStoreUUID)
                    var added = 0
                    store.modify { state in
                        added = state.mergeImported(entries)
                        state.trim()
                    }
                    store.save()
                    cont.resume(returning: added)
                }
            }
            result.historySites = added

            // A space with no favorites gets its most-visited sites. Ranked
            // from the import itself, not the merged history's decayed
            // scores: those decay from *now*, so a browser the user hasn't
            // opened in a few weeks would score every site as ~0.
            let topSites = ImportedHistoryEntry.topSiteRoots(entries)
            result.favoritesAdded = await BrowserStore.shared.modifyAsync { state -> Int in
                state.addFavoritesFromTopSitesIfEmpty(profile: profileID, topSites: topSites, limit: favoritesFromTopSites)
            }
        }

        if categories.contains(.bookmarks), !bundle.bookmarks.isEmpty {
            result.bookmarks = await ArchiveStore.shared.importBookmarks(bundle.bookmarks)
        }
        return result
    }
}

// MARK: - Autofill merge

extension AutofillProfileData {
    /// Adds names/emails/phones/organizations/addresses we don't already have.
    /// Returns how many were added.
    mutating func mergeImported(_ identity: ImportedIdentity, now: Date = Date()) -> Int {
        var added = 0
        for n in identity.names {
            let full = AutofillName(given: n.given, family: n.family).full.lowercased()
            guard !full.isEmpty, !names.contains(where: { $0.full.lowercased() == full }) else { continue }
            names.append(AutofillName(given: n.given, family: n.family, lastUsed: now, useCount: 1))
            added += 1
        }
        func mergeValues(_ incoming: [String], into list: inout [AutofillValue], key: (String) -> String) {
            for v in incoming {
                let t = v.trimmingCharacters(in: .whitespacesAndNewlines)
                let k = key(t)
                guard !k.isEmpty, !list.contains(where: { key($0.value) == k }) else { continue }
                list.append(AutofillValue(value: t, lastUsed: now, useCount: 1))
                added += 1
            }
        }
        mergeValues(identity.emails, into: &emails) { $0.lowercased() }
        mergeValues(identity.phones, into: &phones) { $0.filter(\.isNumber) }
        mergeValues(identity.organizations, into: &organizations) { $0.lowercased() }
        for a in identity.addresses where !a.isEmpty {
            guard !addresses.contains(where: { $0.isSamePlace(as: a) }) else { continue }
            var a = a
            a.lastUsed = now
            addresses.append(a)
            added += 1
        }
        return added
    }

    /// Adds logins (one per registrable domain + username). Returns the
    /// credentials whose passwords should be written to the keychain — new
    /// ones, and existing ones the other browser used more recently — one per
    /// credential (the most recently used login wins).
    mutating func mergeImported(_ logins: [ImportedLogin], now: Date = Date()) -> [(AutofillCredential, String)] {
        var writes: [UUID: (credential: AutofillCredential, password: String, lastUsed: Date)] = [:]
        var order: [UUID] = []
        var createdHere = Set<UUID>()
        for login in logins {
            guard AutofillHostMatcher.isFillableURL(login.url), let host = login.url.host?.lowercased(), !login.password.isEmpty else { continue }
            let username = login.username.trimmingCharacters(in: .whitespacesAndNewlines)
            let domain = AutofillHostMatcher.registrableDomain(host)
            let lastUsed = login.lastUsed ?? .distantPast
            if let idx = credentials.firstIndex(where: { $0.domain == domain && $0.username.lowercased() == username.lowercased() }) {
                let id = credentials[idx].id
                if createdHere.contains(id) {
                    // Duplicate within the import (e.g. http + https): the
                    // most recently used wins; on a tie, the later row.
                    guard let prior = writes[id], lastUsed >= prior.lastUsed else { continue }
                    if login.lastUsed != nil { credentials[idx].lastUsed = lastUsed }
                } else {
                    // Already saved here: only replace with something newer.
                    guard lastUsed > credentials[idx].lastUsed else { continue }
                    credentials[idx].lastUsed = lastUsed
                    if writes[id] == nil { order.append(id) }
                }
                credentials[idx].useCount = max(credentials[idx].useCount, login.timesUsed)
                writes[id] = (credentials[idx], login.password, lastUsed)
            } else {
                let c = AutofillCredential(domain: domain, host: host, username: username, created: now, lastUsed: login.lastUsed ?? now, useCount: max(1, login.timesUsed))
                credentials.append(c)
                createdHere.insert(c.id)
                order.append(c.id)
                writes[c.id] = (c, login.password, lastUsed)
            }
        }
        return order.compactMap { id in writes[id].map { ($0.credential, $0.password) } }
    }

    /// Drops credentials created by an import whose keychain write failed, so
    /// no login is left without a password. Pre-existing ones are kept.
    mutating func removeNewCredentials(_ ids: Set<UUID>, existingBeforeImport: Set<UUID>) {
        credentials.removeAll { ids.contains($0.id) && !existingBeforeImport.contains($0.id) }
    }
}

// MARK: - History replay

extension DecayedCounter {
    /// Like `add(count:interval:)`, but as if it happened at `date`
    /// (for replaying imported visits in chronological order).
    mutating func add(count: Double, interval: TimeInterval, at date: Date) {
        lastCount = decayedCount(interval: interval, at: date) + count
        lastUpdateDate = date
    }

    func decayedCount(interval: TimeInterval, at date: Date) -> Double {
        guard let lastUpdateDate else { return 0 }
        let halfLives = max(0, (date.timeIntervalSinceReferenceDate - lastUpdateDate.timeIntervalSinceReferenceDate) / interval)
        return lastCount / pow(2, halfLives)
    }
}

extension HistoryState {
    /// Replays imported visits into the decayed visit counters (the same
    /// 5-minute debounce as live browsing), then folds each URL into any
    /// existing entry. For a URL we already have, only visits after its
    /// `lastVisit` (+ debounce) count, so importing the same data twice — or
    /// history we already recorded ourselves — doesn't double-count.
    /// Returns the number of URLs that are new here. Call `trim()` afterwards.
    mutating func mergeImported(_ entries: [ImportedHistoryEntry], now: Date = Date()) -> Int {
        let debounce: TimeInterval = 5 * 60
        var added = 0
        for entry in entries {
            guard let scheme = entry.url.scheme?.lowercased(), scheme == "http" || scheme == "https" else { continue }
            let existing = items[entry.url.historyKey]
            let after = existing.map { $0.lastVisit.addingTimeInterval(debounce) } ?? .distantPast
            var counter = DecayedCounter()
            var lastVisit: Date?
            for visit in entry.visits.sorted() where visit <= now && visit > after {
                if let lastVisit, visit.timeIntervalSince(lastVisit) < debounce { continue }
                counter.add(count: 1, interval: .decayedVisitCounterHalfLife, at: visit)
                lastVisit = visit
            }
            guard let lastVisit else { continue }
            let importedScore = counter.decayedCount(interval: .decayedVisitCounterHalfLife, at: now)

            modify(url: entry.url) { item in
                let current = item.decayedVisitCount.decayedCount(interval: .decayedVisitCounterHalfLife, at: now)
                item.decayedVisitCount = DecayedCounter(lastCount: current + importedScore, lastUpdateDate: now)
                if item.title?.nilIfEmpty == nil { item.title = entry.title?.nilIfEmpty }
                if lastVisit > item.lastVisit { item.lastVisit = lastVisit }
            }
            if existing == nil { added += 1 }
        }
        return added
    }
}

// MARK: - Favorites

extension ImportedHistoryEntry {
    /// Sites by recency-weighted visit count, one per host (sans "www."), as
    /// root URLs. Recency is measured back from the import's latest visit,
    /// not from now, so a browser that sat unused for months still ranks.
    static func topSiteRoots(_ entries: [ImportedHistoryEntry]) -> [(url: URL, host: String)] {
        guard let latest = entries.compactMap({ $0.visits.max() }).max() else { return [] }
        let halfLife = TimeInterval.decayedVisitCounterHalfLife
        var scoreByHost: [String: Double] = [:]
        var sample: [String: URL] = [:]
        for entry in entries {
            guard let scheme = entry.url.scheme?.lowercased(), scheme == "http" || scheme == "https",
                  let host = entry.url.host?.lowercased() else { continue }
            let key = entry.url.hostWithoutWWW
            scoreByHost[key, default: 0] += entry.visits.reduce(0) { $0 + pow(2, -max(0, latest.timeIntervalSince($1)) / halfLife) }
            if sample[key] == nil {
                var c = URLComponents()
                c.scheme = scheme
                c.host = host
                c.path = "/"
                sample[key] = c.url
            }
        }
        return scoreByHost
            .sorted { $0.value > $1.value }
            .compactMap { host, _ in sample[host].map { ($0, host) } }
    }
}

extension BrowserState {
    /// If `profile` has no favorites, adds the first `limit` of `topSites`
    /// (best first) that are well-known apps. Returns how many were added.
    mutating func addFavoritesFromTopSitesIfEmpty(profile profileID: ID<Profile>, topSites: [(url: URL, host: String)], limit: Int) -> Int {
        guard let profile = profiles[profileID] else { return 0 }
        let existing = (profile.manualFavorites + profile.autoFavorites).filter { tabs[$0] != nil }
        guard existing.isEmpty else { return 0 }
        let sites = topSites
            .filter { CuratedFavoriteSites.contains(host: $0.host) && !profile.removedFavoriteDomains.contains($0.host) }
            .prefix(limit)
        for site in sites {
            var info = WebContent.Info(url: site.url)
            info.title = site.host
            let tab = Tab(id: .assign(), panes: [.init(id: .assign(), info: info)])
            insertTab(tab, intoProfileFavoritesAtIndex: profiles[profileID]?.manualFavorites.count ?? 0, profile: profileID)
        }
        return sites.count
    }
}

/// Sites worth pinning as a favorite when they're among an import's top
/// sites: the apps people keep open all day. Random frequently-visited pages
/// (search results, news articles, intranet one-offs) don't make the cut.
enum CuratedFavoriteSites {
    /// Matched against a host (sans "www.") exactly or as a parent domain.
    static let domains: Set<String> = [
        // Google
        "mail.google.com", "drive.google.com", "docs.google.com", "calendar.google.com",
        "meet.google.com", "photos.google.com", "keep.google.com", "gemini.google.com",
        // Microsoft
        "outlook.live.com", "outlook.office.com", "outlook.office365.com", "teams.microsoft.com",
        "teams.live.com", "onedrive.live.com", "office.com", "microsoft365.com",
        // Other mail / calendars
        "mail.yahoo.com", "icloud.com", "fastmail.com", "mail.proton.me", "app.hey.com",
        // Work
        "notion.so", "notion.com", "slack.com", "linear.app", "figma.com", "github.com",
        "gitlab.com", "trello.com", "asana.com", "airtable.com", "dropbox.com", "canva.com",
        "zoom.us", "monday.com", "app.clickup.com", "todoist.com",
        // AI
        "chatgpt.com", "claude.ai", "perplexity.ai",
        // Social / messaging
        "x.com", "twitter.com", "threads.net", "threads.com", "instagram.com", "facebook.com",
        "messenger.com", "web.whatsapp.com", "linkedin.com", "discord.com", "bsky.app",
        "reddit.com", "news.ycombinator.com", "tiktok.com", "pinterest.com",
        // Media
        "youtube.com", "open.spotify.com", "netflix.com", "twitch.tv", "substack.com",
    ]

    static func contains(host: String) -> Bool {
        var h = host.lowercased()
        if h.hasPrefix("www.") { h.removeFirst(4) }
        while true {
            if domains.contains(h) { return true }
            guard let dot = h.firstIndex(of: ".") else { return false }
            h = String(h[h.index(after: dot)...])
        }
    }
}

// MARK: - Bookmarks

extension ArchiveStore {
    /// Adds bookmarks in bulk (no per-item AI tidy pass). Returns how many were new.
    func importBookmarks(_ bookmarks: [ImportedBookmark]) async -> Int {
        let now = Date()
        let added = await modifyAsync { state -> Int in
            var added = 0
            for b in bookmarks {
                guard let scheme = b.url.scheme?.lowercased(), scheme == "http" || scheme == "https" else { continue }
                let key = b.url.historyKey
                if var existing = state.itemsByHistoryKey[key] {
                    existing.kind = .bookmark
                    if existing.title?.nilIfEmpty == nil { existing.title = b.title }
                    state.itemsByHistoryKey[key] = existing
                } else {
                    state.itemsByHistoryKey[key] = ArchiveItem(added: b.added ?? now, url: b.url, historyKey: key, title: b.title, kind: .bookmark)
                    added += 1
                }
            }
            return added
        }
        save()
        return added
    }
}
