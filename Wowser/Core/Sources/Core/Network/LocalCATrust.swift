#if os(macOS)
import Foundation
import Security

/// Validate a server trust against the system root store *plus* our private
/// `LocalCA`. Used in two places:
///
/// 1. `WebContent` overrides `WKNavigationDelegate.didReceive:` to accept
///    server certs that root in our LocalCA — that's how our own webviews
///    trust the forged leaf certs the local proxy presents.
/// 2. `LocalProxy`'s upstream forwarder (URLSession) uses this to talk to
///    self-signed test origins that we deliberately set up signed by our CA
///    so the integration test loop closes end-to-end.
public enum LocalCATrust {
    /// Returns `true` if the trust evaluates either against the system roots
    /// or against our LocalCA root.
    public static func trustIsValid(_ trust: SecTrust, allowingLocalCA ca: LocalCA = .shared) -> Bool {
        // First try strict system trust — fast path for real public certs.
        var error: CFError?
        if SecTrustEvaluateWithError(trust, &error) { return true }

        // Otherwise, add our LocalCA root as an anchor and re-evaluate.
        do {
            let rootSec = try ca.rootSecCertificate()
            // Set our root as an anchor *additionally* to system roots.
            SecTrustSetAnchorCertificates(trust, [rootSec] as CFArray)
            SecTrustSetAnchorCertificatesOnly(trust, false)
            error = nil
            return SecTrustEvaluateWithError(trust, &error)
        } catch {
            return false
        }
    }
}

/// `URLSessionDelegate` that defers TLS validation to `LocalCATrust`. Use it
/// for any URLSession that legitimately needs to accept LocalCA-signed certs
/// (the proxy's upstream forwarder; integration tests that talk to a
/// LocalCA-issued test origin).
final class LocalCATrustingSessionDelegate: NSObject, URLSessionDelegate, @unchecked Sendable {
    let ca: LocalCA
    init(ca: LocalCA = .shared) { self.ca = ca }
    func urlSession(_ session: URLSession,
                    didReceive challenge: URLAuthenticationChallenge,
                    completionHandler: @escaping (URLSession.AuthChallengeDisposition, URLCredential?) -> Void) {
        guard challenge.protectionSpace.authenticationMethod == NSURLAuthenticationMethodServerTrust,
              let trust = challenge.protectionSpace.serverTrust
        else {
            completionHandler(.performDefaultHandling, nil)
            return
        }
        if LocalCATrust.trustIsValid(trust, allowingLocalCA: ca) {
            completionHandler(.useCredential, URLCredential(trust: trust))
        } else {
            completionHandler(.cancelAuthenticationChallenge, nil)
        }
    }
}
#endif
