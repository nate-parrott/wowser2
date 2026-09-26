import Foundation

// Shared dispatch core for the `browser.*` API surface.
//
// Both entry points route through here so there is exactly ONE implementation
// of the API:
//   1. The privileged JSContext runtime (`BrowserJSRuntime`), driven by the
//      `run_browser_js` MCP tool.
//   2. The web bridge (`TangBridge`), which exposes `window.browser` to
//      tang:// webapp pages.
//
// `handle` takes a method name + JSON-encoded args and returns a
// JSON-stringified result (or nil for void), calling into the supplied host.
enum BrowserJSDispatch {
    static func handle(fn: String, argsJSON: String, host: any BrowserJSHost) async throws -> String? {
        let data = argsJSON.data(using: .utf8) ?? Data()
        let raw = (try? JSONSerialization.jsonObject(with: data, options: [.fragmentsAllowed])) as? [String: Any] ?? [:]
        // The originating terminal pane rides along on every call from the
        // runtime (see BrowserJSCallOrigin). Bind it for the host call so
        // window/space selection can prefer where the caller lives.
        let origin = (raw[BrowserJSCallOrigin.argsKey] as? String).map { ID<WebContent>(raw: $0) }
        let originSpace = (raw[BrowserJSCallOrigin.argsSpaceKey] as? String).map { ID<Profile>(raw: $0) }
        return try await BrowserJSCallOrigin.$paneID.withValue(origin) {
            try await BrowserJSCallOrigin.$spaceID.withValue(originSpace) {
                try await handleUnscoped(fn: fn, raw: raw, host: host)
            }
        }
    }

    private static func handleUnscoped(fn: String, raw: [String: Any], host: any BrowserJSHost) async throws -> String? {

        func str(_ k: String) -> String? { raw[k] as? String }
        func optStr(_ k: String) -> String? { raw[k] as? String }
        func bool(_ k: String, _ d: Bool = false) -> Bool { (raw[k] as? Bool) ?? d }
        func int(_ k: String) -> Int? { (raw[k] as? Int) ?? (raw[k] as? Double).map(Int.init) }

        func encodeValue<T: Encodable>(_ v: T) throws -> String? {
            let data = try JSONEncoder().encode(v)
            return String(data: data, encoding: .utf8)
        }
        func encodeAny(_ any: Any?) throws -> String? {
            guard let any else { return nil }
            if let str = any as? String, !JSONSerialization.isValidJSONObject([str]) {
                // primitive — wrap and unwrap
                let arr = try JSONSerialization.data(withJSONObject: [str])
                return String(data: arr, encoding: .utf8).flatMap { String($0.dropFirst().dropLast()) }
            }
            let data: Data
            if JSONSerialization.isValidJSONObject(any) {
                data = try JSONSerialization.data(withJSONObject: any, options: [.fragmentsAllowed])
            } else {
                data = try JSONSerialization.data(withJSONObject: [any], options: [.fragmentsAllowed])
                let s = String(data: data, encoding: .utf8) ?? "[]"
                // strip outer brackets
                return String(s.dropFirst().dropLast())
            }
            return String(data: data, encoding: .utf8)
        }

        switch fn {
        case "tabs.list":
            let info = try await host.tabsList(windowId: optStr("windowId"), spaceId: optStr("spaceId"))
            return try encodeValue(info)
        case "tabs.open":
            guard let url = str("url") else { throw BrowserJSError.invalidArgs("url") }
            let id = try await host.tabsOpen(url: url, background: bool("background"), windowId: optStr("windowId"))
            return try encodeValue(id)
        case "tabs.openSplit":
            guard let url = str("url") else { throw BrowserJSError.invalidArgs("url") }
            let id = try await host.tabsOpenSplit(url: url, besideTabId: optStr("besideTabId"), activate: bool("activate", true), windowId: optStr("windowId"))
            return try encodeValue(id)
        case "tabs.openGhost":
            guard let url = str("url") else { throw BrowserJSError.invalidArgs("url") }
            let id = try await host.tabsOpenGhost(url: url, windowId: optStr("windowId"))
            return try encodeValue(id)
        case "tabs.use":
            guard let id = str("id") else { throw BrowserJSError.invalidArgs("id") }
            let until = try await host.tabsUse(id: id, minutes: raw["minutes"] as? Double)
            return try encodeValue(until)
        case "tabs.openHTML":
            guard let html = str("html") else { throw BrowserJSError.invalidArgs("html") }
            let id = try await host.tabsOpenHTML(html: html, title: optStr("title"), windowId: optStr("windowId"))
            return try encodeValue(id)
        case "tabs.close":
            guard let id = str("id") else { throw BrowserJSError.invalidArgs("id") }
            try await host.tabsClose(id: id)
            return nil
        case "tabs.activate":
            guard let id = str("id") else { throw BrowserJSError.invalidArgs("id") }
            try await host.tabsActivate(id: id)
            return nil
        case "tabs.move":
            guard let id = str("id"), let idx = int("toIndex") else { throw BrowserJSError.invalidArgs("id, toIndex") }
            try await host.tabsMove(id: id, toIndex: idx)
            return nil
        case "tabs.get":
            guard let id = str("id") else { throw BrowserJSError.invalidArgs("id") }
            let info = try await host.tabsGet(id: id)
            return try encodeValue(info)
        case "tabs.navigate":
            guard let id = str("id"), let url = str("url") else { throw BrowserJSError.invalidArgs("id, url") }
            try await host.tabsNavigate(id: id, url: url)
            return nil
        case "content.read":
            guard let id = str("id") else { throw BrowserJSError.invalidArgs("id") }
            let kind = optStr("as") ?? "text"
            let result = try await host.contentRead(id: id, as: kind)
            return try encodeValue(result)
        case "content.screenshot":
            guard let id = str("id") else { throw BrowserJSError.invalidArgs("id") }
            let result = try await host.contentScreenshot(id: id)
            return try encodeValue(result)
        case "page.eval":
            guard let id = str("id"), let js = str("js") else { throw BrowserJSError.invalidArgs("id, js") }
            let result = try await host.pageEval(id: id, js: js)
            return try encodeAny(result)
        case "page.waitFor":
            guard let id = str("id"), let predicateJs = str("predicateJs") else { throw BrowserJSError.invalidArgs("id, predicateJs") }
            let timeoutMs = int("timeoutMs") ?? 30_000
            let result = try await host.pageWaitFor(id: id, predicateJs: predicateJs, timeoutMs: timeoutMs)
            return try encodeAny(result)
        case "page.click":
            guard let id = str("id") else { throw BrowserJSError.invalidArgs("id") }
            let x = (raw["x"] as? Double) ?? Double(raw["x"] as? Int ?? 0)
            let y = (raw["y"] as? Double) ?? Double(raw["y"] as? Int ?? 0)
            let button = optStr("button") ?? "left"
            let clickCount = int("clickCount") ?? 1
            try await host.pageClick(id: id, x: x, y: y, button: button, clickCount: clickCount)
            return nil
        case "page.type":
            guard let id = str("id"), let text = str("text") else { throw BrowserJSError.invalidArgs("id, text") }
            try await host.pageType(id: id, text: text)
            return nil
        case "page.key":
            guard let id = str("id"), let key = str("key") else { throw BrowserJSError.invalidArgs("id, key") }
            let mods = (raw["modifiers"] as? [String]) ?? []
            try await host.pageKey(id: id, key: key, modifiers: mods)
            return nil
        case "page.scroll":
            guard let id = str("id") else { throw BrowserJSError.invalidArgs("id") }
            let dx = (raw["dx"] as? Double) ?? Double(raw["dx"] as? Int ?? 0)
            let dy = (raw["dy"] as? Double) ?? Double(raw["dy"] as? Int ?? 0)
            try await host.pageScroll(id: id, dx: dx, dy: dy)
            return nil
        case "windows.list":
            let info = try await host.windowsList()
            return try encodeValue(info)
        case "windows.getCurrent":
            let info = try await host.windowsGetCurrent()
            return try encodeValue(info)
        case "windows.getById":
            guard let id = str("id") else { throw BrowserJSError.invalidArgs("id") }
            let info = try await host.windowsGetById(id: id)
            return try encodeValue(info)
        case "net.log":
            let filter = NetLogFilter(
                tabId: optStr("tabId"),
                urlRegex: optStr("urlRegex"),
                method: optStr("method"),
                since: raw["since"] as? Double ?? (raw["since"] as? Int).map(Double.init),
                limit: int("limit")
            )
            let entries = try await host.netLog(filter: filter)
            return try encodeValue(entries)
        case "net.grep":
            guard let pattern = str("pattern") else { throw BrowserJSError.invalidArgs("pattern") }
            let entries = try await host.netGrep(pattern: pattern, where: optStr("where") ?? "url")
            return try encodeValue(entries)
        case "net.fetch":
            let req = NetFetchRequest(
                url: str("url"),
                method: optStr("method"),
                headers: raw["headers"] as? [String: String],
                body: optStr("body"),
                cookiesFrom: optStr("cookiesFrom")
            )
            let resp = try await host.netFetch(req: req)
            return try encodeValue(resp)
        case "net.replay":
            guard let entryId = str("entryId") else { throw BrowserJSError.invalidArgs("entryId") }
            var overrides: NetFetchRequest? = nil
            if let dict = raw["overrides"] as? [String: Any] {
                overrides = NetFetchRequest(
                    url: dict["url"] as? String,
                    method: dict["method"] as? String,
                    headers: dict["headers"] as? [String: String],
                    body: dict["body"] as? String,
                    cookiesFrom: dict["cookiesFrom"] as? String
                )
            }
            let resp = try await host.netReplay(entryId: entryId, overrides: overrides)
            return try encodeValue(resp)
        case "net.captureOrigin":
            guard let origin = str("origin") else { throw BrowserJSError.invalidArgs("origin") }
            let enabled = bool("enabled", true)
            try await host.netCaptureOrigin(origin: origin, enabled: enabled)
            return nil
        case "splits.list":
            let info = try await host.splitsList(windowId: optStr("windowId"), spaceId: optStr("spaceId"))
            return try encodeValue(info)
        case "splits.get":
            guard let tabId = str("tabId") else { throw BrowserJSError.invalidArgs("tabId") }
            let info = try await host.splitsGet(tabId: tabId)
            return try encodeValue(info)
        case "splits.separate":
            guard let tabId = str("tabId") else { throw BrowserJSError.invalidArgs("tabId") }
            let ids = try await host.splitsSeparate(tabId: tabId)
            return try encodeValue(ids)

        case "spaces.list":
            let info = try await host.spacesList(windowId: optStr("windowId"), includeHidden: bool("includeHidden", false))
            return try encodeValue(info)
        case "spaces.getCurrent":
            let info = try await host.spacesGetCurrent(windowId: optStr("windowId"))
            return try encodeValue(info)
        case "spaces.activate":
            guard let spaceId = str("spaceId") else { throw BrowserJSError.invalidArgs("spaceId") }
            try await host.spacesActivate(spaceId: spaceId, windowId: optStr("windowId"))
            return nil
        case "spaces.setChatMode":
            guard let spaceId = str("spaceId") else { throw BrowserJSError.invalidArgs("spaceId") }
            try await host.spacesSetChatMode(spaceId: spaceId, enabled: bool("enabled", true))
            return nil

        case "folders.list":
            let info = try await host.foldersList(spaceId: optStr("spaceId"), windowId: optStr("windowId"))
            return try encodeValue(info)
        case "folders.get":
            guard let folderId = str("folderId") else { throw BrowserJSError.invalidArgs("folderId") }
            return try encodeValue(try await host.foldersGet(folderId: folderId))
        case "folders.create":
            guard let name = str("name") else { throw BrowserJSError.invalidArgs("name") }
            let id = try await host.foldersCreate(name: name, spaceId: optStr("spaceId"), windowId: optStr("windowId"))
            return try encodeValue(id)
        case "folders.rename":
            guard let folderId = str("folderId"), let name = str("name") else { throw BrowserJSError.invalidArgs("folderId, name") }
            try await host.foldersRename(folderId: folderId, name: name)
            return nil
        case "folders.delete":
            guard let folderId = str("folderId") else { throw BrowserJSError.invalidArgs("folderId") }
            try await host.foldersDelete(folderId: folderId, closeTabs: bool("closeTabs"), windowId: optStr("windowId"))
            return nil
        case "folders.addTab":
            guard let tabId = str("tabId"), let folderId = str("folderId") else { throw BrowserJSError.invalidArgs("tabId, folderId") }
            try await host.foldersAddTab(tabId: tabId, folderId: folderId, open: bool("open"))
            return nil
        case "folders.removeTab":
            guard let tabId = str("tabId") else { throw BrowserJSError.invalidArgs("tabId") }
            try await host.foldersRemoveTab(tabId: tabId)
            return nil

        case "webapp.create":
            guard let name = str("name") else { throw BrowserJSError.invalidArgs("name") }
            let files = (raw["files"] as? [String: Any])?.compactMapValues { $0 as? String } ?? [:]
            let id = try await host.webappCreate(name: name, files: files, exposeBrowserJS: bool("exposeBrowserJS", true))
            return try encodeValue(id)
        case "agent.create":
            let options = BrowserJSAgentCreateOptions(
                key: optStr("key"),
                name: optStr("name"),
                model: optStr("model"),
                effort: optStr("effort"),
                systemPrompt: optStr("systemPrompt"),
                exposeBrowserJS: bool("exposeBrowserJS", true),
                fileSystemTools: bool("fileSystemTools", false),
                workingDirectory: optStr("workingDirectory"),
                tools: ((raw["tools"] as? [[String: Any]]) ?? []).compactMap { dict in
                    guard let name = dict["name"] as? String else { return nil }
                    let schema = dict["inputSchema"] ?? ["type": "object"]
                    let schemaJSON = (try? JSONSerialization.data(withJSONObject: schema))
                        .flatMap { String(data: $0, encoding: .utf8) } ?? #"{"type":"object"}"#
                    return BrowserJSAgentToolSpec(
                        name: name,
                        description: dict["description"] as? String ?? "",
                        inputSchemaJSON: schemaJSON
                    )
                }
            )
            let id = try await host.agentCreate(options: options)
            return try encodeValue(id)
        case "agent.send":
            guard let id = str("id"), let text = str("text") else { throw BrowserJSError.invalidArgs("id, text") }
            let images: [BrowserJSImage] = ((raw["images"] as? [[String: Any]]) ?? []).compactMap { dict in
                guard let data = dict["data"] as? String, !data.isEmpty else { return nil }
                return BrowserJSImage(mime: dict["mime"] as? String ?? "image/png", data: data)
            }
            try await host.agentSend(id: id, text: text, images: images)
            return nil
        case "agent.await":
            guard let id = str("id") else { throw BrowserJSError.invalidArgs("id") }
            let result = try await host.agentAwait(id: id, timeoutMs: int("timeoutMs") ?? 30_000, since: int("since"))
            return try encodeValue(result)
        case "agent.messages":
            guard let id = str("id") else { throw BrowserJSError.invalidArgs("id") }
            let messages = try await host.agentMessages(id: id, since: int("since") ?? 0)
            return try encodeValue(messages)
        case "agent.respondTool":
            guard let callId = str("callId") else { throw BrowserJSError.invalidArgs("callId") }
            // `result` may be any JSON value; stringify non-strings for the agent.
            let text: String
            if let s = raw["result"] as? String {
                text = s
            } else if let value = raw["result"], let encoded = try encodeAny(value) {
                text = encoded
            } else {
                text = ""
            }
            try await host.agentRespondTool(callId: callId, text: text, isError: bool("isError", false))
            return nil
        case "agent.list":
            let info = try await host.agentList()
            return try encodeValue(info)
        case "agent.interrupt":
            guard let id = str("id") else { throw BrowserJSError.invalidArgs("id") }
            try await host.agentInterrupt(id: id)
            return nil
        case "agent.dispose":
            guard let id = str("id") else { throw BrowserJSError.invalidArgs("id") }
            try await host.agentDispose(id: id)
            return nil

        case "fs.read":
            guard let path = str("path") else { throw BrowserJSError.invalidArgs("path") }
            let result = try await host.fsRead(path: path, encoding: optStr("encoding") ?? "utf8")
            return try encodeValue(result)
        case "fs.write":
            guard let path = str("path"), let data = str("data") else { throw BrowserJSError.invalidArgs("path, data") }
            try await host.fsWrite(path: path, data: data, encoding: optStr("encoding") ?? "utf8", append: bool("append"))
            return nil
        case "fs.list":
            guard let path = str("path") else { throw BrowserJSError.invalidArgs("path") }
            return try encodeValue(try await host.fsList(path: path))
        case "fs.stat":
            guard let path = str("path") else { throw BrowserJSError.invalidArgs("path") }
            return try encodeValue(try await host.fsStat(path: path))
        case "fs.remove":
            guard let path = str("path") else { throw BrowserJSError.invalidArgs("path") }
            try await host.fsRemove(path: path)
            return nil
        case "fs.mkdir":
            guard let path = str("path") else { throw BrowserJSError.invalidArgs("path") }
            try await host.fsMkdir(path: path)
            return nil

        case "chat.present":
            let id = try await host.chatPresent(agentKey: optStr("agentKey"), tabId: optStr("tabId"), url: optStr("url"), show: optStr("show") ?? "card", note: optStr("note"))
            return try encodeValue(["tabId": id])
        case "agents.spawn":
            guard let task = str("task") else { throw BrowserJSError.invalidArgs("task") }
            let info = try await host.agentsSpawn(agentKey: optStr("agentKey"), task: task, name: optStr("name"), model: optStr("model"), effort: optStr("effort"), fileSystemTools: bool("fileSystemTools"), workingDirectory: optStr("workingDirectory"), show: optStr("show") ?? "card")
            return try encodeValue(info)
        case "agents.send":
            guard let key = str("key"), let text = str("text") else { throw BrowserJSError.invalidArgs("key, text") }
            try await host.agentsSend(agentKey: optStr("agentKey"), toKey: key, text: text)
            return nil
        case "agents.list":
            return try encodeValue(try await host.agentsList(agentKey: optStr("agentKey")))
        case "agents.transcript":
            guard let key = str("key") else { throw BrowserJSError.invalidArgs("key") }
            return try encodeValue(try await host.agentsTranscript(key: key, since: int("since") ?? 0))
        case "terminal.open":
            let id = try await host.terminalOpen(agentKey: optStr("agentKey"), cwd: optStr("cwd"), command: optStr("command"), show: optStr("show") ?? "card")
            return try encodeValue(id)
        case "terminal.read":
            guard let id = str("id") else { throw BrowserJSError.invalidArgs("id") }
            return try encodeValue(try await host.terminalRead(id: id, since: optStr("since"), maxChars: int("maxChars")))
        case "terminal.write":
            guard let id = str("id"), let text = str("text") else { throw BrowserJSError.invalidArgs("id, text") }
            try await host.terminalWrite(id: id, text: text)
            return nil
        case "notes.write":
            guard let title = str("title") else { throw BrowserJSError.invalidArgs("title") }
            let info = try await host.notesWrite(agentKey: optStr("agentKey"), title: title, markdown: optStr("markdown"), html: optStr("html"), show: optStr("show") ?? "both")
            return try encodeValue(info)

        case "tasks.list":
            return try encodeValue(try await host.tasksList())

        case "toolbar.list":
            return try encodeValue(try await host.toolbarListButtons())
        case "toolbar.get":
            guard let id = str("id") else { throw BrowserJSError.invalidArgs("id") }
            return try encodeValue(try await host.toolbarGetButton(id: id))
        case "toolbar.create":
            guard let label = str("label") else { throw BrowserJSError.invalidArgs("label") }
            return try encodeValue(try await host.toolbarCreateButton(label: label, icon: optStr("icon"), bjs: optStr("bjs"), instructions: optStr("instructions")))
        case "toolbar.update":
            guard let id = str("id") else { throw BrowserJSError.invalidArgs("id") }
            let clearBJS = raw["bjs"] is NSNull
            return try encodeValue(try await host.toolbarUpdateButton(id: id, label: optStr("label"), icon: optStr("icon"), bjs: optStr("bjs"), clearBJS: clearBJS, instructions: optStr("instructions")))
        case "toolbar.remove":
            guard let id = str("id") else { throw BrowserJSError.invalidArgs("id") }
            try await host.toolbarRemoveButton(id: id)
            return nil
        case "toolbar.click":
            guard let id = str("id") else { throw BrowserJSError.invalidArgs("id") }
            try await host.toolbarClickButton(id: id, tabId: optStr("tabId"))
            return nil

        case "inject.get":
            guard let h = str("host") else { throw BrowserJSError.invalidArgs("host") }
            return try encodeValue(try await host.injectGet(host: h))
        case "inject.set":
            guard let h = str("host") else { throw BrowserJSError.invalidArgs("host") }
            return try encodeValue(try await host.injectSet(host: h, css: optStr("css"), js: optStr("js")))
        case "inject.clear":
            guard let h = str("host") else { throw BrowserJSError.invalidArgs("host") }
            try await host.injectClear(host: h)
            return nil

        case "memory.scopes":
            return try encodeValue(try await host.memoryScopes())
        case "memory.schema":
            return try encodeAny(try await host.memorySchema())
        case "memory.query":
            guard let sql = str("sql") else { throw BrowserJSError.invalidArgs("sql") }
            let rows = try await host.memoryQuery(scope: optStr("scope"), sql: sql, params: (raw["params"] as? [Any]) ?? [], limit: int("limit") ?? 200)
            return try encodeAny(rows)
        case "memory.overview":
            return try encodeValue(try await host.memoryOverview(scope: optStr("scope")))
        case "memory.setOverview":
            guard let text = str("text") else { throw BrowserJSError.invalidArgs("text") }
            return try encodeValue(try await host.memorySetOverview(scope: optStr("scope"), text: text))
        case "credentials.lookup":
            guard let domain = str("domain") else { throw BrowserJSError.invalidArgs("domain") }
            return try encodeValue(try await host.credentialsLookup(domain: domain, spaceId: optStr("spaceId")))
        case "credentials.hasPassword":
            guard let domain = str("domain") else { throw BrowserJSError.invalidArgs("domain") }
            return try encodeValue(try await host.credentialsHasPassword(domain: domain, username: optStr("username"), spaceId: optStr("spaceId")))
        case "credentials.fillPassword":
            guard let tabId = str("tabId") else { throw BrowserJSError.invalidArgs("tabId") }
            return try encodeValue(try await host.credentialsFillPassword(tabId: tabId, username: optStr("username"), domain: optStr("domain")))
        case "profile.get":
            return try encodeValue(try await host.profileGet(spaceId: optStr("spaceId")))

        case "content.write":
            throw BrowserJSError.notImplemented(fn)
        default:
            throw BrowserJSError.invalidArgs("unknown fn: \(fn)")
        }
    }
}

// The shared JS definition of the `browser` object. It assumes the embedding
// context has already defined an async `__browserCall(fn, args)` plus the
// `__nativeLog` / `__nativeAttachImage` shims. Used verbatim by both the
// JSContext runtime preamble and the tang:// web bridge.
enum BrowserJSBridgeSource {
    static let browserObjectJS: String = """
    function __selfKey() { return (typeof __agentKey !== 'undefined') ? __agentKey : undefined; }
    var browser = {
        tabs: {
            list:     function(opts) { opts = opts || {}; return __browserCall('tabs.list', { windowId: opts.windowId, spaceId: opts.spaceId }); },
            open:     function(url, opts) { opts = opts || {}; return __browserCall('tabs.open', { url: url, background: !!opts.background, windowId: opts.windowId }); },
            openGhost:function(url, opts) { opts = opts || {}; return __browserCall('tabs.openGhost', { url: url, windowId: opts.windowId }); },
            use:function(id, opts) { opts = opts || {}; return __browserCall('tabs.use', { id: id, minutes: opts.minutes }); },
            openSplit:function(url, opts) { opts = opts || {}; return __browserCall('tabs.openSplit', { url: url, besideTabId: opts.besideTabId, activate: opts.activate !== false, windowId: opts.windowId }); },
            openHTML: function(html, opts) { opts = opts || {}; return __browserCall('tabs.openHTML', { html: html, title: opts.title, windowId: opts.windowId }); },
            close:    function(id) { return __browserCall('tabs.close', { id: id }); },
            activate: function(id) { return __browserCall('tabs.activate', { id: id }); },
            move:     function(id, toIndex) { return __browserCall('tabs.move', { id: id, toIndex: toIndex }); },
            get:      function(id) { return __browserCall('tabs.get', { id: id }); },
            navigate: function(id, url) { return __browserCall('tabs.navigate', { id: id, url: url }); },
        },
        content: {
            read:       function(id, opts) { opts = opts || {}; return __browserCall('content.read', { id: id, as: opts.as || 'text' }); },
            screenshot: function(id) { return __browserCall('content.screenshot', { id: id }); },
            write:      function(id, html) { return __browserCall('content.write', { id: id, html: html }); },
        },
        page: {
            eval:    function(id, js) { return __browserCall('page.eval', { id: id, js: js }); },
            waitFor: function(id, predicateJs, timeoutMs) { return __browserCall('page.waitFor', { id: id, predicateJs: predicateJs, timeoutMs: timeoutMs }); },
            click:   function(id, x, y, opts) { opts = opts || {}; return __browserCall('page.click', { id: id, x: x, y: y, button: opts.button || 'left', clickCount: opts.clickCount || 1 }); },
            type:    function(id, text) { return __browserCall('page.type', { id: id, text: String(text) }); },
            key:     function(id, key, modifiers) { return __browserCall('page.key', { id: id, key: key, modifiers: modifiers || [] }); },
            scroll:  function(id, dx, dy) { return __browserCall('page.scroll', { id: id, dx: dx || 0, dy: dy || 0 }); },
        },
        windows: {
            list:       function() { return __browserCall('windows.list', {}); },
            getCurrent: function() { return __browserCall('windows.getCurrent', {}); },
            getById:    function(id) { return __browserCall('windows.getById', { id: id }); },
        },
        splits: {
            list:     function(opts) { opts = opts || {}; return __browserCall('splits.list', { windowId: opts.windowId, spaceId: opts.spaceId }); },
            get:      function(tabId) { return __browserCall('splits.get', { tabId: tabId }); },
            separate: function(tabId) { return __browserCall('splits.separate', { tabId: tabId }); },
        },
        spaces: {
            list:       function(opts) { opts = opts || {}; return __browserCall('spaces.list', { windowId: opts.windowId, includeHidden: !!opts.includeHidden }); },
            getCurrent: function(opts) { opts = opts || {}; return __browserCall('spaces.getCurrent', { windowId: opts.windowId }); },
            activate:   function(spaceId, opts) { opts = opts || {}; return __browserCall('spaces.activate', { spaceId: spaceId, windowId: opts.windowId }); },
            setChatMode: function(spaceId, enabled) { return __browserCall('spaces.setChatMode', { spaceId: spaceId, enabled: !!enabled }); },
        },
        folders: {
            list:      function(opts) { opts = opts || {}; return __browserCall('folders.list', { spaceId: opts.spaceId, windowId: opts.windowId }); },
            get:       function(folderId) { return __browserCall('folders.get', { folderId: folderId }); },
            create:    function(name, opts) { opts = opts || {}; return __browserCall('folders.create', { name: name, spaceId: opts.spaceId, windowId: opts.windowId }); },
            rename:    function(folderId, name) { return __browserCall('folders.rename', { folderId: folderId, name: name }); },
            delete:    function(folderId, opts) { opts = opts || {}; return __browserCall('folders.delete', { folderId: folderId, closeTabs: !!opts.closeTabs, windowId: opts.windowId }); },
            addTab:    function(tabId, folderId, opts) { opts = opts || {}; return __browserCall('folders.addTab', { tabId: tabId, folderId: folderId, open: !!opts.open }); },
            removeTab: function(tabId) { return __browserCall('folders.removeTab', { tabId: tabId }); },
        },
        net: {
            log:           function(filter)  { return __browserCall('net.log', filter || {}); },
            grep:          function(pattern, where) { return __browserCall('net.grep', { pattern: pattern, where: where }); },
            fetch:         function(req)     { return __browserCall('net.fetch', req || {}); },
            replay:        function(entryId, overrides) { return __browserCall('net.replay', { entryId: entryId, overrides: overrides }); },
            captureOrigin: function(origin, enabled) { return __browserCall('net.captureOrigin', { origin: origin, enabled: enabled }); },
        },
        webapp: {
            create: function(opts) { return __browserCall('webapp.create', opts || {}); },
        },
        notes: {
            write: function(opts) { return __browserCall('notes.write', opts || {}); },
        },
        tasks: {
            list: function() { return __browserCall('tasks.list', {}); },
        },
        toolbar: {
            list:   function() { return __browserCall('toolbar.list', {}); },
            get:    function(id) { return __browserCall('toolbar.get', { id: id }); },
            create: function(opts) { return __browserCall('toolbar.create', opts || {}); },
            update: function(id, opts) { opts = opts || {}; return __browserCall('toolbar.update', { id: id, label: opts.label, icon: opts.icon, bjs: opts.bjs, instructions: opts.instructions }); },
            remove: function(id) { return __browserCall('toolbar.remove', { id: id }); },
            click:  function(id, opts) { opts = opts || {}; return __browserCall('toolbar.click', { id: id, tabId: opts.tabId }); },
        },
        inject: {
            get:   function(host) { return __browserCall('inject.get', { host: host }); },
            set:   function(host, opts) { opts = opts || {}; return __browserCall('inject.set', { host: host, css: opts.css, js: opts.js }); },
            clear: function(host) { return __browserCall('inject.clear', { host: host }); },
        },
        memory: {
            scopes:      function() { return __browserCall('memory.scopes', {}); },
            schema:      function() { return __browserCall('memory.schema', {}); },
            query:       function(opts) { return __browserCall('memory.query', opts || {}); },
            overview:    function(opts) { return __browserCall('memory.overview', opts || {}); },
            setOverview: function(opts) { return __browserCall('memory.setOverview', opts || {}); },
        },
        fs: {
            read:   function(path, opts) { opts = opts || {}; return __browserCall('fs.read', { path: path, encoding: opts.encoding || 'utf8' }); },
            write:  function(path, data, opts) { opts = opts || {}; return __browserCall('fs.write', { path: path, data: String(data), encoding: opts.encoding || 'utf8', append: !!opts.append }); },
            list:   function(path) { return __browserCall('fs.list', { path: path }); },
            stat:   function(path) { return __browserCall('fs.stat', { path: path }); },
            remove: function(path) { return __browserCall('fs.remove', { path: path }); },
            mkdir:  function(path) { return __browserCall('fs.mkdir', { path: path }); },
        },
        agent: {
            create:      function(opts) { return __browserCall('agent.create', opts || {}); },
            send:        function(opts) { return __browserCall('agent.send', opts || {}); },
            await:       function(opts) { return __browserCall('agent.await', opts || {}); },
            messages:    function(opts) { return __browserCall('agent.messages', opts || {}); },
            list:        function() { return __browserCall('agent.list', {}); },
            interrupt:   function(id) { return __browserCall('agent.interrupt', { id: id }); },
            dispose:     function(id) { return __browserCall('agent.dispose', { id: id }); },
            respondTool: function(opts) { return __browserCall('agent.respondTool', opts || {}); },

            // Runs the agent's tool calls against your JS handlers until the
            // agent goes idle. `handlers` maps tool name -> function(args).
            // Returns the final await result. Anything a handler returns is
            // sent back to the agent (objects are JSON-stringified); a handler
            // that throws is reported to the agent as a tool error, so a bug
            // in your code doesn't wedge the turn.
            serve: async function(id, handlers, opts) {
                opts = opts || {};
                var since = opts.since || 0;
                var onMessage = opts.onMessage;
                for (;;) {
                    var r = await browser.agent.await({ id: id, since: since, timeoutMs: opts.timeoutMs || 30000 });
                    since = r.nextIndex;
                    if (onMessage) { for (var i = 0; i < r.messages.length; i++) onMessage(r.messages[i]); }
                    for (var j = 0; j < r.toolCalls.length; j++) {
                        var call = r.toolCalls[j];
                        var handler = handlers ? handlers[call.name] : null;
                        if (!handler) {
                            await browser.agent.respondTool({ callId: call.callId, result: 'no handler for tool: ' + call.name, isError: true });
                            continue;
                        }
                        try {
                            var args = {};
                            try { args = JSON.parse(call.inputJSON || '{}'); } catch (e) {}
                            var out = await handler(args);
                            await browser.agent.respondTool({ callId: call.callId, result: out === undefined ? 'ok' : out });
                        } catch (err) {
                            await browser.agent.respondTool({ callId: call.callId, result: String((err && err.message) || err), isError: true });
                        }
                    }
                    if (r.done) return r;
                }
            },
        },
        // Chat mode. `__agentKey` is declared by the agent runtime so the host
        // knows which agent (and thread) is calling; the MCP runtime has none
        // and falls back to the current chat-mode space.
        present: function(opts) { opts = opts || {}; return __browserCall('chat.present', { agentKey: __selfKey(), tabId: opts.tabId, url: opts.url, show: opts.show || 'card', note: opts.note }); },
        agents: {
            spawn:      function(opts) { opts = opts || {}; return __browserCall('agents.spawn', { agentKey: __selfKey(), task: opts.task, name: opts.name, model: opts.model, effort: opts.effort, fileSystemTools: !!opts.fileSystemTools, workingDirectory: opts.workingDirectory, show: opts.show || 'card' }); },
            send:       function(opts) { opts = opts || {}; return __browserCall('agents.send', { agentKey: __selfKey(), key: opts.key, text: opts.text }); },
            list:       function() { return __browserCall('agents.list', { agentKey: __selfKey() }); },
            transcript: function(opts) { opts = opts || {}; return __browserCall('agents.transcript', { key: opts.key, since: opts.since || 0 }); },
        },
        terminal: {
            open:  function(opts) { opts = opts || {}; return __browserCall('terminal.open', { agentKey: __selfKey(), cwd: opts.cwd, command: opts.command, show: opts.show || 'card' }); },
            read:  function(id, opts) { opts = opts || {}; return __browserCall('terminal.read', { id: id, since: opts.since, maxChars: opts.maxChars }); },
            write: function(id, text) { return __browserCall('terminal.write', { id: id, text: String(text) }); },
        },
        credentials: {
            lookup:       function(domain, opts) { opts = opts || {}; return __browserCall('credentials.lookup', { domain: domain, spaceId: opts.spaceId }); },
            hasPassword:  function(domain, opts) { opts = opts || {}; return __browserCall('credentials.hasPassword', { domain: domain, username: opts.username, spaceId: opts.spaceId }); },
            fillPassword: function(tabId, opts) { opts = opts || {}; return __browserCall('credentials.fillPassword', { tabId: tabId, username: opts.username, domain: opts.domain }); },
        },
        profile: {
            get: function(opts) { opts = opts || {}; return __browserCall('profile.get', { spaceId: opts.spaceId }); },
        },
        sleep: function(ms) { return new Promise(function(r) { setTimeout(r, ms); }); },
        log:   function() {
            var parts = [];
            for (var i = 0; i < arguments.length; i++) {
                var a = arguments[i];
                try { parts.push(typeof a === 'string' ? a : JSON.stringify(a)); }
                catch (e) { parts.push(String(a)); }
            }
            __nativeLog(parts.join(' '));
        },
        viewImage: function(img) {
            if (!img) return;
            var data, mime;
            if (typeof img === 'string') { data = img; mime = 'image/png'; }
            else { data = img.data; mime = img.mime || 'image/png'; }
            if (!data) return;
            __nativeAttachImage(String(data), String(mime));
        },
    };
    """
}
