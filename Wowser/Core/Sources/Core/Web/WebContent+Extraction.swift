import Foundation
import WebKit

struct WebContentExtractedData: Equatable, Codable {
    var favicon: URL?
    var ogImage: URL?
    var readyState: String?
    var jsURL: URL?
    var isRecipe: Bool?
    
    var isReady: Bool {
        readyState == "interactive" || readyState == "complete"
    }
}

extension WebContentWebKit {
    func extractWebContentData() async throws -> WebContentExtractedData {
        try await webview.evaluateJS("""
        const result = {};
        
        result.readyState = document.readyState;
        result.jsURL = window.location.href;
        
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
        
        result.isRecipe = \(RecipeExtraction.recipeCheckExpression)
        
        return result;
        """.wrappedInSelfCallingJSFunction, resultType: WebContentExtractedData.self)
    }
}
