import Foundation
import SwiftSoup
import QuartzCore
import Fuzi

public struct DDGSearchEngine: WebSearchEngine {
    public init() {
    }

    // MARK: - WebSearchEngine
    public func search(query: String, page: Int = 0) async throws -> WebSearchResponse {
        var urlComponents = URLComponents(string: "https://duckduckgo.com/")!
        urlComponents.queryItems = [
            URLQueryItem(name: "q", value: query),
//            URLQueryItem(name: "ia", value: "web"),
//            URLQueryItem(name: "gbv", value: "1"), // google basic version = 1 (no js)
            // https://www.google.com/search?q=nate+parrott&sca_esv=e9871a05a871ab10&ei=OII7aNjJCcP_ptQPgamm8Q8&start=20&sa=N&sstk=Ac65TH476ORB7dK2AXx1U_u8zuAvKchzwaGq81jMzxxY3FJg3tAfK3vdgnf_aTNkEgKU923Cf4SVxTzZt7z1Pqnu4akgvWo0CQeO561UMZRCN0ZuhEDp4SVHrSVOQeW8Vq66&ved=2ahUKEwjYxfW94M6NAxXDv4kEHYGUKf44ChDy0wN6BAgKEAc&biw=1038&bih=750&dpr=2
        ]
        if page > 0 {
            urlComponents.queryItems!.append(URLQueryItem(name: "start", value: "\(page * 10)"))
        }
        let session = URLSession(configuration: .ephemeral)
        var request = URLRequest(url: urlComponents.url!)
        request.httpShouldHandleCookies = false
        request.setValue("text/html,application/xhtml+xml", forHTTPHeaderField: "Accept")
        request.setValue("utf-8, iso-8859-1;q=0.5", forHTTPHeaderField: "Accept-Charset")
        let userAgent = "Lynx/2.8.8dev.3 libwww-FM/2.14 SSL-MM/1.4.1"
//        let userAgent = "Mozilla/4.0 (compatible; MSIE 6.0; Windows NT 5.1; SV1)"
        request.setValue(userAgent, forHTTPHeaderField: "User-Agent")
//        print("[N] Making Google Request '\(query)'")
        let (data, response) = try await session.data(for: request)
        guard let html = String(data: data, encoding: .isoLatin1) else {
            throw SearchError.invalidHTML
        }
        print("[BEGIN HTML]")
        print(html)
        print("[END HTML]")
        let baseURL = response.url ?? urlComponents.url!

//        let t2 = CACurrentMediaTime()
        let extracted = try extract(html: html, baseURL: baseURL, query: query)
//        print("[Timing] [GoogleSearch] Parsed at \(CACurrentMediaTime() - t2)")
        
        var resp = extracted
        resp.html = html
        return resp
    }

    func extract(html: String, baseURL: URL, query: String) throws -> WebSearchResponse {
        let doc = try Fuzi.HTMLDocument(stringSAFE: html)
        var results = [WebSearchResult]()
        
        // Parse search results with the following structure:
        // <a href="/url?q=..."><span>Title</span></a> then parent.parent has <table> with snippet
        for anchor in doc.css(".result-link") {
            guard let href = anchor.attr("href"),
                  let ddgUrlComps = URLComponents(string: href),
                  let urlStr = ddgUrlComps.queryItems?.first(where: { $0.name == "uddg" })?.value,
                  let url = URL(string: urlStr),
                  let parentTr = anchor.firstParentMatching({ $0.tag?.lowercased() == "tr" }),
                  let title = anchor.stringValue.trimmed.nilIfEmptyOrJustWhitespace
//                  let span = anchor.css("span").first,
//                  let title = span.stringValue.trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmptyOrJustWhitespace,
//                  let parentParent = anchor.nthParent(2),
//                  let table = parentParent.css("table").first,
//                  let snippet = table.stringValue.trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmptyOrJustWhitespace
            else { continue }
            let snippet = parentTr.nextElementSibling?.css(".result-snippet").first?.stringValue.trimmed.nilIfEmptyOrJustWhitespace
            
            results.append(WebSearchResult(url: url, title: title, snippet: snippet))
        }
        
        return .init(query: query, results: results, infoBox: nil)
    }

    enum SearchError: Error {
        case invalidHTML
        case missingMainElement
    }
}

private extension Fuzi.XMLElement {
    func nthParent(_ n: Int) -> Fuzi.XMLElement? {
        if n <= 0 {
            return self
        }
        return parent?.nthParent(n - 1)
    }
    
    var nextElementSibling: Fuzi.XMLElement? {
        if let sibs = parent?.childNodes(ofTypes: [.Element]),
           let idx = sibs.firstIndex(of: self)
        {
            return sibs.get(idx + 1) as? Fuzi.XMLElement
        }
        return nil
    }
    
    func firstParentMatching(_ fn: (Fuzi.XMLElement) -> Bool) -> Fuzi.XMLElement? {
        if let parent {
            if fn(parent) {
                return parent
            }
            return parent.firstParentMatching(fn)
        }
        return nil
    }
}
