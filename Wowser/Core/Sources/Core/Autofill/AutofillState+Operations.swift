import Foundation

// Pure business logic over the persisted autofill data: what to suggest for a
// field, and what to remember from a submitted form. No I/O in here — the
// keychain is touched only by `AutofillStore`.

// MARK: - Suggestions

/// One row in the suggestion menu under a focused field.
public struct AutofillSuggestion: Equatable, Identifiable, Sendable {
    public enum Payload: Equatable, Sendable {
        /// Fills the username field and the password field of the form.
        case credential(AutofillCredential)
        /// Fills the focused field only.
        case value(String)
        /// Fills the given/family/full-name fields of the form.
        case name(AutofillName)
        /// Fills every address field of the form.
        case address(AutofillAddress)
    }

    public var id: String
    public var title: String
    public var subtitle: String?
    public var systemImage: String
    public var payload: Payload
    /// What lands in the focused field. Used for prefix filtering and to hide
    /// suggestions that equal what's already typed.
    public var primaryValue: String

    public init(id: String, title: String, subtitle: String? = nil, systemImage: String, payload: Payload, primaryValue: String) {
        self.id = id; self.title = title; self.subtitle = subtitle; self.systemImage = systemImage; self.payload = payload; self.primaryValue = primaryValue
    }
}

/// What the suggestion engine needs to know about the focused field.
public struct AutofillSuggestionContext: Equatable, Sendable {
    public var field: AutofillClassifiedField
    public var formFields: [AutofillClassifiedField]
    public var pageHost: String
    public var currentValue: String

    public init(field: AutofillClassifiedField, formFields: [AutofillClassifiedField], pageHost: String, currentValue: String) {
        self.field = field; self.formFields = formFields; self.pageHost = pageHost; self.currentValue = currentValue
    }

    /// A form with an existing-password field is a sign-in form.
    public var isSignInForm: Bool {
        formFields.contains { $0.kind == .password } || field.kind == .password
    }
}

public extension AutofillProfileData {
    static let maxSuggestions = 6

    /// Credentials that apply to a host, best first (exact host, then most used).
    func credentials(forHost host: String) -> [AutofillCredential] {
        let exact = host.lowercased()
        return credentials
            .filter { AutofillHostMatcher.credential(domain: $0.domain, appliesTo: host) }
            .sorted { a, b in
                let ae = a.host.lowercased() == exact, be = b.host.lowercased() == exact
                if ae != be { return ae }
                if a.useCount != b.useCount { return a.useCount > b.useCount }
                return a.lastUsed > b.lastUsed
            }
    }

    func suggestions(for ctx: AutofillSuggestionContext) -> [AutofillSuggestion] {
        guard let kind = ctx.field.kind else { return [] }
        var rows: [AutofillSuggestion] = []
        let host = ctx.pageHost

        func credentialRows() -> [AutofillSuggestion] {
            credentials(forHost: host).map { c in
                AutofillSuggestion(
                    id: "cred:\(c.id.uuidString)",
                    title: c.username,
                    subtitle: "Password for \(c.host)",
                    systemImage: "key.fill",
                    payload: .credential(c),
                    primaryValue: kind == .password ? "" : c.username
                )
            }
        }
        func valueRows(_ values: [AutofillValue], image: String, prefix: String) -> [AutofillSuggestion] {
            values.sortedByUse().map { v in
                AutofillSuggestion(id: "\(prefix):\(v.id.uuidString)", title: v.value, systemImage: image, payload: .value(v.value), primaryValue: v.value)
            }
        }

        switch kind {
        case .password:
            // Only offer on an empty password field; a half-typed password
            // means the user is doing it themselves.
            guard ctx.currentValue.isEmpty else { return [] }
            rows = credentialRows()
        case .newPassword:
            return []
        case .username, .email, .phone:
            if ctx.isSignInForm {
                rows = credentialRows()
            }
            let coveredUsernames = Set(rows.map { $0.primaryValue.lowercased() })
            switch kind {
            case .email:
                rows += valueRows(emails, image: "envelope", prefix: "email").filter { !coveredUsernames.contains($0.primaryValue.lowercased()) }
                // Logins that look like emails are emails too.
                let emailLikeUsernames = credentials.filter { $0.username.contains("@") }.map { $0.username }
                for u in emailLikeUsernames.uniqued(by: { $0.lowercased() }) where !coveredUsernames.contains(u.lowercased()) && !emails.contains(where: { $0.value.lowercased() == u.lowercased() }) {
                    rows.append(AutofillSuggestion(id: "emailu:\(u)", title: u, systemImage: "envelope", payload: .value(u), primaryValue: u))
                }
            case .phone:
                rows += valueRows(phones, image: "phone", prefix: "phone").filter { !coveredUsernames.contains($0.primaryValue.lowercased()) }
            default: // .username
                // Usernames saved anywhere, then emails (many sites accept either).
                let otherUsernames = credentials.sorted(by: { $0.useCount > $1.useCount }).map { $0.username }.uniqued(by: { $0.lowercased() })
                for u in otherUsernames where !coveredUsernames.contains(u.lowercased()) {
                    rows.append(AutofillSuggestion(id: "user:\(u)", title: u, systemImage: "person", payload: .value(u), primaryValue: u))
                }
                let covered2 = Set(rows.map { $0.primaryValue.lowercased() })
                rows += valueRows(emails, image: "envelope", prefix: "email").filter { !covered2.contains($0.primaryValue.lowercased()) }
            }
        case .givenName, .familyName, .fullName:
            for n in names.sortedByUse() {
                guard let v = n.value(for: kind) else { continue }
                rows.append(AutofillSuggestion(id: "name:\(n.id.uuidString)", title: v, subtitle: v == n.full ? nil : n.full, systemImage: "person.text.rectangle", payload: .name(n), primaryValue: v))
            }
        case .streetAddress, .addressLine2, .city, .state, .postalCode, .country:
            for a in addresses.sortedByUse() {
                guard let v = a.value(for: kind) else { continue }
                rows.append(AutofillSuggestion(id: "addr:\(a.id.uuidString)", title: v, subtitle: a.oneLine == v ? nil : a.oneLine, systemImage: "mappin.and.ellipse", payload: .address(a), primaryValue: v))
            }
        case .organization:
            rows = valueRows(organizations, image: "building.2", prefix: "org")
        }

        // Prefix-filter by what's typed, and never suggest what's already there.
        let typed = ctx.currentValue.trimmingCharacters(in: .whitespaces).lowercased()
        if !typed.isEmpty, kind != .password {
            rows = rows.filter { $0.primaryValue.lowercased().hasPrefix(typed) && $0.primaryValue.lowercased() != typed }
        }
        return Array(rows.prefix(Self.maxSuggestions))
    }
}

// MARK: - Remembering submitted forms

public struct AutofillFormSubmission: Equatable, Sendable {
    public struct Entry: Equatable, Sendable {
        public var kind: AutofillFieldKind
        public var value: String
        public init(kind: AutofillFieldKind, value: String) { self.kind = kind; self.value = value }
    }
    public var url: URL
    public var entries: [Entry]

    public init(url: URL, entries: [Entry]) {
        self.url = url; self.entries = entries
    }

    public func value(_ kind: AutofillFieldKind) -> String? {
        entries.first { $0.kind == kind && !$0.value.trimmingCharacters(in: .whitespaces).isEmpty }?.value
    }
}

public struct AutofillRememberOutcome: Equatable, Sendable {
    /// The credential this submission belongs to (created or updated).
    public var credential: AutofillCredential?
    /// The password that goes with `credential`. The caller stores it in the
    /// keychain (and can compare with the existing secret first).
    public var password: String?
    public var isNewCredential = false
    /// Kinds of identity data saved (names, emails, phones, addresses…).
    public var savedIdentityKinds: [AutofillFieldKind] = []
    /// Every record this submission created or bumped — what "Forget" removes.
    public var touchedIDs: [UUID] = []

    public var savedAnything: Bool { credential != nil || !savedIdentityKinds.isEmpty }
}

public extension AutofillProfileData {
    /// Folds a submitted form into the profile. Returns nil when nothing was
    /// worth keeping (or the site is on the never-remember list).
    mutating func remember(_ submission: AutofillFormSubmission, now: Date = Date()) -> AutofillRememberOutcome? {
        guard AutofillHostMatcher.isFillableURL(submission.url), let host = submission.url.host else { return nil }
        let domain = AutofillHostMatcher.registrableDomain(host)
        if neverRememberDomains.contains(domain) { return nil }

        var outcome = AutofillRememberOutcome()

        // Credentials.
        let passwordValues = submission.entries.filter { $0.kind.isPassword && !$0.value.isEmpty }.map { $0.value }
        if let password = passwordValues.first, passwordValues.allSatisfy({ $0 == password }) {
            let username = submission.value(.username) ?? submission.value(.email) ?? submission.value(.phone)
            if let username = username?.trimmingCharacters(in: .whitespacesAndNewlines), !username.isEmpty {
                if let idx = credentials.firstIndex(where: { $0.domain == domain && $0.username.lowercased() == username.lowercased() }) {
                    credentials[idx].lastUsed = now
                    credentials[idx].useCount += 1
                    credentials[idx].host = host.lowercased()
                    credentials[idx].username = username
                    outcome.credential = credentials[idx]
                } else {
                    let c = AutofillCredential(domain: domain, host: host.lowercased(), username: username, created: now, lastUsed: now)
                    credentials.append(c)
                    outcome.credential = c
                    outcome.isNewCredential = true
                }
                outcome.password = password
                outcome.touchedIDs.append(outcome.credential!.id)
            } else if credentials.filter({ $0.domain == domain }).count == 1,
                      let idx = credentials.firstIndex(where: { $0.domain == domain }) {
                // Password-only form (re-auth / change password) for a site with
                // exactly one saved login: keep that login's password current.
                credentials[idx].lastUsed = now
                credentials[idx].useCount += 1
                outcome.credential = credentials[idx]
                outcome.password = password
                outcome.touchedIDs.append(credentials[idx].id)
            }
        }

        // Names.
        var given = submission.value(.givenName) ?? ""
        var family = submission.value(.familyName) ?? ""
        if given.isEmpty, family.isEmpty, let full = submission.value(.fullName) {
            (given, family) = AutofillName.parse(full: full)
        }
        given = given.trimmingCharacters(in: .whitespaces); family = family.trimmingCharacters(in: .whitespaces)
        if !given.isEmpty || !family.isEmpty {
            let candidate = AutofillName(given: given, family: family, lastUsed: now)
            if let idx = names.firstIndex(where: { $0.full.lowercased() == candidate.full.lowercased() }) {
                names[idx].lastUsed = now; names[idx].useCount += 1
                outcome.touchedIDs.append(names[idx].id)
            } else {
                names.append(candidate)
                outcome.touchedIDs.append(candidate.id)
                outcome.savedIdentityKinds.append(.fullName)
            }
        }

        // Emails / phones / organizations. Only NEW values count as news for
        // the toast; known ones just get their use count bumped.
        if let email = submission.value(.email)?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased(), email.contains("@") {
            let (id, isNew) = emails.upsert(email, now: now)
            outcome.touchedIDs.append(id)
            if isNew { outcome.savedIdentityKinds.append(.email) }
        }
        if let phone = submission.value(.phone)?.trimmingCharacters(in: .whitespacesAndNewlines), phone.filter(\.isNumber).count >= 6 {
            let (id, isNew) = phones.upsert(phone, now: now, key: { $0.filter(\.isNumber) })
            outcome.touchedIDs.append(id)
            if isNew { outcome.savedIdentityKinds.append(.phone) }
        }
        if let org = submission.value(.organization)?.trimmingCharacters(in: .whitespacesAndNewlines), !org.isEmpty {
            let (id, isNew) = organizations.upsert(org, now: now)
            outcome.touchedIDs.append(id)
            if isNew { outcome.savedIdentityKinds.append(.organization) }
        }

        // Addresses (need at least a street line).
        if let line1 = submission.value(.streetAddress)?.trimmingCharacters(in: .whitespacesAndNewlines), !line1.isEmpty {
            var addr = AutofillAddress(
                line1: line1,
                line2: submission.value(.addressLine2) ?? "",
                city: submission.value(.city) ?? "",
                state: submission.value(.state) ?? "",
                postalCode: submission.value(.postalCode) ?? "",
                country: submission.value(.country) ?? "",
                lastUsed: now
            )
            if let idx = addresses.firstIndex(where: { $0.isSamePlace(as: addr) }) {
                // Fill in blanks on the existing record, keep its identity.
                addr.id = addresses[idx].id
                addr.useCount = addresses[idx].useCount + 1
                if addr.line2.isEmpty { addr.line2 = addresses[idx].line2 }
                if addr.city.isEmpty { addr.city = addresses[idx].city }
                if addr.state.isEmpty { addr.state = addresses[idx].state }
                if addr.postalCode.isEmpty { addr.postalCode = addresses[idx].postalCode }
                if addr.country.isEmpty { addr.country = addresses[idx].country }
                addresses[idx] = addr
            } else {
                addresses.append(addr)
                outcome.savedIdentityKinds.append(.streetAddress)
            }
            outcome.touchedIDs.append(addr.id)
        }

        // Anything worth telling the user about — or at least a login we can
        // keep current?
        return (outcome.savedAnything || outcome.credential != nil) ? outcome : nil
    }

    /// Removes records by id. Returns the ids of removed credentials so the
    /// caller can delete their keychain secrets.
    @discardableResult
    mutating func forget(ids: Set<UUID>) -> [UUID] {
        let removedCredentials = credentials.filter { ids.contains($0.id) }.map { $0.id }
        credentials.removeAll { ids.contains($0.id) }
        names.removeAll { ids.contains($0.id) }
        emails.removeAll { ids.contains($0.id) }
        phones.removeAll { ids.contains($0.id) }
        organizations.removeAll { ids.contains($0.id) }
        addresses.removeAll { ids.contains($0.id) }
        return removedCredentials
    }

    /// Marks a domain as never-remember and drops any logins saved for it.
    /// Returns removed credential ids (for keychain cleanup).
    @discardableResult
    mutating func neverRemember(domain rawDomain: String) -> [UUID] {
        let domain = AutofillHostMatcher.registrableDomain(rawDomain)
        guard !domain.isEmpty else { return [] }
        neverRememberDomains.insert(domain)
        let removed = credentials.filter { $0.domain == domain }.map { $0.id }
        credentials.removeAll { $0.domain == domain }
        return removed
    }

    /// Records that a suggestion was used (ranking).
    mutating func markUsed(_ payload: AutofillSuggestion.Payload, now: Date = Date()) {
        switch payload {
        case .credential(let c):
            if let i = credentials.firstIndex(where: { $0.id == c.id }) { credentials[i].lastUsed = now; credentials[i].useCount += 1 }
        case .name(let n):
            if let i = names.firstIndex(where: { $0.id == n.id }) { names[i].lastUsed = now; names[i].useCount += 1 }
        case .address(let a):
            if let i = addresses.firstIndex(where: { $0.id == a.id }) { addresses[i].lastUsed = now; addresses[i].useCount += 1 }
        case .value(let v):
            for list in [\AutofillProfileData.emails, \.phones, \.organizations] {
                if let i = self[keyPath: list].firstIndex(where: { $0.value == v }) {
                    self[keyPath: list][i].lastUsed = now
                    self[keyPath: list][i].useCount += 1
                }
            }
        }
    }

    // MARK: - Agent-facing summary

    /// Plain-text description of the user's identity data for an agent's
    /// system prompt. Never includes passwords.
    func systemPromptSummary() -> String? {
        var lines: [String] = []
        let sortedNames = names.sortedByUse()
        if let primary = sortedNames.first {
            lines.append("Name: \(primary.full)" + (sortedNames.count > 1 ? " (also: \(sortedNames.dropFirst().map { $0.full }.joined(separator: ", ")))" : ""))
        }
        if !emails.isEmpty { lines.append("Email: \(emails.sortedByUse().map { $0.value }.joined(separator: ", "))") }
        if !phones.isEmpty { lines.append("Phone: \(phones.sortedByUse().map { $0.value }.joined(separator: ", "))") }
        if !organizations.isEmpty { lines.append("Company: \(organizations.sortedByUse().map { $0.value }.joined(separator: ", "))") }
        for (i, a) in addresses.sortedByUse().enumerated() {
            lines.append("Address\(addresses.count > 1 ? " \(i + 1)" : ""): \(a.oneLine)")
        }
        if !credentials.isEmpty {
            let domains = Set(credentials.map { $0.domain }).sorted()
            lines.append("Saved logins exist for: \(domains.prefix(40).joined(separator: ", "))\(domains.count > 40 ? ", …" : "") (usernames via browser.credentials.lookup(domain); passwords are never exposed to you — browser.credentials.fillPassword types one into a focused password field).")
        }
        return lines.isEmpty ? nil : lines.joined(separator: "\n")
    }
}

// MARK: - Helpers

extension Array where Element == AutofillValue {
    func sortedByUse() -> [AutofillValue] {
        sorted { a, b in a.useCount != b.useCount ? a.useCount > b.useCount : a.lastUsed > b.lastUsed }
    }

    /// Insert-or-bump by a normalized key. Returns the record's id and
    /// whether it was newly created.
    mutating func upsert(_ value: String, now: Date, key: (String) -> String = { $0.lowercased() }) -> (id: UUID, isNew: Bool) {
        let k = key(value)
        if let idx = firstIndex(where: { key($0.value) == k }) {
            self[idx].lastUsed = now
            self[idx].useCount += 1
            return (self[idx].id, false)
        }
        let v = AutofillValue(value: value, lastUsed: now)
        append(v)
        return (v.id, true)
    }
}

extension Array where Element == AutofillName {
    func sortedByUse() -> [AutofillName] {
        sorted { a, b in a.useCount != b.useCount ? a.useCount > b.useCount : a.lastUsed > b.lastUsed }
    }
}

extension Array where Element == AutofillAddress {
    func sortedByUse() -> [AutofillAddress] {
        sorted { a, b in a.useCount != b.useCount ? a.useCount > b.useCount : a.lastUsed > b.lastUsed }
    }
}

extension Array {
    func uniqued<K: Hashable>(by key: (Element) -> K) -> [Element] {
        var seen = Set<K>()
        return filter { seen.insert(key($0)).inserted }
    }
}
