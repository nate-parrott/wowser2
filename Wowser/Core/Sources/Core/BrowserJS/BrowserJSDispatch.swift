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
