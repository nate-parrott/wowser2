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
/// profile has no favorites yet — favorites from the imported top sites.
public enum ImportApplier {
    public static let favoritesFromTopSites = 8

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
            let (added, history) = await withCheckedContinuation { (cont: CheckedContinuation<(Int, HistoryState), Never>) in
                Queue.historyQueue.run {
                    let store = HistoryStore.historyStoreForStoreUUID_historyQueueOnly(dataStoreUUID)
                    var added = 0
                    store.modify { state in
                        added = state.mergeImported(entries)
                        state.trim()
                    }
                    store.save()
                    cont.resume(returning: (added, store.model))
                }
            }
            result.historySites = added

            // A space with no favorites gets its most-visited sites.
            if added > 0 {
                result.favoritesAdded = await BrowserStore.shared.modifyAsync { state -> Int in
                    state.addFavoritesFromTopSitesIfEmpty(profile: profileID, history: history, limit: favoritesFromTopSites)
                }
            }
        }

        if categories.contains(.bookmarks), !bundle.bookmarks.isEmpty {
            result.bookmarks = await ArchiveStore.shared.importBookmarks(bundle.bookmarks)
        }

        if case .newProfile = target {
            BrowserStore.shared.modify { state in
                if let windowID = state.activeWindow?.id {
                    state.windows[windowID]?.profile = profileID
                }
            }
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

    /// Highest-scoring sites, one per host, as root URLs.
    func topSiteRoots(limit: Int) -> [(url: URL, host: String)] {
        var scoreByHost: [String: Double] = [:]
        var sample: [String: URL] = [:]
        for item in items.values {
            guard let scheme = item.url.scheme?.lowercased(), scheme == "http" || scheme == "https", let host = item.url.host?.lowercased() else { continue }
            let key = item.url.hostWithoutWWW
            scoreByHost[key, default: 0] += item.score
            if sample[key] == nil {
                var c = URLComponents()
                c.scheme = scheme
                c.host = host
                c.path = "/"
                sample[key] = c.url
            }
        }
        return scoreByHost
            .filter { $0.value > 0.05 }
            .sorted { $0.value > $1.value }
            .prefix(limit)
            .compactMap { host, _ in sample[host].map { ($0, host) } }
    }
}

// MARK: - Favorites

extension BrowserState {
    /// If `profile` has no favorites, adds its top sites (by decayed visit
    /// score) as favorites. Returns how many were added.
    mutating func addFavoritesFromTopSitesIfEmpty(profile profileID: ID<Profile>, history: HistoryState, limit: Int) -> Int {
        guard let profile = profiles[profileID] else { return 0 }
        let existing = (profile.manualFavorites + profile.autoFavorites).filter { tabs[$0] != nil }
        guard existing.isEmpty else { return 0 }
        let sites = history.topSiteRoots(limit: limit).filter { !profile.removedFavoriteDomains.contains($0.host) }
        for site in sites {
            var info = WebContent.Info(url: site.url)
            info.title = site.host
            let tab = Tab(id: .assign(), panes: [.init(id: .assign(), info: info)])
            insertTab(tab, intoProfileFavoritesAtIndex: profiles[profileID]?.manualFavorites.count ?? 0, profile: profileID)
        }
        return sites.count
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
