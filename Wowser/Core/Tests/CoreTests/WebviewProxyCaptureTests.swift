#if os(macOS)
import XCTest
import WebKit
import Network
import Security
@testable import Core

/// Tests for the capture-proxy wiring used by `WebContent`.
///
/// NOTE on HTTPS: an end-to-end "real WKWebView loads HTTPS through the proxy
/// and we see a `proxy-tls` capture entry" test is intentionally absent. We
/// verified manually that a live `WKWebView` *does* route through the proxy
/// (the proxy logs `CONNECT … captured=true` + `MITM swap done`), but WebKit
/// then rejects the forged MITM leaf with `NSURLErrorDomain -1200` and never
/// delivers a server-trust challenge to the navigation delegate — neither the
/// async `respondTo` nor the `didReceive(completionHandler:)` variant is called
/// for proxied TLS. WebKit validates proxied-origin certs against the *system*
/// trust store only. So MITM HTTPS capture requires the LocalCA root to be
/// trusted at the system/keychain level; it cannot be unlocked from app code.
/// The proxy MITM + capture machinery itself is covered by `HTTPSCaptureTests`.
@MainActor
final class WebviewProxyCaptureTests: XCTestCase {

    func testCaptureProxyConfigurationsHelper() {
        XCTAssertTrue(WebContent.captureProxyConfigurations(port: nil).isEmpty)
        XCTAssertTrue(WebContent.captureProxyConfigurations(port: 0).isEmpty)
        XCTAssertEqual(WebContent.captureProxyConfigurations(port: 8080).count, 1)
    }

    /// The trust logic `WebContent`'s nav delegate runs: accept our LocalCA's
    /// forged leaf certs, reject any other CA's. (This logic is correct; it's
    /// just never consulted for proxied connections — see the type doc above.)
    func testLocalCATrustAcceptsForgedLeafOnly() throws {
        let ca = LocalCA(keychainService: "com.wowser.test-ca-\(UUID().uuidString)")
        _ = try ca.ensureRoot()
        let foreignCA = LocalCA(keychainService: "com.wowser.test-ca-\(UUID().uuidString)")
        _ = try foreignCA.ensureRoot()

        let leaf = try ca.leafSecCertificate(forHost: "example.com")
        let ourTrust = try makeServerTrust(leaf: leaf, host: "example.com")
        XCTAssertFalse(SecTrustEvaluateWithError(ourTrust, nil), "forged leaf must not chain to a system root")
        XCTAssertTrue(LocalCATrust.trustIsValid(ourTrust, allowingLocalCA: ca), "must trust our LocalCA's forged leaf")

        let foreignLeaf = try foreignCA.leafSecCertificate(forHost: "example.com")
        let foreignTrust = try makeServerTrust(leaf: foreignLeaf, host: "example.com")
        XCTAssertFalse(LocalCATrust.trustIsValid(foreignTrust, allowingLocalCA: ca), "must not trust a foreign CA's leaf")
    }

    /// Safety gate: a freshly generated CA must report NOT system-trusted, so
    /// the proxy blind-tunnels allowlisted HTTPS (page loads, uncaptured)
    /// instead of MITM'ing with a cert WebKit would reject (which breaks the
    /// page). Only after the user installs trust does MITM kick in.
    func testFreshLocalCAIsNotSystemTrusted() throws {
        let ca = LocalCA(keychainService: "com.wowser.test-ca-\(UUID().uuidString)")
        _ = try ca.ensureRoot()
        XCTAssertFalse(ca.isRootTrusted(forceRefresh: true))
    }

    // MARK: - Helpers

    private func makeServerTrust(leaf: SecCertificate, host: String) throws -> SecTrust {
        let policy = SecPolicyCreateSSL(true, host as CFString)
        var trust: SecTrust?
        let status = SecTrustCreateWithCertificates([leaf] as CFArray, policy, &trust)
        guard status == errSecSuccess, let trust else {
            throw NSError(domain: "WebviewProxyCaptureTests", code: Int(status))
        }
        return trust
    }
}
#endif
