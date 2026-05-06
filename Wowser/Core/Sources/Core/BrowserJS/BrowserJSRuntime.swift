import Foundation
import JavaScriptCore

// Single-threaded, serial-execution JS runtime backing the `run_browser_js`
// MCP tool. One JSContext shared across all callers (Q14). Calls are
// serialized through an actor (Q16). Helpers are prepended in alpha order
// at every call (Q18).
//
// Caps (Q17): 60s execution, 1 MB result payload, 1000 log lines.

public struct BrowserJSResult: Equatable, Codable, Sendable {
    public var result: String?     // JSON-stringified result, or nil for void
    public var logs: [String]
    public var error: String?
    public var truncated: Bool
    /// Images attached via `browser.viewImage(...)` during the run. The MCP
    /// layer surfaces these as `image` content blocks alongside the text result.
    public var images: [BrowserJSImage] = []
}

public actor BrowserJSRuntime {
    public struct Caps: Sendable {
        public var timeoutSeconds: Double = 60
        public var maxResultBytes: Int = 1_000_000
        public var maxLogLines: Int = 1_000
        public init() {}
    }

    private let host: any BrowserJSHost
    private let helpers: BrowserJSHelpersProvider
    private let caps: Caps

    // The JSContext, initialized lazily on first use. JSContexts are not
    // thread-safe; we only ever touch this from inside the actor.
    private var contextBox: ContextBox?

    public init(host: any BrowserJSHost, helpers: BrowserJSHelpersProvider, caps: Caps = Caps()) {
        self.host = host
        self.helpers = helpers
        self.caps = caps
    }

    public func run(code: String) async -> BrowserJSResult {
        let ctx = ensureContext()
        let helperPreamble = (try? helpers.concatenatedHelpers()) ?? ""

        // Pass helpers and user code to the JS-side runner as string literals,
        // so the runner can construct AsyncFunctions and try the user code as
        // an expression first (capturing the final value). JSON-encoded
        // strings are valid JS string literals.
        let helpersLit = Self.jsStringLiteral(helperPreamble)
        let codeLit = Self.jsStringLiteral(code)
        let timeoutMS = Int(caps.timeoutSeconds * 1000)

        let wrapped = """
        (async () => {
            __resetRunState();
            try {
                const AsyncFunction = (async function(){}).constructor;
                const __helpers = \(helpersLit);
                const __code = \(codeLit);

                async function __runUser() {
                    // Strategy 1: whole user code as a single expression.
                    // Catches `42`, `await foo()`, `obj.prop`, etc.
                    try {
                        const fn = new AsyncFunction(__helpers + '\\n;return (' + __code + '\\n);');
                        return await fn();
                    } catch (e) {
                        if (!(e instanceof SyntaxError)) throw e;
                    }
                    // Strategy 2: last non-empty line as expression, prior
                    // lines as statements. Catches `let x = 1; x + 1`.
                    const lines = __code.split(/\\r?\\n/);
                    let lastIdx = lines.length - 1;
                    while (lastIdx >= 0 && lines[lastIdx].trim() === '') lastIdx--;
                    if (lastIdx > 0) {
                        const head = lines.slice(0, lastIdx).join('\\n');
                        const tail = lines[lastIdx];
                        try {
                            const fn = new AsyncFunction(__helpers + '\\n;' + head + '\\n;return (' + tail + '\\n);');
                            return await fn();
                        } catch (e) {
                            if (!(e instanceof SyntaxError)) throw e;
                        }
                    }
                    // Strategy 3: pure statements, no implicit return.
                    const fn = new AsyncFunction(__helpers + '\\n;' + __code);
                    return await fn();
                }

                __runResult = await Promise.race([
                    __runUser(),
                    new Promise((_, rej) =>
                        setTimeout(() => rej(new Error('BrowserJS timeout')), \(timeoutMS)))
                ]);
                __runError = null;
            } catch (e) {
                if (e && e.message) {
                    __runError = String(e.message);
                    if (e.stack) { __runError += '\\n' + String(e.stack); }
                } else {
                    __runError = String(e);
                }
                __runResult = undefined;
            } finally {
                __runDone = true;
            }
        })();
        """

        // Reset state, evaluate. The IIFE runs the script asynchronously —
        // we have to drive the run loop until __runDone flips true.
        ctx.context.evaluateScript(wrapped)
        if let exc = ctx.context.exception {
            return BrowserJSResult(
                result: nil,
                logs: ctx.takeLogs(max: caps.maxLogLines),
                error: "JS evaluation error: \(exc.toString() ?? "<unknown>")",
                truncated: false,
                images: ctx.takeImages()
            )
        }

        // Wait for completion.
        let deadline = Date().addingTimeInterval(caps.timeoutSeconds + 5)
        while !ctx.isDone() {
            if Date() > deadline { break }
            // Yield a tiny slice of run loop so dispatch_async work for
            // host callbacks gets serviced. We're inside an actor on a
            // background thread, but our setTimeout shim hops everything
            // through the actor's queue. Sleep briefly.
            try? await Task.sleep(nanoseconds: 5_000_000) // 5ms
        }

        if !ctx.isDone() {
            return BrowserJSResult(
                result: nil,
                logs: ctx.takeLogs(max: caps.maxLogLines),
                error: "BrowserJS hard timeout",
                truncated: false,
                images: ctx.takeImages()
            )
        }

        if let err = ctx.takeError() {
            return BrowserJSResult(
                result: nil,
                logs: ctx.takeLogs(max: caps.maxLogLines),
                error: err,
                truncated: false,
                images: ctx.takeImages()
            )
        }

        let (resultStr, truncated) = ctx.takeResult(maxBytes: caps.maxResultBytes)
        let logs = ctx.takeLogs(max: caps.maxLogLines)
        return BrowserJSResult(result: resultStr, logs: logs, error: nil, truncated: truncated, images: ctx.takeImages())
    }

    // MARK: - Context setup

    /// JSON-encode a string into a valid JS string literal (with surrounding
    /// quotes) so it can be interpolated into source we evaluate.
    private static func jsStringLiteral(_ s: String) -> String {
        let data = (try? JSONEncoder().encode(s)) ?? Data("\"\"".utf8)
        return String(data: data, encoding: .utf8) ?? "\"\""
    }

    private func ensureContext() -> ContextBox {
        if let contextBox { return contextBox }
        let box = ContextBox(host: host, runtime: self)
        contextBox = box
        return box
    }

    // Called from the JS-bound block. Marked nonisolated so it can be
    // referenced from a @convention(block); the implementation hops back
    // into the actor to satisfy isolation.
    fileprivate nonisolated func dispatchHostCall(id: Int, fn: String, argsJSON: String, completion: @escaping (Result<String?, Error>) -> Void) {
        Task { [weak self] in
            guard let self else { return }
            do {
                let result = try await self.handleHostCall(fn: fn, argsJSON: argsJSON)
                completion(.success(result))
            } catch {
                completion(.failure(error))
            }
        }
    }

    private func handleHostCall(fn: String, argsJSON: String) async throws -> String? {
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
            let info = try await host.tabsList(windowId: optStr("windowId"))
            return try encodeValue(info)
        case "tabs.open":
            guard let url = str("url") else { throw BrowserJSError.invalidArgs("url") }
            let id = try await host.tabsOpen(url: url, background: bool("background"), windowId: optStr("windowId"))
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
        case "webapp.create", "content.write":
            throw BrowserJSError.notImplemented(fn)
        default:
            throw BrowserJSError.invalidArgs("unknown fn: \(fn)")
        }
    }
}

// MARK: - JSContext box
//
// Holds a JSContext with the BrowserJS preamble installed and bridges to
// Swift via __nativeRequest. JSContext is not thread-safe; ContextBox is
// only ever accessed from inside the BrowserJSRuntime actor.
final class ContextBox {
    let context: JSContext
    private var logs: [String] = []
    private var maxLogsSeen = false
    private var images: [BrowserJSImage] = []
    private weak var runtime: BrowserJSRuntime?

    /// Cap on attached images per run. Each PNG screenshot is ~hundreds of KB
    /// base64; keep this conservative so a runaway loop can't blow up the
    /// MCP response.
    static let maxImagesPerRun = 16

    init(host: any BrowserJSHost, runtime: BrowserJSRuntime) {
        self.context = JSContext()!
        self.runtime = runtime
        installPreamble()
        installNativeBridge(runtime: runtime)
        installSetTimeoutShim()
        installLogShim()
        installAttachImageShim()
    }

    private func installPreamble() {
        context.exceptionHandler = { _, exc in
            // Swallowed; consumed via `context.exception` after each evaluate.
            _ = exc
        }
        context.evaluateScript(Self.preambleJS)
    }

    private func installNativeBridge(runtime: BrowserJSRuntime) {
        let block: @convention(block) (Int, String, String) -> Void = { [weak runtime] id, fn, argsJSON in
            guard let runtime else { return }
            runtime.dispatchHostCall(id: id, fn: fn, argsJSON: argsJSON) { [weak self] result in
                guard let self else { return }
                // Hop back to the JSContext's queue (which is the actor's
                // queue). We do that by enqueueing on the runtime actor.
                Task { [weak runtime, weak self] in
                    guard let runtime, let self else { return }
                    await runtime._resolveOnContext(self, id: id, result: result)
                }
            }
        }
        context.setObject(block, forKeyedSubscript: "__nativeRequest" as NSString)
    }

    private func installSetTimeoutShim() {
        let block: @convention(block) (JSValue, Double) -> Void = { fn, ms in
            let secs = max(0.0, ms / 1000.0)
            DispatchQueue.global().asyncAfter(deadline: .now() + secs) {
                fn.call(withArguments: [])
            }
        }
        context.setObject(block, forKeyedSubscript: "setTimeout" as NSString)
    }

    private func installLogShim() {
        let block: @convention(block) (String) -> Void = { [weak self] msg in
            guard let self else { return }
            if self.logs.count < 1000 {
                self.logs.append(msg)
            } else {
                self.maxLogsSeen = true
            }
        }
        context.setObject(block, forKeyedSubscript: "__nativeLog" as NSString)
    }

    private func installAttachImageShim() {
        let block: @convention(block) (String, String) -> Void = { [weak self] data, mime in
            guard let self else { return }
            guard !data.isEmpty else { return }
            if self.images.count >= Self.maxImagesPerRun { return }
            let m = mime.isEmpty ? "image/png" : mime
            self.images.append(BrowserJSImage(mime: m, data: data))
        }
        context.setObject(block, forKeyedSubscript: "__nativeAttachImage" as NSString)
    }

    func deliver(id: Int, result: Result<String?, Error>) {
        switch result {
        case .success(let json):
            let arg: Any = json ?? NSNull()
            context.objectForKeyedSubscript("__nativeResolve")?.call(withArguments: [id, arg])
        case .failure(let err):
            context.objectForKeyedSubscript("__nativeReject")?.call(withArguments: [id, err.localizedDescription])
        }
    }

    func isDone() -> Bool {
        context.objectForKeyedSubscript("__runDone")?.toBool() ?? false
    }

    func takeError() -> String? {
        let v = context.objectForKeyedSubscript("__runError")
        if let v, !v.isNull, !v.isUndefined { return v.toString() }
        return nil
    }

    func takeResult(maxBytes: Int) -> (String?, Bool) {
        let v = context.objectForKeyedSubscript("__runResult")
        guard let v, !v.isUndefined, !v.isNull else { return (nil, false) }
        let json = context.evaluateScript("JSON.stringify(__runResult)")?.toString()
        guard let json, json != "undefined" else { return (nil, false) }
        if json.utf8.count > maxBytes {
            let truncated = String(json.prefix(maxBytes / 2)) + "...[truncated]"
            return (truncated, true)
        }
        return (json, false)
    }

    func takeLogs(max n: Int) -> [String] {
        let result = Array(logs.prefix(n))
        logs.removeAll(keepingCapacity: false)
        return result
    }

    func takeImages() -> [BrowserJSImage] {
        let result = images
        images.removeAll(keepingCapacity: false)
        return result
    }

    private static let preambleJS: String = """
    var __runDone = false;
    var __runResult = undefined;
    var __runError = null;
    var __nativePending = {};
    var __nativeNextId = 1;

    function __resetRunState() {
        __runDone = false;
        __runResult = undefined;
        __runError = null;
    }

    function __browserCall(fn, args) {
        return new Promise(function(resolve, reject) {
            var id = __nativeNextId++;
            __nativePending[id] = { resolve: resolve, reject: reject };
            __nativeRequest(id, fn, JSON.stringify(args || {}));
        });
    }

    function __nativeResolve(id, jsonStr) {
        var p = __nativePending[id];
        if (!p) return;
        delete __nativePending[id];
        try {
            if (jsonStr === null || jsonStr === undefined) {
                p.resolve(undefined);
            } else if (typeof jsonStr === 'string') {
                p.resolve(JSON.parse(jsonStr));
            } else {
                p.resolve(jsonStr);
            }
        } catch (e) {
            p.reject(e);
        }
    }
    function __nativeReject(id, errMsg) {
        var p = __nativePending[id];
        if (!p) return;
        delete __nativePending[id];
        p.reject(new Error(errMsg));
    }

    var browser = {
        tabs: {
            list:     function(opts) { opts = opts || {}; return __browserCall('tabs.list', { windowId: opts.windowId }); },
            open:     function(url, opts) { opts = opts || {}; return __browserCall('tabs.open', { url: url, background: !!opts.background, windowId: opts.windowId }); },
            openGhost:function(url, opts) { opts = opts || {}; return __browserCall('tabs.openGhost', { url: url, windowId: opts.windowId }); },
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
        /// Attach an image to the MCP tool output so the calling model can
        /// actually see it. Accepts the {mime, data} shape returned by
        /// `content.screenshot`, or a bare base64 string (assumed PNG).
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

extension BrowserJSRuntime {
    fileprivate func _resolveOnContext(_ box: ContextBox, id: Int, result: Result<String?, Error>) {
        box.deliver(id: id, result: result)
    }
}
