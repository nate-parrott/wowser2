import Foundation

/// Shortens page titles for tab rows. Many sites append (or prepend) their own
/// name to every document title — "PROJECTS – Figma", "Dog - Wikipedia" — but
/// the tab already shows the site's favicon, so the name is redundant.
///
/// Two passes:
/// 1. A per-site rule (`siteRules`) for sites whose titles carry other noise
///    (GitHub's "· Issue #43 · owner/repo", Gmail's account email, Amazon's
///    category, Stack Overflow's tag prefix…).
/// 2. A generic pass that repeatedly drops a trailing " - Site Name" segment
///    when it names the site the page is on (see `isSiteName`).
///
/// Pure: a function of the title and URL only.
enum TabTitleTidier {
    static func tidy(_ title: String, url: URL?) -> String {
        // Runs for every tab on every tab-row snapshot, and the regexes cost ~50µs, so memoize.
        let key = "\(url?.host ?? "")\n\(url?.path ?? "")\n\(url?.query != nil)\n\(title)" as NSString
        if let hit = cache.object(forKey: key) { return hit as String }
        let out = compute(title, url: url)
        cache.setObject(out as NSString, forKey: key)
        return out
    }

    private static let cache: NSCache<NSString, NSString> = {
        let c = NSCache<NSString, NSString>()
        c.countLimit = 2000
        return c
    }()

    private static func compute(_ title: String, url: URL?) -> String {
        let original = title.trimmingCharacters(in: .whitespacesAndNewlines)
        // "(3) Home / X", "(12) Instagram": unread counts
        var t = original.replacing(leadingCount, with: "")
        guard let url, let host = url.host?.lowercased() else { return t.nilIfEmpty ?? original }
        // A homepage's title is usually "Site - Tagline"; the site name is the best title there.
        if url.path.isEmpty || url.path == "/", url.query == nil { return t.nilIfEmpty ?? original }

        let rule = siteRules.first { r in r.domains.contains { host == $0 || host.hasSuffix("." + $0) } }
        if let transform = rule?.transform, let out = transform(t)?.trimmingCharacters(in: .whitespaces), !out.isEmpty {
            t = out
        }
        t = t.replacing(sphinxDocsSuffix, with: "")

        let label = siteLabel(host: host)
        let names = (rule?.names ?? []).map(normalize)
        for _ in 0..<3 {
            guard let (head, tail) = splitLastSeparator(t), !head.isEmpty,
                  isSiteName(tail, label: label, extraNames: names) else { break }
            t = head
        }
        return t.nilIfEmpty ?? original
    }

    // MARK: - Site rules

    private struct SiteRule {
        /// Registrable domains (subdomains match too).
        var domains: [String]
        /// Extra names the generic pass should treat as this site's name, for
        /// sites whose name doesn't resemble their domain ("Hacker News" on ycombinator.com).
        var names: [String] = []
        /// Site-specific rewrite, run before the generic pass. nil = no change.
        var transform: ((String) -> String?)? = nil
    }

    private static let siteRules: [SiteRule] = [
        SiteRule(domains: ["github.com"], transform: { t in
            let t = t.replacing(#/^GitHub - /#, with: "")
            // "Support Alfred workflows · Issue #43 · nate-parrott/Flashlight"
            if let m = t.wholeMatch(of: #/(.+) · Issue #\d+ · [\w.-]+\/[\w.-]+/#) { return String(m.1) }
            // "Redundant Load Elimination Patches by trentxintong · Pull Request #1 · swiftlang/swift"
            if let m = t.wholeMatch(of: #/(.+?)(?: by [\w-]+)? · Pull Request #\d+ · [\w.-]+\/[\w.-]+/#) { return String(m.1) }
            // "Remove Claude PR GitHub workflow · nate-parrott/wowser2@775f637"
            if let m = t.wholeMatch(of: #/(.+) · [\w.-]+\/[\w.-]+@[0-9a-f]+/#) { return String(m.1) }
            // "swift/README.md at main · swiftlang/swift"
            if let m = t.wholeMatch(of: #/(.+) at [^ ]+ · [\w.-]+\/[\w.-]+/#) { return String(m.1) }
            // "swiftlang/swift: The Swift Programming Language"
            if let m = t.wholeMatch(of: #/([\w.-]+\/[\w.-]+): .*/#) { return String(m.1) }
            return t
        }),
        // "Subject - me@gmail.com - Gmail"
        SiteRule(domains: ["mail.google.com"], transform: { t in
            t.wholeMatch(of: #/(.+) - \S+@\S+ - Gmail/#).map { String($0.1) }
        }),
        // "Google Calendar - Event details"
        SiteRule(domains: ["calendar.google.com"], transform: { t in
            t.wholeMatch(of: #/Google Calendar - (.+)/#).map { String($0.1) }
        }),
        // `BBC Name on X: "tweet text" / X` → `BBC Name: "tweet text"`
        SiteRule(domains: ["x.com", "twitter.com"], names: ["X", "Twitter"], transform: { t in
            t.wholeMatch(of: #/(.+) on (?:X|Twitter): (".*") \/ (?:X|Twitter)/#).map { "\($0.1): \($0.2)" }
        }),
        // "java - Why is processing a sorted array faster…? - Stack Overflow"
        SiteRule(domains: ["stackoverflow.com", "stackexchange.com", "superuser.com", "serverfault.com", "askubuntu.com", "mathoverflow.net"], transform: { t in
            t.replacing(#/^[a-z0-9.#+-]+ - /#, with: "")
        }),
        // "Title : r/mac" / "r/mac on Reddit: Title"
        SiteRule(domains: ["reddit.com"], transform: { t in
            if let m = t.wholeMatch(of: #/(.+) : r\/\w+/#) { return String(m.1) }
            if let m = t.wholeMatch(of: #/r\/\w+ on Reddit: (.+)/#) { return String(m.1) }
            return nil
        }),
        // "Amazon.com: AirPods Pro 2 … : Electronics" / "Amazon.com : delicious candy"
        SiteRule(domains: ["amazon.com"], transform: { t in
            t.wholeMatch(of: #/Amazon\.com ?: (.+?)(?: : [^:]+)?/#).map { String($0.1) }
        }),
        // "Software 2.0. I sometimes see… | by Andrej Karpathy | Medium"
        SiteRule(domains: ["medium.com"], transform: { t in
            t.wholeMatch(of: #/(.+) \| by .+ \| Medium/#).map { String($0.1) }
        }),
        // "Array.prototype.map() - JavaScript | MDN"
        SiteRule(domains: ["developer.mozilla.org"], names: ["MDN"], transform: { t in
            t.wholeMatch(of: #/(.+) - [^-|]+ \| MDN/#).map { String($0.1) }
        }),
        // "Never Gonna Give You Up - song and lyrics by Rick Astley | Spotify"
        SiteRule(domains: ["spotify.com"], transform: { t in
            t.wholeMatch(of: #/(.+) - (?:song and lyrics|Album|Single|EP) by (.+) \| Spotify/#).map { "\($0.1) · \($0.2)" }
        }),
        // "TARTINE BAKERY - Updated October 2026 - 9208 Reviews - … - Yelp"
        SiteRule(domains: ["yelp.com"], transform: { t in
            t.firstMatch(of: #/^(.+?) - Updated /#).map { String($0.1) }
        }),
        // "Headline | World news | The Guardian"
        SiteRule(domains: ["theguardian.com"], transform: { t in
            t.firstMatch(of: #/^(.+?) \| /#).map { String($0.1) }
        }),
        // "macos wallpaper at DuckDuckGo"
        SiteRule(domains: ["duckduckgo.com"], transform: { t in
            t.wholeMatch(of: #/(.+) at DuckDuckGo/#).map { String($0.1) }
        }),
        // "[1706.03762] Attention Is All You Need"
        SiteRule(domains: ["arxiv.org"], transform: { t in
            t.wholeMatch(of: #/\[[\w.\/-]+\] (.+)/#).map { String($0.1) }
        }),
        SiteRule(domains: ["ycombinator.com"], names: ["Hacker News"]),
        SiteRule(domains: ["nytimes.com"], names: ["The New York Times", "NYTimes.com"]),
        SiteRule(domains: ["wsj.com"], names: ["WSJ"]),
        SiteRule(domains: ["bbc.com", "bbc.co.uk"], names: ["BBC", "BBC News", "BBC Sport"]),
        SiteRule(domains: ["npmjs.com"], names: ["npm"]),
        SiteRule(domains: ["apple.com"], names: ["Apple", "Apple Support"]),
    ]

    // MARK: - Generic suffix stripping

    private nonisolated(unsafe) static let leadingCount = #/^\(\d[\d,]*\+?\)\s+/#
    /// Sphinx docs: "json — JSON encoder and decoder — Python 3.15.0 documentation"
    private nonisolated(unsafe) static let sphinxDocsSuffix = #/ — [^—]+ documentation$/#

    private static let separators = [" - ", " – ", " — ", " | ", " · ", " • ", " / ", " :: "]

    /// Splits at the LAST separator: "A - B | C" → ("A - B", "C").
    private static func splitLastSeparator(_ t: String) -> (String, String)? {
        var best: Range<String.Index>?
        for sep in separators {
            if let r = t.range(of: sep, options: .backwards), r.lowerBound > (best?.lowerBound ?? t.startIndex) {
                best = r
            }
        }
        guard let best else { return nil }
        return (String(t[..<best.lowerBound]), String(t[best.upperBound...]))
    }

    /// Whether a trailing title segment is the site's name: it's in the site's
    /// extra names, or (for a short segment) contains the domain's main label —
    /// "Stack Overflow" on stackoverflow.com, "Mathematics Stack Exchange" on
    /// math.stackexchange.com, "Apple Developer Documentation" on developer.apple.com.
    private static func isSiteName(_ segment: String, label: String, extraNames: [String]) -> Bool {
        let n = normalize(segment)
        if n.isEmpty { return false }
        if extraNames.contains(n) { return true }
        if segment.split(separator: " ").count > 4 { return false }
        // Short labels ("x", "bbc") only match exactly, so "Xcode" isn't taken for X.
        return label.count >= 4 ? n.contains(label) : n == label
    }

    /// "en.wikipedia.org" → "wikipedia"; "www.bbc.co.uk" → "bbc".
    private static func siteLabel(host: String) -> String {
        let domain = AutofillHostMatcher.registrableDomain(host)
        return normalize(String(domain.split(separator: ".").first ?? ""))
    }

    /// Lowercased alphanumerics, minus a leading "the": "The Verge" → "verge".
    private static func normalize(_ s: String) -> String {
        let n = String(s.lowercased().unicodeScalars.filter { CharacterSet.alphanumerics.contains($0) })
        return n.hasPrefix("the") && n.count > 3 ? String(n.dropFirst(3)) : n
    }
}
