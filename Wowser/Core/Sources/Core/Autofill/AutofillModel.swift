import Foundation

// MARK: - Field kinds

/// What a form field is asking for. Produced by `AutofillFieldClassifier`,
/// consumed by the suggestion engine and by form-submission capture.
public enum AutofillFieldKind: String, Codable, CaseIterable, Sendable, Hashable {
    case username
    case password        // an existing password (sign-in)
    case newPassword     // a password being created / confirmed (sign-up, change password)
    case email
    case phone
    case givenName
    case familyName
    case fullName
    case streetAddress
    case addressLine2
    case city
    case state
    case postalCode
    case country
    case organization

    public var isPassword: Bool { self == .password || self == .newPassword }
    public var isName: Bool { self == .givenName || self == .familyName || self == .fullName }
    public var isAddressPart: Bool {
        switch self {
        case .streetAddress, .addressLine2, .city, .state, .postalCode, .country: return true
        default: return false
        }
    }
    /// Fields that identify the account on a sign-in form.
    public var isLoginIdentifier: Bool { self == .username || self == .email || self == .phone }

    public var displayName: String {
        switch self {
        case .username: return "Username"
        case .password: return "Password"
        case .newPassword: return "New password"
        case .email: return "Email"
        case .phone: return "Phone"
        case .givenName: return "First name"
        case .familyName: return "Last name"
        case .fullName: return "Name"
        case .streetAddress: return "Street address"
        case .addressLine2: return "Address line 2"
        case .city: return "City"
        case .state: return "State"
        case .postalCode: return "Postal code"
        case .country: return "Country"
        case .organization: return "Company"
        }
    }
}

// MARK: - Persisted profile data (non-secret)

/// Everything autofill remembers, keyed by space/profile. Passwords are NOT
/// in here — they live in the keychain, referenced by `AutofillCredential.id`.
/// Persisted as JSON by `AutofillStore`.
public struct AutofillState: Equatable, Codable {
    public var profiles: [ID<Profile>: AutofillProfileData] = [:]

    public init(profiles: [ID<Profile>: AutofillProfileData] = [:]) {
        self.profiles = profiles
    }

    public subscript(profile id: ID<Profile>) -> AutofillProfileData {
        get { profiles[id] ?? AutofillProfileData() }
        set { profiles[id] = newValue }
    }
}

public struct AutofillProfileData: Equatable, Codable {
    public var names: [AutofillName] = []
    public var emails: [AutofillValue] = []
    public var phones: [AutofillValue] = []
    public var organizations: [AutofillValue] = []
    public var addresses: [AutofillAddress] = []
    /// Saved logins. The password for each lives in the keychain under the
    /// credential's `id` (see `AutofillKeychain`).
    public var credentials: [AutofillCredential] = []
    /// Registrable domains (e.g. "example.com") the user asked us never to
    /// remember logins for.
    public var neverRememberDomains: Set<String> = []

    public init() {}

    public var isEmpty: Bool {
        names.isEmpty && emails.isEmpty && phones.isEmpty && organizations.isEmpty && addresses.isEmpty && credentials.isEmpty
    }
}

/// A single remembered string (an email, a phone number, a company name).
public struct AutofillValue: Equatable, Codable, Identifiable, Sendable {
    public var id: UUID
    public var value: String
    public var lastUsed: Date
    public var useCount: Int

    public init(id: UUID = UUID(), value: String, lastUsed: Date = Date(), useCount: Int = 1) {
        self.id = id
        self.value = value
        self.lastUsed = lastUsed
        self.useCount = useCount
    }
}

public struct AutofillName: Equatable, Codable, Identifiable, Sendable {
    public var id: UUID
    public var given: String
    public var family: String
    public var lastUsed: Date
    public var useCount: Int

    public init(id: UUID = UUID(), given: String, family: String, lastUsed: Date = Date(), useCount: Int = 1) {
        self.id = id
        self.given = given
        self.family = family
        self.lastUsed = lastUsed
        self.useCount = useCount
    }

    public var full: String {
        [given, family].map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }.joined(separator: " ")
    }

    /// Splits "Ada Lovelace" into given/family. Single words are a given name.
    public static func parse(full: String) -> (given: String, family: String) {
        let parts = full.split(whereSeparator: { $0.isWhitespace }).map(String.init)
        guard parts.count > 1 else { return (parts.first ?? "", "") }
        return (parts.dropLast().joined(separator: " "), parts.last ?? "")
    }

    public func value(for kind: AutofillFieldKind) -> String? {
        switch kind {
        case .givenName: return given.nilIfEmpty
        case .familyName: return family.nilIfEmpty
        case .fullName: return full.nilIfEmpty
        default: return nil
        }
    }
}

public struct AutofillAddress: Equatable, Codable, Identifiable, Sendable {
    public var id: UUID
    public var line1: String
    public var line2: String
    public var city: String
    public var state: String
    public var postalCode: String
    public var country: String
    public var lastUsed: Date
    public var useCount: Int

    public init(id: UUID = UUID(), line1: String = "", line2: String = "", city: String = "", state: String = "", postalCode: String = "", country: String = "", lastUsed: Date = Date(), useCount: Int = 1) {
        self.id = id
        self.line1 = line1
        self.line2 = line2
        self.city = city
        self.state = state
        self.postalCode = postalCode
        self.country = country
        self.lastUsed = lastUsed
        self.useCount = useCount
    }

    public func value(for kind: AutofillFieldKind) -> String? {
        switch kind {
        case .streetAddress: return line1.nilIfEmpty
        case .addressLine2: return line2.nilIfEmpty
        case .city: return city.nilIfEmpty
        case .state: return state.nilIfEmpty
        case .postalCode: return postalCode.nilIfEmpty
        case .country: return country.nilIfEmpty
        default: return nil
        }
    }

    public var oneLine: String {
        let cityLine = [city, state].compactMap { $0.nilIfEmpty }.joined(separator: ", ")
        let cityAndZip = [cityLine, postalCode].compactMap { $0.nilIfEmpty }.joined(separator: " ")
        return [line1, line2, cityAndZip, country].compactMap { $0.nilIfEmpty }.joined(separator: ", ")
    }

    public var isEmpty: Bool { oneLine.isEmpty }

    /// Two addresses are "the same place" if their street + postal code (or
    /// street + city) agree, ignoring case and whitespace.
    public func isSamePlace(as other: AutofillAddress) -> Bool {
        func n(_ s: String) -> String { s.lowercased().filter { !$0.isWhitespace && $0 != "," && $0 != "." } }
        guard !line1.isEmpty, n(line1) == n(other.line1) else { return false }
        if !postalCode.isEmpty || !other.postalCode.isEmpty { return n(postalCode) == n(other.postalCode) }
        return n(city) == n(other.city)
    }
}

/// A saved login. The secret is in the keychain (`AutofillKeychain`), keyed
/// by `id` + the owning profile.
public struct AutofillCredential: Equatable, Codable, Identifiable, Sendable {
    public var id: UUID
    /// Registrable domain the login belongs to, e.g. "github.com". Used for
    /// matching, so a login saved on `accounts.example.com` also offers on
    /// `www.example.com`.
    public var domain: String
    /// The exact host it was saved on (ranks above other subdomains).
    public var host: String
    public var username: String
    public var created: Date
    public var lastUsed: Date
    public var useCount: Int

    public init(id: UUID = UUID(), domain: String, host: String, username: String, created: Date = Date(), lastUsed: Date = Date(), useCount: Int = 1) {
        self.id = id
        self.domain = domain
        self.host = host
        self.username = username
        self.created = created
        self.lastUsed = lastUsed
        self.useCount = useCount
    }
}

// MARK: - Runtime field descriptors

/// Where a field sits in the webview's viewport (CSS px).
public struct AutofillRect: Equatable, Codable, Sendable {
    public var x: Double
    public var y: Double
    public var width: Double
    public var height: Double

    public init(x: Double, y: Double, width: Double, height: Double) {
        self.x = x; self.y = y; self.width = width; self.height = height
    }
}

/// Everything we know about one form control, as read from the page (or from
/// a benchmark fixture). Pure data — see `AutofillFieldClassifier`.
public struct AutofillFieldDescriptor: Equatable, Codable, Sendable {
    /// Index into the document's `input, textarea, select` list (same frame).
    /// Stable enough to address the element again shortly afterwards.
    public var fieldIndex: Int
    public var tag: String          // "input" | "textarea" | "select"
    public var type: String         // input type, lowercased; "select"/"textarea" for those tags
    public var name: String
    public var id: String
    public var autocomplete: String
    public var placeholder: String
    public var ariaLabel: String
    public var title: String
    public var className: String
    /// Text of associated <label>s (for=, ancestor, aria-labelledby).
    public var label: String
    /// Nearest short run of text before the control — many sites label fields
    /// with plain divs/spans instead of <label>.
    public var previousText: String
    public var maxLength: Int?
    public var readOnly: Bool
    public var disabled: Bool
    /// Index of the owning <form> in `document.forms`, nil when form-less.
    public var formIndex: Int?
    public var formHasPassword: Bool
    public var passwordFieldCount: Int
    /// Position among this form's (non-hidden) controls.
    public var indexInForm: Int
    public var textFieldCountInForm: Int
    public var optionCount: Int?
    public var optionSample: [String]?
    /// Current value. Runtime only (never in fixtures).
    public var value: String?
    /// Viewport rect. Runtime only.
    public var rect: AutofillRect?
    /// Path of iframe indices from the top document to the field's document.
    public var framePath: [Int]?

    public init(fieldIndex: Int = 0, tag: String = "input", type: String = "text", name: String = "", id: String = "", autocomplete: String = "", placeholder: String = "", ariaLabel: String = "", title: String = "", className: String = "", label: String = "", previousText: String = "", maxLength: Int? = nil, readOnly: Bool = false, disabled: Bool = false, formIndex: Int? = nil, formHasPassword: Bool = false, passwordFieldCount: Int = 0, indexInForm: Int = 0, textFieldCountInForm: Int = 0, optionCount: Int? = nil, optionSample: [String]? = nil, value: String? = nil, rect: AutofillRect? = nil, framePath: [Int]? = nil) {
        self.fieldIndex = fieldIndex; self.tag = tag; self.type = type; self.name = name; self.id = id
        self.autocomplete = autocomplete; self.placeholder = placeholder; self.ariaLabel = ariaLabel; self.title = title
        self.className = className; self.label = label; self.previousText = previousText; self.maxLength = maxLength
        self.readOnly = readOnly; self.disabled = disabled; self.formIndex = formIndex; self.formHasPassword = formHasPassword
        self.passwordFieldCount = passwordFieldCount; self.indexInForm = indexInForm; self.textFieldCountInForm = textFieldCountInForm
        self.optionCount = optionCount; self.optionSample = optionSample; self.value = value; self.rect = rect; self.framePath = framePath
    }

    // Tolerant decoding: every key is optional so the in-page query and the
    // fixtures can omit what they don't know.
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        fieldIndex = try c.decodeIfPresent(Int.self, forKey: .fieldIndex) ?? 0
        tag = try c.decodeIfPresent(String.self, forKey: .tag) ?? "input"
        type = (try c.decodeIfPresent(String.self, forKey: .type) ?? "text").lowercased()
        name = try c.decodeIfPresent(String.self, forKey: .name) ?? ""
        id = try c.decodeIfPresent(String.self, forKey: .id) ?? ""
        autocomplete = (try c.decodeIfPresent(String.self, forKey: .autocomplete) ?? "").lowercased()
        placeholder = try c.decodeIfPresent(String.self, forKey: .placeholder) ?? ""
        ariaLabel = try c.decodeIfPresent(String.self, forKey: .ariaLabel) ?? ""
        title = try c.decodeIfPresent(String.self, forKey: .title) ?? ""
        className = try c.decodeIfPresent(String.self, forKey: .className) ?? ""
        label = try c.decodeIfPresent(String.self, forKey: .label) ?? ""
        previousText = try c.decodeIfPresent(String.self, forKey: .previousText) ?? ""
        maxLength = try c.decodeIfPresent(Int.self, forKey: .maxLength)
        readOnly = try c.decodeIfPresent(Bool.self, forKey: .readOnly) ?? false
        disabled = try c.decodeIfPresent(Bool.self, forKey: .disabled) ?? false
        formIndex = try c.decodeIfPresent(Int.self, forKey: .formIndex)
        formHasPassword = try c.decodeIfPresent(Bool.self, forKey: .formHasPassword) ?? false
        passwordFieldCount = try c.decodeIfPresent(Int.self, forKey: .passwordFieldCount) ?? 0
        indexInForm = try c.decodeIfPresent(Int.self, forKey: .indexInForm) ?? 0
        textFieldCountInForm = try c.decodeIfPresent(Int.self, forKey: .textFieldCountInForm) ?? 0
        optionCount = try c.decodeIfPresent(Int.self, forKey: .optionCount)
        optionSample = try c.decodeIfPresent([String].self, forKey: .optionSample)
        value = try c.decodeIfPresent(String.self, forKey: .value)
        rect = try c.decodeIfPresent(AutofillRect.self, forKey: .rect)
        framePath = try c.decodeIfPresent([Int].self, forKey: .framePath)
    }

    public var isPasswordInput: Bool { tag == "input" && type == "password" }
    public var isSelect: Bool { tag == "select" }

    /// A stable-ish identity for "the same field" across refreshes, used to
    /// remember that the user dismissed suggestions for it.
    public var signature: String {
        "\(framePath ?? [])/\(fieldIndex)/\(tag)/\(type)/\(name)/\(id)"
    }
}

/// A classified field: descriptor + what we think it's for.
public struct AutofillClassifiedField: Equatable, Sendable {
    public var descriptor: AutofillFieldDescriptor
    public var kind: AutofillFieldKind?
    public var confidence: Double
    public var reason: String

    public init(descriptor: AutofillFieldDescriptor, kind: AutofillFieldKind?, confidence: Double, reason: String) {
        self.descriptor = descriptor; self.kind = kind; self.confidence = confidence; self.reason = reason
    }
}
