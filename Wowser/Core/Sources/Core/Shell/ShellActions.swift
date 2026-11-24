import Foundation
import Combine
import WebKit
#if os(macOS)
import AppKit
#else
import UIKit
#endif

/// The write side of the shell API: `host.call(name, args)` from JS lands
/// here and is mapped onto the same `BrowserState` / `BrowserStore`
/// operations the built-in UI uses. Names and argument shapes are documented
/// in wowser.d.ts (`tabs.close(id)` → `"tabs.close"` + `{tabId}`).
///
/// Keep this a thin mapping. Behaviour belongs in `BrowserState` extensions so
/// native UI and scripted UI can't drift apart.
enum ShellActions {
    // MARK: Argument helpers

    private struct Args {
        let json: ShellJSON
        func string(_ key: String) -> String? { json[key]?.string }
        func bool(_ key: String) -> Bool? { json[key]?.bool }
        func double(_ key: String) -> Double? { json[key]?.double }
        func int(_ key: String) -> Int? { json[key]?.int }
        func require(_ key: String) throws -> String {
            guard let value = json[key]?.string, !value.isEmpty else { throw ShellCallError("missing \"\(key)\"") }
            return value
        }
        func tab(_ key: String = "tabId") throws -> ID<Tab> { ID<Tab>(raw: try require(key)) }
        func pane(_ key: String = "paneId") throws -> ID<WebContent> { ID<WebContent>(raw: try require(key)) }
        func space(_ key: String = "spaceId") throws -> ID<Profile> { ID<Profile>(raw: try require(key)) }
        func optionalTab(_ key: String) -> ID<Tab>? { string(key).map { ID<Tab>(raw: $0) } }
    }

    private static func j(_ s: String?) -> ShellJSON {
        if let s { return .string(s) }
        return .null
    }

    private static func modify(_ block: @escaping (inout BrowserState) -> Void) {
        BrowserStore.shared.modify(block)
    }

    private static func webContent(_ pane: ID<WebContent>, _ engine: ShellEngine) -> WebContent? {
        BrowserStore.shared.getOrCreateWebContent(forId: pane, toBeActiveInWindow: engine.windowID)
    }

    /// A URL for what the user typed: a URL if it looks like one, else a search.
    static func url(forInput text: String) -> URL {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        return URL.withNaturalString(trimmed) ?? SearchEngine.current.urlForQuery(trimmed)
    }

    private static func load(_ url: URL, in pane: ID<WebContent>, engine: ShellEngine) {
        let windowID = engine.windowID
        modify { state in
            state.modifyPaneAndTab(forWebContentId: pane) { p, _ in
                p.info = WebContent.Info(url: url)
            }
            state.windows[windowID]?.searchOverlayActive = false
        }
        // State only seeds a web content that doesn't exist yet; an existing
        // one has to be told to navigate.
        DispatchQueue.main.async {
            BrowserStore.shared.getOrCreateWebContent(forId: pane, toBeActiveInWindow: windowID)?.load(url: url)
        }
    }

    /// Calls a headless check may make: they only read, or only touch the
    /// engine itself.
    static func isSafeInDryRun(_ name: String) -> Bool {
        switch name {
        case "search.suggest", "search.topSites", "tabs.visibleOrder", "tabs.recent", "settings.get", "storage.get",
             "commands.register", "commands.unregister", "commands.list", "events.listen", "shell.readFile", "shell.files",
             "shell.rootFailed", "mouse.location":
            return true
        default:
            return false
        }
    }

    // MARK: Synchronous calls

    static func perform(_ name: String, _ json: ShellJSON, engine: ShellEngine) throws -> ShellJSON? {
        let a = Args(json: json)
        let w = engine.windowID
        let model = BrowserStore.shared.model

        switch name {
        // ---------------------------------------------------------- tabs
        case "tabs.create":
            let url = a.string("url").map { Self.url(forInput: $0) }
            let activate = a.bool("activate") ?? true
            let id = BrowserStore.shared.createTab(withURL: url, in: w, activate: activate, inCurrentSplit: a.bool("inSplit") ?? false)
            if url == nil, activate {
                modify { $0.windows[w]?.searchOverlayActive = true }
            }
            return .string(id.raw)

        case "tabs.close":
            closeTab(tabID: try a.tab())
            return nil

        case "tabs.activate":
            let id = try a.tab()
            modify { state in
                state.activate(tabId: id, in: w)
                state.unghostTab(id: id)
            }
            return nil

        case "tabs.select":
            let id = try a.tab()
            let mods = json["modifiers"]
            let wantsSplit = mods?["alt"]?.bool == true || mods?["cmd"]?.bool == true || mods?["shift"]?.bool == true
            if model.tabs[id]?.isPip == true {
                modify { $0.togglePipOpen(tabId: id) }
            } else if wantsSplit, let current = model.windows[w]?.currentTab, current != id {
                modify { _ = $0.moveAllPanesToSplitView(sourceTabId: id, destinationTabId: current, activateLast: true) }
            } else {
                modify { state in
                    state.activate(tabId: id, in: w)
                    state.unghostTab(id: id)
                }
            }
            return nil

        case "tabs.move":
            let id = try a.tab()
            let before = a.optionalTab("before")
            let dest: TabDropDestination
            switch a.string("to") ?? "tabs" {
            case "pinned":
                guard let profile = model.windows[w]?.profile else { return .bool(false) }
                dest = .favorites(profile: profile, before: before)
            case "folder":
                dest = .folder(folderTab: try a.tab("folderId"), before: before, open: a.bool("open") ?? true)
            case "space":
                BrowserStore.shared.move(tab: id, toSpace: try a.space(), inWindow: w)
                return .bool(true)
            default:
                dest = .ordinaryTabs(window: w, before: before)
            }
            guard model.canMove(tab: id, to: dest) else { return .bool(false) }
            modify { $0.move(tab: id, to: dest, makeActiveInWindow: nil) }
            return .bool(true)

        case "tabs.rename":
            let id = try a.tab()
            let title = a.string("title")?.nilIfEmpty
            modify { $0.modifyTab(id: id) { $0.customTitle = title } }
            return nil

        case "tabs.setEmoji":
            let id = try a.tab()
            let emoji = a.string("emoji")?.trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty
            modify { $0.modifyTab(id: id) { $0.customEmoji = emoji } }
            return nil

        case "tabs.duplicate":
            let id = try a.tab()
            guard let url = model.tabs[id]?.focusedPane?.info.url else {
                return .string(BrowserStore.shared.createTab(withURL: nil, in: w).raw)
            }
            var newID: ID<Tab>?
            modify { newID = $0.openTab(url: url, activate: true, windowID: w).id }
            return j(newID?.raw)

        case "tabs.reopenClosed":
            guard let url = model.windows[w]?.lastClosedTabURL else { return nil }
            var newID: ID<Tab>?
            modify { newID = $0.openTab(url: url, activate: true, windowID: w).id }
            return j(newID?.raw)

        case "tabs.resetToPinnedURL":
            resetTabToBaseURL(tabID: try a.tab(), windowID: w)
            return nil

        case "tabs.splitWith":
            let source = try a.tab()
            let into = try a.tab("intoTabId")
            modify { _ = $0.moveAllPanesToSplitView(sourceTabId: source, destinationTabId: into, activateLast: true) }
            return nil

        case "tabs.separateSplit":
            let id = try a.tab()
            modify { _ = $0.separateSplitTabs(tabId: id) }
            return nil

        case "tabs.setPip":
            let id = try a.tab()
            let on = a.bool("on") ?? true
            modify { $0.setPipMode(on, tabId: id) }
            return nil

        case "tabs.closeAll":
            BrowserStore.shared.clearAllTabs(in: w)
            return nil

        case "tabs.visibleOrder":
            return .array(model.tabsInVisibleOrder(inWindow: w).map { .string($0.raw) })

        case "tabs.recent":
            return .array(model.tabsInRecencyOrder(inWindow: w, max: a.int("max") ?? 12).map { .string($0.raw) })

        // ---------------------------------------------------------- panes
        case "panes.load":
            load(url(forInput: try a.require("text")), in: try a.pane(), engine: engine)
            return nil

        case "panes.back":
            webContent(try a.pane(), engine)?.goBack()
            return nil

        case "panes.forward":
            webContent(try a.pane(), engine)?.goForward()
            return nil

        case "panes.reload":
            webContent(try a.pane(), engine)?.reload()
            return nil

        case "panes.stop":
            BrowserStore.shared.existingWebContent(forId: try a.pane())?.wkWebview?.stopLoading()
            return nil

        case "panes.close":
            BrowserStore.shared.close(webContentId: try a.pane(), removeIfPinned: false)
            return nil

        case "panes.focus":
            let id = try a.pane()
            modify { state in
                state.windows[w]?.shellFocusedInput = nil
                state.didFocus(target: .webContent(id))
            }
            return nil

        case "panes.zoom":
            #if os(macOS)
            let content = webContent(try a.pane(), engine)
            switch a.int("dir") ?? 0 {
            case 1: content?.zoomIn()
            case -1: content?.zoomOut()
            default: content?.resetZoom()
            }
            #endif
            return nil

        case "panes.find":
            let id = try a.pane()
            let open = a.bool("open") ?? true
            modify { state in
                if open { state.didFocus(target: .findInPage(id)) } else { state.didLoseFocus(target: .findInPage(id)) }
            }
            return nil

        case "panes.setWeights":
            let id = try a.tab()
            guard let left = a.int("leftIndex"), let lw = a.double("leftWeight"), let rw = a.double("rightWeight") else {
                throw ShellCallError("leftIndex, leftWeight and rightWeight are required")
            }
            modify { $0.setPaneWeights(tabId: id, leftPaneIdx: left, leftWeight: lw, rightWeight: rw) }
            return nil

        case "panes.watch":
            let id = engine.watchPage(paneID: try a.pane(), expression: try a.require("js"), throttleMs: a.int("throttleMs") ?? 100)
            return .string(id)

        case "panes.unwatch":
            engine.unwatchPage(try a.require("id"))
            return nil

        case "panes.copyURL":
            guard let url = model.pane(forId: try a.pane())?.info.url else { return nil }
            writeClipboard(url.absoluteString)
            modify { $0.addToast(message: "Copied link", icon: "link", in: w) }
            return nil

        case "panes.toggleBookmark":
            guard let info = model.pane(forId: try a.pane())?.info else { return nil }
            ArchiveStore.shared.toggleBookmark(url: info.url, title: info.title)
            return nil

        // ---------------------------------------------------------- spaces
        case "spaces.activate":
            let id = try a.space()
            guard model.profiles[id] != nil else { throw ShellCallError("no such space") }
            modify { state in
                state.windows[w]?.profile = id
                state.windows[w]?.showingNewProfilePage = nil
            }
            return nil

        case "spaces.create":
            let share = a.string("shareLoginsWith").map { ID<Profile>(raw: $0) }
            let title = a.string("title")?.nilIfEmpty
            var newID: ID<Profile>?
            modify { state in
                let id = state.createNewProfile(sharingLoginsWith: share)
                if let title { state.profiles[id]?.title = title }
                state.windows[w]?.profile = id
                state.windows[w]?.showingNewProfilePage = nil
                newID = id
            }
            return j(newID?.raw)

        case "spaces.rename":
            let id = try a.space()
            let title = a.string("title")?.nilIfEmpty
            modify { $0.profiles[id]?.title = title }
            return nil

        case "spaces.setEmoji":
            let id = try a.space()
            let emoji = a.string("emoji")?.nilIfEmpty
            modify { $0.profiles[id]?.emoji = emoji }
            return nil

        case "spaces.setTheme":
            let id = try a.space()
            var theme: SpaceTheme?
            if let hue = json["theme"]?["hue"]?.double {
                let h = hue.truncatingRemainder(dividingBy: 360)
                let secondary = json["theme"]?["secondaryHue"]?.double ?? (h + 22).truncatingRemainder(dividingBy: 360)
                theme = SpaceTheme(hue: h, secondaryHue: secondary)
            }
            modify { $0.profiles[id]?.theme = theme }
            return nil

        case "spaces.move":
            let id = try a.space()
            let before = try a.space("before")
            modify { $0.moveProfile(id, toPositionOf: before) }
            return nil

        case "spaces.hide":
            let id = try a.space()
            modify { $0.hideProfile(id) }
            return nil

        case "spaces.delete":
            let id = try a.space()
            modify { $0.deleteProfile(id) }
            return nil

        case "spaces.showNewSpacePage":
            modify { $0.windows[w]?.showingNewProfilePage = true }
            return nil

        // ---------------------------------------------------------- folders
        case "folders.create":
            let name = try a.require("name")
            var newID: ID<Tab>?
            modify { newID = $0.createFolder(name: name, windowID: w) }
            return j(newID?.raw)

        case "folders.rename":
            let id = try a.tab("folderId")
            let name = try a.require("name")
            modify { $0.renameFolder(id: id, name: name) }
            return nil

        case "folders.delete":
            let id = try a.tab("folderId")
            modify { $0.deleteFolder(id: id, moveTabsToWindow: w) }
            return nil

        case "folders.addTab":
            let folder = try a.tab("folderId")
            let tab = try a.tab()
            let before = a.optionalTab("before")
            let open = a.bool("open") ?? true
            modify { $0.addTab(tab, toFolder: folder, before: before, open: open) }
            return nil

        case "folders.removeTab":
            let tab = try a.tab()
            modify { $0.removeTabFromFolder(tab) }
            return nil

        case "folders.putAway":
            BrowserStore.shared.putAwayFolder(id: try a.tab("folderId"))
            return nil

        // ---------------------------------------------------------- window
        case "window.setSidebar":
            let visible = a.bool("visible")
            modify { state in
                guard let current = state.windows[w]?.sidebarLocked else { return }
                state.windows[w]?.sidebarLocked = visible ?? !current
            }
            return nil

        case "window.new":
            modify { _ = $0.newWindow() }
            return nil

        case "window.close":
            #if os(macOS)
            engine.hostWindow?.performClose(nil)
            #endif
            return nil

        case "window.activate":
            // Bring the browser (and this window) to the front, e.g. from a
            // global hotkey or a floating panel.
            #if os(macOS)
            NSApp.activate(ignoringOtherApps: true)
            engine.hostWindow?.makeKeyAndOrderFront(nil)
            #endif
            return nil

        case "window.minimize":
            #if os(macOS)
            engine.hostWindow?.miniaturize(nil)
            #endif
            return nil

        case "window.zoom":
            #if os(macOS)
            engine.hostWindow?.zoom(nil)
            #endif
            return nil

        case "window.toggleFullscreen":
            #if os(macOS)
            engine.hostWindow?.toggleFullScreen(nil)
            #endif
            return nil

        case "window.configure":
            #if os(macOS)
            if let minWidth = a.double("minWidth"), let minHeight = a.double("minHeight") {
                engine.hostWindow?.minSize = NSSize(width: minWidth, height: minHeight)
            }
            #endif
            return nil

        // ---------------------------------------------------------- command bar
        case "commandBar.set":
            let open = a.bool("open") ?? true
            let prefill = a.bool("prefillURL") ?? false
            modify { state in
                state.windows[w]?.omniboxPrefillsURL = (open && prefill) ? true : nil
                state.windows[w]?.searchOverlayActive = open
            }
            return nil

        // ---------------------------------------------------------- search
        case "search.suggest":
            let query = a.string("query") ?? ""
            let limit = a.int("limit") ?? 6
            let list = MainActor.assumeIsolated { engine.search.suggest(query: query, limit: limit, windowID: w) }
            return .array(list)

        case "search.topSites":
            let limit = a.int("limit") ?? 8
            let list = MainActor.assumeIsolated { engine.search.topSites(limit: limit, windowID: w) }
            return .array(list)

        case "search.open":
            let id = try a.require("id")
            let newTab = a.bool("newTab") ?? false
            let found = MainActor.assumeIsolated { engine.search.open(id: id, windowID: w, newTab: newTab) }
            guard found else { throw ShellCallError("That suggestion is no longer available; call search.suggest again.") }
            modify { $0.windows[w]?.searchOverlayActive = false }
            return nil

        case "search.go":
            let text = try a.require("text")
            let newTab = a.bool("newTab") ?? false
            let target = url(forInput: text)
            if !newTab, let pane = model.currentPane(forWindow: w) {
                load(target, in: pane.id, engine: engine)
            } else {
                modify { state in
                    _ = state.openTab(url: target, activate: true, windowID: w)
                    state.windows[w]?.searchOverlayActive = false
                }
            }
            return nil

        // ---------------------------------------------------------- toasts
        case "toasts.show":
            var toast = Toast(message: try a.require("message"), icon: a.string("icon") ?? "info.circle")
            toast.title = a.string("title")
            if a.bool("sticky") == true { toast.sticky = true }
            let id = toast.id
            modify { $0.addToast(toast, in: w) }
            return .string(id.uuidString)

        case "toasts.dismiss":
            if let raw = a.string("id"), let id = UUID(uuidString: raw) {
                modify { $0.removeToast(id: id, in: w) }
            } else {
                modify { $0.removeFirstToast(in: w) }
            }
            return nil

        case "toasts.performAction":
            guard let id = UUID(uuidString: try a.require("id")),
                  let toast = model.windows[w]?.toasts.first(where: { $0.id == id }),
                  let index = a.int("index"), let action = toast.actions?.get(index)
            else { return nil }
            action.kind.perform()
            modify { $0.removeToast(id: id, in: w) }
            return nil

        // ---------------------------------------------------------- settings / storage
        case "settings.get":
            return ShellSlices.setting(a.string("key") ?? "")

        case "settings.set":
            let name = try a.require("key")
            guard let key = ShellSlices.settingKey(name) else { throw ShellCallError("\"\(name)\" is not a setting scripts can change") }
            switch json["value"] ?? .null {
            case .bool(let b): UserDefaults.standard.set(b, forKey: key.rawValue)
            case .number(let n): UserDefaults.standard.set(n, forKey: key.rawValue)
            case .string(let s): UserDefaults.standard.set(s, forKey: key.rawValue)
            case .null: UserDefaults.standard.removeObject(forKey: key.rawValue)
            default: throw ShellCallError("settings hold booleans, numbers and strings")
            }
            return nil

        case "storage.get":
            return engine.store.storageValue(branch: engine.branch, key: try a.require("key"))

        case "storage.set":
            engine.store.setStorageValue(branch: engine.branch, key: try a.require("key"), value: json["value"])
            return nil

        case "clipboard.write":
            writeClipboard(a.string("text") ?? "")
            return nil

        case "clipboard.read":
            return .string(readClipboard())

        // ---------------------------------------------------------- commands / events
        case "commands.register":
            engine.registerCommand(ShellCommand(
                id: try a.require("id"),
                title: a.string("title") ?? "",
                icon: a.string("icon"),
                hotkey: a.string("hotkey"),
                keywords: json["keywords"]?.array?.compactMap(\.string) ?? [],
                global: a.bool("global") ?? false
            ))
            return nil

        case "commands.unregister":
            engine.unregisterCommand(try a.require("id"))
            return nil

        case "commands.list":
            var list: [ShellJSON] = []
            for command in engine.commands.values.sorted(by: { $0.id < $1.id }) {
                list.append(["id": .string(command.id), "title": .string(command.title), "hotkey": j(command.hotkey)])
            }
            for command in builtinCommands {
                list.append(["id": .string("builtin:" + command.id), "title": .string(command.title), "hotkey": j(command.hotkey)])
            }
            return .array(list)

        case "commands.run":
            let id = try a.require("id")
            if id.hasPrefix("builtin:") {
                try runBuiltin(String(id.dropFirst("builtin:".count)), engine: engine)
            } else if !engine.runCommand(id) {
                throw ShellCallError("no command \"\(id)\"")
            }
            return nil

        case "events.listen":
            engine.setListening(try a.require("name"), a.bool("on") ?? true)
            return nil

        // ---------------------------------------------------------- misc
        case "haptics.tap":
            #if os(macOS)
            NSHapticFeedbackManager.defaultPerformer.perform(.generic, performanceTime: .now)
            #else
            Haptics.shared.performSelectionHaptic()
            #endif
            return nil

        case "mouse.location":
            // Screen coordinates, top-left origin, plus the same point in the window.
            #if os(macOS)
            let point = ShellScreen.topLeft(NSEvent.mouseLocation)
            return [
                "screenX": .number(Double(point.x)), "screenY": .number(Double(point.y)),
                "x": .number(Double(engine.mouse.x)), "y": .number(Double(engine.mouse.y)), "inside": .bool(engine.mouseInside),
                "buttons": .number(Double(NSEvent.pressedMouseButtons)),
            ]
            #else
            return ["screenX": 0, "screenY": 0, "x": 0, "y": 0, "inside": false, "buttons": 0]
            #endif

        case "shell.files":
            return .array(engine.store.files(in: engine.branch).map { .string($0) })

        case "shell.reload":
            engine.scheduleReload()
            return nil

        case "shell.readFile":
            return j(engine.store.read(branch: engine.branch, path: try a.require("path")))

        case "shell.openSettings":
            SettingsTab.shell.open()
            return nil

        case "shell.rootFailed":
            engine.rootDidFail(
                message: a.string("message") ?? "The UI failed to render.",
                stack: a.string("stack") ?? "",
                componentStack: json["componentStack"]?.array?.compactMap(\.string) ?? []
            )
            return nil

        default:
            throw ShellCallError("unknown call \"\(name)\"")
        }
    }

    // MARK: Built-in commands

    struct BuiltinCommand {
        var id: String
        var title: String
        var hotkey: String?
    }

    /// Browser actions a branch can trigger by id (`commands.run("builtin:reload")`)
    /// without knowing which pane or tab is current.
    static let builtinCommands: [BuiltinCommand] = [
        .init(id: "newTab", title: "New Tab", hotkey: "cmd+t"),
        .init(id: "closeTab", title: "Close Tab", hotkey: "cmd+w"),
        .init(id: "reopenClosedTab", title: "Reopen Last Closed Tab", hotkey: "cmd+shift+t"),
        .init(id: "newWindow", title: "New Window", hotkey: "cmd+n"),
        .init(id: "openCommandBar", title: "Edit URL", hotkey: "cmd+l"),
        .init(id: "toggleSidebar", title: "Toggle Sidebar", hotkey: nil),
        .init(id: "back", title: "Back", hotkey: "cmd+["),
        .init(id: "forward", title: "Forward", hotkey: "cmd+]"),
        .init(id: "reload", title: "Reload", hotkey: "cmd+r"),
        .init(id: "findInPage", title: "Find in Page", hotkey: "cmd+f"),
        .init(id: "zoomIn", title: "Zoom In", hotkey: "cmd+="),
        .init(id: "zoomOut", title: "Zoom Out", hotkey: "cmd+-"),
        .init(id: "resetZoom", title: "Actual Size", hotkey: "cmd+0"),
        .init(id: "copyURL", title: "Copy Current URL", hotkey: "cmd+shift+c"),
        .init(id: "nextTab", title: "Next Tab", hotkey: nil),
        .init(id: "previousTab", title: "Previous Tab", hotkey: nil),
        .init(id: "clearTabs", title: "Clear All Tabs", hotkey: "cmd+shift+k"),
    ]

    private static func runBuiltin(_ id: String, engine: ShellEngine) throws {
        let w = engine.windowID
        let model = BrowserStore.shared.model
        let pane = model.currentPane(forWindow: w)?.id
        func paneArgs() throws -> ShellJSON {
            guard let pane else { throw ShellCallError("no current page") }
            return ["paneId": .string(pane.raw)]
        }
        switch id {
        case "newTab": _ = try perform("tabs.create", [:], engine: engine)
        case "closeTab":
            if let tab = model.windows[w]?.currentTab { _ = try perform("tabs.close", ["tabId": .string(tab.raw)], engine: engine) }
        case "reopenClosedTab": _ = try perform("tabs.reopenClosed", [:], engine: engine)
        case "newWindow": _ = try perform("window.new", [:], engine: engine)
        case "openCommandBar": _ = try perform("commandBar.set", ["open": true, "prefillURL": true], engine: engine)
        case "toggleSidebar": _ = try perform("window.setSidebar", [:], engine: engine)
        case "back": _ = try perform("panes.back", try paneArgs(), engine: engine)
        case "forward": _ = try perform("panes.forward", try paneArgs(), engine: engine)
        case "reload": _ = try perform("panes.reload", try paneArgs(), engine: engine)
        case "findInPage": _ = try perform("panes.find", try paneArgs(), engine: engine)
        case "copyURL": _ = try perform("panes.copyURL", try paneArgs(), engine: engine)
        case "zoomIn", "zoomOut", "resetZoom":
            guard let pane else { return }
            let dir: Double = id == "zoomIn" ? 1 : (id == "zoomOut" ? -1 : 0)
            _ = try perform("panes.zoom", ["paneId": .string(pane.raw), "dir": .number(dir)], engine: engine)
        case "nextTab", "previousTab":
            let order = model.tabsInVisibleOrder(inWindow: w)
            guard !order.isEmpty else { return }
            let current = model.windows[w]?.currentTab.flatMap { order.firstIndex(of: $0) } ?? 0
            let next = order[(current + (id == "nextTab" ? 1 : order.count - 1)) % order.count]
            _ = try perform("tabs.activate", ["tabId": .string(next.raw)], engine: engine)
        case "clearTabs": _ = try perform("tabs.closeAll", [:], engine: engine)
        default: throw ShellCallError("no built-in command \"\(id)\"")
        }
    }

    // MARK: Asynchronous calls

    @MainActor
    static func performAsync(_ name: String, _ json: ShellJSON, engine: ShellEngine) async throws -> ShellJSON? {
        let a = Args(json: json)
        switch name {
        case "search.suggestMore":
            let list = await engine.search.suggestMore(query: a.string("query") ?? "", limit: a.int("limit") ?? 6, windowID: engine.windowID)
            return .array(list)

        case "panes.eval":
            let pane = try a.pane()
            let js = try a.require("js")
            guard let webView = BrowserStore.shared.getOrCreateWebContent(forId: pane, toBeActiveInWindow: engine.windowID)?.wkWebview else {
                throw ShellCallError("That pane has no web view to evaluate in.")
            }
            // The completion-handler form, as BrowserJS uses it.
            let value: Any? = try await withCheckedThrowingContinuation { (done: CheckedContinuation<Any?, Error>) in
                webView.callAsyncJavaScript("return (async () => { return eval(__code); })()", arguments: ["__code": js], in: nil, in: .defaultClient) { result in
                    switch result {
                    case .success(let value): done.resume(returning: value)
                    case .failure(let error): done.resume(throwing: error)
                    }
                }
            }
            guard let value, JSONSerialization.isValidJSONObject([value]) else { return nil }
            return ShellJSON(any: value)

        case "panes.setInjection":
            // Same persistent per-host store Clean Mode and `browser.inject` use.
            var args: [String: Any] = ["host": try a.require("host")]
            if let css = a.string("css") { args["css"] = css }
            if let js = a.string("js") { args["js"] = js }
            let data = try JSONSerialization.data(withJSONObject: args)
            _ = try await BrowserJSDispatch.handle(fn: "inject.set", argsJSON: String(data: data, encoding: .utf8) ?? "{}", host: BrowserJSLiveHost.shared)
            return nil

        case "menus.show":
            #if os(macOS)
            let items = json["items"]?.array ?? []
            var at: CGPoint?
            if let x = json["at"]?["x"]?.double, let y = json["at"]?["y"]?.double { at = CGPoint(x: x, y: y) }
            return j(ShellMenus.popUp(items: items, at: at, in: engine.hostWindow))
            #else
            return nil
            #endif

        case "bjs":
            // The agent-facing BrowserJS API, called from UI code.
            let fn = try a.require("fn")
            let argsJSON = (json["args"] ?? [:]).jsonString()
            let out = try await BrowserJSDispatch.handle(fn: fn, argsJSON: argsJSON, host: BrowserJSLiveHost.shared)
            return out.flatMap { ShellJSON.parse($0) }

        default:
            throw ShellCallError("unknown async call \"\(name)\"")
        }
    }

    // MARK: Clipboard

    static func writeClipboard(_ text: String) {
        #if os(macOS)
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
        #else
        UIPasteboard.general.string = text
        #endif
    }

    static func readClipboard() -> String {
        #if os(macOS)
        return NSPasteboard.general.string(forType: .string) ?? ""
        #else
        return UIPasteboard.general.string ?? ""
        #endif
    }
}

/// Command-bar suggestions for scripted UIs, backed by the same `Searcher`
/// the native omnibox uses.
///
/// The split mirrors the native one: `suggest` is the synchronous fast path
/// (typed URL, open tabs, top history, actions) and runs on every keystroke;
/// `suggestMore` is the slow path (full history scan, search-engine
/// completions).
final class ShellSearch {
    // Main thread only; the methods are @MainActor and nothing else touches these.
    private var searcher: Searcher?
    private var topSitesFetcher: TopSitesFetcher?
    private var topSitesSink: AnyCancellable?
    private var dataStoreID: UUID?
    /// Results handed to JS recently, by id, so `search.open(id)` can run them.
    private var handedOut: [String: SearchResult] = [:]
    private var lastQuery = ""
    private var lastFast: [SearchResult] = []

    init() {}

    @MainActor
    private func ensure(windowID: ID<WindowState>) -> Searcher {
        if let searcher { return searcher }
        let s = Searcher(windowID: windowID)
        s.topSitesEnabled = true
        let fetcher = TopSitesFetcher()
        topSitesSink = fetcher.$topSites.sink { [weak s] sites in s?.topSites = sites }
        searcher = s
        topSitesFetcher = fetcher
        return s
    }

    /// Follow the window's current space: history and top sites are per data store.
    @MainActor
    func update(state: BrowserState, windowID: ID<WindowState>) {
        guard let searcher else { return }
        let id = state.windows[windowID].flatMap { state.profiles[$0.profile]?.dataStoreUUID }
        if id != dataStoreID {
            dataStoreID = id
            searcher.datastoreProfileID = id
            topSitesFetcher?.profileDataStoreID = id
        }
    }

    @MainActor
    private func prepared(windowID: ID<WindowState>, limit: Int) -> Searcher {
        let s = ensure(windowID: windowID)
        s.n = max(1, min(limit, 20))
        if dataStoreID == nil { update(state: BrowserStore.shared.model, windowID: windowID) }
        return s
    }

    @MainActor
    private func finish(_ results: [SearchResult], query: String, searcher s: Searcher) -> [ShellJSON] {
        let trimmed = Array(results.deduplicate({ $0.item.dedupeKey }).prefix(s.n))
        let final = query.isEmpty ? trimmed : s.reservingSlotsForLowPriorityActions(s.ensuringAskAgentResult(trimmed, query: query), query: query)
        if handedOut.count > 400 { handedOut.removeAll(keepingCapacity: true) }
        return final.enumerated().map { index, result in
            handedOut[result.id] = result
            return Self.json(result, isTopHit: index == 0 && result.matchQuality == .prefixMatchURL)
        }
    }

    @MainActor
    func suggest(query: String, limit: Int, windowID: ID<WindowState>) -> [ShellJSON] {
        let s = prepared(windowID: windowID, limit: limit)
        if query.isEmpty {
            // The searcher keeps the empty-query list (folder actions + top sites).
            if s.query.isEmpty { s.refreshForEmptyQuery() } else { s.query = "" }
            lastQuery = ""
            lastFast = []
            return finish(s.results, query: "", searcher: s)
        }
        let previous = query.hasPrefix(lastQuery) && !lastQuery.isEmpty ? lastFast : []
        var fast = s.fastPathSearch(query: query, prevResults: previous)
        // Keep rows the user was already looking at until the slow path replaces them.
        for old in previous.dropFirst(fast.count) { fast.append(old) }
        lastQuery = query
        lastFast = fast
        return finish(fast, query: query, searcher: s)
    }

    @MainActor
    func suggestMore(query: String, limit: Int, windowID: ID<WindowState>) async -> [ShellJSON] {
        guard !query.isEmpty else { return [] }
        let s = prepared(windowID: windowID, limit: limit)
        let fast = s.fastPathSearch(query: query, prevResults: [])
        let slow = await s.slowPathSearch(query: query, fastPath: fast)
        return finish(slow, query: query, searcher: s)
    }

    @MainActor
    func topSites(limit: Int, windowID: ID<WindowState>) -> [ShellJSON] {
        let s = prepared(windowID: windowID, limit: limit)
        return finish(s.topSites.map(\.asSearchResult), query: "", searcher: s)
    }

    @MainActor
    func open(id: String, windowID: ID<WindowState>, newTab: Bool) -> Bool {
        guard let result = handedOut[id] else { return false }
        BrowserStore.shared.select(result: result, windowID: windowID, forceNewTab: newTab)
        return true
    }

    private static func symbol(_ name: String) -> ShellJSON {
        ["kind": "symbol", "name": .string(name)]
    }

    private static func favicon(_ page: URL, src: URL? = nil) -> ShellJSON {
        if NativePageKey(url: page) != nil { return ["kind": "native"] }
        return ["kind": "favicon", "url": .string(page.absoluteString), "src": .string((src ?? page.inferredFaviconURL).absoluteString)]
    }

    private static func json(_ result: SearchResult, isTopHit: Bool) -> ShellJSON {
        let item = result.item
        let display = item.displayTitleSubtitle
        var kind = "search"
        var url: URL?
        var tabID: String?
        var icon = symbol("magnifyingglass")
        switch item.content {
        case .urlYouTyped(let u):
            kind = "url"
            url = u
            icon = favicon(u)
        case .historyItem(let h):
            kind = "history"
            url = h.url
            icon = favicon(h.url)
        case .tab(let id, let info):
            kind = "tab"
            url = info.url
            tabID = id.raw
            if let u = info.url { icon = favicon(u, src: info.favicon) } else { icon = ["kind": "native"] }
        case .searchWhatYouTyped:
            kind = "search"
        case .searchSuggestion:
            kind = "suggestion"
        case .imFeelingLucky:
            kind = "lucky"
            icon = symbol("arrow.forward.circle.fill")
        case .chatbot, .askAgent:
            kind = "agent"
            icon = symbol("sparkles")
        case .searchAction:
            kind = "action"
            icon = symbol("arrow.right.circle.fill")
        case .terminalCommand:
            kind = "terminal"
            icon = symbol("terminal")
        }
        let subtitle: ShellJSON = display.subtitle.map { ShellJSON.string($0) } ?? .null
        let urlJSON: ShellJSON = url.map { ShellJSON.string($0.absoluteString) } ?? .null
        let tabJSON: ShellJSON = tabID.map { ShellJSON.string($0) } ?? .null
        return [
            "id": .string(result.id),
            "kind": .string(kind),
            "title": .string(display.title ?? ""),
            "subtitle": subtitle,
            "url": urlJSON,
            "tabId": tabJSON,
            "icon": icon,
            "isTopHit": .bool(isTopHit),
        ]
    }
}
