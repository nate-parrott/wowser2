import XCTest
@testable import Core

#if os(macOS)
/// The `browser.credentials.*` / `browser.profile.get()` BrowserJS surface:
/// bridge JS → dispatch → host, through the real JSContext runtime.
final class AutofillBrowserJSTests: XCTestCase {

    func testCredentialsLookupAndHasPassword() async throws {
        let host = AutofillMockHost()
        let rt = BrowserJSRuntime(host: host, helpers: AutofillMemoryHelpers())
        let r = await rt.run(code: """
        const list = await browser.credentials.lookup("github.com");
        const yes = await browser.credentials.hasPassword("github.com", { username: "octocat" });
        const no = await browser.credentials.hasPassword("github.com", { username: "nobody" });
        return { names: list.map(c => c.username), yes, no };
        """)
        XCTAssertNil(r.error, r.error ?? "")
        let obj = try XCTUnwrap(json(r.result))
        XCTAssertEqual(obj["names"] as? [String], ["octocat"])
        XCTAssertEqual(obj["yes"] as? Bool, true)
        XCTAssertEqual(obj["no"] as? Bool, false)
        XCTAssertEqual(host.lookups, ["github.com"])
    }

    func testFillPasswordPassesThroughAndNeverReturnsSecret() async throws {
        let host = AutofillMockHost()
        let rt = BrowserJSRuntime(host: host, helpers: AutofillMemoryHelpers())
        let r = await rt.run(code: """
        const out = await browser.credentials.fillPassword("t1", { username: "octocat", domain: "github.com" });
        return out;
        """)
        XCTAssertNil(r.error, r.error ?? "")
        let obj = try XCTUnwrap(json(r.result))
        XCTAssertEqual(obj["filled"] as? Bool, true)
        XCTAssertEqual(obj["username"] as? String, "octocat")
        XCTAssertEqual(host.fills.count, 1)
        XCTAssertEqual(host.fills.first?.tabId, "t1")
        XCTAssertEqual(host.fills.first?.domain, "github.com")
        XCTAssertFalse(r.result?.contains("hunter2") ?? true)
    }

    func testFillPasswordErrorsSurfaceAsJSErrors() async throws {
        let host = AutofillMockHost()
        host.fillError = "the focused element is not a password field"
        let rt = BrowserJSRuntime(host: host, helpers: AutofillMemoryHelpers())
        let r = await rt.run(code: """
        try { await browser.credentials.fillPassword("t1"); return "filled"; }
        catch (e) { return "error: " + e.message; }
        """)
        XCTAssertNil(r.error, r.error ?? "")
        XCTAssertEqual(r.result, #""error: the focused element is not a password field""#)
    }

    func testProfileGet() async throws {
        let host = AutofillMockHost()
        let rt = BrowserJSRuntime(host: host, helpers: AutofillMemoryHelpers())
        let r = await rt.run(code: """
        const p = await browser.profile.get();
        return [p.name, p.emails[0], p.addresses[0].oneLine, p.savedLoginDomains.length];
        """)
        XCTAssertNil(r.error, r.error ?? "")
        XCTAssertEqual(r.result, #"["Ada Lovelace","ada@example.com","1 Infinite Loop, Cupertino, CA 95014",1]"#)
    }

    private func json(_ s: String?) -> [String: Any]? {
        guard let s, let data = s.data(using: .utf8) else { return nil }
        return (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
    }

    func testDocsMentionCredentialsAndProfile() {
        let dts = BrowserJSDocs.dts
        XCTAssertTrue(dts.contains("credentials: {"))
        XCTAssertTrue(dts.contains("fillPassword(tabId: TabId"))
        XCTAssertTrue(dts.contains("profile: {"))
        XCTAssertTrue(dts.contains("interface ProfileInfo"))
    }
}

// MARK: - Test doubles

private final class AutofillMockHost: BrowserJSHost, @unchecked Sendable {
    var lookups: [String] = []
    var fills: [(tabId: String, username: String?, domain: String?)] = []
    var fillError: String?

    private let creds = [BrowserJSCredentialInfo(id: "c1", username: "octocat", domain: "github.com", host: "github.com", lastUsed: 0)]

    func credentialsLookup(domain: String, spaceId: String?) async throws -> [BrowserJSCredentialInfo] {
        lookups.append(domain)
        return creds.filter { AutofillHostMatcher.credential(domain: $0.domain, appliesTo: domain) }
    }
    func credentialsHasPassword(domain: String, username: String?, spaceId: String?) async throws -> Bool {
        creds.contains { AutofillHostMatcher.credential(domain: $0.domain, appliesTo: domain) && (username == nil || $0.username == username) }
    }
    func credentialsFillPassword(tabId: String, username: String?, domain: String?) async throws -> BrowserJSFillPasswordResult {
        if let fillError { throw BrowserJSError.underlying(fillError) }
        fills.append((tabId, username, domain))
        return BrowserJSFillPasswordResult(filled: true, username: username ?? "octocat")
    }
    func profileGet(spaceId: String?) async throws -> BrowserJSProfileInfo {
        BrowserJSProfileInfo(
            name: "Ada Lovelace", givenName: "Ada", familyName: "Lovelace", names: ["Ada Lovelace"],
            emails: ["ada@example.com"], phones: [], organizations: [],
            addresses: [BrowserJSAddressInfo(line1: "1 Infinite Loop", line2: "", city: "Cupertino", state: "CA", postalCode: "95014", country: "", oneLine: "1 Infinite Loop, Cupertino, CA 95014")],
            savedLoginDomains: ["github.com"]
        )
    }

    // Unused surface.
    func tabsList(windowId: String?, spaceId: String?) async throws -> [BrowserJSTabInfo] { [] }
    func tabsOpen(url: String, background: Bool, windowId: String?) async throws -> String { "t1" }
    func tabsOpenGhost(url: String, windowId: String?) async throws -> String { "t1" }
    func tabsOpenHTML(html: String, title: String?, windowId: String?) async throws -> String { "t1" }
    func tabsClose(id: String) async throws {}
    func tabsActivate(id: String) async throws {}
    func tabsMove(id: String, toIndex: Int) async throws {}
    func tabsGet(id: String) async throws -> BrowserJSTabInfo { BrowserJSTabInfo(id: id) }
    func tabsNavigate(id: String, url: String) async throws {}
    func contentRead(id: String, as kind: String) async throws -> String { "" }
    func contentScreenshot(id: String) async throws -> BrowserJSImage { BrowserJSImage(mime: "image/png", data: "") }
    func pageEval(id: String, js: String) async throws -> Any? { nil }
    func pageWaitFor(id: String, predicateJs: String, timeoutMs: Int) async throws -> Any? { true }
    func pageClick(id: String, x: Double, y: Double, button: String, clickCount: Int) async throws {}
    func pageType(id: String, text: String) async throws {}
    func pageKey(id: String, key: String, modifiers: [String]) async throws {}
    func pageScroll(id: String, dx: Double, dy: Double) async throws {}
    func windowsList() async throws -> [BrowserJSWindowInfo] { [] }
    func windowsGetCurrent() async throws -> BrowserJSWindowInfo? { nil }
    func windowsGetById(id: String) async throws -> BrowserJSWindowInfo? { nil }
    func netLog(filter: NetLogFilter) async throws -> [NetEntrySummary] { [] }
    func netGrep(pattern: String, where field: String) async throws -> [NetEntrySummary] { [] }
    func netFetch(req: NetFetchRequest) async throws -> NetFetchResponse { NetFetchResponse(status: 0, headers: [:], body: "") }
    func netReplay(entryId: String, overrides: NetFetchRequest?) async throws -> NetFetchResponse { NetFetchResponse(status: 0, headers: [:], body: "") }
    func netCaptureOrigin(origin: String, enabled: Bool) async throws {}
}

private final class AutofillMemoryHelpers: BrowserJSHelpersProvider, @unchecked Sendable {
    func saveHelper(name: String, content: String) throws {}
    func readHelper(name: String) throws -> String? { nil }
    func listHelpers() throws -> [(name: String, content: String)] { [] }
    func concatenatedHelpers() throws -> String { "" }
}
#endif
