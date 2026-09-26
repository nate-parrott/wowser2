import Ink
import Foundation
import ChatToys

private struct WebSearchPageModel {
    var query: String
    var page: Int = 0
    var includeSidebar = true
    var searchResults: [WebSearchResult]?
    var imageResults: [ImageSearchResult]?
    var aiAnswer: String? // html
    
    func html() -> String {
        let resultItems: [String] = (searchResults ?? []).map { item in
            return """
            <li>
                <a href="\(item.url)">
                    <div class="url">
                        <img src="\(item.url.googleFaviconURL ?? item.url.inferredFaviconURL)" />
                        <span>\(item.url.stripped.truncateTailWithEllipsis(chars: 80))</span>
                    </div>
                    <h3>\(item.title)</h3>
                    \(item.snippet?.nilIfEmpty != nil ? "<p>\(item.snippet ?? "")</p>" : "")
                </a>
            </li>
            """
        }
        
        var imageResultItems: [String] = (imageResults ?? []).map { item in
            return """
            <a class='imageResult' href="\(item.hostPageURL.absoluteString)">
                <img class="thumbnail" src="\(item.thumbnailURL?.absoluteURL ?? item.imageURL.absoluteURL)" />
                <img class="real" src="\(item.imageURL.absoluteString)" />
            </a>
            """
        }
        
        while imageResultItems.count < 5 {
            imageResultItems.append("<a class='imageResult placeholder'></a>")
        }
        
        // Pagination links
        let paginationHTML: String = {
            var links: [String] = []
            
            if page > 0 {
                let prevKey = GeneratedPageKey.webSearch(q: query, page: page - 1)
                links.append("<a href=\"\(prevKey.url.absoluteString)\">← Previous</a>")
            }
            
            let nextKey = GeneratedPageKey.webSearch(q: query, page: page + 1)
            links.append("<a href=\"\(nextKey.url.absoluteString)\">Next →</a>")
            
            return links.isEmpty ? "" : "<div class='pagination'>\(links.joined(separator: " | "))</div>"
        }()
        
        let html = """
        <!DOCTYPE html>
        <html>
        <head>
        <meta charset='utf-8' />
        <meta name='viewport' content='width=device-width, initial-scale=1' />
        <title>\(query.escapedForHTML)</title>
        <style>
            :root {
                --background-light: #fff;
                --text-light: #0500200;
                --text-secondary-light: rgba(31, 14, 8, 0.66);
                --placeholder-light: #224;
                
                --background-dark: #1c1c1e;
                --text-dark: #e5e5e7;
                --text-secondary-dark: rgba(229, 229, 231, 0.66);
                --placeholder-dark: #334;
            }
            
            @media (prefers-color-scheme: light) {
                body {
                    background-color: var(--background-light);
                    color: var(--text-light);
                }
                .url span, #results p, #ai { 
                    opacity: 0.5;
                }
                #images .placeholder {
                    background-color: var(--placeholder-light);
                }
            }
            
            @media (prefers-color-scheme: dark) {
                body {
                    background-color: var(--background-dark);
                    color: var(--text-dark);
                }
                .url span, #results p, #ai { 
                    opacity: 0.5;
                }
                #images .placeholder {
                    background-color: var(--placeholder-dark);
                }
            }
            
            body { 
                font-family: -apple-system, BlinkMacSystemFont, sans-serif; 
                line-height: 1.5;
                max-width: 900px; 
                margin: 0 auto; 
                padding: 40px; 
                box-sizing: border-box;
            }
            @media screen and (max-width: 500px) {
                body {
                    padding: 24px;
                }
            }
            #results { list-style: none; padding: 0; }
            a {
                color: inherit;
                text-decoration: inherit;
            }
            .url { display: flex; align-items: center; }
            .url img { width: 16px; height: 16px; object-fit: contain; margin-right: 0.5em; }
            .url span { font-size: small; width: 0; flex-grow: 1; white-space: nowrap; overflow: hidden; text-overflow: ellipsis; font-weight: 500; } 
            #results h3 { color: inherit; font-size: 1.4em; line-height: 1.2; } 
            #results p { font-size: small; font-weight: 500; }
            #results > li > a > * { margin-top: 0; margin-bottom: 8px; }
            #results > li { margin-bottom: 2em; }
        
            main {
                display: flex;
                flex-direction: row;
                align-items: top;
            }
        
            main, pre {
                word-wrap: break-word;
            }
        
            aside {
                width: 300px;
                margin-left: 2em;
            }
        
            #images {
                width: 100%;
                overflow-x: scroll;
                height: 150px;
                display: flex;
                flex-direction: row;
            }
            #images a {
                position: relative;
                border-radius: 6px;
                overflow: hidden;
                height: 100%;
                flex: 0 0 auto;
            }
            #images img {
                object-fit: cover;
                height: 150px;
                width: auto;
            }
            #images img.real {
                position: absolute;
                inset: 0;
            }
            #images .placeholder {
                width: 100px;
            }
            #ai {
                font-size: small;
            }
            .pagination {
                font-size: small;
            }
            .pagination a {
                color: inherit;
                text-decoration: underline;
                margin-right: 1em;
            }
        </style>
        </head>
        <body>
            <main>
                <ul id="results">
                    \(resultItems.joined(separator: "\n"))
                    <li>\(paginationHTML)</li>
                </ul>
                <aside style="display: \(includeSidebar ? "block" : "none")">
                    <div id="images">
                        \(imageResultItems.joined(separator: "\n"))
                    </div>
                    <div id="ai">\(aiAnswer ?? "")</div>
                </aside>
            </main>
        </body>
        </html>
        """
        return html
    }
}

extension PageGenerator {
    static func generateAnswer(query: String, page: Int = 0, continuation: AsyncThrowingStream<ContentUpdate, Error>.Continuation, includeAI: Bool = false) async throws {
        var model = WebSearchPageModel(query: query, page: page)
        model.includeSidebar = includeAI
        async let results_ = try await GoogleSearchEngine().search(query: query, page: page).results
        
        if !includeAI {
            model.searchResults = try await results_
            continuation.yield(ContentUpdate(html: model.html(), progress: 1))
            return
        }
        
//        async let imageResults_ = try await GoogleImageSearchEngine().searchImages(query: query, page: page)
        model.searchResults = try await results_
        let aiAnswerStream = aiAnswer(query: query, results: model.searchResults!)
        continuation.yield(ContentUpdate(html: model.html(), progress: 0.5))
//        model.imageResults = try? await imageResults_
        continuation.yield(ContentUpdate(html: model.html(), progress: 0.7))
        
        for try await ai in aiAnswerStream.throttle(for: 1) {
            model.aiAnswer = ai
            continuation.yield(ContentUpdate(html: model.html(), progress: 0.9))
        }
        
        
        continuation.yield(ContentUpdate(html: model.html(), progress: 1))
        continuation.finish()
    }
}

private func aiAnswer(query: String, results: [WebSearchResult]) -> AsyncThrowingStream<String, Error> {
    return AsyncThrowingStream { continuation in
        Task {
            do {
                // The on-device model has a ~4K-token window.
                let small = MicroAI.backend(for: .searchAnswer) == .onDevice
                let context = try await WebContext.from(results: results, query: query, timeout: 3, resultCount: small ? 4 : 6, charLimit: small ? 4_000 : 10_000, urlMode: .truncate(200))
                let sys = """
                You read the top web search results for a user's query and describe the information in them that is relevant to it.
                First work out what the user most likely wants: a vague query or a bare name usually means "the most likely facts about this thing" (e.g. "the bear hulu" → premise, where to stream, reception; "iphone 6s release date" → the date; "apple inc" → latest news, company details, products).
                Lead with the most relevant specific facts, then what the sources say in more detail. Don't answer from your own knowledge; describe what the sources say, and cite where every fact came from, like: "This is a fact [(en.wikipedia.org)](https://source.com)."
                Write 2-3 paragraphs of Markdown, with headers and bullets if useful. Don't use the words "Overview" or "Conclusion". Output only the Markdown.
                """
                let prompt = """
                Search query: '\(query)'

                Markdown content extracted from the first few results (may be incomplete, out of date, or irrelevant):
                \(context.asXML)
                """

                let parser = MarkdownParser()
                for try await markdown in MicroAI.streamText(.searchAnswer, MicroAIPrompt(instructions: sys, input: prompt)) {
                    continuation.yield(parser.html(from: markdown))
                }
                continuation.finish()
            } catch {
                continuation.finish(throwing: error)
            }
        }
    }
}
