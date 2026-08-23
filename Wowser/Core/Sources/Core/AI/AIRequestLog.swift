import ChatToys
import Combine
import Foundation

/// The most recent LLM request made through `LLMs.current`, shown in Settings → AI.
public struct AIRequestRecord: Equatable, Codable, Identifiable {
    public var id: UUID
    public var date: Date
    public var modelName: String
    public var status: Status
    public var errorDescription: String? = nil
    public var durationSeconds: Double? = nil
    public var promptTokens: Int? = nil
    public var completionTokens: Int? = nil
    public var cachedPromptTokens: Int? = nil
    public var cost: Double? = nil // USD; only reported by OpenRouter

    public enum Status: String, Codable {
        case inFlight
        case succeeded
        case failed
    }
}

public final class AIRequestLog: ObservableObject {
    public static let shared = AIRequestLog()

    @Published public private(set) var lastRequest: AIRequestRecord?

    private init() {
        if let json = DefaultsKeys.lastAIRequest.stringValue().nilIfEmpty,
           let record = try? JSONDecoder().decode(AIRequestRecord.self, from: Data(json.utf8)) {
            lastRequest = record
        }
    }

    func begin(modelName: String) -> UUID {
        let record = AIRequestRecord(id: UUID(), date: Date(), modelName: modelName, status: .inFlight)
        update { $0 = record }
        return record.id
    }

    func finish(id: UUID, error: Error?) {
        update { record in
            // If a newer request has taken over the slot, leave it alone
            guard var cur = record, cur.id == id else { return }
            cur.status = error == nil ? .succeeded : .failed
            cur.errorDescription = error.map { "\($0)" }
            cur.durationSeconds = Date().timeIntervalSince(cur.date)
            record = cur
        }
    }

    func recordUsage(_ usage: Usage) {
        // Usage arrives via a separate callback with no request id; attach it to the latest request
        update { record in
            guard var cur = record else { return }
            cur.promptTokens = usage.prompt_tokens
            cur.completionTokens = usage.completion_tokens
            cur.cachedPromptTokens = usage.prompt_tokens_details?.cached_tokens
            cur.cost = usage.cost
            record = cur
        }
    }

    private func update(_ block: @escaping (inout AIRequestRecord?) -> Void) {
        DispatchQueue.main.async {
            block(&self.lastRequest)
            if let record = self.lastRequest, let data = try? JSONEncoder().encode(record) {
                DefaultsKeys.lastAIRequest.setString(String(data: data, encoding: .utf8) ?? "")
            }
        }
    }
}

/// Wraps a ChatLLM and reports request lifecycle (start, success/failure, duration) to `AIRequestLog`.
struct LoggingLLM: ChatLLM, FunctionCallingLLM {
    var inner: any ChatLLM
    var modelName: String

    var tokenLimit: Int { inner.tokenLimit }

    func completeStreaming(prompt: [LLMMessage]) -> AsyncThrowingStream<LLMMessage, Error> {
        logged(inner.completeStreaming(prompt: prompt))
    }

    func completeStreamingWithJsonHint(prompt: [LLMMessage]) -> AsyncThrowingStream<LLMMessage, Error> {
        logged(inner.completeStreamingWithJsonHint(prompt: prompt))
    }

    func complete(prompt: [LLMMessage], functions: [LLMFunction]) async throws -> LLMMessage {
        guard let fn = inner as? FunctionCallingLLM else { throw AIError.noModelChosen }
        let id = AIRequestLog.shared.begin(modelName: modelName)
        do {
            let result = try await fn.complete(prompt: prompt, functions: functions)
            AIRequestLog.shared.finish(id: id, error: nil)
            return result
        } catch {
            AIRequestLog.shared.finish(id: id, error: error)
            throw error
        }
    }

    func completeStreaming(prompt: [LLMMessage], functions: [LLMFunction]) -> AsyncThrowingStream<LLMMessage, Error> {
        guard let fn = inner as? FunctionCallingLLM else {
            return AsyncThrowingStream { $0.finish(throwing: AIError.noModelChosen) }
        }
        return logged(fn.completeStreaming(prompt: prompt, functions: functions))
    }

    private func logged(_ upstream: AsyncThrowingStream<LLMMessage, Error>) -> AsyncThrowingStream<LLMMessage, Error> {
        let id = AIRequestLog.shared.begin(modelName: modelName)
        return AsyncThrowingStream { continuation in
            let task = Task {
                do {
                    for try await message in upstream {
                        continuation.yield(message)
                    }
                    AIRequestLog.shared.finish(id: id, error: nil)
                    continuation.finish()
                } catch {
                    AIRequestLog.shared.finish(id: id, error: error)
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }
}
