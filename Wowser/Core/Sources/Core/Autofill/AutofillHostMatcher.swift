import Foundation

/// Decides which saved logins apply to which pages. Matching is by
/// registrable domain ("eTLD+1"-ish): a login saved on `accounts.example.com`
/// is offered on `www.example.com`. We approximate the public suffix list with
/// the common two-label suffixes (co.uk, com.au, …) rather than shipping it.
public enum AutofillHostMatcher {
    /// Second-level labels that are themselves public suffixes under a
    /// country-code TLD, e.g. `co` in `bbc.co.uk`.
    private static let secondLevelSuffixes: Set<String> = [
        "co", "com", "org", "net", "gov", "edu", "ac", "or", "ne", "gob", "mil", "int", "nom", "biz", "info", "ltd", "plc", "me", "sch",
    ]

    /// "www.accounts.example.co.uk" → "example.co.uk"; "localhost" → "localhost";
    /// IPs are returned as-is.
    public static func registrableDomain(_ host: String) -> String {
        let h = host.lowercased().trimmingCharacters(in: CharacterSet(charactersIn: ". "))
        if h.isEmpty { return "" }
        if isIPAddress(h) { return h }
        let labels = h.split(separator: ".").map(String.init)
        if labels.count <= 2 { return labels.joined(separator: ".") }
        let tld = labels[labels.count - 1]
        let sld = labels[labels.count - 2]
        if tld.count == 2, secondLevelSuffixes.contains(sld) {
            return labels.suffix(3).joined(separator: ".")
        }
        return labels.suffix(2).joined(separator: ".")
    }

    public static func registrableDomain(of url: URL?) -> String? {
        guard let host = url?.host, !host.isEmpty else { return nil }
        return registrableDomain(host)
    }

    /// True if a login saved for `credentialDomain` should be offered on `pageHost`.
    public static func credential(domain credentialDomain: String, appliesTo pageHost: String) -> Bool {
        let a = registrableDomain(credentialDomain)
        let b = registrableDomain(pageHost)
        return !a.isEmpty && a == b
    }

    /// Only ever remember / fill on real web origins.
    public static func isFillableURL(_ url: URL?) -> Bool {
        guard let url, let scheme = url.scheme?.lowercased(), let host = url.host, !host.isEmpty else { return false }
        return scheme == "https" || scheme == "http"
    }

    static func isIPAddress(_ s: String) -> Bool {
        if s.contains(":") { return true } // IPv6
        let parts = s.split(separator: ".")
        return parts.count == 4 && parts.allSatisfy { !$0.isEmpty && $0.allSatisfy(\.isNumber) }
    }
}
