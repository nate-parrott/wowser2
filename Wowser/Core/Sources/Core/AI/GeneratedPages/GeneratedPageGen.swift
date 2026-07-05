import Foundation
import ChatToys

// Generator for AI-powered pages
public enum PageGenerator {
    // Generation functions
    public static func generateContent(for key: GeneratedPageKey, lastHTML: String?) -> AsyncThrowingStream<ContentUpdate, Error> {
        return AsyncThrowingStream { continuation in
            Task {
                do {
                    switch key {
                    case .webSearch(let query, let page):
                        try await generateAnswer(query: query, page: page, continuation: continuation)
                    case .imageSearch(let query, let page):
                        try await generateImageSearch(query: query, page: page, continuation: continuation)
                    }
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
        }
    }
    
}

extension Date {
    static var llmDateTime: String {
        let fmt = DateFormatter()
        fmt.dateStyle = .short
        fmt.timeStyle = .short
        return fmt.string(from: Date())
    }
}

private extension LLMMessage {
    var extractContentUpdate: ContentUpdate {
        let estimatedCharLen = 1500
        var html = content
        html = html.trimmingCharacters(in: .whitespacesAndNewlines).withoutPrefix("```").withoutPrefix("html")
        html = "<meta name='viewport' content='width=device-width, initial-scale=1' />" + html
        html = RetroGifs.shared.replaceShortURLsWithLongURLs(inString: html)
        let p = min(0.9, Double(content.count) / Double(estimatedCharLen))
        return ContentUpdate(html: html, progress: p)
    }
}
