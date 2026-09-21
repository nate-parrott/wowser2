import XCTest
@testable import Core

/// Benchmarks `AutofillFieldClassifier` against form fields captured from
/// real sites (`Fixtures/autofill/fetched_sites.json`: sign-in, sign-up and
/// checkout pages fetched as served) plus reconstructed forms for pages that
/// need a session or are JS-rendered (`reconstructed_sites.json`: Shopify /
/// Stripe / Amazon address forms, big-name logins, non-English forms).
///
/// Each fixture field lists the acceptable kinds; "none" means the classifier
/// must NOT offer autofill (search boxes, OTP codes, card numbers, dates…).
/// Regenerate with `scripts/autofill_bench/` (see the README there).
final class AutofillClassifierTests: XCTestCase {

    private struct FixturePage: Decodable {
        var site: String
        var source: String
        var fields: [FixtureField]
    }
    private struct FixtureField: Decodable {
        var expected: [String]
        var descriptor: AutofillFieldDescriptor
        private enum K: String, CodingKey { case expected }
        init(from decoder: Decoder) throws {
            expected = try decoder.container(keyedBy: K.self).decode([String].self, forKey: .expected)
            descriptor = try AutofillFieldDescriptor(from: decoder)
        }
    }

    private struct Score {
        var total = 0
        var correct = 0
        var missedFills = 0   // expected a kind, got none
        var falseFills = 0    // expected none, got a kind
        var wrongKind = 0
        var misses: [String] = []
        var accuracy: Double { total == 0 ? 1 : Double(correct) / Double(total) }
    }

    private func loadFixture(_ name: String) throws -> [FixturePage] {
        let here = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
        var url = here.appendingPathComponent("Fixtures/autofill/\(name)")
        if !FileManager.default.fileExists(atPath: url.path),
           let bundled = Bundle.module.url(forResource: "autofill/\(name)", withExtension: nil, subdirectory: "Fixtures") {
            url = bundled
        }
        let data = try Data(contentsOf: url)
        return try JSONDecoder().decode([FixturePage].self, from: data)
    }

    private func score(_ pages: [FixturePage]) -> Score {
        var s = Score()
        for page in pages {
            // Mirrors runtime: fields are classified per form, with siblings.
            let results = AutofillFieldClassifier.classify(fields: page.fields.map(\.descriptor))
            for (field, result) in zip(page.fields, results) {
                s.total += 1
                let got = result.kind?.rawValue ?? "none"
                if field.expected.contains(got) { s.correct += 1; continue }
                if got == "none" { s.missedFills += 1 } else if field.expected == ["none"] { s.falseFills += 1 } else { s.wrongKind += 1 }
                let d = field.descriptor
                s.misses.append("[\(page.site)] #\(d.fieldIndex) \(d.tag)/\(d.type) name=\(d.name) id=\(d.id) label=\(d.label.prefix(40)) → \(got) (\(result.reason)); expected \(field.expected)")
            }
        }
        return s
    }

    func testBenchmarkFetchedSites() throws {
        let s = score(try loadFixture("fetched_sites.json"))
        print("[autofill bench] fetched: \(s.correct)/\(s.total) (\(Int(s.accuracy * 100))%) missed=\(s.missedFills) false=\(s.falseFills) wrong=\(s.wrongKind)")
        s.misses.forEach { print("  MISS \($0)") }
        XCTAssertGreaterThan(s.total, 250, "fixture looks truncated")
        // False fills are the dangerous kind (typing an address into a search
        // box); hold them to zero and keep overall accuracy high.
        XCTAssertEqual(s.falseFills, 0, "classifier offers autofill on fields it must not:\n" + s.misses.joined(separator: "\n"))
        XCTAssertGreaterThanOrEqual(s.accuracy, 0.97, s.misses.joined(separator: "\n"))
    }

    func testBenchmarkReconstructedSites() throws {
        let s = score(try loadFixture("reconstructed_sites.json"))
        print("[autofill bench] reconstructed: \(s.correct)/\(s.total) (\(Int(s.accuracy * 100))%)")
        s.misses.forEach { print("  MISS \($0)") }
        XCTAssertGreaterThan(s.total, 100)
        XCTAssertEqual(s.falseFills, 0, s.misses.joined(separator: "\n"))
        XCTAssertGreaterThanOrEqual(s.accuracy, 0.97, s.misses.joined(separator: "\n"))
    }

    // MARK: - Targeted rules

    func testNormalizeSplitsCamelCaseAndBrackets() {
        XCTAssertEqual(AutofillFieldClassifier.normalize("checkout[shipping_address][first_name]"), "checkout shipping address first name")
        XCTAssertEqual(AutofillFieldClassifier.normalize("emailAddressField"), "email address field")
        XCTAssertEqual(AutofillFieldClassifier.normalize("address-ui-widgets-enterAddressLine2"), "address ui widgets enter address line 2")
        XCTAssertEqual(AutofillFieldClassifier.normalize("Prénom"), "prenom")
    }

    func testAutocompleteBeatsEverything() {
        let f = AutofillFieldDescriptor(type: "text", name: "search", autocomplete: "shipping given-name", placeholder: "Search")
        XCTAssertEqual(AutofillFieldClassifier.classify(f).kind, .givenName)
        let never = AutofillFieldDescriptor(type: "text", name: "name", autocomplete: "cc-number")
        XCTAssertNil(AutofillFieldClassifier.classify(never).kind)
    }

    func testHoneypotAutocompleteOnTextFieldIsIgnored() {
        let f = AutofillFieldDescriptor(type: "text", name: "country", autocomplete: "new-password", label: "country")
        XCTAssertEqual(AutofillFieldClassifier.classify(f).kind, .country)
    }

    func testNonTextInputsNeverFill() {
        for type in ["hidden", "checkbox", "radio", "submit", "file", "date", "search", "url"] {
            let f = AutofillFieldDescriptor(type: type, name: "email")
            XCTAssertNil(AutofillFieldClassifier.classify(f).kind, type)
        }
        XCTAssertNil(AutofillFieldClassifier.classify(AutofillFieldDescriptor(tag: "textarea", type: "textarea", name: "address")).kind)
    }

    func testAdjacentPasswordsAreSignUpButSeparatedOnesAreLogins() {
        // create + confirm
        let signup = [
            AutofillFieldDescriptor(fieldIndex: 0, type: "text", name: "user", formIndex: 0, formHasPassword: true, passwordFieldCount: 2, indexInForm: 0, textFieldCountInForm: 3),
            AutofillFieldDescriptor(fieldIndex: 1, type: "password", name: "pw", formIndex: 0, formHasPassword: true, passwordFieldCount: 2, indexInForm: 1, textFieldCountInForm: 3),
            AutofillFieldDescriptor(fieldIndex: 2, type: "password", name: "pw2", formIndex: 0, formHasPassword: true, passwordFieldCount: 2, indexInForm: 2, textFieldCountInForm: 3),
        ]
        let r = AutofillFieldClassifier.classify(fields: signup)
        XCTAssertEqual(r.map(\.kind), [.username, .newPassword, .newPassword])

        // two login widgets in one page-wide form
        let twoLogins = [
            AutofillFieldDescriptor(fieldIndex: 0, type: "text", name: "LoginUserName", formIndex: 0, formHasPassword: true, passwordFieldCount: 2, indexInForm: 0, textFieldCountInForm: 5),
            AutofillFieldDescriptor(fieldIndex: 1, type: "password", name: "LoginPassword", formIndex: 0, formHasPassword: true, passwordFieldCount: 2, indexInForm: 1, textFieldCountInForm: 5),
            AutofillFieldDescriptor(fieldIndex: 2, type: "search", name: "q", formIndex: 0, formHasPassword: true, passwordFieldCount: 2, indexInForm: 2, textFieldCountInForm: 5),
            AutofillFieldDescriptor(fieldIndex: 3, type: "text", name: "LoginUserName", formIndex: 0, formHasPassword: true, passwordFieldCount: 2, indexInForm: 3, textFieldCountInForm: 5),
            AutofillFieldDescriptor(fieldIndex: 4, type: "password", name: "LoginPassword", formIndex: 0, formHasPassword: true, passwordFieldCount: 2, indexInForm: 4, textFieldCountInForm: 5),
        ]
        let r2 = AutofillFieldClassifier.classify(fields: twoLogins)
        XCTAssertEqual(r2.map(\.kind), [.username, .password, nil, .username, .password])
    }

    func testUnlabeledFieldBeforePasswordIsUsername() {
        let fields = [
            AutofillFieldDescriptor(fieldIndex: 0, type: "text", id: "field-1", formIndex: 0, formHasPassword: true, passwordFieldCount: 1, indexInForm: 0, textFieldCountInForm: 2),
            AutofillFieldDescriptor(fieldIndex: 1, type: "password", id: "field-2", formIndex: 0, formHasPassword: true, passwordFieldCount: 1, indexInForm: 1, textFieldCountInForm: 2),
        ]
        XCTAssertEqual(AutofillFieldClassifier.classify(fields: fields).map(\.kind), [.username, .password])
    }

    func testLocatorBoxMentioningSeveralAddressPartsIsNotAnAddress() {
        let f = AutofillFieldDescriptor(type: "text", name: "qp", ariaLabel: "City, State or ZIP")
        XCTAssertNil(AutofillFieldClassifier.classify(f).kind)
    }

    func testTelTypedZipIsPostalCode() {
        let f = AutofillFieldDescriptor(type: "tel", name: "ZipCode", label: "ZIP Code")
        XCTAssertEqual(AutofillFieldClassifier.classify(f).kind, .postalCode)
    }

    func testDescriptorDecodingIsTolerant() throws {
        let json = #"{"tag":"input","type":"EMAIL","name":"e"}"#
        let d = try JSONDecoder().decode(AutofillFieldDescriptor.self, from: Data(json.utf8))
        XCTAssertEqual(d.type, "email")
        XCTAssertEqual(d.fieldIndex, 0)
        XCTAssertFalse(d.formHasPassword)
    }
}
