import XCTest
@testable import Core

/// Pure-logic tests for suggestions, remembering submitted forms, forget /
/// never-remember, domain matching, and the in-page query's result parsing.
final class AutofillOperationsTests: XCTestCase {

    private let github = URL(string: "https://github.com/login")!

    private func classified(_ kind: AutofillFieldKind?, index: Int = 0, value: String? = nil, type: String = "text") -> AutofillClassifiedField {
        AutofillClassifiedField(
            descriptor: AutofillFieldDescriptor(fieldIndex: index, type: type, name: kind?.rawValue ?? "x", indexInForm: index, value: value),
            kind: kind, confidence: 1, reason: "test"
        )
    }

    private func sampleData() -> AutofillProfileData {
        var d = AutofillProfileData()
        d.credentials = [
            AutofillCredential(domain: "github.com", host: "github.com", username: "octocat", useCount: 5),
            AutofillCredential(domain: "github.com", host: "gist.github.com", username: "octo@example.com", useCount: 1),
            AutofillCredential(domain: "example.org", host: "example.org", username: "someone", useCount: 9),
        ]
        d.emails = [AutofillValue(value: "octo@example.com", useCount: 3), AutofillValue(value: "second@example.com", useCount: 1)]
        d.phones = [AutofillValue(value: "+1 555 010 0000")]
        d.names = [AutofillName(given: "Ada", family: "Lovelace", useCount: 2)]
        d.addresses = [AutofillAddress(line1: "1 Infinite Loop", city: "Cupertino", state: "CA", postalCode: "95014", country: "United States")]
        return d
    }

    // MARK: - Host matching

    func testRegistrableDomain() {
        XCTAssertEqual(AutofillHostMatcher.registrableDomain("www.accounts.example.com"), "example.com")
        XCTAssertEqual(AutofillHostMatcher.registrableDomain("news.bbc.co.uk"), "bbc.co.uk")
        XCTAssertEqual(AutofillHostMatcher.registrableDomain("EXAMPLE.com."), "example.com")
        XCTAssertEqual(AutofillHostMatcher.registrableDomain("localhost"), "localhost")
        XCTAssertEqual(AutofillHostMatcher.registrableDomain("192.168.1.10"), "192.168.1.10")
        XCTAssertTrue(AutofillHostMatcher.credential(domain: "github.com", appliesTo: "gist.github.com"))
        XCTAssertFalse(AutofillHostMatcher.credential(domain: "github.com", appliesTo: "github.community"))
        XCTAssertTrue(AutofillHostMatcher.isFillableURL(URL(string: "https://a.b/c")))
        XCTAssertFalse(AutofillHostMatcher.isFillableURL(URL(string: "about:blank")))
        XCTAssertFalse(AutofillHostMatcher.isFillableURL(URL(string: "file:///tmp/x.html")))
    }

    // MARK: - Suggestions

    func testUsernameOnSignInFormOffersCredentialsFirst() {
        let d = sampleData()
        let user = classified(.username, index: 0, value: "")
        let pw = classified(.password, index: 1, type: "password")
        let ctx = AutofillSuggestionContext(field: user, formFields: [user, pw], pageHost: "github.com", currentValue: "")
        let rows = d.suggestions(for: ctx)
        XCTAssertEqual(rows.first?.title, "octocat")
        if case .credential(let c) = rows.first?.payload { XCTAssertEqual(c.username, "octocat") } else { XCTFail("expected credential") }
        // Other site's login + emails come after, deduped.
        XCTAssertTrue(rows.contains { $0.title == "someone" })
        XCTAssertTrue(rows.contains { $0.title == "second@example.com" })
        XCTAssertEqual(rows.filter { $0.title == "octo@example.com" }.count, 1)
    }

    func testPasswordFieldOffersOnlyWhenEmpty() {
        let d = sampleData()
        let pw = classified(.password, index: 1, value: "", type: "password")
        let ctx = AutofillSuggestionContext(field: pw, formFields: [classified(.username), pw], pageHost: "github.com", currentValue: "")
        XCTAssertEqual(d.suggestions(for: ctx).count, 2)
        let typed = AutofillSuggestionContext(field: pw, formFields: [pw], pageHost: "github.com", currentValue: "hunter2")
        XCTAssertTrue(d.suggestions(for: typed).isEmpty)
    }

    func testNoCredentialsForOtherDomains() {
        let d = sampleData()
        let pw = classified(.password, index: 1, type: "password")
        let ctx = AutofillSuggestionContext(field: pw, formFields: [pw], pageHost: "notgithub.com", currentValue: "")
        XCTAssertTrue(d.suggestions(for: ctx).isEmpty)
    }

    func testPrefixFilteringAndAlreadyTypedValueHidden() {
        let d = sampleData()
        let email = classified(.email, value: "sec")
        let ctx = AutofillSuggestionContext(field: email, formFields: [email], pageHost: "shop.example", currentValue: "sec")
        XCTAssertEqual(d.suggestions(for: ctx).map(\.title), ["second@example.com"])
        let full = AutofillSuggestionContext(field: email, formFields: [email], pageHost: "shop.example", currentValue: "second@example.com")
        XCTAssertTrue(d.suggestions(for: full).isEmpty)
    }

    func testNameAndAddressSuggestionsCarryWholeRecords() {
        let d = sampleData()
        let given = classified(.givenName)
        let rows = d.suggestions(for: AutofillSuggestionContext(field: given, formFields: [given], pageHost: "x.com", currentValue: ""))
        XCTAssertEqual(rows.first?.title, "Ada")
        XCTAssertEqual(rows.first?.subtitle, "Ada Lovelace")
        if case .name(let n) = rows.first?.payload { XCTAssertEqual(n.family, "Lovelace") } else { XCTFail() }

        let zip = classified(.postalCode)
        let addr = d.suggestions(for: AutofillSuggestionContext(field: zip, formFields: [zip], pageHost: "x.com", currentValue: ""))
        XCTAssertEqual(addr.first?.title, "95014")
        XCTAssertEqual(addr.first?.subtitle, "1 Infinite Loop, Cupertino, CA 95014, United States")
    }

    func testNewPasswordFieldsGetNoSuggestions() {
        let d = sampleData()
        let np = classified(.newPassword, type: "password")
        XCTAssertTrue(d.suggestions(for: AutofillSuggestionContext(field: np, formFields: [np], pageHost: "github.com", currentValue: "")).isEmpty)
    }

    // MARK: - Remembering

    func testRememberLoginCreatesCredentialAndReportsPassword() {
        var d = AutofillProfileData()
        let sub = AutofillFormSubmission(url: github, entries: [.init(kind: .username, value: "octocat"), .init(kind: .password, value: "hunter2")])
        let outcome = d.remember(sub)
        XCTAssertEqual(outcome?.credential?.username, "octocat")
        XCTAssertEqual(outcome?.credential?.domain, "github.com")
        XCTAssertEqual(outcome?.password, "hunter2")
        XCTAssertEqual(outcome?.isNewCredential, true)
        XCTAssertEqual(d.credentials.count, 1)

        // Same login again: updated, not duplicated.
        let again = d.remember(sub)
        XCTAssertEqual(again?.isNewCredential, false)
        XCTAssertEqual(d.credentials.count, 1)
        XCTAssertEqual(d.credentials[0].useCount, 2)
    }

    func testRememberUsesEmailAsUsernameAndSavesIdentity() {
        var d = AutofillProfileData()
        let sub = AutofillFormSubmission(url: URL(string: "https://shop.example.com/checkout")!, entries: [
            .init(kind: .email, value: "Ada@Example.com"),
            .init(kind: .givenName, value: "Ada"), .init(kind: .familyName, value: "Lovelace"),
            .init(kind: .phone, value: "555-010-0000"),
            .init(kind: .streetAddress, value: "1 Infinite Loop"), .init(kind: .city, value: "Cupertino"),
            .init(kind: .state, value: "CA"), .init(kind: .postalCode, value: "95014"),
            .init(kind: .newPassword, value: "pw"), .init(kind: .newPassword, value: "pw"),
        ])
        let outcome = d.remember(sub)!
        XCTAssertEqual(outcome.credential?.username, "Ada@Example.com")
        XCTAssertEqual(Set(outcome.savedIdentityKinds), [.fullName, .email, .phone, .streetAddress])
        XCTAssertEqual(d.emails.map(\.value), ["ada@example.com"])
        XCTAssertEqual(d.names.first?.full, "Ada Lovelace")
        XCTAssertEqual(d.addresses.first?.oneLine, "1 Infinite Loop, Cupertino, CA 95014")
        XCTAssertEqual(outcome.touchedIDs.count, 5)

        // Resubmitting known identity is not news (no toast), but bumps usage.
        let second = d.remember(AutofillFormSubmission(url: URL(string: "https://other.example/x")!, entries: [.init(kind: .email, value: "ada@example.com")]))
        XCTAssertNil(second)
        XCTAssertEqual(d.emails.first?.useCount, 2)
    }

    func testMismatchedNewPasswordsAreNotSaved() {
        var d = AutofillProfileData()
        let sub = AutofillFormSubmission(url: github, entries: [.init(kind: .username, value: "u"), .init(kind: .newPassword, value: "a"), .init(kind: .newPassword, value: "b")])
        XCTAssertNil(d.remember(sub))
        XCTAssertTrue(d.credentials.isEmpty)
    }

    func testPasswordOnlyFormUpdatesTheSitesOnlyLogin() {
        var d = sampleData()
        d.credentials = [AutofillCredential(domain: "example.org", host: "example.org", username: "someone")]
        let sub = AutofillFormSubmission(url: URL(string: "https://example.org/reauth")!, entries: [.init(kind: .password, value: "new")])
        let outcome = d.remember(sub)
        XCTAssertEqual(outcome?.credential?.username, "someone")
        XCTAssertEqual(outcome?.password, "new")
    }

    func testNeverRememberDomainBlocksAndForgets() {
        var d = sampleData()
        let removed = d.neverRemember(domain: "gist.github.com")
        XCTAssertEqual(removed.count, 2)
        XCTAssertTrue(d.neverRememberDomains.contains("github.com"))
        XCTAssertNil(d.remember(AutofillFormSubmission(url: github, entries: [.init(kind: .username, value: "u"), .init(kind: .password, value: "p")])))
    }

    func testForgetRemovesAcrossLists() {
        var d = sampleData()
        let ids: Set<UUID> = [d.credentials[0].id, d.emails[0].id, d.names[0].id, d.addresses[0].id]
        let removedCreds = d.forget(ids: ids)
        XCTAssertEqual(removedCreds.count, 1)
        XCTAssertEqual(d.credentials.count, 2)
        XCTAssertEqual(d.emails.count, 1)
        XCTAssertTrue(d.names.isEmpty)
        XCTAssertTrue(d.addresses.isEmpty)
    }

    func testNonWebURLsAreIgnored() {
        var d = AutofillProfileData()
        XCTAssertNil(d.remember(AutofillFormSubmission(url: URL(string: "about:blank")!, entries: [.init(kind: .username, value: "u"), .init(kind: .password, value: "p")])))
    }

    func testSystemPromptSummaryNeverContainsPasswords() {
        let summary = sampleData().systemPromptSummary()!
        XCTAssertTrue(summary.contains("Ada Lovelace"))
        XCTAssertTrue(summary.contains("octo@example.com"))
        XCTAssertTrue(summary.contains("github.com"))
        XCTAssertFalse(summary.lowercased().contains("hunter"))
        XCTAssertNil(AutofillProfileData().systemPromptSummary())
    }

    // MARK: - Query parsing

    func testSnapshotParsing() {
        let raw: [String: Any] = [
            "url": "https://github.com/login",
            "active": ["fieldIndex": 3, "tag": "input", "type": "text", "name": "login", "id": "login_field", "autocomplete": "username",
                       "value": "oct", "rect": ["x": 10.0, "y": 20.0, "width": 200.0, "height": 30.0], "framePath": [Int](),
                       "formIndex": 0, "formHasPassword": true, "passwordFieldCount": 1, "indexInForm": 0, "textFieldCountInForm": 2],
            "activeSelect": NSNull(),
            "form": [
                ["fieldIndex": 3, "tag": "input", "type": "text", "name": "login"],
                ["fieldIndex": 4, "tag": "input", "type": "password", "name": "password", "value": "s3cret"],
            ],
            "selects": [["fieldIndex": 9, "rect": ["x": 1, "y": 2, "width": 3, "height": 4]]],
        ]
        let snap = AutofillFieldQuery.parseSnapshot(raw)!
        XCTAssertEqual(snap.url?.host, "github.com")
        XCTAssertEqual(snap.active?.name, "login")
        XCTAssertEqual(snap.active?.value, "oct")
        XCTAssertEqual(snap.active?.rect?.width, 200)
        XCTAssertEqual(snap.form.count, 2)
        XCTAssertEqual(snap.form[1].value, "s3cret")
        XCTAssertEqual(snap.selects.first?.fieldIndex, 9)
        XCTAssertEqual(snap.selects.first?.rect.height, 4)
        XCTAssertEqual(snap.active?.signature, "[]/3/input/text/login/login_field")
    }

    func testSelectInfoParsing() {
        let field = AutofillFieldDescriptor(fieldIndex: 2, tag: "select", type: "select", name: "state")
        let info = AutofillFieldQuery.parseSelectInfo(["selectedIndex": 1, "options": [
            ["index": 0, "label": "Choose…", "value": "", "disabled": true],
            ["index": 1, "label": "California", "value": "CA", "group": "West"],
        ]], field: field)!
        XCTAssertEqual(info.selectedIndex, 1)
        XCTAssertEqual(info.options.count, 2)
        XCTAssertEqual(info.options[1].group, "West")
        XCTAssertTrue(info.options[0].disabled)
    }

    func testQueryJSIsWellFormedCalls() {
        XCTAssertTrue(AutofillFieldQuery.snapshotActiveJS.hasSuffix("({mode: 'active'})"))
        XCTAssertTrue(AutofillFieldQuery.selectAtPointJS(x: 1.5, y: 2).contains("mode: 'point'"))
        XCTAssertTrue(AutofillFieldQuery.focusFieldJS(.init(fieldIndex: 4, framePath: [1]), selectAll: true).contains("{fieldIndex: 4, framePath: [1]}"))
    }
}
