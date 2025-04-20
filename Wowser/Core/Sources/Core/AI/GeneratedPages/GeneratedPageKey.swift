import Foundation

public enum GeneratedPageKey: Hashable, Codable {
    case homepage
    case answer(q: String)
    
    init?(url: URL) {
        guard url.absoluteString.hasPrefix("about:blank") else { return nil }
        if url.queryParam(name: "homepage") != nil {
            self = .homepage
            return
        }
        if let q = url.queryParam(name: "q") {
            self = .answer(q: q)
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
        case .answer(let q):
            components.queryItems = [URLQueryItem(name: "q", value: q)]
        }
        
        return components.url!
    }
}
