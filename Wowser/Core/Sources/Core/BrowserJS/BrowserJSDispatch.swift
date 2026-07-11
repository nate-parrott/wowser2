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

        case "webapp.create":
            guard let name = str("name") else { throw BrowserJSError.invalidArgs("name") }
            let files = (raw["files"] as? [String: Any])?.compactMapValues { $0 as? String } ?? [:]
            let id = try await host.webappCreate(name: name, files: files, exposeBrowserJS: bool("exposeBrowserJS", true))
            return try encodeValue(id)
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
    var browser = {
        tabs: {
            list:     function(opts) { opts = opts || {}; return __browserCall('tabs.list', { windowId: opts.windowId, spaceId: opts.spaceId }); },
            open:     function(url, opts) { opts = opts || {}; return __browserCall('tabs.open', { url: url, background: !!opts.background, windowId: opts.windowId }); },
            openGhost:function(url, opts) { opts = opts || {}; return __browserCall('tabs.openGhost', { url: url, windowId: opts.windowId }); },
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
