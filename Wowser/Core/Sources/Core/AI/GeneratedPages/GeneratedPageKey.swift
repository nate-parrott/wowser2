import Foundation

public enum GeneratedPageKey: Hashable, Codable {
    case homepage
    case webSearch(q: String, page: Int = 0)
    case imageSearch(q: String, page: Int = 0)
    
    init?(url: URL) {
        guard url.absoluteString.hasPrefix("about:blank") else { return nil }
        if url.queryParam(name: "homepage") != nil {
            self = .homepage
            return
        }
        if let q = url.queryParam(name: "q") {
            let page = Int(url.queryParam(name: "page") ?? "0") ?? 0
            if url.queryParam(name: "images") != nil {
                self = .imageSearch(q: q, page: page)
            } else {
                self = .webSearch(q: q, page: page)
            }
            return
        }
        return nil
    }
    
    var url: URL {
        var components = URLComponents()
        components.scheme = "about"
        components.path = "blank"
        
        switch self {
        case .homepage:
            components.queryItems = [URLQueryItem(name: "homepage", value: "true")]
        case .webSearch(let q, let page):
            var queryItems = [URLQueryItem(name: "q", value: q)]
            if page > 0 {
                queryItems.append(URLQueryItem(name: "page", value: String(page)))
            }
            components.queryItems = queryItems
        case .imageSearch(let q, let page):
            var queryItems = [
                URLQueryItem(name: "q", value: q),
                URLQueryItem(name: "images", value: "true")
            ]
            if page > 0 {
                queryItems.append(URLQueryItem(name: "page", value: String(page)))
            }
            components.queryItems = queryItems
        }
        
        return components.url!
    }
}
