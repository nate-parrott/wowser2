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
                let context = try await WebContext.from(results: results, query: query, timeout: 3, resultCount: 6, charLimit: 10_000, urlMode: .truncate(200))
                let sys = "The assistant is understanding a user's search query, reviewing Markdown webpage content from the top search results, and describing any information, if any, from the webpage is relevant to the user's query."
                let prompt = """
                Here is the user's search query: '\(query)'
                Here is the Markdown content extracted from the first few results:
                \(context.asXML)
                
                # YOUR TASK
                Now, your task is to analyze the user's search query to determine what information they want. Then, look at the content (which may be incomplete, out-of-date, improperly parsed or irrelevant) and extracting any relevant details or facts.
                Your job is not to answer the question. Your job is to describe the information you find that is relevant to the queation.
                For every fact you state, describe WHERE it came from.
                LEAD with the most relevant information to the user's question, then describe what the sources say in more detail.
                Do not use the word 'Overview' or 'Conclusion.' Cut to the chase; specific facts first.
                
                # QUERY EXPANSION
                You will be asked to expand the user's query into a RICHER query. It is this RICHER query that you should use as a guide when deciding which information to provide.
                If the user's query is vague, or just the name of a thing, you should assume they want to learn the most likely facts about this thing.
                
                Examples of query expansions:
                "the bear hulu" -> "Tell me about the premise, availability to stream, airing time and critical reception of the show The Bear on Hulu."
                "iphone 6s release date" -> "Tell me when the iPhone 6s will be released."
                "weather": -> "Tell me the weather forecast."
                "apple inc" -> "Tell me the latest news, company details, products, and key metrics for Apple Inc."
                "swift string to markdown" -> "Provide commented code samples for converting a string to Markdown in Swift."
                
                # RESPONSE FORMAT
                Respond in JSON in this exact format:
                
                ```
                {
                    "expanded_query": string,
                    "markdown": string // 2-3 paragraphs of text, with headers and bullets if appropriate.
                }
                ```
                
                Your markdown should include citations like this:
                "This is a fact [(en.wikipedia.org)](https://source.com)."
                """
                
                struct Response: Codable {
                    var expanded_query: String // dont rlly care abt this; just for the model
                    var markdown: String
                }
                
                let parser = MarkdownParser()
                let llm = try LLMs.currentOrThrow(json: true)
                for try await partial in llm.completeStreamingWithJSONObject(prompt: [LLMMessage(role: .system, content: sys), LLMMessage(role: .user, content: prompt)], type: Response.self, completeLinesOnly: false) {
                    let html = parser.html(from: partial.markdown)
                    continuation.yield(html)
                }
                continuation.finish()
            } catch {
                continuation.finish(throwing: error)
            }
        }
    }
}
