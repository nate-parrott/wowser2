import Foundation
import FoundationModels
import ChatToys

// "Micro AI": small one-shot model calls the browser makes on its own
// (picking a space for a link, naming tab groups, ...), as opposed to agents.
// Each feature picks its backend in Settings → AI:
//   - onDevice:   Apple's on-device model (FoundationModels), guided generation
//   - openRouter: the cloud model configured under Settings → AI (`LLMs.current`)
//   - agent:      a throwaway Claude Code session in a hidden working directory
// Structured outputs are `@Generable` types: on-device they drive guided
// generation; for the other backends their JSON schema goes into the prompt
// and the reply is parsed back through `GeneratedContent(json:)`.

public enum MicroAIFeature: String, CaseIterable, Codable, Identifiable {
    case linkSpace
    case tabGroups
    case spaceTitle
    case spaceIcon
    case archiveTidy
    case dictationCleanup
    case searchAnswer

    public var id: String { rawValue }

    public var title: String {
        switch self {
        case .linkSpace: return "Choose space for opened links"
        case .tabGroups: return "Organize tabs into sections"
        case .spaceTitle: return "Auto-title spaces"
        case .spaceIcon: return "Space icon & color"
        case .archiveTidy: return "Tidy archived tab titles"
        case .dictationCleanup: return "Clean up dictation"
        case .searchAnswer: return "Search result summaries"
        }
    }

    public var detail: String {
        switch self {
        case .linkSpace: return "Moves links opened from other apps into the space they fit best."
        case .tabGroups: return "Groups the tabs in a space into named sections."
        case .spaceTitle: return "Names a space from the tabs in it."
        case .spaceIcon: return "Picks an emoji and color from the space's name."
        case .archiveTidy: return "Shortens titles and picks a category for archived tabs."
        case .dictationCleanup: return "Removes filler words from text dictated into pages."
        case .searchAnswer: return "Summarizes top search results on the search page."
        }
    }
}

public enum MicroAIBackend: String, CaseIterable, Codable {
    case onDevice
    case openRouter
    case agent

    public var title: String {
        switch self {
        case .onDevice: return "On device"
        case .openRouter: return "OpenRouter"
        case .agent: return "Agent"
        }
    }
}

public enum MicroAIError: LocalizedError {
    case unavailable(MicroAIBackend)
    case noJSON(String)

    public var errorDescription: String? {
        switch self {
        case .unavailable(let b): return "\(b.title) model is not available"
        case .noJSON(let text): return "Model reply had no JSON: \(text.prefix(200))"
        }
    }
}

/// A prompt split the way every backend wants it: standing instructions
/// (system prompt) plus the per-call input.
struct MicroAIPrompt {
    var instructions: String
    var input: String
}

enum MicroAI {
    // MARK: Settings

    static func backend(for feature: MicroAIFeature) -> MicroAIBackend {
        storedBackends()[feature] ?? defaultBackend
    }

    static func setBackend(_ backend: MicroAIBackend, for feature: MicroAIFeature) {
        var all = storedBackends()
        all[feature] = backend
        let raw = Dictionary(uniqueKeysWithValues: all.map { ($0.key.rawValue, $0.value.rawValue) })
        if let data = try? JSONEncoder().encode(raw) {
            DefaultsKeys.microAIBackends.setString(String(decoding: data, as: UTF8.self))
        }
    }

    static var defaultBackend: MicroAIBackend {
        onDeviceAvailable ? .onDevice : .openRouter
    }

    private static func storedBackends() -> [MicroAIFeature: MicroAIBackend] {
        guard let json = DefaultsKeys.microAIBackends.stringValue().nilIfEmpty,
              let raw = try? JSONDecoder().decode([String: String].self, from: Data(json.utf8)) else { return [:] }
        var out = [MicroAIFeature: MicroAIBackend]()
        for (k, v) in raw {
            if let f = MicroAIFeature(rawValue: k), let b = MicroAIBackend(rawValue: v) { out[f] = b }
        }
        return out
    }

    static var onDeviceAvailable: Bool {
        SystemLanguageModel.default.isAvailable
    }

    /// Cheap check for whether `feature`'s backend can run at all right now.
    static func isAvailable(_ feature: MicroAIFeature) -> Bool {
        switch backend(for: feature) {
        case .onDevice: return onDeviceAvailable
        case .openRouter: return LLMs.current(json: true) != nil
        case .agent: return BrowserAgentManager.platformDefaultProvider()?.isAvailable == true
        }
    }

    // MARK: Structured generation

    static func generate<T: Generable>(_ feature: MicroAIFeature, _ prompt: MicroAIPrompt, as type: T.Type, backend: MicroAIBackend? = nil) async throws -> T {
        try T(await generate(feature, prompt, schema: T.generationSchema, backend: backend))
    }

    /// Structured generation against a schema built at runtime (e.g. a field
    /// constrained to the user's actual space names).
    static func generate(_ feature: MicroAIFeature, _ prompt: MicroAIPrompt, schema: GenerationSchema, backend: MicroAIBackend? = nil) async throws -> GeneratedContent {
        let backend = backend ?? self.backend(for: feature)
        let logID = AIRequestLog.shared.begin(modelName: "\(backend.title) - \(feature.title)")
        do {
            let result: GeneratedContent
            switch backend {
            case .onDevice:
                let session = try onDeviceSession(instructions: prompt.instructions)
                result = try await session.respond(to: prompt.input, schema: schema, includeSchemaInPrompt: true, options: onDeviceOptions).content
            case .openRouter:
                let llm = try LLMs.currentOrThrow(json: true)
                let reply = try await llm.complete(prompt: [
                    LLMMessage(role: .system, content: prompt.instructions + "\n\n" + jsonInstructions(for: schema)),
                    LLMMessage(role: .user, content: prompt.input),
                ])
                result = try parse(reply.content)
            case .agent:
                let text = try await runAgent(system: prompt.instructions + "\n\n" + jsonInstructions(for: schema), input: prompt.input)
                result = try parse(text)
            }
            AIRequestLog.shared.finish(id: logID, error: nil)
            return result
        } catch {
            AIRequestLog.shared.finish(id: logID, error: error)
            throw error
        }
    }

    // MARK: Text generation

    /// Yields the reply cumulatively (each element is the full text so far).
    static func streamText(_ feature: MicroAIFeature, _ prompt: MicroAIPrompt, backend: MicroAIBackend? = nil) -> AsyncThrowingStream<String, Error> {
        let backend = backend ?? self.backend(for: feature)
        return AsyncThrowingStream { continuation in
            let task = Task {
                let logID = AIRequestLog.shared.begin(modelName: "\(backend.title) - \(feature.title)")
                do {
                    switch backend {
                    case .onDevice:
                        let session = try onDeviceSession(instructions: prompt.instructions)
                        for try await snapshot in session.streamResponse(to: prompt.input, options: onDeviceOptions) {
                            continuation.yield(snapshot.content)
                        }
                    case .openRouter:
                        let llm = try LLMs.currentOrThrow(json: false)
                        for try await partial in llm.completeStreaming(prompt: [
                            LLMMessage(role: .system, content: prompt.instructions),
                            LLMMessage(role: .user, content: prompt.input),
                        ]) {
                            continuation.yield(partial.content)
                        }
                    case .agent:
                        continuation.yield(try await runAgent(system: prompt.instructions, input: prompt.input))
                    }
                    AIRequestLog.shared.finish(id: logID, error: nil)
                    continuation.finish()
                } catch {
                    AIRequestLog.shared.finish(id: logID, error: error)
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    // MARK: Backends

    private static let onDeviceOptions = GenerationOptions(sampling: .greedy)

    private static func onDeviceSession(instructions: String) throws -> LanguageModelSession {
        guard onDeviceAvailable else { throw MicroAIError.unavailable(.onDevice) }
        return LanguageModelSession(model: .default, instructions: instructions)
    }

    /// Model the agent backend uses. Small tasks, so the fast model.
    static let agentModel = "haiku"

    /// Hidden directory agent-backed calls run in, so a session never sees
    /// (or writes into) anything real.
    static let agentWorkingDirectory: URL = {
        let appDir = "WowserDataStores-\(isProd() ? "prod" : "dev")"
        return FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
            .appendingPathComponent(appDir)
            .appendingPathComponent(Bundle.main.bundleIdentifier ?? "Unknown")
            .appendingPathComponent(".micro-ai-agent")
    }()

    private static func runAgent(system: String, input: String) async throws -> String {
        guard let provider = BrowserAgentManager.platformDefaultProvider(), provider.isAvailable else {
            throw MicroAIError.unavailable(.agent)
        }
        try FileManager.default.createDirectory(at: agentWorkingDirectory, withIntermediateDirectories: true)
        let agent = provider.makeAgent(AgentSpec(
            model: agentModel,
            effort: "low",
            systemPrompt: system,
            workingDirectory: agentWorkingDirectory
        ))
        do {
            let result = try await agent.send(AgentUserMessage(text: input))
            await agent.shutdown()
            if result.isError { throw AgentSDKError.turnFailed(result.text) }
            return result.text
        } catch {
            await agent.shutdown()
            throw error
        }
    }

    // MARK: JSON plumbing (non-on-device backends)

    static func jsonInstructions(for schema: GenerationSchema) -> String {
        let json = (try? JSONEncoder().encode(schema)).map { String(decoding: $0, as: UTF8.self) } ?? "{}"
        return "Respond with ONLY a JSON object (no prose, no code fence) matching this JSON schema. Fill fields in the order given by x-order:\n\(json)"
    }

    /// Parses the first `{...}` object in a model reply.
    static func parse(_ text: String) throws -> GeneratedContent {
        guard let start = text.firstIndex(of: "{"), let end = text.lastIndex(of: "}"), start < end else {
            throw MicroAIError.noJSON(text)
        }
        return try GeneratedContent(json: String(text[start...end]))
    }
}
