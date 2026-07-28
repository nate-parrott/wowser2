import Foundation
#if os(macOS)
import WebKit
#endif

/// Performs URL requests from the app process (bypassing the page's webview)
/// and records them into `NetworkCaptureStore` so the agent can introspect
/// the round-trip via `browser.net.log` / `browser.net.grep`. Used by
/// `browser.net.fetch` and `browser.net.replay`.
enum NetworkSyntheticFetch {
    static func fetch(_ req: NetFetchRequest, captureStore: NetworkCaptureStore) async throws -> NetFetchResponse {
        guard let urlStr = req.url, let url = URL(string: urlStr) else {
            throw BrowserJSError.invalidArgs("url")
        }
        var urlReq = URLRequest(url: url)
        urlReq.httpMethod = (req.method ?? "GET").uppercased()
        for (k, v) in req.headers ?? [:] { urlReq.setValue(v, forHTTPHeaderField: k) }
        if let body = req.body, !body.isEmpty {
            urlReq.httpBody = Data(body.utf8)
        }
        // Cookie attachment (Q32: no raw cookie API; expose via fetch only).
        await attachCookies(to: &urlReq, source: req.cookiesFrom, url: url)

        #if os(macOS)
        let session = URLSession(configuration: .ephemeral, delegate: LocalCATrustingSessionDelegate(), delegateQueue: nil)
        #else
        let session = URLSession(configuration: .ephemeral)
        #endif
        let (data, response) = try await session.data(for: urlReq)
        guard let http = response as? HTTPURLResponse else {
            throw BrowserJSError.underlying("non-HTTP response from \(url)")
        }
        let respHeaders: [String: String] = http.allHeaderFields.reduce(into: [:]) { acc, kv in
            if let k = kv.key as? String, let v = kv.value as? String { acc[k] = v }
        }
        let bodyText = String(data: data, encoding: .utf8) ?? data.base64EncodedString()
        // Always record a synthetic entry, regardless of allowlist — but only
        // if the origin is explicitly captured. The store enforces this.
        let entry = NetCaptureEntry(
            url: url.absoluteString,
            method: urlReq.httpMethod ?? "GET",
            status: http.statusCode,
            requestHeaders: req.headers ?? [:],
            requestBody: req.body,
            responseHeaders: respHeaders,
            responseBody: bodyText,
            tabId: nil,
            source: "synth"
        )
        await captureStore.record(entry)
        return NetFetchResponse(status: http.statusCode, headers: respHeaders, body: bodyText)
    }

    private static func attachCookies(to req: inout URLRequest, source: String?, url: URL) async {
        guard let source else { return }
        #if os(macOS)
        // Source can be "domain" (use any cookies for this URL across all
        // profiles' websiteDataStores) or a tabId (use that tab's profile).
        if source == "domain" {
            let cookies = await Self.cookies(for: url, store: WKWebsiteDataStore.default().httpCookieStore)
            applyCookies(cookies, to: &req)
            return
        }
        // Tab-scoped: look up the WebContent's profile data store.
        let pid = ID<WebContent>(raw: source)
        let store = await MainActor.run { () -> WKHTTPCookieStore? in
            guard let winID = BrowserStore.shared.model.windowContaining(webContentId: pid)?.id,
                  let wc = BrowserStore.shared.getOrCreateWebContent(forId: pid, toBeActiveInWindow: winID)
            else { return nil }
            return wc.wkWebview?.configuration.websiteDataStore.httpCookieStore
        }
        if let store {
            let cookies = await Self.cookies(for: url, store: store)
            applyCookies(cookies, to: &req)
        }
        #endif
    }

    #if os(macOS)
    private static func cookies(for url: URL, store: WKHTTPCookieStore) async -> [HTTPCookie] {
        await withCheckedContinuation { (cont: CheckedContinuation<[HTTPCookie], Never>) in
            store.getAllCookies { all in
                let filtered = all.filter { ck in
                    let domain = ck.domain.hasPrefix(".") ? String(ck.domain.dropFirst()) : ck.domain
                    let host = url.host ?? ""
                    return host == domain || host.hasSuffix("." + domain)
                }
                cont.resume(returning: filtered)
            }
        }
    }

    private static func applyCookies(_ cookies: [HTTPCookie], to req: inout URLRequest) {
        guard !cookies.isEmpty else { return }
        let headers = HTTPCookie.requestHeaderFields(with: cookies)
        for (k, v) in headers { req.setValue(v, forHTTPHeaderField: k) }
    }
    #endif
}
