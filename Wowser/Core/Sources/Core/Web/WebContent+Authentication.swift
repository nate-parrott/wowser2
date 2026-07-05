import WebKit
#if os(macOS)
import Network
#endif

extension WebContent {
    #if os(macOS)
    // MARK: - Capture proxy wiring

    /// Proxy configuration that points a webview's data store at the local
    /// capturing proxy. Returns `[]` when the proxy isn't running yet, in which
    /// case traffic flows normally (uncaptured). Exposed (and pure) so it can be
    /// unit-tested without constructing a full `WebContent`.
    static func captureProxyConfigurations(port: Int?) -> [ProxyConfiguration] {
        // Master kill switch: route all traffic directly, bypassing the
        // capturing proxy (no HTTP capture, no HTTPS MITM). Useful when the
        // proxy/MITM path breaks page loads.
        if DefaultsKeys.disableNetworkProxy.boolValue() {
            return []
        }
        guard let port, let nwPort = NWEndpoint.Port(rawValue: UInt16(truncatingIfNeeded: port)), port > 0 else {
            return []
        }
        let endpoint = NWEndpoint.hostPort(host: "127.0.0.1", port: nwPort)
        return [ProxyConfiguration(httpCONNECTProxy: endpoint)]
    }
    #endif

    // MARK: - HTTP authentication challenges

    /// Handles per-request authentication challenges. For HTTP basic/digest/NTLM
    /// auth we prompt the user for credentials; TLS server-trust challenges are
    /// validated against the system roots *plus* our `LocalCA` so our own
    /// webviews accept the forged leaf certs the capturing proxy presents for
    /// allowlisted origins. Everything else falls back to default handling.
    public func webView(_ webView: WKWebView, respondTo challenge: URLAuthenticationChallenge) async -> (URLSession.AuthChallengeDisposition, URLCredential?) {
        let method = challenge.protectionSpace.authenticationMethod

        #if os(macOS)
        if method == NSURLAuthenticationMethodServerTrust, let trust = challenge.protectionSpace.serverTrust {
            // Accept real public certs (system roots) and our own MITM leaf
            // certs (LocalCA). A genuinely bad cert validates against neither,
            // so we defer to default handling, which rejects it.
            if LocalCATrust.trustIsValid(trust, allowingLocalCA: .shared) {
                return (.useCredential, URLCredential(trust: trust))
            }
            return (.performDefaultHandling, nil)
        }
        #endif

        let promptableMethods: Set<String> = [
            NSURLAuthenticationMethodHTTPBasic,
            NSURLAuthenticationMethodHTTPDigest,
            NSURLAuthenticationMethodNTLM,
        ]
        guard promptableMethods.contains(method) else {
            return (.performDefaultHandling, nil)
        }

        let space = challenge.protectionSpace
        let host = space.host
        let realm = space.realm
        let message: String
        if let realm, !realm.isEmpty {
            message = "Your sign-in to \(host) (\(realm))."
        } else {
            message = "Your sign-in to \(host)."
        }

        let credentials = await Alerts.showAppLoginPrompt(
            title: "Sign in to \(host)",
            message: message,
            baseView: webview
        )

        guard let credentials else {
            return (.cancelAuthenticationChallenge, nil)
        }

        let credential = URLCredential(
            user: credentials.username,
            password: credentials.password,
            persistence: .forSession
        )
        return (.useCredential, credential)
    }
}
