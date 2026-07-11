import Foundation

private func stringHasURLScheme(_ str: String) -> Bool {
    if let comps = URLComponents(string: str), let scheme = comps.scheme?.nilIfEmpty {
        if scheme.contains(".") || scheme == "localhost" {
            return false
        }
        return true
    }
    return false
}

extension URL {
    var displayString: String {
        stripped
    }
    
    /// Creates a unique file URL by incrementing filename if it already exists
    /// - Parameters:
    ///   - folder: The directory URL where the file will be saved
    ///   - name: The suggested filename, which may be modified to make it valid and unique
    /// - Returns: A URL with a unique filename that doesn't exist on disk
    public static func unique(folder: URL, name: String) -> URL {
        // Sanitize the filename by removing leading dots and slashes
        var sanitizedName = name
        while sanitizedName.hasPrefix(".") || sanitizedName.hasPrefix("/") || sanitizedName.hasPrefix("\\") {
            sanitizedName.removeFirst()
        }
        
        // If name was completely invalid, use a default
        if sanitizedName.isEmpty {
            sanitizedName = "download"
        }
        
        // Check if file already exists, if not return the URL
        var fileURL = folder.appendingPathComponent(sanitizedName)
        if !FileManager.default.fileExists(atPath: fileURL.path) {
            return fileURL
        }
        
        // File exists, need to create a unique name
        let fileExtension = sanitizedName.contains(".") ? "." + sanitizedName.components(separatedBy: ".").last! : ""
        let baseName = sanitizedName.contains(".") ? sanitizedName.components(separatedBy: ".").dropLast().joined(separator: ".") : sanitizedName
        
        var counter = 2
        repeat {
            let newName = "\(baseName) \(counter)\(fileExtension)"
            fileURL = folder.appendingPathComponent(newName)
            counter += 1
        } while FileManager.default.fileExists(atPath: fileURL.path)
        
        return fileURL
    }
    
    public static func withNaturalString(_ string: String) -> URL? {
        if string.contains(" ") {
            return nil
        }
        let hasUrlChars = string.contains(":") || string.withoutSuffix(".").contains(".")
        if !hasUrlChars {
            return nil
        }
        if stringHasURLScheme(string) {
            return URL(string: string)
        }
        let url = URL(string: "https://" + string)
        // Check if it's a local url and dont use https
        if url?.hostWithoutWWW == "localhost" || url?.hostWithoutWWW == "127.0.0.1" {
            return URL(string: "http://" + string)
        }
        return url
    }
//    public static func withSearchQuery(_ searchQuery: String) -> URL {
//        return withNaturalString(searchQuery) ?? googleSearch(searchQuery)
//    }
    public static func googleSearch(_ query: String) -> URL {
        var comps = URLComponents(string: "https://google.com/search")!
        comps.queryItems = [URLQueryItem(name: "q", value: query)]
        return comps.url!
    }

    public static func googleTranslateURL(for url: URL) -> URL? {
        // https://translate.google.com/translate?sl=auto&u=https%3A%2F%2Fwww.bbc.com
        var comps = URLComponents(string: "https://translate.google.com/translate")!
        comps.queryItems = [URLQueryItem(name: "sl", value: "auto"), URLQueryItem(name: "u", value: url.absoluteString)]
        return comps.url
    }

    public func withScheme(_ scheme: String) -> URL? {
        guard var comps = URLComponents(url: self, resolvingAgainstBaseURL: true) else { return nil }
        comps.scheme = scheme
        return comps.url
    }

    // don't use this for navigation -- only deduplication
    public var historyKey: String {
        guard var comps = URLComponents(string: absoluteString.lowercased()) else { return absoluteString }
        if comps.scheme == "https" {
            comps.scheme = "http"
        }
        comps.fragment = nil

        var hostParts = (comps.host ?? "").split(separator: ".")
        if hostParts.first == "www" {
            hostParts.removeFirst()
        }
        comps.host = hostParts.joined(separator: ".")

        comps.queryItems = comps.queryItems?.filter({ !shouldDropQueryItemForHistoryKey($0.name, val: $0.value) })
        var str = comps.url?.absoluteString ?? absoluteString
        if str.hasSuffix("/") {
            str.removeLast()
        }
        return str
    }

    public var normalizedKey: String {
        return historyKey
    }

    public var stringsToSearchBasedOn: [String] {
        var strings = [absoluteString.lowercased(), historyKey]
        let withoutScheme = absoluteString.lowercased().components(separatedBy: "://").dropFirst().joined(separator: "://")
        strings.append(withoutScheme)
        if withoutScheme.hasPrefix("www.") {
            // can u believe people enjoy using this language
            strings.append(String(withoutScheme.suffix(from: withoutScheme.index(withoutScheme.startIndex, offsetBy: 4))))
        }
        return strings
    }

    public var stripped: String {
//        guard var comps = URLComponents(string: absoluteString.lowercased()) else { return absoluteString }
//        comps.scheme = nil
        var str = absoluteString
        for prefix in ["https://", "http://", "www."] {
            if str.hasPrefix(prefix) {
                str = String(str.suffix(from: str.index(str.startIndex, offsetBy: prefix.count)))
            }
        }
        return String(str.withoutSuffix("/"))
    }

    public func isAncestorOf(_ child: URL) -> Bool {
        let normSelf = self.standardizedFileURL.resolvingSymlinksInPath().absoluteString
        let normChild = child.standardizedFileURL.resolvingSymlinksInPath().absoluteString
        return normChild.hasPrefix(normSelf)
    }

    public var isDescendantOfApplicationsDir: Bool {
        return URL(fileURLWithPath: "/Applications").isAncestorOf(self) || URL(fileURLWithPath: "~/Applications").isAncestorOf(self)
    }

    public var hostWithoutWWW: String {
        var parts = (host ?? "").components(separatedBy: ".")
        if parts.first == "www" {
            parts.remove(at: 0)
        }
        return parts.joined(separator: ".")
    }

    public var isRootOfDomain: Bool {
        return pathComponents.count == 0
    }

    /// Icon to use when the page didn't declare a favicon of its own. Google's s2
    /// service resolves an icon for a domain by whatever means the site offers
    /// (`/favicon.ico`, `<link rel=icon>`, web manifest), so it succeeds for plenty
    /// of sites where a bare `/favicon.ico` guess 404s.
    ///
    /// Only the host is sent — never the full URL, which would hand Google the
    /// user's browsing path.
    public var inferredFaviconURL: URL {
        return googleFaviconURL ?? URL(string: "/favicon.ico", relativeTo: self)!
    }

    public var googleFaviconURL: URL? {
        guard let host else { return nil }
        var components = URLComponents()
        components.scheme = "https"
        components.host = "www.google.com"
        components.path = "/s2/favicons"
        components.queryItems = [
            URLQueryItem(name: "domain", value: host),
            URLQueryItem(name: "sz", value: "64"),
        ]
        return components.url
    }

    public func hasRootHost(_ host: String) -> Bool {
        let hw = hostWithoutWWW
        if hw == host {
            return true
        }
        if hw.hasSuffix("." + host) {
            return true
        }
        return false
    }

    public func queryParam(name: String) -> String? {
        guard let comps = URLComponents(url: self, resolvingAgainstBaseURL: true) else { return nil }
        return comps.queryItems?.first(where: { $0.name == name })?.value
    }

    public static var aboutBlank: URL { URL(string: "about:blank")! }
    
    public var parsedAsGoogleSearchQuery: String? {
        guard let host = host?.lowercased(), host.contains("google") else { return nil }
        guard let urlWithSpacesSubbed = URL(string: self.absoluteString.replacingOccurrences(of: "+", with: "%20")) else {
            return nil
        }
        let path = urlWithSpacesSubbed.path
        guard path == "/search" || path == "/webhp" else { return nil }
        return urlWithSpacesSubbed.queryParam(name: "q")?.nilIfEmpty
    }
    
    public var parsedAsDuckDuckGoLuckyQuery: String? {
        guard hasRootHost("duckduckgo.com") else { return nil }
        guard let query = queryParam(name: "q") else { return nil }
        
        // Check if it's a backslash query (I'm feeling lucky format)
        if query.hasPrefix("\\") {
            // %5C is the escaped backslash
            let decodedQuery = String(query.dropFirst(1))
            return decodedQuery.removingPercentEncoding
        }
        
        return nil
    }
    
    /// Creates a DuckDuckGo "I'm feeling lucky" URL
    /// - Parameter query: The search query
    /// - Returns: URL for a "I'm feeling lucky" search
    public static func duckDuckGoLuckyURL(for query: String) -> URL? {
        guard let encodedQuery = query.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) else {
            return nil
        }
        let backslashQuery = "%5C" + encodedQuery
        return URL(string: "https://duckduckgo.com/?q=\(backslashQuery)")
    }
}

private func shouldDropQueryItemForHistoryKey(_ name: String, val: String?) -> Bool {
    if (val ?? "") == "" {
        return true
    }
    if name.hasPrefix("utm_") {
        return true
    }
    return false
}
