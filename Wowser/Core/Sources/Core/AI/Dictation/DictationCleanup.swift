import Foundation
import ChatToys

// Optional AI pass over dictated text: removes filler words and fixes likely transcription
// errors, using the target field's contents and page context. Streams the cleaned text back
// so it can be inserted into the field as it's generated.
enum DictationCleanup {
    // Yields deltas (new characters only) of the cleaned-up text
    static func cleanedTextStream(rawTranscript: String, fieldValue: String, pageText: String, pageTitle: String?, url: URL?) throws -> AsyncThrowingStream<String, Error> {
        let llm = try LLMs.currentOrThrow(json: false)

        var contextLines = [String]()
        if let pageTitle, !pageTitle.isEmpty {
            contextLines.append("Page title: \(pageTitle)")
        }
        if let url {
            contextLines.append("Page URL: \(url.absoluteString)")
        }
        if !fieldValue.isEmpty {
            contextLines.append("Current contents of the text field (your text will be inserted at the cursor):\n\(fieldValue)")
        }
        if !pageText.isEmpty {
            contextLines.append("Beginning of the page's text, for context:\n\(pageText)")
        }

        let systemPrompt = """
        The user dictated text into a text field in their web browser using speech recognition, which is unreliable. Clean up the transcription:
        - Remove filler words (um, uh, like) and false starts.
        - Fix anything that clearly looks like a transcription error or typo, using the page context to infer intended words.
        - Add sensible punctuation and capitalization.
        - Do NOT deviate far from what the user said; do not add, embellish, or reorder content.
        Respond with ONLY the cleaned-up text, no quotes or commentary.
        """

        let userPrompt = (contextLines.isEmpty ? "" : contextLines.joined(separator: "\n\n") + "\n\n") + "Dictated text:\n\(rawTranscript)"

        let messages = [
            LLMMessage(role: .system, content: systemPrompt),
            LLMMessage(role: .user, content: userPrompt),
        ]

        return AsyncThrowingStream { continuation in
            let task = Task {
                var emitted = ""
                do {
                    for try await partial in llm.completeStreaming(prompt: messages) {
                        let content = partial.content
                        // Partials are cumulative; only emit what's new
                        if content.hasPrefix(emitted), content.count > emitted.count {
                            let delta = String(content.dropFirst(emitted.count))
                            emitted = content
                            continuation.yield(delta)
                        } else if !content.hasPrefix(emitted) {
                            // Content changed unexpectedly; emit the whole remainder at the end instead
                        }
                    }
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { _ in
                task.cancel()
            }
        }
    }
}
