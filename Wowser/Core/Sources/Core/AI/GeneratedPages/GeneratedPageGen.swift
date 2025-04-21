import Foundation
import ChatToys

// Generator for AI-powered pages
public enum PageGenerator {
    // Generation functions
    public static func generateContent(for key: GeneratedPageKey) -> AsyncThrowingStream<ContentUpdate, Error> {
        return AsyncThrowingStream { continuation in
            Task {
                do {
                    switch key {
                    case .homepage:
                        try await generateHomepage(continuation: continuation)
                    case .answer(let query):
                        try await generateAnswer(query: query, continuation: continuation)
                    }
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
        }
    }
    
    private static func generateHomepage(continuation: AsyncThrowingStream<ContentUpdate, Error>.Continuation) async throws {
        let gifs = RetroGifs.shared.allShortURLs.joined(separator: ", ")
        let prompt = """
        You will be generating HTML web pages in a browser.
        
        HTML PAGES SHOULD:
        - Use simple, concise HTML
        - Contain links, tables, headers, hrs, divs, form, marquee, bold and i tags.
        - ONLY use <img> tags to refer to GIFs in this list: \(gifs)
        - Forms may be included if relevant. All forms should have a descriptive `action` parameter that ends in `.php`
        - Be short (only a few paragraphs at most)
        - Specify fun, relevant fonts and colors using inline HTML <font> tags and style elements. NO <style> tags in <head>.
          - Any font available on iOS may be used.
        - Have colors, fonts and styles which help to establish the world described in the description.
        - Make sure to use a reasonable content max width and line height

        First, here is a description of the alternate universe that the server should pretend it exists within. This world description should dictate inform the content, tone and visual aesthetic of the output HTML.
        <world-description>
        Pretend it is an alternate-reality version of 1996 where:
        - Websites have fun, colorful retro designs, and project a warm and optimistic tone.
        - Constantly refer to the internet as the 'information superhighway,' and use words like 'e-meet,' 'portal', and 'global village.'
        - Are friendly, eager and happy to help.
        Then, when prompted with a URL, you are to output a valid HTML page that could plausibly represent the requested URL. Output the HTML and only the HTML.
        </world-description>
        
        Generate an HTML page that is a user's homepage on the internet. It should serve to excite, inspire and link to exciting, useful sitres.
        It is \(Date.llmDateTime)
        Now, output your response in HTML ONLY (no commentary). Do not break character. Here:
        """
        try await generatePage(prompt: prompt, estimatedCharLen: 3000, continuation: continuation)
    }
    
    private static func generatePage(prompt: String, estimatedCharLen: Int, continuation: AsyncThrowingStream<ContentUpdate, Error>.Continuation) async throws {
        var lastGen: ContentUpdate?
        for try await partial in try LLMs.currentOrThrow(json: false).completeStreaming(prompt: [LLMMessage(role: .user, content: prompt)]) {
            var html = partial.content
            html = html.trimmingCharacters(in: .whitespacesAndNewlines).withoutPrefix("```").withoutPrefix("html")
            html = "<meta name='viewport' content='width=device-width, initial-scale=1' />" + html
            html = RetroGifs.shared.replaceShortURLsWithLongURLs(inString: html)
            let p = min(0.9, Double(partial.content.count) / Double(estimatedCharLen))
            lastGen = ContentUpdate(html: html, progress: p)
            continuation.yield(lastGen!)
        }
        lastGen?.progress = 1
        if let lastGen {
            continuation.yield(lastGen)
        }
    }
    
    private static func generateAnswer(query: String, continuation: AsyncThrowingStream<ContentUpdate, Error>.Continuation) async throws {
        let gifs = RetroGifs.shared.allShortURLs.joined(separator: ", ")
        let prompt = """
        You will be generating HTML web pages in a browser.
        
        HTML PAGES SHOULD:
        - Use simple, concise HTML
        - Contain links, tables, headers, hrs, divs, form, marquee, bold and i tags.
        - ONLY use <img> tags to refer to GIFs in this list: \(gifs)
        - Forms may be included if relevant. All forms should have a descriptive `action` parameter that ends in `.php`
        - Be short (only a few paragraphs at most)
        - Specify fun, relevant fonts and colors using inline HTML <font> tags and style elements. NO <style> tags in <head>.
          - Any font available on iOS may be used.
        - Have colors, fonts and styles which help to establish the world described in the description.
        - Make sure to use a reasonable content max width and line height

        First, here is a description of the alternate universe that the server should pretend it exists within. This world description should dictate inform the content, tone and visual aesthetic of the output HTML.
        <world-description>
        Pretend it is an alternate-reality version of 1996 where:
        - Websites have fun, colorful retro designs, and project a warm and optimistic tone.
        - Constantly refer to the internet as the 'information superhighway,' and use words like 'e-meet,' 'portal', and 'global village.'
        - Are friendly, eager and happy to help.
        Then, when prompted with a URL, you are to output a valid HTML page that could plausibly represent the requested URL. Output the HTML and only the HTML.
        </world-description>
        
        Generate an HTML page that answers the user's question:
        <question>
        \(query)
        </question>
        It should serve to excite, inspire and link to exciting, useful sitres.
        It is \(Date.llmDateTime)
        Now, output your response in HTML ONLY as a rich webpage. No non-html commentary. Do not break character. Here:   
        """
        try await generatePage(prompt: prompt, estimatedCharLen: 3000, continuation: continuation)
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
