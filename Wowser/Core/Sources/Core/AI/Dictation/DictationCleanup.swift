#if os(macOS)
import Foundation
import ChatToys

/// Optional LLM pass over a dictated transcript before it lands in a page's
/// text field: strips filler, fixes obvious mis-hearings, keeps the user's
/// words otherwise. Streams the cleaned text so it can be typed in as it arrives.
enum DictationCleanup {
    struct Context {
        var pageTitle: String
        var pageURL: String
        var fieldText: String
        var fieldLabel: String
        var visibleText: String
    }

    /// What's in and around the focused field, for the model's benefit.
    @MainActor
    static func captureContext(webview: WebContentWebView) async -> Context {
        let js = """
        (() => {
            let el = document.activeElement;
            for (let i = 0; i < 4 && el && el.tagName === 'IFRAME'; i++) {
                try { el = el.contentDocument && el.contentDocument.activeElement; } catch (_) { el = null; }
            }
            let fieldText = '', label = '';
            if (el) {
                if (el.tagName === 'INPUT' || el.tagName === 'TEXTAREA') fieldText = el.value || '';
                else if (el.isContentEditable) fieldText = el.innerText || '';
                label = el.getAttribute('aria-label') || el.getAttribute('placeholder') || el.getAttribute('name') || '';
                if (!label && el.id) { const l = document.querySelector('label[for="' + el.id + '"]'); if (l) label = l.innerText; }
            }
            const vh = window.innerHeight, vw = window.innerWidth;
            const parts = []; let total = 0;
            const walker = document.createTreeWalker(document.body, NodeFilter.SHOW_TEXT);
            let node;
            while ((node = walker.nextNode())) {
                const t = node.textContent.trim();
                if (!t) continue;
                const p = node.parentElement; if (!p) continue;
                const tag = p.tagName; if (tag === 'SCRIPT' || tag === 'STYLE' || tag === 'NOSCRIPT') continue;
                const r = p.getBoundingClientRect();
                if (r.width === 0 || r.height === 0 || r.bottom < 0 || r.top > vh || r.right < 0 || r.left > vw) continue;
                parts.push(t); total += t.length;
                if (total > 4000) break;
            }
            return { title: document.title, url: location.href, fieldText: fieldText.slice(-3000), label: label.slice(0, 200), visible: parts.join('\\n').slice(0, 4000) };
        })()
        """
        let dict = (try? await webview.evalReturningValue(js)) as? [String: Any] ?? [:]
        return Context(
            pageTitle: dict["title"] as? String ?? "",
            pageURL: dict["url"] as? String ?? "",
            fieldText: dict["fieldText"] as? String ?? "",
            fieldLabel: dict["label"] as? String ?? "",
            visibleText: dict["visible"] as? String ?? ""
        )
    }

    /// Yields the cleaned transcript cumulatively as it streams.
    static func stream(raw: String, context: Context, llm: any ChatLLM) -> AsyncThrowingStream<String, Error> {
        let system = """
        You clean up text that a user just DICTATED via speech recognition, so it \
        can be inserted into a text field on a web page. Rules:
        - Remove filler words and false starts ("um", "uh", "like", "you know", repeated words).
        - Fix words that are clearly mis-transcribed homophones or typos, using the page context to guess the intended word (names, product terms, etc.).
        - Add sensible punctuation and capitalization.
        - Do NOT rephrase, summarize, expand, or change the meaning. Stay as close to what the user said as possible.
        - Output ONLY the cleaned text — no quotes, no commentary, no preamble.
        """
        var user = "## Page\nTitle: \(context.pageTitle)\nURL: \(context.pageURL)\n"
        if !context.fieldLabel.isEmpty { user += "Field: \(context.fieldLabel)\n" }
        if !context.fieldText.isEmpty { user += "\n## Text already in the field (the dictation continues after it)\n\"\"\"\n\(context.fieldText)\n\"\"\"\n" }
        if !context.visibleText.isEmpty { user += "\n## Text visible on the page\n\"\"\"\n\(context.visibleText)\n\"\"\"\n" }
        user += "\n## Dictated transcript\n\"\"\"\n\(raw)\n\"\"\"\n\nCleaned text:"

        let prompt = [
            LLMMessage(role: .system, content: system),
            LLMMessage(role: .user, content: user),
        ]
        return AsyncThrowingStream { continuation in
            let task = Task {
                do {
                    for try await partial in llm.completeStreaming(prompt: prompt) {
                        continuation.yield(partial.content)
                    }
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }
}
#endif
