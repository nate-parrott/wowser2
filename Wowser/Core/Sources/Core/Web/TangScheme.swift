import Foundation
import WebKit
import Ink

// tang:// — custom scheme for local BrowserJS webapps.
//
// Apps live on disk under ~/Library/Application Support/Wowser/Apps/<app>/
// as a folder of files (index.html + assets). A `tang://<app>/<path>` URL maps
// to <app>/<path> (defaulting to index.html). Pages loaded from tang:// receive
// `window.browser` — the full BrowserJS surface — via TangBridge.
//
// Pieces:
//   - TangAppStore:     on-disk store (create / resolve apps)
//   - TangSchemeHandler: WKURLSchemeHandler serving files
//   - TangBridge:        WKScriptMessageHandlerWithReply exposing browser.* to pages

public final class TangAppStore: @unchecked Sendable {
    public static let shared = TangAppStore()

    public let dir: URL
    /// Apps shipped inside the app bundle (`Core/TangApps/<slug>/`). They are
    /// served when nothing on disk claims the slug, so a user (or agent) can
    /// override a bundled app simply by writing one with the same name.
    public let bundledDir: URL?
    private let queue = DispatchQueue(label: "TangAppStore")

    public static let defaultBundledDir: URL? = Bundle.module.url(forResource: "TangApps", withExtension: nil)

    public init(dir: URL? = nil, bundledDir: URL? = TangAppStore.defaultBundledDir) {
        if let dir {
            self.dir = dir
        } else {
            let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
            let base = appSupport.appendingPathComponent("Wowser", isDirectory: true)
            self.dir = base.appendingPathComponent("Apps", isDirectory: true)
            // One-time migration from the pre-rename folder.
            let legacy = base.appendingPathComponent("Tangerine", isDirectory: true)
            if FileManager.default.fileExists(atPath: legacy.path), !FileManager.default.fileExists(atPath: self.dir.path) {
                try? FileManager.default.moveItem(at: legacy, to: self.dir)
            }
        }
        self.bundledDir = bundledDir
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

    private func bundledAppDir(slug: String) -> URL? {
        bundledDir?.appendingPathComponent(slug, isDirectory: true)
    }

    /// Slugs of apps shipped in the bundle.
    public func bundledSlugs() -> [String] {
        guard let bundledDir else { return [] }
        let urls = (try? FileManager.default.contentsOfDirectory(at: bundledDir, includingPropertiesForKeys: [.isDirectoryKey])) ?? []
        return urls
            .filter { (try? $0.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true }
            .map { $0.lastPathComponent }
    }

    /// The app's `manifest.json`, preferring an on-disk copy over the bundled one.
    func manifestURL(slug: String) -> URL? {
        let disk = appDir(slug: slug).appendingPathComponent("manifest.json")
        if FileManager.default.fileExists(atPath: disk.path) { return disk }
        return bundledAppDir(slug: slug)?.appendingPathComponent("manifest.json")
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

    // MARK: - Notes

    /// Simple documents agents write for the user (a comparison, a summary, a
    /// plan) — anything too long for a chat bubble. Stored as files under the
    /// reserved `notes` host: `tang://notes/<slug>.md` (rendered to HTML when
    /// served) or `tang://notes/<slug>.html` (served as-is).
    public static let notesHost = "notes"

    /// Write a note and return its tang:// URL. Markdown gets a `# title`
    /// heading prepended if it doesn't already start with one; HTML is stored
    /// verbatim. A new file is created each time (slug-N on collision) so a
    /// note the user is looking at is never rewritten under them.
    public func writeNote(title: String, markdown: String?, html: String?) throws -> URL {
        let ext = html != nil ? "html" : "md"
        var body: String
        if let html {
            body = html
        } else {
            body = markdown ?? ""
            if !body.trimmingCharacters(in: .whitespacesAndNewlines).hasPrefix("# ") {
                body = "# \(title)\n\n" + body
            }
        }
        let base = Self.slug(for: title)
        let notesURL = appDir(slug: Self.notesHost)
        return try queue.sync {
            try FileManager.default.createDirectory(at: notesURL, withIntermediateDirectories: true)
            var name = base
            var n = 2
            while FileManager.default.fileExists(atPath: notesURL.appendingPathComponent(name + "." + ext).path) {
                name = "\(base)-\(n)"; n += 1
            }
            try body.write(to: notesURL.appendingPathComponent(name + "." + ext), atomically: true, encoding: .utf8)
            var comps = URLComponents()
            comps.scheme = TangSchemeHandler.scheme
            comps.host = Self.notesHost
            comps.path = "/" + name + "." + ext
            return comps.url!
        }
    }

    /// Wrap a markdown note as a readable standalone HTML page.
    static func renderNote(markdown: String) -> String {
        let html = MarkdownParser().html(from: markdown)
        let firstHeading = markdown.split(separator: "\n").first(where: { $0.hasPrefix("# ") }).map { String($0.dropFirst(2)) }
        let title = (firstHeading ?? "Note")
            .replacingOccurrences(of: "&", with: "&amp;")
            .replacingOccurrences(of: "<", with: "&lt;")
        return """
        <!doctype html>
        <html><head><meta charset="utf-8"><meta name="viewport" content="width=device-width, initial-scale=1">
        <title>\(title)</title>
        <style>
          :root { color-scheme: light dark; }
          body { margin: 0; padding: 48px 24px 96px; font: 16px/1.55 -apple-system, system-ui, sans-serif; color: CanvasText; background: Canvas; }
          main { max-width: 680px; margin: 0 auto; }
          h1 { font-size: 28px; line-height: 1.2; margin: 0 0 20px; }
          h2 { font-size: 20px; margin: 32px 0 10px; } h3 { font-size: 17px; margin: 24px 0 8px; }
          p, ul, ol { margin: 0 0 14px; } li { margin: 4px 0; }
          a { color: LinkText; } code { font: 13.5px ui-monospace, monospace; background: color-mix(in srgb, CanvasText 8%, transparent); padding: 1px 5px; border-radius: 4px; }
          pre { background: color-mix(in srgb, CanvasText 6%, transparent); padding: 12px 14px; border-radius: 8px; overflow-x: auto; } pre code { background: none; padding: 0; }
          table { border-collapse: collapse; margin: 0 0 14px; } th, td { text-align: left; padding: 6px 12px 6px 0; border-bottom: 1px solid color-mix(in srgb, CanvasText 15%, transparent); }
          blockquote { margin: 0 0 14px; padding-left: 14px; border-left: 3px solid color-mix(in srgb, CanvasText 20%, transparent); opacity: 0.85; }
          hr { border: 0; border-top: 1px solid color-mix(in srgb, CanvasText 15%, transparent); margin: 24px 0; }
          img { max-width: 100%; }
        </style></head>
        <body><main>\(html)</main></body></html>
        """
    }

    /// Installed apps: bundled ones plus every directory on disk. The `notes`
    /// dir on disk is only an app if it's bundled (or a user app of that name
    /// with an index.html), otherwise it just holds agent-written notes.
    public func list() -> [String] {
        let urls = (try? FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: [.isDirectoryKey])) ?? []
        let onDisk = urls
            .filter { (try? $0.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true }
            .map { $0.lastPathComponent }
            .filter { $0 != Self.notesHost || FileManager.default.fileExists(atPath: appDir(slug: $0).appendingPathComponent("index.html").path) }
        return Array(Set(onDisk).union(bundledSlugs())).sorted()
    }

    /// Resolve a tang:// request (host = app slug, path = file) to a file,
    /// guarding against `..` traversal. On-disk apps win; if the file isn't
    /// there, fall back to the bundled app of the same slug. Returns nil if
    /// outside the app or if nothing exists at that path.
    func resolveFile(forHost host: String, path: String) -> URL? {
        var rel = path
        if rel.hasPrefix("/") { rel.removeFirst() }
        if rel.isEmpty { rel = "index.html" }
        if let disk = safeFileURL(appURL: appDir(slug: host), relativePath: rel),
           FileManager.default.fileExists(atPath: disk.path) {
            return disk
        }
        if let bundledApp = bundledAppDir(slug: host),
           let bundled = safeFileURL(appURL: bundledApp, relativePath: rel),
           FileManager.default.fileExists(atPath: bundled.path) {
            return bundled
        }
        return nil
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
    private let apps: TangAppStore

    init(apps: TangAppStore = .shared) {
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
        if host == TangAppStore.notesHost, fileURL.pathExtension.lowercased() == "md",
           let markdown = String(data: data, encoding: .utf8) {
            let page = TangAppStore.renderNote(markdown: markdown)
            respond(task: urlSchemeTask, url: url, status: 200, mime: "text/html; charset=utf-8", data: Data(page.utf8))
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
