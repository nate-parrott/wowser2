import Foundation
import WebKit

// tang:// — custom scheme for local BrowserJS webapps.
//
// Apps live on disk under ~/Library/Application Support/Wowser/Tangerine/<app>/
// as a folder of files (index.html + assets). A `tang://<app>/<path>` URL maps
// to <app>/<path> (defaulting to index.html). Pages loaded from tang:// receive
// `window.browser` — the full BrowserJS surface — via TangBridge.
//
// Pieces:
//   - TangerineApps:     on-disk store (create / resolve apps)
//   - TangSchemeHandler: WKURLSchemeHandler serving files
//   - TangBridge:        WKScriptMessageHandlerWithReply exposing browser.* to pages

public final class TangerineApps: @unchecked Sendable {
    public static let shared = TangerineApps()

    public let dir: URL
    private let queue = DispatchQueue(label: "TangerineApps")

    public init(dir: URL? = nil) {
        if let dir {
            self.dir = dir
        } else {
            let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
            self.dir = appSupport
                .appendingPathComponent("Wowser", isDirectory: true)
                .appendingPathComponent("Tangerine", isDirectory: true)
        }
        try? FileManager.default.createDirectory(at: self.dir, withIntermediateDirectories: true)
    }

    public enum TangError: LocalizedError {
        case invalidPath(String)
        case missingIndex
        public var errorDescription: String? {
            switch self {
            case .invalidPath(let p): return "invalid file path in webapp: \(p)"
            case .missingIndex: return "webapp must include an index.html"
            }
        }
    }

    func appDir(slug: String) -> URL {
        dir.appendingPathComponent(slug, isDirectory: true)
    }

    /// Turn an app name into a filesystem- and host-safe slug (the tang:// host).
    public static func slug(for name: String) -> String {
        var out = ""
        var lastDash = false
        for scalar in name.lowercased().unicodeScalars {
            if (scalar >= "a" && scalar <= "z") || (scalar >= "0" && scalar <= "9") {
                out.unicodeScalars.append(scalar)
                lastDash = false
            } else if !lastDash && !out.isEmpty {
                out.append("-")
                lastDash = true
            }
        }
        while out.hasSuffix("-") { out.removeLast() }
        return out.isEmpty ? "app" : out
    }

    /// Write an app's files to disk (replacing any existing app of the same
    /// slug). `files` keys are relative paths; one must normalize to index.html.
    /// Returns the slug.
    @discardableResult
    public func create(name: String, files: [String: String]) throws -> String {
        let slug = Self.slug(for: name)
        let appURL = appDir(slug: slug)
        try queue.sync {
            guard files.keys.contains(where: { Self.normalize($0) == "index.html" }) else {
                throw TangError.missingIndex
            }
            // Validate all paths up front so we don't half-write a bad app.
            var resolved: [(URL, String)] = []
            for (rel, content) in files {
                guard let fileURL = safeFileURL(appURL: appURL, relativePath: rel) else {
                    throw TangError.invalidPath(rel)
                }
                resolved.append((fileURL, content))
            }
            try? FileManager.default.removeItem(at: appURL)
            try FileManager.default.createDirectory(at: appURL, withIntermediateDirectories: true)
            for (fileURL, content) in resolved {
                try FileManager.default.createDirectory(at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
                try content.write(to: fileURL, atomically: true, encoding: .utf8)
            }
        }
        return slug
    }

    public func list() -> [String] {
        let urls = (try? FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: [.isDirectoryKey])) ?? []
        return urls
            .filter { (try? $0.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true }
            .map { $0.lastPathComponent }
            .sorted()
    }

    /// Resolve a tang:// request (host = app slug, path = file) to a file on
    /// disk, guarding against `..` traversal. Returns nil if outside the app.
    func resolveFile(forHost host: String, path: String) -> URL? {
        var rel = path
        if rel.hasPrefix("/") { rel.removeFirst() }
        if rel.isEmpty { rel = "index.html" }
        return safeFileURL(appURL: appDir(slug: host), relativePath: rel)
    }

    private static func normalize(_ p: String) -> String {
        var s = p
        if s.hasPrefix("/") { s.removeFirst() }
        return s
    }

    /// Resolve `relativePath` under `appURL`, ensuring it stays inside the app
    /// directory (no path-traversal escape, no targeting the dir itself).
    private func safeFileURL(appURL: URL, relativePath: String) -> URL? {
        var rel = relativePath
        if rel.hasPrefix("/") { rel.removeFirst() }
        if rel.isEmpty { return nil }
        let candidate = appURL.appendingPathComponent(rel).standardizedFileURL
        let base = appURL.standardizedFileURL
        guard candidate.path.hasPrefix(base.path + "/") else { return nil }
        return candidate
    }
}

// MARK: - Scheme handler

final class TangSchemeHandler: NSObject, WKURLSchemeHandler {
    static let scheme = "tang"
    private let apps: TangerineApps

    init(apps: TangerineApps = .shared) {
        self.apps = apps
    }

    func webView(_ webView: WKWebView, start urlSchemeTask: WKURLSchemeTask) {
        let request = urlSchemeTask.request
        guard let url = request.url, let host = url.host else {
            urlSchemeTask.didFailWithError(NSError(domain: "tang", code: -1, userInfo: [NSLocalizedDescriptionKey: "bad tang:// URL"]))
            return
        }
        guard let fileURL = apps.resolveFile(forHost: host, path: url.path),
              let data = try? Data(contentsOf: fileURL) else {
            respond(task: urlSchemeTask, url: url, status: 404, mime: "text/plain; charset=utf-8", data: Data("Not found".utf8))
            return
        }
        let mime = Self.mimeType(forExtension: fileURL.pathExtension)
        respond(task: urlSchemeTask, url: url, status: 200, mime: mime, data: data)
    }

    func webView(_ webView: WKWebView, stop urlSchemeTask: WKURLSchemeTask) {
        // We complete synchronously in `start`, so there's nothing in flight.
    }

    private func respond(task: WKURLSchemeTask, url: URL, status: Int, mime: String, data: Data) {
        let headers = [
            "Content-Type": mime,
            "Content-Length": "\(data.count)",
            "Access-Control-Allow-Origin": "*",
        ]
        let response = HTTPURLResponse(url: url, statusCode: status, httpVersion: "HTTP/1.1", headerFields: headers)
            ?? URLResponse(url: url, mimeType: mime, expectedContentLength: data.count, textEncodingName: nil)
        task.didReceive(response)
        task.didReceive(data)
        task.didFinish()
    }

    static func mimeType(forExtension ext: String) -> String {
        switch ext.lowercased() {
        case "html", "htm": return "text/html; charset=utf-8"
        case "js", "mjs": return "text/javascript; charset=utf-8"
        case "css": return "text/css; charset=utf-8"
        case "json": return "application/json; charset=utf-8"
        case "svg": return "image/svg+xml"
        case "png": return "image/png"
        case "jpg", "jpeg": return "image/jpeg"
        case "gif": return "image/gif"
        case "webp": return "image/webp"
        case "ico": return "image/x-icon"
        case "woff": return "font/woff"
        case "woff2": return "font/woff2"
        case "ttf": return "font/ttf"
        case "wasm": return "application/wasm"
        case "txt", "md": return "text/plain; charset=utf-8"
        default: return "application/octet-stream"
        }
    }
}

// MARK: - Web → BrowserJS bridge

/// Exposes `window.browser` (the full BrowserJS surface) to tang:// pages.
/// Registered as a reply-style message handler; the injected user script wires
/// `__browserCall` to `webkit.messageHandlers.tangBJS.postMessage`. Calls from
/// non-tang origins are rejected here as defense-in-depth (the user script also
/// self-gates on `location.protocol`).
final class TangBridge: NSObject, WKScriptMessageHandlerWithReply {
    static let handlerName = "tangBJS"
    private let host: any BrowserJSHost

    init(host: any BrowserJSHost = BrowserJSLiveHost.shared) {
        self.host = host
    }

    func userContentController(_ userContentController: WKUserContentController,
                               didReceive message: WKScriptMessage,
                               replyHandler: @escaping (Any?, String?) -> Void) {
        guard message.frameInfo.securityOrigin.`protocol` == TangSchemeHandler.scheme else {
            replyHandler(nil, "browser API is only available to tang:// apps")
            return
        }
        guard let body = message.body as? [String: Any], let fn = body["fn"] as? String else {
            replyHandler(nil, "invalid bridge message")
            return
        }
        let argsJSON: String = {
            guard let args = body["args"], JSONSerialization.isValidJSONObject(args),
                  let data = try? JSONSerialization.data(withJSONObject: args),
                  let s = String(data: data, encoding: .utf8) else { return "{}" }
            return s
        }()
        let host = self.host
        Task {
            do {
                let result = try await BrowserJSDispatch.handle(fn: fn, argsJSON: argsJSON, host: host)
                // `result` is a JSON-stringified value (or nil for void); the
                // page-side __browserCall JSON.parses it.
                replyHandler(result ?? NSNull(), nil)
            } catch {
                replyHandler(nil, error.localizedDescription)
            }
        }
    }

    /// Wire the tang:// scheme handler and the BrowserJS bridge (message
    /// handler + `window.browser` user script) onto a fresh configuration.
    static func install(on config: WKWebViewConfiguration) {
        if config.urlSchemeHandler(forURLScheme: TangSchemeHandler.scheme) == nil {
            config.setURLSchemeHandler(TangSchemeHandler(), forURLScheme: TangSchemeHandler.scheme)
        }
        let ucc = config.userContentController
        ucc.addScriptMessageHandler(TangBridge(), contentWorld: .page, name: handlerName)
        let userScript = WKUserScript(source: userScriptSource, injectionTime: .atDocumentStart, forMainFrameOnly: true, in: .page)
        ucc.addUserScript(userScript)
    }

    /// User script that defines `window.browser` on tang:// pages, bridging to
    /// the native reply handler. Reuses the shared `browser` object definition.
    static let userScriptSource: String = """
    (function() {
        if (location.protocol !== 'tang:') return;
        function __browserCall(fn, args) {
            return window.webkit.messageHandlers.\(handlerName).postMessage({ fn: fn, args: args || {} })
                .then(function(json) {
                    if (json === null || json === undefined) return undefined;
                    if (typeof json === 'string') return JSON.parse(json);
                    return json;
                });
        }
        var __nativeLog = function(m) { try { console.log('[bjs]', m); } catch (e) {} };
        var __nativeAttachImage = function() {};
    \(BrowserJSBridgeSource.browserObjectJS)
        window.browser = browser;
    })();
    """
}
