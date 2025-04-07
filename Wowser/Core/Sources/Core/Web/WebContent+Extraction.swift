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
        
        // Extract favicon URL
        const faviconLink = document.querySelector('link[rel="icon"], link[rel="shortcut icon"], link[rel="apple-touch-icon"]');
        if (faviconLink && faviconLink.href) {
            result.favicon = new URL(faviconLink.href, window.location.href).toString();
        }
        
        // Extract Open Graph image
        const ogImageMeta = document.querySelector('meta[property="og:image"]');
        if (ogImageMeta && ogImageMeta.content) {
            result.ogImage = new URL(ogImageMeta.content, window.location.href).toString();
        }
        
        return result;
        """.wrappedInSelfCallingJSFunction, resultType: WebContentExtractedData.self)
    }
}
