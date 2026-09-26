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

    /// `preamble` is extra JS evaluated ahead of the helpers and user code —
    /// e.g. an identity declaration (`var __agentKey = ...`) for the caller.
    /// `originPaneID` names the terminal / agent-chat pane the call came from
    /// and `originSpaceID` the caller's space (for pane-less callers like a
    /// chat-space coordinator) — see BrowserJSCallOrigin. Both are (re)declared
    /// on every run so a stale value never leaks from one caller to the next
    /// in the shared context.
    public func run(code: String, preamble: String = "", originPaneID: String? = nil, originSpaceID: String? = nil) async -> BrowserJSResult {
        let ctx = ensureContext()
        // Global scope, so the `browser` object's helpers (`__selfKey`) can see it.
        ctx.context.evaluateScript("var __originPaneId = \(originPaneID.map(Self.jsStringLiteral) ?? "undefined");")
        ctx.context.evaluateScript("var __originSpaceId = \(originSpaceID.map(Self.jsStringLiteral) ?? "undefined");")
        if !preamble.isEmpty {
            ctx.context.evaluateScript(preamble)
        }
        let helperPreamble = (try? helpers.concatenatedHelpers()) ?? ""

        // Pass helpers and user code to the JS-side runner as string literals.
        // The user code is the body of an async function, so the CALLER is
        // responsible for an explicit `return <expr>` to produce a result —
        // no implicit-final-expression heuristic. JSContext (JavaScriptCore)
        // is the parser; we don't second-guess it. JSON-encoded strings are
        // valid JS string literals.
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

                // User code is the async-function body. `return <expr>` yields
                // the result; bare expressions produce nothing (undefined).
                const __runUser = new AsyncFunction(__helpers + '\\n;' + __code);

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
        try await BrowserJSDispatch.handle(fn: fn, argsJSON: argsJSON, host: host)
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
            context.objectForKeyedSubscript("__nativeReject")?.call(withArguments: [id, BrowserJSRuntime.describe(err)])
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

    private static let preambleJS: String = preambleHeadJS + "\n" + BrowserJSBridgeSource.browserObjectJS

    private static let preambleHeadJS: String = """
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
            var env = Object.assign({}, args || {});
            // Originating terminal pane (MCP calls from a tab in the browser).
            if (typeof __originPaneId === 'string') env.__origin = __originPaneId;
            if (typeof __originSpaceId === 'string') env.__originSpace = __originSpaceId;
            __nativeRequest(id, fn, JSON.stringify(env));
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
    """
}

extension BrowserJSRuntime {
    fileprivate func _resolveOnContext(_ box: ContextBox, id: Int, result: Result<String?, Error>) {
        box.deliver(id: id, result: result)
    }
}

extension BrowserJSRuntime {
    /// Human-readable error text for a rejected native call. WebKit wraps
    /// in-page exceptions in a generic "A JavaScript exception occurred"; pull
    /// the real message (and line, if any) out of `userInfo` so the caller sees
    /// e.g. `TypeError: null is not an object (evaluating 'x.getBoundingClientRect')`.
    static func describe(_ err: Error) -> String {
        let ns = err as NSError
        if let msg = ns.userInfo["WKJavaScriptExceptionMessage"] as? String, !msg.isEmpty {
            var out = msg
            if let line = ns.userInfo["WKJavaScriptExceptionLineNumber"] as? Int, line > 0 {
                out += " (page script line \(line))"
            }
            return out
        }
        return err.localizedDescription
    }
}
