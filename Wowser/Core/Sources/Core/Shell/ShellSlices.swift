import Foundation
import SwiftUI

/// What a slice is computed from: browser state plus the few per-window
/// facts that live outside it.
struct ShellSliceContext {
    var state: BrowserState
    var windowID: ID<WindowState>
    var branch: String
    var store: ShellBranchStore
    var platform: String
    var isDark: Bool
    var isFullscreen: Bool
    var isKey: Bool
    var mouse = CGPoint.zero
    var mouseInside = false
    /// The window's screen and its usable part (no menu bar / Dock), in
    /// global top-left coordinates.
    var screenFrame = CGRect.zero
    var screenVisible = CGRect.zero
}

/// Slices are the read side of the shell API: small JSON snapshots of browser
/// state that JS subscribes to by name (`useTabs()` → `"tabs"`).
///
/// Each is a pure function of `ShellSliceContext` (no disk, no network — they
/// run on every state change) and is only re-encoded and pushed to JS when
/// its value actually changes. The JSON shapes are documented in wowser.d.ts
/// and mirrored by scripts/shell/lib/fakeBrowser.js; change all three together.
enum ShellSlices {
    /// `key` is `name` or `name|{json args}`.
    static func compute(key: String, _ c: ShellSliceContext) -> ShellJSON {
        let (name, arg) = split(key)
        switch name {
        case "window": return window(c)
        case "spaces": return spaces(c)
        case "tabs": return tabStrip(c, spaceID: arg["space"]?.string.map { ID<Profile>(raw: $0) })
        case "tab": return tab(c, id: ID<Tab>(raw: arg["id"]?.string ?? ""))
        case "pane": return pane(c, id: ID<WebContent>(raw: arg["id"]?.string ?? ""))
        case "theme": return theme(c)
        case "toasts": return toasts(c)
        case "mouse":
            return ["x": .number(Double(c.mouse.x.rounded())), "y": .number(Double(c.mouse.y.rounded())), "inside": .bool(c.mouseInside)]
        case "screen":
            let f = c.screenFrame
            let v = c.screenVisible
            return [
                "x": .number(Double(f.minX)), "y": .number(Double(f.minY)),
                "width": .number(Double(f.width)), "height": .number(Double(f.height)),
                "visible": ["x": .number(Double(v.minX)), "y": .number(Double(v.minY)), "width": .number(Double(v.width)), "height": .number(Double(v.height))],
            ]
        case "setting": return setting(arg["key"]?.string ?? "")
        case "storage": return c.store.storageValue(branch: c.branch, key: arg["key"]?.string ?? "") ?? .null
        default: return .null
        }
    }

    static func split(_ key: String) -> (String, [String: ShellJSON]) {
        guard let bar = key.firstIndex(of: "|") else { return (key, [:]) }
        let arg = ShellJSON.parse(String(key[key.index(after: bar)...]))?.object ?? [:]
        return (String(key[..<bar]), arg)
    }

    // MARK: Helpers

    private static func j(_ s: String?) -> ShellJSON { s.map { .string($0) } ?? .null }
    private static func j(_ url: URL?) -> ShellJSON { url.map { .string($0.absoluteString) } ?? .null }
    private static func j(_ d: Double?) -> ShellJSON { d.map { .number($0) } ?? .null }

    /// The command bar counts as open when the user opened it, and also on an
    /// empty tab or an empty window — the same rule `focusState` uses.
    static func commandBarOpen(_ state: BrowserState, window: WindowState) -> Bool {
        if window.searchOverlayActive { return true }
        guard let tabID = window.currentTab, let tab = state.tabs[tabID], let pane = tab.focusedPane else { return true }
        return pane.info.isEmptyPage && !state.isChatMode
    }

    // MARK: window

    static func window(_ c: ShellSliceContext) -> ShellJSON {
        guard let w = c.state.windows[c.windowID] else { return .null }
        let tab = w.currentTab.flatMap { c.state.tabs[$0] }
        return [
            "id": .string(c.windowID.raw),
            "platform": .string(c.platform),
            "spaceId": .string(w.profile.raw),
            "currentTabId": j(tab?.id.raw),
            "focusedPaneId": j(tab?.focusedPane?.id.raw),
            "sidebarVisible": .bool(w.sidebarLocked),
            "commandBarOpen": .bool(commandBarOpen(c.state, window: w)),
            "commandBarPrefillsURL": .bool(w.omniboxPrefillsURL == true),
            "isFullscreen": .bool(c.isFullscreen),
            "isKey": .bool(c.isKey),
            "showingNewSpacePage": .bool(w.showingNewProfilePage == true),
            "chatMode": .bool(c.state.isChatMode),
        ]
    }

    // MARK: spaces

    static func spaces(_ c: ShellSliceContext) -> ShellJSON {
        let current = c.state.windows[c.windowID]?.profile
        return .array(c.state.visibleProfiles.map { p in
            [
                "id": .string(p.id.raw),
                "name": .string(p.displayName),
                "title": j(p.title?.nilIfEmpty),
                "emoji": j(p.emoji?.nilIfEmpty),
                "isCurrent": .bool(p.id == current),
                "hue": j(p.theme?.hue),
                "secondaryHue": j(p.theme?.secondaryHue),
                "hasImage": .bool(p.imageInfo != nil),
                "folderPath": j(p.folderPath),
            ]
        })
    }

    // MARK: tabs

    static func icon(_ icon: TabAppearance.Icon, pageURL: URL?) -> ShellJSON {
        switch icon {
        case .favicon(let src):
            guard let pageURL else {
                if src == nil { return ["kind": "native"] }
                return ["kind": "favicon", "url": "", "src": j(src)]
            }
            return ["kind": "favicon", "url": .string(pageURL.absoluteString), "src": j(src)]
        case .sfSymbol(let name):
            return ["kind": "symbol", "name": .string(name)]
        case .emoji(let value):
            return ["kind": "emoji", "value": .string(value)]
        case .terminal, .claude, .vscode, .files, .fileIcon, .agentFruit, .empty:
            return ["kind": "native"]
        }
    }

    static func tabInfo(_ tab: Tab, state: BrowserState, currentTabID: ID<Tab>?, pinned: Bool, folderID: ID<Tab>?) -> ShellJSON {
        let appearance = tab.appearance()
        let pane = tab.focusedPane ?? tab.panes.first
        let url = pane?.info.url
        let kind = url.flatMap { NativePageKey(url: $0) }?.kindString ?? "web"
        var folder: ShellJSON = .null
        if let f = tab.folder {
            folder = [
                "name": .string(f.name),
                "tabIds": .array(f.tabs.map { .string($0.raw) }),
                "openTabIds": .array(f.openTabs.map { .string($0.raw) }),
            ]
        }
        let badge: ShellJSON
        switch appearance.badge {
        case .dot: badge = "dot"
        case .cursor: badge = "cursor"
        case nil: badge = .null
        }
        return [
            "id": .string(tab.id.raw),
            "title": .string(appearance.title.isEmpty && tab.folder == nil ? (appearance.specialTitle ? "New Tab" : "") : appearance.title),
            "subtitle": j(appearance.subtitle),
            "url": j(url),
            "icon": icon(appearance.icon, pageURL: url),
            "isCurrent": .bool(tab.id == currentTabID),
            "isPinned": .bool(pinned),
            "isLoading": .bool(pane?.info.isLoading ?? false),
            "isGhost": .bool(appearance.isGhost),
            "isUnloaded": .bool(appearance.isUnloaded),
            "isPip": .bool(tab.isPip),
            "isSplit": .bool(tab.isSplit),
            "badge": badge,
            "group": j(tab.aiTags?.groupName),
            "kind": .string(tab.folder != nil ? "folder" : kind),
            "hasCustomTitle": .bool(appearance.isCustomTitle),
            "paneIds": .array(tab.panes.elements.map { .string($0.id.raw) }),
            "focusedPaneId": j(pane?.id.raw),
            "folder": folder,
            "folderId": j(folderID?.raw),
        ]
    }

    static func tabStrip(_ c: ShellSliceContext, spaceID: ID<Profile>?) -> ShellJSON {
        let state = c.state
        guard let w = state.windows[c.windowID] else { return .null }
        let profileID = spaceID ?? w.profile
        let perProfile = w.perProfileData[profileID]
        let current = perProfile?.currentTab
        let favoriteIDs = state.profiles[profileID].map { $0.manualFavorites + $0.autoFavorites } ?? []
        let shareTabs = DefaultsKeys.allWindowsShareTabs.boolValue(defaultValue: true)
        let regular = shareTabs
            ? state.sharedSidebarTabIDs(windowID: c.windowID, profileID: profileID)
            : (perProfile?.tabs ?? [])

        var tabs: [ShellJSON] = []
        tabs.reserveCapacity(regular.count)
        for id in regular {
            guard let tab = state.tabs[id] else { continue }
            tabs.append(tabInfo(tab, state: state, currentTabID: current, pinned: false, folderID: nil))
            // Open members of a folder are listed right under it.
            if let f = tab.folder {
                for memberID in f.openTabs {
                    if let member = state.tabs[memberID] {
                        tabs.append(tabInfo(member, state: state, currentTabID: current, pinned: true, folderID: id))
                    }
                }
            }
        }
        return [
            "spaceId": .string(profileID.raw),
            "currentTabId": j(current?.raw),
            "pinned": .array(favoriteIDs.compactMap { state.tabs[$0] }.map {
                tabInfo($0, state: state, currentTabID: current, pinned: true, folderID: nil)
            }),
            "tabs": .array(tabs),
        ]
    }

    static func tab(_ c: ShellSliceContext, id: ID<Tab>) -> ShellJSON {
        guard let tab = c.state.tabs[id] else { return .null }
        let w = c.state.windows[c.windowID]
        let folderID = c.state.folderTab(containingTabId: id)?.id
        guard case .object(var out) = tabInfo(tab, state: c.state, currentTabID: w?.currentTab, pinned: c.state.isPinned(tabId: id), folderID: folderID) else {
            return .null
        }
        out["panes"] = .array(tab.panes.elements.map { paneInfo($0, tab: tab, c) })
        return .object(out)
    }

    // MARK: pane

    static func pane(_ c: ShellSliceContext, id: ID<WebContent>) -> ShellJSON {
        guard let tabID = c.state.paneToTabMapping[id], let tab = c.state.tabs[tabID], let pane = tab.panes[id] else { return .null }
        return paneInfo(pane, tab: tab, c)
    }

    static func paneInfo(_ pane: Pane, tab: Tab, _ c: ShellSliceContext) -> ShellJSON {
        let info = pane.info
        let w = c.state.windows[c.windowID]
        let appearance = pane.tabAppearance()
        let isFocused = w?.currentTab == tab.id && tab.focusedPane?.id == pane.id
        var failed: ShellJSON = .null
        if let f = info.failedNavToURL {
            var message = ""
            if case .generic(let m) = f.error { message = m }
            failed = ["url": .string(f.url.absoluteString), "error": .string(message)]
        }
        var scheme: ShellJSON = .null
        var topColor: ShellJSON = .null
        if let cs = info.colorScheme {
            // The foreground is light exactly when the page top is dark.
            scheme = .string(cs.foreground.brightness > 0.5 ? "dark" : "light")
            topColor = .string(ShellColors.hex(cs.background.uiColor))
        }
        let kind = info.url.flatMap { NativePageKey(url: $0) }?.kindString ?? "web"
        return [
            "id": .string(pane.id.raw),
            "tabId": .string(tab.id.raw),
            "url": j(info.url),
            "displayURL": .string(appearance.urlFieldTextDeselected),
            "title": j(info.title),
            "isLoading": .bool(info.isLoading),
            "progress": .number((info.estimatedProgress * 100).rounded() / 100),
            "canGoBack": .bool(info.canGoBack),
            "canGoForward": .bool(info.canGoForward),
            "isSecure": .bool(info.isSecure),
            "isEmpty": .bool(info.isEmptyPage),
            "favicon": j(info.favicon),
            "kind": .string(kind),
            "weight": .number(pane.weight ?? 1),
            "isFocused": .bool(isFocused),
            "findOpen": .bool(w?.findInPageActiveInPaneId == pane.id),
            "commandBarOpen": .bool(isFocused && (w.map { commandBarOpen(c.state, window: $0) } ?? false)),
            "topColor": topColor,
            "scheme": scheme,
            "failed": failed,
        ]
    }

    // MARK: theme

    static func theme(_ c: ShellSliceContext) -> ShellJSON {
        let profile = c.state.windows[c.windowID].flatMap { c.state.profiles[$0.profile] }
        let accent = SpaceAccent.forSpace(theme: profile?.theme, imageInfo: profile?.imageInfo) ?? .system
        var env = EnvironmentValues()
        env.colorScheme = c.isDark ? .dark : .light
        var gradient: ShellJSON = .null
        if let theme = profile?.theme {
            let a = HSBA(hue: CGFloat(theme.secondaryHue / 360), saturation: 0.5, brightness: 0.9, alpha: 0.05)
            let b = HSBA(hue: CGFloat(theme.hue / 360), saturation: 0.55, brightness: 0.85, alpha: 0.13)
            gradient = [.string(ShellColors.hex(a.uiColor)), .string(ShellColors.hex(b.uiColor))]
        }
        return [
            "scheme": .string(c.isDark ? "dark" : "light"),
            "accent": .string(ShellColors.hex(accent.accent, in: env)),
            "onAccent": .string(ShellColors.hex(accent.onAccent, in: env)),
            "hue": j(profile?.theme?.hue),
            "secondaryHue": j(profile?.theme?.secondaryHue),
            "gradient": gradient,
            "backgroundImage": .null,
        ]
    }

    // MARK: toasts

    static func toasts(_ c: ShellSliceContext) -> ShellJSON {
        guard let w = c.state.windows[c.windowID] else { return [] }
        return .array(w.toasts.map { t in
            [
                "id": .string(t.id.uuidString),
                "title": j(t.title),
                "message": .string(t.message),
                "icon": .string(t.icon),
                "actions": .array((t.actions ?? []).map { .string($0.title) }),
                "sticky": .bool(t.sticky == true),
            ]
        })
    }

    // MARK: settings

    /// Preferences JS may read and write: any `DefaultsKeys` case that isn't
    /// a credential.
    static func settingKey(_ name: String) -> DefaultsKeys? {
        guard let key = DefaultsKeys(rawValue: name) else { return nil }
        let lower = name.lowercased()
        if lower.hasSuffix("key") || lower.contains("token") || lower.contains("bookmark") { return nil }
        return key
    }

    static func setting(_ name: String) -> ShellJSON {
        guard let key = settingKey(name), let value = UserDefaults.standard.object(forKey: key.rawValue) else { return .null }
        switch value {
        case let s as String: return .string(s)
        case let n as NSNumber: return ShellJSON(any: n)
        case let a as [String]: return .array(a.map { .string($0) })
        default: return .null
        }
    }
}

/// One live subscription: recomputes on demand and reports the new JSON only
/// when the value changed.
final class ShellSliceSubscription {
    let key: String
    private var last: ShellJSON?
    private(set) var json: String = ""

    init(key: String) {
        self.key = key
    }

    /// Returns the new JSON if the slice changed since the last call.
    func refresh(_ c: ShellSliceContext) -> String? {
        let value = ShellSlices.compute(key: key, c)
        if let last, last == value { return nil }
        last = value
        json = value.isNull ? "" : value.jsonString()
        return json
    }
}

enum ShellColors {
    static func hex(_ color: UINSColor) -> String {
        #if os(macOS)
        let c = color.usingColorSpace(.sRGB) ?? color
        return ShellColorToken.hex(Double(c.redComponent), Double(c.greenComponent), Double(c.blueComponent), Double(c.alphaComponent))
        #else
        var r: CGFloat = 0, g: CGFloat = 0, b: CGFloat = 0, a: CGFloat = 0
        color.getRed(&r, green: &g, blue: &b, alpha: &a)
        return ShellColorToken.hex(Double(r), Double(g), Double(b), Double(a))
        #endif
    }

    static func hex(_ color: Color, in env: EnvironmentValues) -> String {
        let r = color.resolve(in: env)
        return ShellColorToken.hex(Double(r.red), Double(r.green), Double(r.blue), Double(r.opacity))
    }
}
