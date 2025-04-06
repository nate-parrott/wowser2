import Foundation
import WebKit

struct WebContentExtractedData: Equatable, Codable {
    var favicon: URL?
    var ogImage: URL?
}

extension WebContent {
    // TODO: Call this periodically
    func extractWebContentData() async throws -> WebContentExtractedData {
        try await webview.evaluateJS("""
        const result = {};
        // TODO
        return result;
        """.wrappedInSelfCallingJSFunction, resultType: WebContentExtractedData.self)
    }
}
