import Foundation
import FoundationModels

// The on-device agent's tools. Page text never enters the agent's own
// (tiny) context: ask_page and web_research hand trimmed text to a one-shot
// on-device "reader" session and return only its short answer.

typealias LocalAgentLog = @Sendable (AgentEvent) async -> Void

struct NavigateTool: FoundationModels.Tool {
    let name = "navigate"
    let description = "Open a URL in the user's page."
    let key: String
    let log: LocalAgentLog

    @Generable
    struct Arguments {
        @Guide(description: "Full URL, e.g. https://example.com")
        var url: String
    }

    func call(arguments: Arguments) async throws -> String {
        await log(.toolUse(name: name, inputJSON: LocalAgentText.json(["url": arguments.url])))
        let output: String
        if let url = LocalAgentText.normalizedURL(arguments.url) {
            let host = BrowserJSLiveHost.shared
            do {
                if let pane = await LocalAgentContext.targetPaneID(key: key) {
                    try await host.tabsNavigate(id: pane.raw, url: url.absoluteString)
                } else {
                    _ = try await host.tabsOpen(url: url.absoluteString, background: false, windowId: nil)
                }
                output = "Opened \(url.absoluteString)"
            } catch {
                output = "Failed: \(error.localizedDescription)"
            }
        } else {
            output = "Not a URL. Give a full URL."
        }
        await log(.toolResult(text: output, isError: false))
        return output
    }
}

struct AskPageTool: FoundationModels.Tool {
    let name = "ask_page"
    let description = "Answer a question using the text of the page the user is looking at."
    let key: String
    let log: LocalAgentLog

    @Generable
    struct Arguments {
        @Guide(description: "A specific, self-contained question about the page")
        var question: String
    }

    func call(arguments: Arguments) async throws -> String {
        await log(.toolUse(name: name, inputJSON: LocalAgentText.json(["question": arguments.question])))
        let output: String
        if let pane = await LocalAgentContext.targetPaneID(key: key) {
            do {
                let text = try await BrowserJSLiveHost.shared.contentRead(id: pane.raw, as: "text")
                let excerpt = LocalAgentText.excerpt(text, question: arguments.question, limit: 6000)
                output = try await LocalAgentReader.answer(arguments.question, from: excerpt)
            } catch {
                output = "Couldn't read the page: \(error.localizedDescription)"
            }
        } else {
            output = "The user has no page open."
        }
        await log(.toolResult(text: output, isError: false))
        return output
    }
}

struct WebResearchLocalTool: FoundationModels.Tool {
    let name = "web_research"
    let description = "Search the web and answer a question from the top results."
    let log: LocalAgentLog

    @Generable
    struct Arguments {
        @Guide(description: "A specific, self-contained question")
        var question: String
    }

    func call(arguments: Arguments) async throws -> String {
        await log(.toolUse(name: name, inputJSON: LocalAgentText.json(["question": arguments.question])))
        let output: String
        do {
            let urls = try await LocalAgentResearch.googleResultURLs(query: arguments.question)
            let pages = await LocalAgentResearch.fetchExcerpts(urls: urls, question: arguments.question, count: 3, limit: 2000)
            if pages.isEmpty {
                output = "No readable results."
            } else {
                let source = pages.map { "Source: \($0.url.host ?? "")\n\($0.text)" }.joined(separator: "\n\n")
                let answer = try await LocalAgentReader.answer(arguments.question, from: source)
                output = answer + "\nSources: " + pages.map { $0.url.absoluteString }.joined(separator: " ")
            }
        } catch {
            output = "Research failed: \(error.localizedDescription)"
        }
        await log(.toolResult(text: output, isError: false))
        return output
    }
}

// MARK: - Reader subagent

enum LocalAgentReader {
    /// One-shot on-device call: answer `question` from `text` alone.
    static func answer(_ question: String, from text: String) async throws -> String {
        let logID = AIRequestLog.shared.begin(modelName: "On device - Agent reader")
        do {
            let session = LanguageModelSession(model: .default, instructions: """
            Answer the question using only the provided text. Be concise: 1-3 sentences with specifics \
            (names, numbers, dates). If the text doesn't answer it, say so.
            """)
            let reply = try await session.respond(
                to: "Text:\n\"\"\"\n\(text)\n\"\"\"\n\nQuestion: \(question)",
                options: GenerationOptions(sampling: .greedy, maximumResponseTokens: 250)
            )
            AIRequestLog.shared.finish(id: logID, error: nil)
            return reply.content
        } catch {
            AIRequestLog.shared.finish(id: logID, error: error)
            throw error
        }
    }
}

// MARK: - Web research

enum LocalAgentResearch {
    /// Loads Google in a hidden (ghost) tab and pulls the organic result links.
    static func googleResultURLs(query: String) async throws -> [URL] {
        var components = URLComponents()
        components.scheme = "https"
        components.host = "www.google.com"
        components.path = "/search"
        components.queryItems = [URLQueryItem(name: "q", value: query)]
        guard let url = components.url else { return [] }

        let host = BrowserJSLiveHost.shared
        let tabID = try await host.tabsOpenGhost(url: url.absoluteString, windowId: nil)
        defer { Task { try? await host.tabsClose(id: tabID) } }
        let js = """
        (() => {
            const links = [...document.querySelectorAll('#search a[href^="http"]')]
                .filter(a => a.querySelector('h3'))
                .map(a => a.href)
                .filter(h => !/^https?:\\/\\/([^/]+\\.)?google\\./.test(h));
            return links.length ? [...new Set(links)].slice(0, 6) : null;
        })()
        """
        let result = try await host.pageWaitFor(id: tabID, predicateJs: js, timeoutMs: 10_000)
        return (result as? [String] ?? []).compactMap(URL.init(string:))
    }

    struct Excerpt {
        var url: URL
        var text: String
    }

    /// Fetches `urls` in parallel and returns the first `count` that yield
    /// readable text, each trimmed to the `limit` chars most relevant to `question`.
    static func fetchExcerpts(urls: [URL], question: String, count: Int, limit: Int) async -> [Excerpt] {
        let fetched = await withTaskGroup(of: (Int, Excerpt?).self) { group in
            for (i, url) in urls.enumerated() {
                group.addTask {
                    guard let text = try? await fetchText(url), text.count > 200 else { return (i, nil) }
                    return (i, Excerpt(url: url, text: LocalAgentText.excerpt(text, question: question, limit: limit)))
                }
            }
            var out = [(Int, Excerpt)]()
            for await (i, excerpt) in group { if let excerpt { out.append((i, excerpt)) } }
            return out
        }
        // Keep Google's ranking.
        return fetched.sorted { $0.0 < $1.0 }.prefix(count).map(\.1)
    }

    private static func fetchText(_ url: URL) async throws -> String {
        var request = URLRequest(url: url, timeoutInterval: 6)
        request.setValue("Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/18.0 Safari/605.1.15", forHTTPHeaderField: "User-Agent")
        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse, http.statusCode < 400,
              http.mimeType?.contains("html") ?? true else { return "" }
        return LocalAgentText.readableText(html: String(decoding: data, as: UTF8.self))
    }
}

// MARK: - Context

@MainActor
enum LocalAgentContext {
    /// The page the agent acts on: the pane its chat is split with, else the
    /// page it was asked from, else what's focused in its window.
    static func targetPaneID(key: String) -> ID<WebContent>? {
        targetPane(key: key)?.id
    }

    private static func targetPane(key: String) -> Pane? {
        let state = BrowserStore.shared.model
        guard let own = state.agentChatPane(forKey: key) else { return nil }
        if let sibling = state.splitSibling(ofPane: own) { return sibling }
        if let source = AgentChatSession.session(forKey: key).sourcePaneID,
           let pane = state.pane(forId: source), isWebPage(pane) {
            return pane
        }
        if let window = state.windowContaining(webContentId: own),
           let current = state.currentPane(forWindow: window.id),
           current.id != own, isWebPage(current) {
            return current
        }
        return nil
    }

    private static func isWebPage(_ pane: Pane) -> Bool {
        guard let url = pane.info.url else { return false }
        return NativePageKey(url: url) == nil && !url.absoluteString.hasPrefix("about:")
    }

    /// One line prefixed to each user message, e.g.
    /// `[Sat, Sep 26, 2026 at 2:03 PM | User's page: "Title" (example.com)]`.
    static func ambient(key: String) -> String {
        var parts = [Date().formatted(.dateTime.weekday(.abbreviated).month(.abbreviated).day().year().hour().minute())]
        if let pane = targetPane(key: key), let url = pane.info.url {
            let title = String((pane.info.title ?? "").prefix(80))
            parts.append("User's page: \"\(title)\" (\(url.host ?? url.absoluteString))")
        } else {
            parts.append("No page open")
        }
        return "[" + parts.joined(separator: " | ") + "]"
    }
}

// MARK: - Text

enum LocalAgentText {
    static func json(_ object: [String: String]) -> String {
        (try? JSONSerialization.data(withJSONObject: object)).map { String(decoding: $0, as: UTF8.self) } ?? "{}"
    }

    static func normalizedURL(_ raw: String) -> URL? {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.contains(" "), trimmed.contains(".") || trimmed.contains("://") else { return nil }
        let withScheme = trimmed.contains("://") ? trimmed : "https://" + trimmed
        guard let url = URL(string: withScheme), url.host != nil else { return nil }
        return url
    }

    /// HTML → plain text, one block per line, minus page chrome.
    static func readableText(html: String) -> String {
        var html = html
        for tag in ["nav", "header", "footer", "aside", "svg", "form", "button", "select"] {
            html = html.replacingOccurrences(of: "<\(tag)\\b[^>]*>[\\s\\S]*?</\(tag)>", with: "", options: [.regularExpression, .caseInsensitive])
        }
        html = html.replacingOccurrences(of: "<(br|/p|/div|/li|/h[1-6]|/tr|/section|/article)\\b[^>]*>", with: "\n", options: [.regularExpression, .caseInsensitive])
        return BrowserJSLiveHost.htmlToMarkdown(html)
            .replacingOccurrences(of: "&#39;", with: "'")
            .replacingOccurrences(of: "&#x27;", with: "'")
    }

    /// The paragraphs of `text` most relevant to `question` (by keyword
    /// overlap), in page order, up to `limit` characters.
    static func excerpt(_ text: String, question: String, limit: Int) -> String {
        var paragraphs: [String] = []
        for line in text.components(separatedBy: .newlines) {
            let p = line.split(whereSeparator: \.isWhitespace).joined(separator: " ")
            guard p.count >= 3 else { continue }
            paragraphs.append(p.count > 600 ? String(p.prefix(600)) + "…" : p)
        }
        let all = paragraphs.joined(separator: "\n")
        if all.count <= limit { return all }

        let keywords = Set(words(question).filter { $0.count >= 3 && !stopWords.contains($0) })
        // Prefer keyword hits, then real prose over short nav-ish lines, then earlier text.
        var scored: [(index: Int, score: Double)] = []
        for (i, p) in paragraphs.enumerated() {
            let hits = Double(Set(words(p)).intersection(keywords).count)
            let prose = min(Double(p.count), 300) / 300
            scored.append((i, hits * 2 + prose - Double(i) * 0.001))
        }
        var chosen = Set<Int>()
        var used = 0
        for item in scored.sorted(by: { $0.score > $1.score }) {
            let size = paragraphs[item.index].count + 1
            guard used + size <= limit else { continue }
            chosen.insert(item.index)
            used += size
        }
        return chosen.sorted().map { paragraphs[$0] }.joined(separator: "\n")
    }

    private static func words(_ s: String) -> [String] {
        s.lowercased().split(whereSeparator: { !$0.isLetter && !$0.isNumber }).map(String.init)
    }

    private static let stopWords: Set<String> = [
        "the", "and", "for", "are", "was", "what", "when", "where", "who", "why", "how",
        "does", "did", "this", "that", "with", "from", "about", "which", "can", "you", "its", "is",
    ]
}
