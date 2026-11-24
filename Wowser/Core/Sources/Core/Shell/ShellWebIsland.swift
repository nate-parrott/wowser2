import SwiftUI
import WebKit

/// `<WebIsland>` — a web view that is part of the chrome rather than a tab.
///
/// For a file in the branch (`src="widgets/clock.html"`) the page is served
/// from the branch folder over a private scheme, drawn with a transparent
/// background, and given a small bridge:
///
///     wowser.props / wowser.onProps(cb)   the element's `props`
///     wowser.post(message)                → the element's `onMessage`
///     wowser.call(name, args)             → the shell's `call()` API
///
/// For an http(s) `src` it is an ordinary web page (a "web panel") with no
/// bridge at all: remote content never gets access to the browser.
struct ShellWebIslandView: View {
    let node: ShellNode
    @Environment(ShellEngine.self) private var engine

    var body: some View {
        let src = node.string("src") ?? ""
        let remote = src.hasPrefix("http://") || src.hasPrefix("https://")
        ShellIslandRepresentable(
            engine: engine,
            nodeID: node.id,
            src: src,
            remote: remote,
            propsJSON: (node.props["props"] ?? .null).jsonString(),
            transparent: node.props["transparent"]?.bool ?? !remote,
            mobile: node.bool("mobile")
        )
        // Rebuild the web view when it points somewhere else or the branch reloads.
        .id("\(engine.generation)|\(src)")
        .allowsHitTesting(!node.bool("passthrough"))
        .shellStyled(node)
    }
}

enum ShellIsland {
    static let scheme = "wowser-shell"
    static let handlerName = "shell"

    static func url(branch: String, path: String) -> URL? {
        var components = URLComponents()
        components.scheme = scheme
        components.host = branch
        components.path = "/" + path
        return components.url
    }

    /// Defines `window.wowser` before any page script runs.
    static func bridgeScript(initialPropsJSON: String) -> String {
        """
        (function () {
          if (location.protocol !== '\(scheme):') return;
          var listeners = [];
          var bridge = window.webkit.messageHandlers.\(handlerName);
          var wowser = {
            props: \(initialPropsJSON),
            onProps: function (cb) { listeners.push(cb); try { cb(wowser.props); } catch (e) { console.error(e); } },
            post: function (message) { bridge.postMessage({ type: 'post', message: message === undefined ? null : message }); },
            call: function (name, args) {
              return bridge.postMessage({ type: 'call', name: String(name), args: args === undefined ? null : args })
                .then(function (json) { return json == null || json === '' ? null : JSON.parse(json); });
            },
            __setProps: function (props) {
              wowser.props = props;
              listeners.forEach(function (cb) { try { cb(props); } catch (e) { console.error(e); } });
            }
          };
          window.wowser = wowser;
        })();
        """
    }
}

/// Serves branch files and answers the page's bridge messages.
final class ShellIslandCoordinator: NSObject, WKURLSchemeHandler, WKScriptMessageHandlerWithReply {
    weak var engine: ShellEngine?
    let nodeID: Int
    var lastPropsJSON = ""

    init(engine: ShellEngine, nodeID: Int) {
        self.engine = engine
        self.nodeID = nodeID
    }

    // MARK: WKURLSchemeHandler

    func webView(_ webView: WKWebView, start urlSchemeTask: WKURLSchemeTask) {
        guard let url = urlSchemeTask.request.url, let branch = url.host else {
            urlSchemeTask.didFailWithError(NSError(domain: ShellIsland.scheme, code: -1, userInfo: [NSLocalizedDescriptionKey: "bad URL"]))
            return
        }
        let path = String(url.path.drop(while: { $0 == "/" }))
        let data = ShellBranchStore.shared.data(branch: branch, path: path)
        let mime = data == nil ? "text/plain; charset=utf-8" : TangSchemeHandler.mimeType(forExtension: url.pathExtension)
        let body = data ?? Data("Not found: \(path)".utf8)
        let headers = ["Content-Type": mime, "Content-Length": "\(body.count)", "Cache-Control": "no-store"]
        let response = HTTPURLResponse(url: url, statusCode: data == nil ? 404 : 200, httpVersion: "HTTP/1.1", headerFields: headers)
            ?? URLResponse(url: url, mimeType: mime, expectedContentLength: body.count, textEncodingName: nil)
        urlSchemeTask.didReceive(response)
        urlSchemeTask.didReceive(body)
        urlSchemeTask.didFinish()
    }

    func webView(_ webView: WKWebView, stop urlSchemeTask: WKURLSchemeTask) {
        // Completed synchronously in `start`.
    }

    // MARK: Bridge

    func userContentController(_ userContentController: WKUserContentController, didReceive message: WKScriptMessage, replyHandler: @escaping (Any?, String?) -> Void) {
        // Only the island's own document, served from the branch, may talk.
        guard message.frameInfo.isMainFrame,
              message.frameInfo.securityOrigin.`protocol` == ShellIsland.scheme,
              let engine,
              let body = message.body as? [String: Any],
              let type = body["type"] as? String
        else {
            replyHandler(nil, "not allowed")
            return
        }
        switch type {
        case "post":
            let payload = body["message"].map { ShellJSON(any: $0) } ?? .null
            engine.dispatch(nodeID, "onMessage", payload)
            replyHandler(nil, nil)
        case "call":
            guard let name = body["name"] as? String else {
                replyHandler(nil, "missing name")
                return
            }
            let args = body["args"].map { ShellJSON(any: $0) } ?? .null
            do {
                let result = try ShellActions.perform(name, args, engine: engine)
                engine.publishSlices()
                replyHandler(result?.jsonString() ?? "", nil)
            } catch {
                replyHandler(nil, (error as? ShellCallError)?.message ?? error.localizedDescription)
            }
        default:
            replyHandler(nil, "unknown message type")
        }
    }
}

private func makeIslandWebView(engine: ShellEngine, coordinator: ShellIslandCoordinator, src: String, remote: Bool, propsJSON: String, transparent: Bool, mobile: Bool) -> WKWebView {
    let config = WKWebViewConfiguration()
    if !remote {
        config.setURLSchemeHandler(coordinator, forURLScheme: ShellIsland.scheme)
        config.userContentController.addScriptMessageHandler(coordinator, contentWorld: .page, name: ShellIsland.handlerName)
        config.userContentController.addUserScript(WKUserScript(
            source: ShellIsland.bridgeScript(initialPropsJSON: propsJSON),
            injectionTime: .atDocumentStart,
            forMainFrameOnly: true
        ))
        // Chrome widgets don't keep cookies or site data.
        config.websiteDataStore = .nonPersistent()
    }
    let webView = WKWebView(frame: .zero, configuration: config)
    coordinator.lastPropsJSON = propsJSON
    if mobile {
        webView.customUserAgent = "Mozilla/5.0 (iPhone; CPU iPhone OS 18_0 like Mac OS X) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/18.0 Mobile/15E148 Safari/604.1"
    }
    if transparent {
        #if os(macOS)
        webView.underPageBackgroundColor = .clear
        // WKWebView paints an opaque background unless told otherwise; the
        // switch isn't in the public headers, so only use it if it's there.
        let setter = NSSelectorFromString("setDraws" + "Background:")
        if webView.responds(to: setter) {
            webView.setValue(false, forKey: "draws" + "Background")
        }
        #else
        webView.isOpaque = false
        webView.backgroundColor = .clear
        webView.scrollView.backgroundColor = .clear
        #endif
    }
    if remote, let url = URL(string: src) {
        webView.load(URLRequest(url: url))
    } else if let path = ShellBranchStore.safeRelativePath(src), let url = ShellIsland.url(branch: engine.branch, path: path) {
        webView.load(URLRequest(url: url))
    }
    return webView
}

private func updateIslandProps(_ webView: WKWebView, coordinator: ShellIslandCoordinator, propsJSON: String, remote: Bool) {
    guard !remote, coordinator.lastPropsJSON != propsJSON else { return }
    coordinator.lastPropsJSON = propsJSON
    webView.evaluateJavaScript("window.wowser && window.wowser.__setProps(\(propsJSON))", completionHandler: nil)
}

#if os(macOS)
private struct ShellIslandRepresentable: NSViewRepresentable {
    let engine: ShellEngine
    let nodeID: Int
    let src: String
    let remote: Bool
    let propsJSON: String
    let transparent: Bool
    let mobile: Bool

    func makeCoordinator() -> ShellIslandCoordinator {
        ShellIslandCoordinator(engine: engine, nodeID: nodeID)
    }

    func makeNSView(context: Context) -> WKWebView {
        makeIslandWebView(engine: engine, coordinator: context.coordinator, src: src, remote: remote, propsJSON: propsJSON, transparent: transparent, mobile: mobile)
    }

    func updateNSView(_ webView: WKWebView, context: Context) {
        updateIslandProps(webView, coordinator: context.coordinator, propsJSON: propsJSON, remote: remote)
    }
}
#else
private struct ShellIslandRepresentable: UIViewRepresentable {
    let engine: ShellEngine
    let nodeID: Int
    let src: String
    let remote: Bool
    let propsJSON: String
    let transparent: Bool
    let mobile: Bool

    func makeCoordinator() -> ShellIslandCoordinator {
        ShellIslandCoordinator(engine: engine, nodeID: nodeID)
    }

    func makeUIView(context: Context) -> WKWebView {
        makeIslandWebView(engine: engine, coordinator: context.coordinator, src: src, remote: remote, propsJSON: propsJSON, transparent: transparent, mobile: mobile)
    }

    func updateUIView(_ webView: WKWebView, context: Context) {
        updateIslandProps(webView, coordinator: context.coordinator, propsJSON: propsJSON, remote: remote)
    }
}
#endif
