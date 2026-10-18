import Foundation

// Maps BrowserState (spaces, tabs, panes) to and from sync records.
// See sync.md at the repo root for what syncs and why.

/// Per-device sync bookkeeping stored in BrowserState.
public struct BrowserSyncLocalState: Codable, Equatable {
    /// The window whose tab lists sync. Pinned while it exists so switching
    /// windows doesn't look like closing every tab.
    public var primaryWindowID: ID<WindowState>?
    /// A space's login group (which spaces share a cookie jar) syncs as an
    /// opaque id: by default its `dataStoreUUID` string. When another device
    /// names a different group for a cookie jar we already have (e.g. both
    /// devices' default space), we alias it here instead of switching jars,
    /// so nobody gets logged out. dataStoreUUID string → group id.
    public var loginGroupAliases: [String: String]?
}

/// See `Pane.syncPendingNav`.
public struct SyncPendingNavigation: Codable, Equatable {
    public var url: URL?
    public var title: String?
    public var favicon: URL?
}

public enum BrowserSyncSchema {
    public static let space = "space"
    public static let tab = "tab"
    public static let pane = "pane"
    /// Parent of every space record (spaces are one ordered list).
    public static let spacesParent = "spaces"

    public static var collections: [SyncCollectionSpec] {
        [
            SyncCollectionSpec(name: space, ordered: true),
            SyncCollectionSpec(name: tab, ordered: true),
            SyncCollectionSpec(name: pane, ordered: true),
        ]
    }

    /// The lists a tab can sit in.
    public enum TabParent: Hashable {
        case favorites(ID<Profile>)
        case autoFavorites(ID<Profile>)
        /// The space's ordinary tabs, in the primary window.
        case tabs(ID<Profile>)
        case folder(ID<Tab>)

        public var key: String {
            switch self {
            case .favorites(let p): return "favorites:\(p.raw)"
            case .autoFavorites(let p): return "autoFavorites:\(p.raw)"
            case .tabs(let p): return "tabs:\(p.raw)"
            case .folder(let t): return "folder:\(t.raw)"
            }
        }

        public init?(key: String) {
            guard let colon = key.firstIndex(of: ":") else { return nil }
            let raw = String(key[key.index(after: colon)...])
            switch key[..<colon] {
            case "favorites": self = .favorites(.init(raw: raw))
            case "autoFavorites": self = .autoFavorites(.init(raw: raw))
            case "tabs": self = .tabs(.init(raw: raw))
            case "folder": self = .folder(.init(raw: raw))
            default: return nil
            }
        }
    }

    public static func paneParent(_ tab: ID<Tab>) -> String { "tab:\(tab.raw)" }

    public static func tabID(fromPaneParent key: String) -> ID<Tab>? {
        key.hasPrefix("tab:") ? ID(raw: String(key.dropFirst(4))) : nil
    }
}

/// Side effects of applying sync that can't happen inside a state transaction.
public enum BrowserSyncEffect: Hashable {
    case setBuiltinBackground(ID<Profile>, builtinID: String, mode: SpaceBackgroundMode?)
    case clearBackground(ID<Profile>)
}

// MARK: - Projection (local → records)

public extension BrowserState {
    /// The window whose tabs sync: the pinned one, else the most recently
    /// active. nil if there are no windows.
    var syncPrimaryWindow: WindowState? {
        if let id = sync?.primaryWindowID, let w = windows[id] { return w }
        return activeWindow
    }

    func syncLoginGroup(forDataStore uuid: UUID) -> String {
        sync?.loginGroupAliases?[uuid.uuidString] ?? uuid.uuidString
    }

    /// Spaces, tabs and panes as sync records. nil when there's no window
    /// (we can't tell "no tabs" from "no window to hold them").
    func syncProjection() -> SyncProjection? {
        typealias S = BrowserSyncSchema
        guard let primary = syncPrimaryWindow else { return nil }
        var p = SyncProjection()
        p.declare(S.space)
        p.declare(S.tab)
        p.declare(S.pane)

        let ordered = profiles.values.sorted { ($0.creationOrder, $0.id.raw) < ($1.creationOrder, $1.id.raw) }
        for profile in ordered {
            p[S.space, profile.id.raw] = profile.syncFields(loginGroup: syncLoginGroup(forDataStore: profile.dataStoreUUID))
            p.append(profile.id.raw, to: S.spacesParent, in: S.space)
        }

        var seen = Set<ID<Tab>>()
        func add(_ tabID: ID<Tab>, to parent: S.TabParent) {
            guard let tab = tabs[tabID], seen.insert(tabID).inserted else { return }
            p[S.tab, tabID.raw] = tab.syncFields
            p.append(tabID.raw, to: parent.key, in: S.tab)
            for pane in tab.panes.asArray {
                p[S.pane, pane.id.raw] = pane.syncFields
                p.append(pane.id.raw, to: S.paneParent(tabID), in: S.pane)
            }
            for member in tab.folder?.tabs ?? [] {
                add(member, to: .folder(tabID))
            }
        }
        for profile in ordered {
            profile.manualFavorites.forEach { add($0, to: .favorites(profile.id)) }
            profile.autoFavorites.forEach { add($0, to: .autoFavorites(profile.id)) }
            primary.perProfileData[profile.id]?.tabs.forEach { add($0, to: .tabs(profile.id)) }
        }
        return p
    }
}

extension Profile {
    func syncFields(loginGroup: String) -> SyncFields {
        var f = SyncFields()
        f["title"] = SyncValue(title)
        f["emoji"] = SyncValue(emoji)
        f["autoTitle"] = SyncValue(autoTitle)
        f["hidden"] = isHidden ? .bool(true) : .null
        f["folderPath"] = SyncValue(folderPath)
        f["theme"] = .encoding(theme)
        f["themeGeneratedForTitle"] = SyncValue(themeGeneratedForTitle)
        f["background"] = syncBackground
        f["loginGroup"] = .string(loginGroup)
        return f.filter { !$0.value.isNull }
    }

    /// Bundled wallpapers sync by id. Custom images are local files and
    /// don't sync; other devices keep whatever background they have.
    var syncBackground: SyncValue {
        guard let info = imageInfo else { return .null }
        var o: [String: SyncValue] = ["mode": SyncValue(info.mode?.rawValue)]
        if let builtin = info.builtinID {
            o["builtin"] = .string(builtin)
        } else {
            o["custom"] = .bool(true)
        }
        return .object(o.filter { !$0.value.isNull })
    }
}

extension Tab {
    var syncFields: SyncFields {
        var f = SyncFields()
        f["customTitle"] = SyncValue(customTitle)
        f["customEmoji"] = SyncValue(customEmoji)
        f["folderName"] = SyncValue(folder?.name)
        return f.filter { !$0.value.isNull }
    }
}

extension Pane {
    var syncFields: SyncFields {
        var f = SyncFields()
        if let pending = syncPendingNav {
            f["url"] = SyncValue(pending.url)
            f["title"] = SyncValue(pending.title)
            f["favicon"] = SyncValue(pending.favicon)
        } else {
            f["url"] = SyncValue(info.committedURL)
            f["title"] = SyncValue(Pane.syncTitle(info.title))
            f["favicon"] = SyncValue(info.favicon)
        }
        f["baseURL"] = SyncValue(baseInfo?.url)
        f["baseTitle"] = SyncValue(baseInfo.flatMap { Pane.syncTitle($0.title) })
        f["weight"] = SyncValue(weight)
        return f.filter { !$0.value.isNull }
    }

    /// Terminal titles carry Claude Code's spinner glyph, which changes many
    /// times a second; sync the text only.
    static func syncTitle(_ title: String?) -> String? {
        guard var t = title else { return nil }
        if let first = t.first, WebContent.Info.claudeCodeRunningGlyphs.contains(first) || first == WebContent.Info.claudeCodeIdleGlyph {
            t = String(t.dropFirst()).trimmingCharacters(in: .whitespaces)
        }
        return t
    }
}

// MARK: - Apply (records → local)

public extension BrowserState {
    /// Fold remote changes in. `livePanes` are panes with a live webview:
    /// remote navigations of those are parked in `syncPendingNav` rather
    /// than applied. Returns effects for the caller to run afterwards.
    @discardableResult
    mutating func applySync(_ u: SyncUpdate, livePanes: Set<ID<WebContent>>) -> [BrowserSyncEffect] {
        typealias S = BrowserSyncSchema
        guard let current = syncProjection(), let primaryID = syncPrimaryWindow?.id else { return [] }
        if sync?.primaryWindowID != primaryID {
            sync = sync ?? BrowserSyncLocalState()
            sync?.primaryWindowID = primaryID
        }
        var effects = [BrowserSyncEffect]()
        let doc = u.doc

        // Spaces
        for key in u.changedKeys(S.space) {
            let id = ID<Profile>(raw: key)
            let cur = current[S.space, key]
            if u.shouldDelete(S.space, key, current: cur) {
                deleteProfile(id)
                continue
            }
            guard let fields = u.fieldsToApply(S.space, key, current: cur), cur == nil || !fields.isEmpty else { continue }
            if profiles[id] == nil {
                let group = doc.value(S.space, key, "loginGroup").stringValue ?? UUID().uuidString
                let order = (profiles.values.map(\.creationOrder).max() ?? -1) + 1
                profiles[id] = Profile(id: id, dataStoreUUID: dataStoreUUID(forLoginGroup: group), creationOrder: order)
            }
            applySpaceFields(fields, to: id, effects: &effects)
        }

        // Tabs and panes that already exist locally (new ones are created
        // when their parent list is reconciled below).
        var tabParents = u.changedParents[S.tab] ?? []
        for key in u.changedKeys(S.tab) {
            let id = ID<Tab>(raw: key)
            let cur = current[S.tab, key]
            if u.shouldDelete(S.tab, key, current: cur) {
                removeTabForSync(id)
                continue
            }
            if let parent = doc.parent(S.tab, key) { tabParents.insert(parent) }
            guard tabs[id] != nil, let fields = u.fieldsToApply(S.tab, key, current: cur), !fields.isEmpty else { continue }
            modifyTab(id: id) { $0.applySyncFields(fields) }
        }

        var paneParents = u.changedParents[S.pane] ?? []
        for key in u.changedKeys(S.pane) {
            let id = ID<WebContent>(raw: key)
            let cur = current[S.pane, key]
            if u.shouldDelete(S.pane, key, current: cur) {
                if let tabID = paneToTabMapping[id] {
                    modifyTab(id: tabID) { $0.panes.remove(id: id) }
                }
                continue
            }
            if let parent = doc.parent(S.pane, key) { paneParents.insert(parent) }
            guard let tabID = paneToTabMapping[id], let fields = u.fieldsToApply(S.pane, key, current: cur), !fields.isEmpty else { continue }
            let all = doc.fields(S.pane, key) ?? [:]
            let live = livePanes.contains(id)
            modifyTab(id: tabID) { tab in
                if var pane = tab.panes[id] {
                    pane.applySyncFields(fields, all: all, live: live)
                    tab.panes[id] = pane
                }
            }
        }

        // Tab lists. Each list is rewritten only if the user hasn't reordered
        // it locally since the engine last looked (see `desiredOrder`).
        for parentKey in tabParents.sorted() {
            guard let parent = S.TabParent(key: parentKey), let local = syncTabList(parent, primary: primaryID) else { continue }
            guard var desired = u.desiredOrder(S.tab, parent: parentKey, local: local) else { continue }
            desired = desired.filter { raw in
                let id = ID<Tab>(raw: raw)
                if tabs[id] != nil { return true }
                guard createTabFromSync(id, doc: doc) else { return false }
                paneParents.insert(S.paneParent(id))
                return true
            }
            let ids = desired.map { ID<Tab>(raw: $0) }
            detachFromSyncTabLists(Set(ids), except: parent, primary: primaryID)
            setSyncTabList(parent, ids, primary: primaryID)
        }

        // Pane order within tabs (and panes moved between tabs).
        for parentKey in paneParents.sorted() {
            guard let tabID = S.tabID(fromPaneParent: parentKey), let tab = tabs[tabID] else { continue }
            let local = tab.panes.map(\.id.raw)
            guard let desired = u.desiredOrder(S.pane, parent: parentKey, local: local) else { continue }
            var panes = [Pane]()
            for raw in desired {
                let id = ID<WebContent>(raw: raw)
                if let p = tab.panes[id] {
                    panes.append(p)
                } else if let otherTab = paneToTabMapping[id], let p = tabs[otherTab]?.panes[id] {
                    modifyTab(id: otherTab) { $0.panes.remove(id: id) }
                    panes.append(p)
                } else if let fields = doc.fields(S.pane, raw) {
                    panes.append(Pane.fromSync(id: id, fields: fields))
                }
            }
            modifyTab(id: tabID) { $0.panes = .init(items: panes) }
        }

        // Space order.
        if u.changedParents[S.space]?.contains(S.spacesParent) == true {
            let local = profiles.values.sorted { ($0.creationOrder, $0.id.raw) < ($1.creationOrder, $1.id.raw) }.map(\.id.raw)
            if let desired = u.desiredOrder(S.space, parent: S.spacesParent, local: local) {
                for (i, raw) in desired.enumerated() {
                    profiles[ID(raw: raw)]?.creationOrder = i
                }
            }
        }
        return effects
    }

    /// The local cookie jar for a login group: one a space here already uses
    /// for that group, else the group id itself (when it's an unused UUID),
    /// else a fresh one aliased to the group.
    mutating func dataStoreUUID(forLoginGroup group: String) -> UUID {
        if let existing = profiles.values.first(where: { syncLoginGroup(forDataStore: $0.dataStoreUUID) == group }) {
            return existing.dataStoreUUID
        }
        if let uuid = UUID(uuidString: group), !profiles.values.contains(where: { $0.dataStoreUUID == uuid }) {
            return uuid
        }
        let uuid = UUID()
        setLoginGroupAlias(group, for: uuid)
        return uuid
    }

    private mutating func setLoginGroupAlias(_ group: String, for uuid: UUID) {
        sync = sync ?? BrowserSyncLocalState()
        var aliases = sync?.loginGroupAliases ?? [:]
        aliases[uuid.uuidString] = group == uuid.uuidString ? nil : group
        sync?.loginGroupAliases = aliases.isEmpty ? nil : aliases
    }

    private mutating func applySpaceFields(_ fields: SyncFields, to id: ID<Profile>, effects: inout [BrowserSyncEffect]) {
        guard var profile = profiles[id] else { return }
        for (name, v) in fields {
            switch name {
            case "title": profile.title = v.stringValue
            case "emoji": profile.emoji = v.stringValue
            case "autoTitle": profile.autoTitle = v.stringValue
            case "hidden": profile.hidden = v.boolValue == true ? true : nil
            case "folderPath": profile.folderPath = v.stringValue
            case "theme": profile.theme = v.decoded(as: SpaceTheme.self)
            case "themeGeneratedForTitle": profile.themeGeneratedForTitle = v.stringValue
            case "background":
                let o = v.objectValue
                let mode = o?["mode"]?.stringValue.flatMap(SpaceBackgroundMode.init(rawValue:))
                if let builtin = o?["builtin"]?.stringValue {
                    if profile.imageInfo?.builtinID == builtin {
                        profile.imageInfo?.mode = mode
                    } else {
                        effects.append(.setBuiltinBackground(id, builtinID: builtin, mode: mode))
                    }
                } else if o?["custom"] != nil {
                    // Can't fetch another device's image; keep ours, take the mode.
                    if profile.imageInfo != nil { profile.imageInfo?.mode = mode }
                } else if profile.imageInfo != nil {
                    effects.append(.clearBackground(id))
                }
            case "loginGroup":
                guard let group = v.stringValue, syncLoginGroup(forDataStore: profile.dataStoreUUID) != group else { break }
                if let other = profiles.values.first(where: { $0.id != id && syncLoginGroup(forDataStore: $0.dataStoreUUID) == group }) {
                    // Joins a group that already has a cookie jar here.
                    profile.dataStoreUUID = other.dataStoreUUID
                } else {
                    // Same jar, new name for it.
                    setLoginGroupAlias(group, for: profile.dataStoreUUID)
                }
            default: break
            }
        }
        profiles[id] = profile
    }

    /// Ids in a synced tab list, or nil if the list's owner doesn't exist.
    func syncTabList(_ parent: BrowserSyncSchema.TabParent, primary: ID<WindowState>) -> [String]? {
        switch parent {
        case .favorites(let p): return profiles[p]?.manualFavorites.map(\.raw)
        case .autoFavorites(let p): return profiles[p]?.autoFavorites.map(\.raw)
        case .tabs(let p):
            guard profiles[p] != nil, let win = windows[primary] else { return nil }
            return (win.perProfileData[p]?.tabs ?? []).map(\.raw)
        case .folder(let t): return tabs[t]?.folder?.tabs.map(\.raw)
        }
    }

    private mutating func setSyncTabList(_ parent: BrowserSyncSchema.TabParent, _ ids: [ID<Tab>], primary: ID<WindowState>) {
        switch parent {
        case .favorites(let p), .autoFavorites(let p):
            // Favorites reset to a pinned state when closed; make sure they have one.
            for id in ids {
                modifyTab(id: id) { tab in
                    for pane in tab.panes.asArray where pane.baseInfo == nil {
                        tab.panes[pane.id]?.baseInfo = pane.info
                    }
                }
            }
            if case .favorites = parent { profiles[p]?.manualFavorites = ids } else { profiles[p]?.autoFavorites = ids }
        case .tabs(let p):
            if windows[primary]?.perProfileData[p] == nil {
                windows[primary]?.perProfileData[p] = .init(tabs: [])
            }
            windows[primary]?.perProfileData[p]?.tabs = ids
        case .folder(let f):
            modifyFolder(id: f) { folder in
                folder.tabs = ids
                folder.openTabs = folder.openTabs.filter { ids.contains($0) }
            }
        }
    }

    /// Take `ids` out of every sidebar list except `parent` (a tab lives in one place).
    private mutating func detachFromSyncTabLists(_ ids: Set<ID<Tab>>, except parent: BrowserSyncSchema.TabParent?, primary: ID<WindowState>) {
        guard !ids.isEmpty else { return }
        for pid in profiles.keys {
            if parent != .favorites(pid) { profiles[pid]?.manualFavorites.removeAll { ids.contains($0) } }
            if parent != .autoFavorites(pid) { profiles[pid]?.autoFavorites.removeAll { ids.contains($0) } }
        }
        for (winID, win) in windows {
            for (pid, data) in win.perProfileData {
                if winID == primary, parent == .tabs(pid) { continue }
                if data.tabs.contains(where: ids.contains) {
                    windows[winID]?.perProfileData[pid]?.tabs.removeAll { ids.contains($0) }
                }
                if data.attachedAgentTabs?.contains(where: ids.contains) == true {
                    windows[winID]?.perProfileData[pid]?.attachedAgentTabs?.removeAll { ids.contains($0) }
                }
            }
        }
        for (tabID, tab) in tabs where tab.folder != nil && parent != .folder(tabID) {
            if tab.folder!.tabs.contains(where: ids.contains) {
                modifyFolder(id: tabID) { folder in
                    folder.tabs.removeAll { ids.contains($0) }
                    folder.openTabs.removeAll { ids.contains($0) }
                }
            }
        }
    }

    /// Create a tab another device made. Returns false if it isn't usable yet
    /// (a non-folder tab whose panes haven't arrived).
    private mutating func createTabFromSync(_ id: ID<Tab>, doc: SyncDocument) -> Bool {
        typealias S = BrowserSyncSchema
        guard let fields = doc.fields(S.tab, id.raw) else { return false }
        var panes = [Pane]()
        for raw in doc.children(S.pane, parent: S.paneParent(id)) {
            let paneID = ID<WebContent>(raw: raw)
            if let otherTab = paneToTabMapping[paneID], let existing = tabs[otherTab]?.panes[paneID] {
                // Split up on another device: the pane moves here (keeping its live page).
                modifyTab(id: otherTab) { $0.panes.remove(id: paneID) }
                panes.append(existing)
            } else if let paneFields = doc.fields(S.pane, raw) {
                panes.append(Pane.fromSync(id: paneID, fields: paneFields))
            }
        }
        let isFolder = fields["folderName"] != nil
        guard isFolder || !panes.isEmpty else { return false }
        var tab = Tab(id: id, panes: panes)
        tab.applySyncFields(fields)
        _registerTab_unsafe(tab)
        return true
    }

    /// Remove a tab another device closed, reselecting a neighbor in any
    /// window that was showing it.
    private mutating func removeTabForSync(_ id: ID<Tab>) {
        guard tabs[id] != nil, let primary = syncPrimaryWindow?.id else { return }
        for winID in windows.keys where windows[winID]?.currentTab == id {
            let next = tabToSelectAfterClosing(tabId: id)
            windows[winID]?.currentTab = next == id ? nil : next
        }
        var gone: Set<ID<Tab>> = [id]
        gone.formUnion(tabs[id]?.folder?.tabs ?? [])
        detachFromSyncTabLists(gone, except: nil, primary: primary)
        _removeTab_unsafe_doesntCloseWebContent(tabId: id, removeFromParent: false)
    }
}

extension Tab {
    mutating func applySyncFields(_ fields: SyncFields) {
        for (name, v) in fields {
            switch name {
            case "customTitle": customTitle = v.stringValue
            case "customEmoji": customEmoji = v.stringValue
            case "folderName":
                if let n = v.stringValue {
                    if folder == nil { folder = TabFolder(name: n) } else { folder?.name = n }
                }
            default: break
            }
        }
    }
}

extension Pane {
    static func fromSync(id: Core.ID<WebContent>, fields: SyncFields) -> Pane {
        var info = WebContent.Info(url: fields["url"]?.urlValue, title: fields["title"]?.stringValue)
        info.favicon = fields["favicon"]?.urlValue
        var pane = Pane(id: id, info: info)
        if let base = fields["baseURL"]?.urlValue {
            pane.baseInfo = WebContent.Info(url: base, title: fields["baseTitle"]?.stringValue)
        }
        pane.weight = fields["weight"]?.doubleValue
        return pane
    }

    /// `fields` = what to change; `all` = the record's full merged fields.
    mutating func applySyncFields(_ fields: SyncFields, all: SyncFields, live: Bool) {
        let navChanged = fields["url"] != nil || fields["title"] != nil || fields["favicon"] != nil
        if navChanged {
            let url = all["url"]?.urlValue
            let title = all["title"]?.stringValue
            let favicon = all["favicon"]?.urlValue
            if !live {
                info = WebContent.Info(url: url, title: title)
                info.favicon = favicon
                syncPendingNav = nil
            } else if url == info.committedURL {
                // Same page; just a fresher title/icon. Nothing to load.
                info.title = title ?? info.title
                info.favicon = favicon ?? info.favicon
                syncPendingNav = nil
            } else {
                // Don't navigate a page the user may be looking at.
                syncPendingNav = SyncPendingNavigation(url: url, title: title, favicon: favicon)
            }
        }
        if fields["baseURL"] != nil || fields["baseTitle"] != nil {
            if let base = all["baseURL"]?.urlValue {
                baseInfo = WebContent.Info(url: base, title: all["baseTitle"]?.stringValue)
            } else {
                baseInfo = nil
            }
        }
        if let w = fields["weight"] {
            weight = w.doubleValue
        }
    }
}

// MARK: - Parked remote navigations

public extension BrowserState {
    /// The user is reopening `tabID`: turn its parked remote navigations into
    /// real ones. Returns the URLs live webviews should now load.
    mutating func adoptSyncPendingNavigations(tabID: ID<Tab>) -> [(pane: ID<WebContent>, url: URL)] {
        guard let tab = tabs[tabID], tab.panes.contains(where: { $0.syncPendingNav != nil }) else { return [] }
        var loads = [(pane: ID<WebContent>, url: URL)]()
        modifyTab(id: tabID) { tab in
            for var pane in tab.panes.asArray {
                guard let pending = pane.syncPendingNav else { continue }
                pane.info = WebContent.Info(url: pending.url, title: pending.title)
                pane.info.favicon = pending.favicon
                pane.syncPendingNav = nil
                tab.panes[pane.id] = pane
                if let url = pending.url { loads.append((pane.id, url)) }
            }
        }
        return loads
    }

    /// The user navigated this pane: their navigation beats a parked remote one.
    mutating func dropSyncPendingNav(paneID: ID<WebContent>) {
        guard let tabID = paneToTabMapping[paneID], tabs[tabID]?.panes[paneID]?.syncPendingNav != nil else { return }
        modifyTab(id: tabID) { $0.panes[paneID]?.syncPendingNav = nil }
    }
}
