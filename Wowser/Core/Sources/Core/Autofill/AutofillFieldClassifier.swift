import Foundation

/// Decides what each form field is for (username, email, street address, …)
/// from its markup alone — no network, no ML, pure functions — so it can be
/// benchmarked offline against real sites (see `AutofillClassifierTests`,
/// which runs `Fixtures/autofill/*.json`).
///
/// Signal priority:
///   1. Non-text input types (checkbox, hidden, file, …) → never autofill.
///   2. The `autocomplete` attribute (the standard, when present and sane).
///   3. Negative guards (search boxes, OTP codes, card numbers, dates, SSN…).
///   4. The input `type` (password / email / tel).
///   5. Word matching over name, id, placeholder, aria-label, <label>, title
///      and nearby text, in a specific-before-generic order, in English plus
///      the most common French / Spanish / German / Italian / Portuguese terms.
///   6. Form context: a lone unlabeled text field right before a password
///      field is the username; two adjacent password fields are a sign-up.
public enum AutofillFieldClassifier {

    // MARK: - Public API

    /// Classify one field in isolation.
    public static func classify(_ field: AutofillFieldDescriptor) -> AutofillClassifiedField {
        classify(fields: [field]).first ?? AutofillClassifiedField(descriptor: field, kind: nil, confidence: 0, reason: "empty")
    }

    /// Classify a group of fields that share a form (or a page). Context rules
    /// (adjacent password fields, unlabeled username) need the siblings.
    public static func classify(fields: [AutofillFieldDescriptor]) -> [AutofillClassifiedField] {
        var results = fields.map { classifyStandalone($0) }
        applyFormContext(fields: fields, results: &results)
        return results
    }

    // MARK: - Standalone classification

    private static func classifyStandalone(_ f: AutofillFieldDescriptor) -> AutofillClassifiedField {
        func out(_ kind: AutofillFieldKind?, _ conf: Double, _ why: String) -> AutofillClassifiedField {
            AutofillClassifiedField(descriptor: f, kind: kind, confidence: conf, reason: why)
        }

        // (disabled / readonly fields are still classified — the page may enable
        // them later; the fill step skips whatever is not editable right then.)
        if f.tag == "textarea" { return out(nil, 1, "textarea") }
        if f.tag == "input", !Self.textualInputTypes.contains(f.type) { return out(nil, 1, "type=\(f.type)") }
        if f.type == "search" { return out(nil, 0.9, "type=search") }
        if f.type == "url" { return out(nil, 0.9, "type=url") }

        // Sources, most reliable first. `className` is noisy, so it only
        // contributes when nothing else says anything.
        let primaryText = normalize([f.name, f.id, f.placeholder, f.ariaLabel, f.label, f.title].joined(separator: " | "))
        let nearbyText = normalize(f.previousText)
        let hay = (primaryText + " | " + nearbyText).trimmingCharacters(in: .whitespaces)
        let hayWithClass = hay + " | " + normalize(f.className)

        // 2. autocomplete attribute — the standard, and authoritative when sane.
        switch autocompleteKind(f) {
        case .kind(let k):
            return out(k, 0.98, "autocomplete=\(f.autocomplete)")
        case .never:
            return out(nil, 0.98, "autocomplete=\(f.autocomplete)")
        case .none:
            break
        }
        // An example address in the placeholder ("name@domain.com") is as good
        // as type=email.
        if f.placeholder.contains("@"), !f.isPasswordInput {
            return out(.email, 0.9, "placeholder:@")
        }

        // 3. Negative guards. These describe things we must never fill.
        if let guardHit = negativeGuard(in: hay) {
            return out(nil, 0.9, "guard:\(guardHit)")
        }
        // A "City, State or ZIP" locator box mentions several address parts at
        // once — that's a search field, not an address form.
        if distinctAddressPartMentions(in: primaryText) >= 2 || distinctAddressPartMentions(in: nearbyText) >= 2 {
            return out(nil, 0.8, "guard:multi-address-locator")
        }

        // 4. Input type.
        if f.isPasswordInput {
            return out(newPasswordTokens.matches(hay) ? .newPassword : .password, 0.9, "type=password")
        }
        if f.type == "email" {
            return out(.email, 0.95, "type=email")
        }
        if f.type == "tel" {
            // Sites use type=tel for numeric keyboards on ZIP fields too.
            if postalCodeTokens.matches(hay) { return out(.postalCode, 0.85, "type=tel+zip") }
            return out(.phone, 0.9, "type=tel")
        }

        // 5. Token matching, specific before generic.
        if let (kind, why) = tokenKind(in: hay) {
            if f.isSelect, !Self.selectableKinds.contains(kind) {
                return out(nil, 0.6, "select:\(why)")
            }
            return out(kind, 0.75, why)
        }
        if f.isSelect {
            if let k = selectKindFromOptions(f) { return out(k, 0.7, "options") }
            return out(nil, 0.7, "select:no-match")
        }
        if let (kind, why) = tokenKind(in: hayWithClass), !f.isSelect {
            return out(kind, 0.4, "class:" + why)
        }
        return out(nil, 0.3, "no-match")
    }

    // MARK: - Form context

    private static func applyFormContext(fields: [AutofillFieldDescriptor], results: inout [AutofillClassifiedField]) {
        // Group by form (nil form = the page).
        var groups: [Int?: [Int]] = [:]
        for (i, f) in fields.enumerated() { groups[f.formIndex, default: []].append(i) }

        for (_, indices) in groups {
            let pwIndices = indices.filter { results[$0].kind?.isPassword == true }
            let textLikeCount = indices.filter { fields[$0].tag == "input" && Self.textualInputTypes.contains(fields[$0].type) }.count

            // Adjacent password fields (create + confirm) are a sign-up /
            // change-password pair; two far-apart ones are two login widgets.
            if pwIndices.count >= 2 {
                for (n, i) in pwIndices.enumerated() {
                    guard results[i].kind == .password, !results[i].reason.hasPrefix("autocomplete") else { continue }
                    let prev = n > 0 ? pwIndices[n - 1] : nil
                    let next = n + 1 < pwIndices.count ? pwIndices[n + 1] : nil
                    let near = [prev, next].compactMap { $0 }.contains { abs(fields[$0].indexInForm - fields[i].indexInForm) <= 2 }
                    if near {
                        results[i].kind = .newPassword
                        results[i].reason += "+adjacent-password"
                    }
                }
            }

            // A single password on a form that also collects a first/last
            // name is a sign-up form.
            if pwIndices.count == 1, let i = pwIndices.first, results[i].kind == .password, !results[i].reason.hasPrefix("autocomplete") {
                let hasNameParts = indices.contains { results[$0].kind == .givenName || results[$0].kind == .familyName }
                if hasNameParts {
                    results[i].kind = .newPassword
                    results[i].reason += "+signup-context"
                }
            }

            // Unlabeled text field immediately before the first password on a
            // small form (login, or a sign-up's create/confirm pair): that's
            // the username.
            if let pw = pwIndices.first, textLikeCount <= 2 + pwIndices.count {
                let candidates = indices.filter {
                    results[$0].kind == nil && results[$0].reason == "no-match"
                        && fields[$0].tag == "input" && (fields[$0].type == "text" || fields[$0].type == "")
                        && fields[$0].indexInForm < fields[pw].indexInForm
                }
                if let last = candidates.max(by: { fields[$0].indexInForm < fields[$1].indexInForm }),
                   fields[pw].indexInForm - fields[last].indexInForm <= 2 {
                    results[last].kind = .username
                    results[last].confidence = 0.5
                    results[last].reason = "context:before-password"
                }
            }
        }
    }

    // MARK: - Autocomplete

    private enum AutocompleteDecision { case kind(AutofillFieldKind), never, none }

    private static func autocompleteKind(_ f: AutofillFieldDescriptor) -> AutocompleteDecision {
        let tokens = f.autocomplete.split(separator: " ").map(String.init)
        // Scan from the end: the field-name token comes last ("shipping tel").
        for token in tokens.reversed() {
            switch token {
            case "on", "off", "false", "true", "shipping", "billing", "home", "work", "mobile", "fax", "pager", "webauthn":
                continue
            case "username":
                return .kind(f.type == "email" ? .email : .username)
            case "current-password":
                return f.isPasswordInput ? .kind(.password) : .none  // honeypots put this on text fields
            case "new-password":
                return f.isPasswordInput ? .kind(.newPassword) : .none
            case "password":
                return f.isPasswordInput ? .kind(.password) : .none
            case "email":
                return .kind(.email)
            case "tel", "tel-national", "tel-local":
                return .kind(.phone)
            case "name", "cc-name":
                return .kind(.fullName)
            case "given-name", "cc-given-name":
                return .kind(.givenName)
            case "family-name", "cc-family-name":
                return .kind(.familyName)
            case "additional-name", "honorific-prefix", "honorific-suffix", "nickname":
                return .never
            case "organization":
                return .kind(.organization)
            case "street-address", "address-line1":
                return .kind(.streetAddress)
            case "address-line2", "address-line3":
                return .kind(.addressLine2)
            case "address-level2":
                return .kind(.city)
            case "address-level1":
                return .kind(.state)
            case "postal-code":
                return .kind(.postalCode)
            case "country", "country-name":
                return .kind(.country)
            case "one-time-code", "cc-number", "cc-exp", "cc-exp-month", "cc-exp-year", "cc-csc", "cc-type",
                 "bday", "bday-day", "bday-month", "bday-year", "sex", "url", "photo", "organization-title",
                 "transaction-currency", "transaction-amount", "language", "impp", "tel-country-code", "tel-area-code", "tel-extension":
                return .never
            default:
                if token.hasPrefix("section-") { continue }
                // Unknown token: fall through to other signals.
                return .none
            }
        }
        return .none
    }

    // MARK: - Tokens

    /// Regex helper: word-boundary patterns over the normalized haystack.
    struct Pattern {
        let regex: NSRegularExpression
        init(_ p: String) { regex = try! NSRegularExpression(pattern: p, options: [.caseInsensitive]) }
        func matches(_ s: String) -> Bool {
            regex.firstMatch(in: s, options: [], range: NSRange(s.startIndex..., in: s)) != nil
        }
    }

    private static let textualInputTypes: Set<String> = ["", "text", "email", "password", "tel", "search", "url", "number"]
    private static let selectableKinds: Set<AutofillFieldKind> = [.country, .state, .city]

    private static let negativeGuards: [(String, Pattern)] = [
        ("search", Pattern(#"\b(search|suchen?|buscar|busqueda|recherch\w*|cerca|zoek\w*|filter|keyword|query|lookup|tracking|track)\b"#)),
        ("code", Pattern(#"\b(otp|one time|verification|security code|access code|2fa|two factor|mfa|captcha|token|promo|coupon|voucher|discount|gift ?card|referral|invite)\b"#)),
        ("card", Pattern(#"\b(card number|credit card|cc num\w*|cardnumber|ccnumber|cvv|cvc|cvn|ccv|csc|expir\w*|exp date|expdate|iban|bic|swift|routing|account number|sort code)\b"#)),
        ("date", Pattern(#"\b(date|dob|birth\w*|birthday|day|month|year|time|datepicker|timepicker|calendar|mm|dd|yyyy)\b"#)),
        ("identity-doc", Pattern(#"\b(ssn|social security|passport|tax id|tin|ein|vat|driver'?s? licen[cs]e|licen[cs]e number|national id)\b"#)),
        ("secret", Pattern(#"\b(security (question|answer)|secret (question|answer)|answer|hint|pet)\b"#)),
        ("location-search", Pattern(#"\b(pickup|drop ?off|destination|origin|location|where to|from where|near)\b"#)),
        ("misc", Pattern(#"\b(url|website|web site|domain|workspace|subdomain|amount|price|quantity|qty|subject|message|comment|review|feedback|note|notes|description|title|job title|position|reason|honeypot|nospam|bot)\b"#)),
    ]

    private static func negativeGuard(in hay: String) -> String? {
        for (name, p) in negativeGuards where p.matches(hay) {
            // "postal code" / "zip code" / "code postal" must survive the code guard.
            if name == "code", postalCodeTokens.matches(hay) { continue }
            // "country code" isn't an OTP either.
            if name == "code", countryTokens.matches(hay) { continue }
            return name
        }
        return nil
    }

    private static let addressLine2Tokens = Pattern(#"\b(address|addr|street|line|adresse|direccion|indirizzo|endereco|adres) ?(2|two|ii)\b|\b(line ?2|address ?2|addr ?2|apt|apartment|suite|unit|floor|complement\w*|adresszusatz|zusatz|second line|piso|escalera|interior|complemento)\b"#)
    private static let postalCodeTokens = Pattern(#"\b(zip|zipcode|zip code|postal|postcode|post code|plz|postleitzahl|codigo postal|code postal|cep|cap|pincode|pin code|eircode|postnummer|postnr)\b"#)
    private static let emailTokens = Pattern(#"\b(e ?mail\w*|courriel|correo|mail)\b"#)
    private static let phoneTokens = Pattern(#"\b(phone\w*|tel|telephone|telefon\w*|telefono|mobile|mobil|cell|cellphone|cellular|cellulare|movil|celular|handy|portable|numero de telephone|contact number)\b"#)
    private static let fullNameExplicitTokens = Pattern(#"\b(full ?name|fullname|your name|nombre completo|nom complet|nome completo|vollstandiger name|name on card|cardholder\w*|card holder|contact name|customer name|account holder)\b"#)
    private static let givenNameTokens = Pattern(#"\b(first ?name|firstname|fname|given ?name|givenname|forename|prenom|primer nombre|nombre|vorname|nome|first)\b"#)
    private static let familyNameTokens = Pattern(#"\b(last ?name|lastname|lname|family ?name|familyname|surname|sur ?name|second name|apellidos?|nachname|familienname|cognome|sobrenome|nom|last|family)\b"#)
    private static let organizationTokens = Pattern(#"\b(company\w*|organization|organisation|org|firma|empresa|societe|entreprise|azienda|business name|employer)\b"#)
    private static let countryTokens = Pattern(#"\b(country\w*|pays|pais|land|nation|paese|countryregion)\b"#)
    private static let stateTokens = Pattern(#"\b(state|province|provincia|region|county|bundesland|prefecture|territory|administrative area|departement|comunidad|estado|canton|kanton)\b"#)
    private static let cityTokens = Pattern(#"\b(city|town|locality|ville|ciudad|ort|stadt|citta|cidade|municipality|suburb|localidad|commune|comune)\b"#)
    private static let streetTokens = Pattern(#"\b(street|address|addr|adresse|adress|direccion|strasse|str|calle|rua|via|indirizzo|adres|endereco|house number|hausnummer|address ?1|addr ?1|line ?1)\b"#)
    private static let nonPostalAddressGuard = Pattern(#"\b(ip|mac|wallet|web|url|billing email|email|e mail|mail) address\b"#)
    private static let usernameTokens = Pattern(#"\b(user ?name|username|login|log in|signin|sign in|user ?id|userid|uid|acct|account name|handle|nick\w*|screen ?name|identifier|benutzername|usuario|utilisateur|identifiant|who|member ?id|customer ?id|login ?id|account ?id)\b"#)
    private static let fullNameTokens = Pattern(#"\bname\b|\bauthor\b|\bnome\b"#)
    private static let fullNameExclusions = Pattern(#"\b(user|screen|file|company|business|domain|host|workspace|product|project|team|app|card|pet|street|city|nick|display|first|last|middle|maiden|brand|store|shop|site|page|tag|label|group|list|channel|server|db|database|table|column|field|variable|function|class|font|color|plan|package|event|task|item|folder|repo|repository|branch|bucket|key|token|role|permission) ?name\b"#)
    private static let newPasswordTokens = Pattern(#"\b(new|create|confirm\w*|repeat|retype|re type|verify|again|choose|set|reset|change|register|signup|sign up|wiederhol\w*|bestatig\w*|confirmar|repetir|nouveau|confirmer|passwordconfirmation|password2|pass2|pwd2)\b"#)

    /// Ordered, specific-before-generic. Returns (kind, reason).
    private static func tokenKind(in hay: String) -> (AutofillFieldKind, String)? {
        if fullNameExplicitTokens.matches(hay) { return (.fullName, "token:full-name") }
        if addressLine2Tokens.matches(hay) { return (.addressLine2, "token:line2") }
        if postalCodeTokens.matches(hay) { return (.postalCode, "token:postal") }
        if emailTokens.matches(hay) { return (.email, "token:email") }
        // Country before phone: layout prefixes like "mobile-country" would
        // otherwise read as a phone number.
        if countryTokens.matches(hay) { return (.country, "token:country") }
        if phoneTokens.matches(hay) { return (.phone, "token:phone") }
        if givenNameTokens.matches(hay) { return (.givenName, "token:given") }
        if familyNameTokens.matches(hay) { return (.familyName, "token:family") }
        if organizationTokens.matches(hay) { return (.organization, "token:org") }
        if stateTokens.matches(hay) { return (.state, "token:state") }
        if cityTokens.matches(hay) { return (.city, "token:city") }
        if streetTokens.matches(hay), !nonPostalAddressGuard.matches(hay) { return (.streetAddress, "token:street") }
        if usernameTokens.matches(hay) { return (.username, "token:username") }
        if fullNameTokens.matches(hay), !fullNameExclusions.matches(hay) { return (.fullName, "token:name") }
        return nil
    }

    private static func distinctAddressPartMentions(in s: String) -> Int {
        guard !s.isEmpty else { return 0 }
        var n = 0
        if cityTokens.matches(s) { n += 1 }
        if stateTokens.matches(s) { n += 1 }
        if postalCodeTokens.matches(s) { n += 1 }
        return n
    }

    // MARK: - Selects

    private static let usStates: Set<String> = ["alabama", "alaska", "arizona", "arkansas", "california", "colorado", "connecticut", "delaware", "florida", "georgia", "hawaii", "idaho", "illinois", "indiana", "iowa", "kansas", "kentucky", "louisiana", "maine", "maryland", "massachusetts", "michigan", "minnesota", "mississippi", "missouri", "montana", "nebraska", "nevada", "new hampshire", "new jersey", "new mexico", "new york", "north carolina", "north dakota", "ohio", "oklahoma", "oregon", "pennsylvania", "rhode island", "south carolina", "south dakota", "tennessee", "texas", "utah", "vermont", "virginia", "washington", "west virginia", "wisconsin", "wyoming"]
    private static let countries: Set<String> = ["united states", "united kingdom", "canada", "australia", "germany", "france", "spain", "italy", "mexico", "brazil", "india", "japan", "china", "afghanistan", "albania", "algeria", "andorra", "angola", "argentina", "austria", "belgium", "netherlands", "sweden", "norway", "denmark", "finland", "ireland", "portugal", "switzerland", "poland", "new zealand"]

    private static func selectKindFromOptions(_ f: AutofillFieldDescriptor) -> AutofillFieldKind? {
        guard let sample = f.optionSample, !sample.isEmpty else { return nil }
        let lowered = sample.map { $0.lowercased() }
        let stateHits = lowered.filter { usStates.contains($0) }.count
        let countryHits = lowered.filter { countries.contains($0) }.count
        if stateHits >= 2 { return .state }
        if countryHits >= 2, (f.optionCount ?? 0) > 20 { return .country }
        return nil
    }

    // MARK: - Normalization

    /// Lowercases, strips diacritics, splits camelCase and letter/digit
    /// boundaries, and turns punctuation into spaces so word-boundary regexes
    /// work over names like `checkout[shipping_address][first_name]`,
    /// `emailAddressField` or `address-ui-widgets-enterAddressLine2`.
    static func normalize(_ s: String) -> String {
        if s.isEmpty { return "" }
        var out = ""
        out.reserveCapacity(s.count + 8)
        var prev: Character? = nil
        for ch in s {
            if let p = prev {
                let boundary = (p.isLowercase && ch.isUppercase)
                    || (p.isLetter && ch.isNumber)
                    || (p.isNumber && ch.isLetter)
                if boundary { out.append(" ") }
            }
            out.append(ch)
            prev = ch
        }
        let folded = out.folding(options: [.diacriticInsensitive, .caseInsensitive], locale: nil).lowercased()
        var cleaned = ""
        cleaned.reserveCapacity(folded.count)
        var lastWasSpace = false
        for ch in folded {
            if ch.isLetter || ch.isNumber {
                cleaned.append(ch)
                lastWasSpace = false
            } else if ch == "|" {
                cleaned.append(" | ")
                lastWasSpace = false
            } else if !lastWasSpace {
                cleaned.append(" ")
                lastWasSpace = true
            }
        }
        return cleaned.trimmingCharacters(in: .whitespaces)
    }
}
