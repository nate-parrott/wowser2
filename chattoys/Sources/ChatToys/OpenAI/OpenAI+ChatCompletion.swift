import Foundation

public extension URL {
    static var groqOpenAIChatEndpoint: URL {
        URL(string: "https://api.groq.com/openai/v1/chat/completions")!
    }

    static var openRouterOpenAIChatEndpoint: URL {
        URL(string: "https://openrouter.ai/api/v1/chat/completions")!
    }
    
    // https://api.cerebras.ai/v1
    
    static var cerebrasOpenAIChatEndpoint: URL {
        URL(string: "https://api.cerebras.ai/v1/chat/completions")!
    }
    
    static var ollamaOpenAIChatEndpoint: URL {
        URL(string: "http://localhost:11434/v1/chat/completions")!
    }
    
    static var mistralOpenAIChatEndpoint: URL {
        // https://api.mistral.ai/v1/chat/completions
        URL(string: "https://api.mistral.ai/v1/chat/completions")!
    }
}

// This comes from the OpenRouter API, not sure if OpenAI themselves do it this way
public struct Usage: Equatable, Codable {
    public var prompt_tokens: Int
    public var completion_tokens: Int
    public var total_tokens: Int
    public var completion_tokens_details: CompletionDetails?
    // Populated by OpenRouter when usage accounting is requested (Options.requestUsageAccounting)
    public var cost: Double?
    public var prompt_tokens_details: PromptDetails?

    public struct CompletionDetails: Equatable, Codable {
        public var accepted_prediction_tokens: Int?
        public var rejected_prediction_tokens: Int?
        public var reasoning_tokens: Int?
    }

    public struct PromptDetails: Equatable, Codable {
        public var cached_tokens: Int?
        public var cache_write_tokens: Int?
    }
}

public struct ChatGPT {
    static let debug = false
    public var reportUsage: ((Usage) -> Void)?
    // Like reportUsage, but also passes the response/generation id (e.g. for OpenRouter's
    // GET /api/v1/generation?id= cost/cache introspection endpoint).
    public var reportUsageAndId: ((Usage, String?) -> Void)?
    public var prediction: String? // https://platform.openai.com/docs/guides/predicted-outputs

    public enum Model: Equatable, Codable {
        case gpt35_turbo
        case gpt35_turbo_0125
        case gpt35_turbo_16k
        case gpt4
        case gpt4_turbo_preview
        case gpt4_turbo // includes vision
        case gpt4_omni
        case gpt4o_mini
        case gpt4_32k
        case gpt4_vision_preview
        case custom(String, Int)
        case custom2(CustomModel)
        
        public struct CustomModel: Equatable, Codable {
            public var name: String
            public var tokenLimit: Int
            public var openrouter_reasoning = false
            
            public init(name: String, tokenLimit: Int, openrouter_reasoning: Bool = false) {
                self.name = name
                self.tokenLimit = tokenLimit
                self.openrouter_reasoning = openrouter_reasoning
            }
        }

        public var name: String {
            switch self {
            case .gpt35_turbo:
                return "gpt-3.5-turbo"
            case .gpt35_turbo_16k:
                return "gpt-3.5-turbo-16k"
            case .gpt35_turbo_0125:
                return "gpt-3.5-turbo-0125"
            case .gpt4_omni:
                return "gpt-4o"
            case .gpt4o_mini:
                return "gpt-4o-mini"
            case .custom(let string, _):
                return string
            case .gpt4:
                return "gpt-4"
            case .gpt4_turbo: return "gpt-4-turbo"
            case .gpt4_turbo_preview: return "gpt-4-turbo-preview"
            case .gpt4_32k:
                return "gpt-4-32k"
            case .gpt4_vision_preview: return "gpt-4-vision-preview"
            case .custom2(let m): return m.name
            }
        }

        var tokenLimit: Int {
            switch self {
            case .gpt35_turbo: return 4096
            case .gpt35_turbo_16k, .gpt35_turbo_0125: return 16384
            case .gpt4: return 8192
            case .gpt4_32k: return 32768
            case .gpt4_turbo_preview, .gpt4_turbo, .gpt4_vision_preview, .gpt4_omni, .gpt4o_mini: return 128_000
            case .custom(_, let limit): return limit
            case .custom2(let m): return m.tokenLimit
            }
        }
        
        var openRouter_reasoning: Bool {
            switch self {
            case .custom2(let m): return m.openrouter_reasoning
            default: return false
            }
        }
    }

    public struct Options: Equatable, Codable {
        public var temperature: Double
        public var max_tokens: Int?
        public var model: Model
        public var stop: [String]
        public var printToConsole: Bool

        // `printCost` disables streaming and prints cost to the console
        public var printCost: Bool
        public var jsonMode: Bool
        public var baseURL: URL // Use to call OpenAI-compatible models that are not actually OpenAI's
        public var supressJsonMode: Bool // default false; set true on models that don't support it like gpt-4o-audio-preview
        public var headers: [String: String]? // Additional HTTP headers to send with requests
        public var openRouterOptions: OpenRouterOptions?
        public var reasoningEffort: String?
        // OpenRouter unified reasoning config (https://openrouter.ai/docs — reasoning tokens).
        // Preferred over reasoningEffort/include_reasoning for OpenRouter; works across providers
        // (maps to Anthropic thinking budgets, OpenAI effort, Gemini thinkingBudget).
        public var reasoning: ReasoningConfig?

        public struct ReasoningConfig: Equatable, Codable {
            public var effort: String?    // "xhigh" | "high" | "medium" | "low" | "minimal" | "none"
            public var maxTokens: Int?    // provider thinking budget; min 1024 for Anthropic; takes precedence over effort on Anthropic
            public var enabled: Bool?     // set false to explicitly disable reasoning
            public var exclude: Bool?     // reason internally but omit reasoning from the response

            public init(effort: String? = nil, maxTokens: Int? = nil, enabled: Bool? = nil, exclude: Bool? = nil) {
                self.effort = effort
                self.maxTokens = maxTokens
                self.enabled = enabled
                self.exclude = exclude
            }
        }
        // When true, attaches Anthropic-style `cache_control` breakpoints (system message + last two
        // non-system messages) so prompt caching works for Anthropic models via OpenRouter.
        public var autoCacheBreakpoints: Bool = false
        // When true, asks OpenRouter for usage accounting in the final stream chunk
        // (tokens, cached tokens, cost). Delivered via reportUsage/reportUsageAndId.
        public var requestUsageAccounting: Bool = false
        
        public struct OpenRouterOptions: Equatable, Codable {
            public enum ProviderSort: String, Equatable, Codable {
                case price
                case throughput 
                case latency
            }
            
            public var sort: ProviderSort?
            
            public init(sort: ProviderSort? = nil) {
                self.sort = sort
            }
        }
        
        public init(temp: Double = 0, model: Model = .gpt35_turbo, maxTokens: Int? = nil, stop: [String] = [], printToConsole: Bool = false, printCost: Bool = false, jsonMode: Bool = false, baseURL: URL = URL(string: "https://api.openai.com/v1/chat/completions")!, supressJsonMode: Bool = false, headers: [String: String]? = nil, openRouterOptions: OpenRouterOptions? = nil, reasoningEffort: String? = nil) {
            self.temperature = temp
            self.model = model
            self.max_tokens = maxTokens
            self.stop = stop
            self.printToConsole = printToConsole
            self.printCost = printCost
            self.jsonMode = jsonMode
            self.baseURL = baseURL
            self.supressJsonMode = supressJsonMode
            self.headers = headers
            self.openRouterOptions = openRouterOptions
            self.reasoningEffort = reasoningEffort
        }
    }

    public var credentials: OpenAICredentials
    public var options: Options

    public init(credentials: OpenAICredentials, options: Options = Options()) {
        self.credentials = credentials
        self.options = options
    }
}

extension ChatGPT: ChatLLM {
    struct Message: Equatable, Codable, Hashable {
       enum Role: String, Equatable, Codable, Hashable {
           case system
           case user
           case assistant
           case tool
       }

        struct Content: Equatable, Codable, Hashable {
            enum ContentType: String, Equatable, Codable, Hashable {
                case text = "text"
                case imageURL = "image_url"
                case audio = "input_audio"
            }
            struct CacheControl: Equatable, Codable, Hashable {
                var type = "ephemeral"
            }
            struct ImageURL: Equatable, Codable, Hashable {
                var url: String
                var detail: LLMMessage.Image.Detail?
            }
            struct InputAudio: Equatable, Codable, Hashable {
                enum AudioFormat: String, Equatable, Codable {
                    case wav
                    case mp3
                }

                var format: AudioFormat
                var data: String // base64-encoded
            }

            var type: ContentType
            var text: String?
            var image_url: ImageURL?
            var input_audio: InputAudio?
            // Anthropic-style prompt-caching breakpoint (passed through by OpenRouter)
            var cache_control: CacheControl?

            static func text(_ str: String) -> Content {
                .init(type: .text, text: str)
            }

            static func image(url: String, detail: LLMMessage.Image.Detail) -> Content {
                .init(type: .imageURL, image_url: .init(url: url, detail: detail))
            }

            static func audioData(format: InputAudio.AudioFormat, data: Data) -> Content {
                .init(type: .audio, input_audio: .init(format: format, data: data.base64EncodedString()))
            }
        }

        var role: Role
        var content: [Content] // Decode either a string or an array. When encoding, encode as string if possible.

        // For role=tool
        var tool_call_id: String? // For function call responses (role=tool)
        
//        var prefix: Bool? // for role=assistant on MISTRAL ONLY

        // For role=assistant
        struct ToolCall: Equatable, Codable, Hashable {
            var id: String
            var type: String // 'function'
            var function: LLMMessage.FunctionCall

            // Strict providers (e.g. Cerebras) reject extra fields and non-JSON arguments, so:
            // never encode function.id (the id lives at the tool_call level), and encode empty
            // arguments as '{}'.
            private enum CodingKeys: String, CodingKey { case id, type, function }
            private struct WireFunction: Codable {
                var name: String
                var arguments: String
            }

            func encode(to encoder: Encoder) throws {
                var container = encoder.container(keyedBy: CodingKeys.self)
                try container.encode(id, forKey: .id)
                try container.encode(type, forKey: .type)
                let args = function.arguments.trimmingCharacters(in: .whitespacesAndNewlines)
                try container.encode(WireFunction(name: function.name, arguments: args.isEmpty ? "{}" : function.arguments), forKey: .function)
            }

            init(id: String, type: String, function: LLMMessage.FunctionCall) {
                self.id = id
                self.type = type
                self.function = function
            }

            init(from decoder: Decoder) throws {
                let container = try decoder.container(keyedBy: CodingKeys.self)
                id = try container.decode(String.self, forKey: .id)
                type = try container.decode(String.self, forKey: .type)
                let wire = try container.decode(WireFunction.self, forKey: .function)
                function = LLMMessage.FunctionCall(id: nil, name: wire.name, arguments: wire.arguments)
            }
        }
        var tool_calls: [ToolCall]?
        var reasoning: String?
        // Structured reasoning blocks (OpenRouter). Must be sent back unmodified on assistant
        // messages when continuing a tool-call conversation with reasoning enabled (Anthropic).
        var reasoning_details: [LLMMessage.ReasoningDetail]?

        init(assistantWithContent content: [Content], toolCalls: [ToolCall] = []) {
            self.role = .assistant
            self.content = content
            self.tool_calls = toolCalls
        }

        init(userWithContent content: [Content]) {
            self.role = .user
            self.content = content
        }

        init(systemWithContent content: [Content]) {
            self.role = .system
            self.content = content
        }

        init(functionResponse: String, toolCallId: String) {
            self.role = .tool
            self.tool_call_id = toolCallId
            self.content = [.text(functionResponse)]
        }

        var contentAsText: String {
            content.compactMap { $0.text }.joined()
        }

        // MARK: - Encoding/Decoding

        enum CodingKeys: String, CodingKey {
            case role
            case content
            case tool_call_id // For tool responses (role=tool)
            case tool_calls // For role=assistant
            case reasoning_details // For role=assistant
        }

        init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            role = try container.decode(Role.self, forKey: .role)
            if let contentStr = try? container.decode(String.self, forKey: .content) {
                self.content = [.text(contentStr)]
            } else if let contentArray = try? container.decode([Content].self, forKey: .content) {
                self.content = contentArray
            } else {
                self.content = []
            }
            tool_call_id = try container.decodeIfPresent(String.self, forKey: .tool_call_id)
            tool_calls = try container.decodeIfPresent([ToolCall].self, forKey: .tool_calls)
            reasoning_details = try? container.decodeIfPresent([LLMMessage.ReasoningDetail].self, forKey: .reasoning_details)
        }

        func encode(to encoder: Encoder) throws {
            var container = encoder.container(keyedBy: CodingKeys.self)
            try container.encode(role, forKey: .role)
            if content.count == 1, let text = content.first?.text, content.first?.cache_control == nil {
                try container.encode(text, forKey: .content)
            } else {
                try container.encode(content, forKey: .content)
            }
            try container.encodeIfPresent(tool_call_id, forKey: .tool_call_id)
            if let tool_calls, tool_calls.count > 0 {
                try container.encodeIfPresent(tool_calls, forKey: .tool_calls)
            }
            if let reasoning_details, reasoning_details.count > 0 {
                try container.encode(reasoning_details, forKey: .reasoning_details)
            }
        }
   }

   struct ChatCompletionRequest: Encodable {
       var messages: [Message]
       var model: String
       var temperature: Double = 0.2
       var stream = true
       var stop: [String]?
       var tools: [Tool]?
       var response_format: ResponseFormat?
       var max_tokens: Int?
       var logprobs: Bool?
       var n: Int?
       var prediction: Prediction?
       var provider: Provider?
       var include_reasoning: Bool?
       var reasoning_effort: String?
       var reasoning: Reasoning?
       var usage: UsageInclude?

       struct UsageInclude: Encodable {
           var include = true
       }

       struct Reasoning: Encodable {
           var effort: String?
           var max_tokens: Int?
           var enabled: Bool?
           var exclude: Bool?
       }
       
       struct Provider: Encodable {
           var sort: String?
           
           init(sort: Options.OpenRouterOptions.ProviderSort?) {
               self.sort = sort?.rawValue
           }
       }

       struct ResponseFormat: Codable {
           var type: String  = "text"
       }

       struct Tool: Encodable {
           var type: String // 'function'
           var function: LLMFunction
       }

       struct Prediction: Codable {
           var type = "content"
           var content: String
       }
   }

    fileprivate struct ChatCompletionStreamingResponse: Codable {
        struct Choice: Codable {
            struct MessageDelta: Codable {
                /*
                 Examples of tool call deltas:
                 {"id":"chatcmpl-9ljKmkEpJQVVVC8nCUJdlwfIRnaAg","object":"chat.completion.chunk","created":1721162708,"model":"gpt-4o-2024-05-13","system_fingerprint":"fp_5e997b69d8","choices":[{"index":0,"delta":{"tool_calls":[{"index":0,"id":"call_mXsoT1VOsu4d8jYToWdUdi7L","type":"function","function":{"name":"eval","arguments":""}}]},"logprobs":null,"finish_reason":null}]}
                 {"id":"chatcmpl-9ljKmkEpJQVVVC8nCUJdlwfIRnaAg","object":"chat.completion.chunk","created":1721162708,"model":"gpt-4o-2024-05-13","system_fingerprint":"fp_5e997b69d8","choices":[{"index":0,"delta":{"tool_calls":[{"index":0,"function":{"arguments":"{\"ex"}}]},"logprobs":null,"finish_reason":null}]}
                 {"id":"chatcmpl-9ljKmkEpJQVVVC8nCUJdlwfIRnaAg","object":"chat.completion.chunk","created":1721162708,"model":"gpt-4o-2024-05-13","system_fingerprint":"fp_5e997b69d8","choices":[{"index":0,"delta":{"tool_calls":[{"index":0,"function":{"arguments":"pr\": "}}]},"logprobs":null,"finish_reason":null}]}
                 */
                var role: Message.Role?
                var content: String?
                var tool_calls: [PartialToolCall]?
                var reasoning: String?
                var reasoning_details: [LLMMessage.ReasoningDetail]?

                struct PartialToolCall: Codable {
                    var index: Int
                    var id: String?
                    var type: String?
                    var function: Function?

                    struct Function: Codable {
                        var name: String?
                        var arguments: String?
                    }
                }
            }
            var delta: MessageDelta
        }

        var id: String? // generation id
        var choices: [Choice]? // absent/empty on usage-only final chunks
        var usage: Usage?
    }

    public func completeStreaming(prompt: [LLMMessage]) -> AsyncThrowingStream<LLMMessage, Error> {
        _completeStreaming(prompt: prompt, functions: [])
    }

    public var tokenLimit: Int {
        options.model.tokenLimit
    }

    public func completeStreamingWithJsonHint(prompt: [LLMMessage]) -> AsyncThrowingStream<LLMMessage, Error> {
        var model = self
        if !model.options.supressJsonMode {
            model.options.jsonMode = true
        }
        return model.completeStreaming(prompt: prompt)
    }

    func _completeStreaming(prompt: [LLMMessage], functions: [LLMFunction]) -> AsyncThrowingStream<LLMMessage, Error> {
        // OpenRouter supports response prefill by appending an `assistant` message to the end of the request
        let responsePrefill: String = (prompt.last?.role == .assistant ? prompt.last?.content : nil) ?? ""

        // `printCost` requires not streaming the response.
        if options.printCost || ChatGPT.debug {
            return AsyncThrowingStream { cont in
                Task {
                    do {
                        let result = try await _complete(prompt: prompt, functions: functions, responsePrefill: responsePrefill)
                        cont.yield(result)
                        cont.finish()
                    } catch {
                        cont.finish(throwing: error)
                    }
                }
            }
        }

        let request: URLRequest
        do {
            request = try createChatRequest(prompt: prompt, functions: functions, stream: true)
        } catch {
            return AsyncThrowingStream.just({ throw error })
        }

        if options.printToConsole {
            print("OpenAI request:\n\((prompt.asConversationString))")
        }

       return AsyncThrowingStream { continuation in
           let src = EventSource(urlRequest: request)

           var message = Message(assistantWithContent: [.text(responsePrefill)])

           src.onComplete { statusCode, reconnect, error in
               if let statusCode, statusCode / 100 == 2 {
                   if options.printToConsole {
                       print("OpenAI response:\n\(message.contentAsText)")
                   }
                   continuation.finish()
               } else {
                   if let error {
                       continuation.yield(with: .failure(error))
                   } else if let statusCode {
                       if let body = String(data: src.errorResponseBody, encoding: .utf8), !body.isEmpty {
                           continuation.yield(with: .failure(LLMError.httpWithBody(statusCode, body)))
                       } else {
                           continuation.yield(with: .failure(LLMError.http(statusCode)))
                       }
                   } else {
                       continuation.yield(with: .failure(LLMError.unknown(nil)))
                   }
               }
           }
           src.onMessage { id, event, data in
               guard let data, data != "[DONE]" else { return }
               do {
                   let decoded = try JSONDecoder().decode(ChatCompletionStreamingResponse.self, from: Data(data.utf8))
                   if let delta = decoded.choices?.first?.delta {
                       message.role = delta.role ?? message.role
                       message.content = [.text(message.contentAsText + (delta.content ?? ""))]
                       if let r = delta.reasoning {
                           message.reasoning = (message.reasoning ?? "") + r
                       }
                       for detail in delta.reasoning_details ?? [] {
                           message.appendReasoningDetailDelta(detail)
                       }
                       // TODO: Reimplement streaming
                       for toolDelta in delta.tool_calls ?? [] {
                           if message.tool_calls == nil { message.tool_calls = [] }
                           while toolDelta.index >= message.tool_calls!.count {
                               message.tool_calls!.append(.init(id: "", type: "", function: .init(id: "", name: "", arguments: "")))
                           }
                           message.tool_calls![toolDelta.index].apply(delta: toolDelta)
//                           message.function_call = message.function_call ?? .init(name: "", arguments: "")
//                           message.function_call?.name += functionDelta.name ?? ""
//                           message.function_call?.arguments += functionDelta.arguments ?? ""
                       }
                       continuation.yield(message.asLLMMessage)
                   }
                   if let usage = decoded.usage {
                       self.reportUsage?(usage)
                       self.reportUsageAndId?(usage, decoded.id)
                   }
               } catch {
                   print("🤖 ChatGPT error: \(error)")
                   print("Response:\n\(data)")
                   // Try to parse error messages. OpenRouter sends these; not sure if others do too
                   // {"error":{"message":"More credits are required to run this request. 8192 token capacity required, 2340 available. To increase, visit https://openrouter.ai/credits and add more credits","code":402}}
                   struct ErrorMsg: Codable {
                       var error: ErrorObj
                       struct ErrorObj: Codable {
                           var message: String
                           var code: Int?
                       }
                   }
                   enum ServerError: Error {
                       case error(String)
                   }
                   if let parsedAsError = try? JSONDecoder().decode(ErrorMsg.self, from: data.data(using: .utf8)!) {
                       continuation.yield(with: .failure(ServerError.error(parsedAsError.error.message)))
                   } else {
                       // Throw original error
                       continuation.yield(with: .failure(error))
                   }
               }
           }
           src.connect()
       }
    }

    private func decodeChatStreamingResponse(jsonStr: String) -> String? {
       guard let json = try? JSONDecoder().decode(ChatCompletionStreamingResponse.self, from: Data(jsonStr.utf8)) else {
           return nil
       }
       return json.choices?.first?.delta.content
   }

    func createChatRequest(prompt: [LLMMessage], functions: [LLMFunction], stream: Bool, n: Int? = nil, logProbs: Bool = false) throws -> URLRequest {
        var messages = try prompt.flatMap { try $0.asChatGPT() }
        if options.autoCacheBreakpoints {
            messages.addCacheBreakpoints()
        }
        let cr = ChatCompletionRequest(
            messages: messages,
            model: options.model.name,
            temperature: options.temperature,
            stream: stream,
            stop: options.stop.nilIfEmptyArray,
            tools: functions.map { ChatCompletionRequest.Tool(type: "function", function: $0) }.nilIfEmptyArray,
            response_format: options.jsonMode ? .init(type: "json_object") : nil,
            max_tokens: options.max_tokens,
            logprobs: logProbs ? true : nil,
            n: n,
            prediction: prediction != nil ? .init(content: prediction!) : nil,
            provider: options.openRouterOptions?.asProviderStruct,
            include_reasoning: options.model.openRouter_reasoning ? true : nil,
            reasoning_effort: options.reasoningEffort,
            reasoning: options.reasoning.map { .init(effort: $0.effort, max_tokens: $0.maxTokens, enabled: $0.enabled, exclude: $0.exclude) },
            usage: options.requestUsageAccounting ? .init() : nil,
        )
        
//        if options.baseURL == .mistralOpenAIChatEndpoint, cr.messages.last?.role == .assistant {
//            cr.messages[cr.messages.count - 1].prefix = true
//        }

       var request = URLRequest(url: options.baseURL)
       request.httpMethod = "POST"
       request.setValue("Bearer \(credentials.apiKey)", forHTTPHeaderField: "Authorization")
       request.setValue("application/json", forHTTPHeaderField: "Content-Type")
       if let orgId = credentials.orgId {
           request.setValue(orgId, forHTTPHeaderField: "OpenAI-Organization")
       }
       if let headers = options.headers {
           for (key, value) in headers {
               request.setValue(value, forHTTPHeaderField: key)
           }
       }
       request.httpBody = try! JSONEncoder().encode(cr)
       
       // Debug logging: Generate curl command
//       if ChatGPT.debug {
//           print("🔍 ChatGPT curl command:")
//           print(request.curlDebugString)
//           print()
//       }
       
       return request
   }
}

private extension Array where Element == ChatGPT.Message {
    // Anthropic requires explicit cache breakpoints. Mark the system message plus the last two
    // non-system messages: the final breakpoint caches this request's full prefix, and the
    // second-to-last one lets the NEXT request (which extends this one) still hit the cache entry
    // written at this request's final position.
    mutating func addCacheBreakpoints() {
        func markLastBlock(at index: Int) {
            guard self[index].content.count > 0 else { return }
            self[index].content[self[index].content.count - 1].cache_control = .init()
        }
        if let sysIdx = firstIndex(where: { $0.role == .system }) {
            markLastBlock(at: sysIdx)
        }
        let nonSystem = indices.filter { self[$0].role != .system }
        for idx in nonSystem.suffix(2) {
            markLastBlock(at: idx)
        }
    }
}

extension ChatGPT.Message {
    /// Accumulate a streamed reasoning_details delta. Blocks stream incrementally: deltas sharing
    /// an `index` (or, failing that, arriving for the current last block of the same type) have
    /// their text/summary/data concatenated; other fields (signature, id, format) take the latest
    /// non-nil value so the finished block matches what the provider expects to be passed back.
    mutating func appendReasoningDetailDelta(_ delta: LLMMessage.ReasoningDetail) {
        var details = reasoning_details ?? []
        let matchIdx: Int? = {
            if let index = delta.index {
                return details.firstIndex(where: { $0.index == index })
            }
            if let last = details.indices.last, details[last].type == delta.type || delta.type == nil {
                return last
            }
            return nil
        }()
        if let i = matchIdx {
            var block = details[i]
            block.type = delta.type ?? block.type
            if delta.text != nil { block.text = (block.text ?? "") + delta.text! }
            if delta.summary != nil { block.summary = (block.summary ?? "") + delta.summary! }
            if delta.data != nil { block.data = (block.data ?? "") + delta.data! }
            block.signature = delta.signature ?? block.signature
            block.id = delta.id ?? block.id
            block.format = delta.format ?? block.format
            details[i] = block
        } else {
            details.append(delta)
        }
        reasoning_details = details
    }
}

private extension ChatGPT.Message.ToolCall {
    mutating func apply(delta: ChatGPT.ChatCompletionStreamingResponse.Choice.MessageDelta.PartialToolCall) {
        if let id = delta.id {
            self.id += id
        }
        if let type = delta.type {
            self.type += type
        }
        if let fn = delta.function {
            self.function.name += fn.name ?? ""
            self.function.arguments += fn.arguments ?? ""
        }
//        message.function_call = message.function_call ?? .init(name: "", arguments: "")
//        message.function_call?.name += functionDelta.name ?? ""
//        message.function_call?.arguments += functionDelta.arguments ?? ""
    }
}

private enum ChatGPTError: Error {
    case unsupportedInputAudioFormat(String)
}

private extension LLMMessage {
    func asChatGPT() throws -> [ChatGPT.Message] {
        var content = [ChatGPT.Message.Content]()
        for image in images {
            content.append(.image(url: image.url.absoluteString, detail: image.detail ?? .auto))
        }
        for audio in inputAudio {
            if let format = audio.format.asChatGPT {
                content.append(.audioData(format: format, data: audio.data))
            } else {
                throw ChatGPTError.unsupportedInputAudioFormat(audio.format.rawValue)
            }
        }
        if content.count == 0 || self.content.nilIfEmpty != nil {
            content.append(.text(self.content))
        }

        switch role {
        case .function:
            return functionResponses.map { resp in
                return .init(functionResponse: resp.text, toolCallId: resp.id ?? "no_id")
            }
        case .assistant:
            let toolCalls = self.functionCalls.map { ChatGPT.Message.ToolCall(id: $0.id ?? "no_id", type: "function", function: $0) }
            var msg = ChatGPT.Message(assistantWithContent: content, toolCalls: toolCalls)
            msg.reasoning_details = reasoningDetails?.nilIfEmptyArray
            return [msg]
        case .user:
            return [.init(userWithContent: content)]
        case .system:
            return [.init(systemWithContent: content)]
        }
    }
}

extension LLMMessage.Audio.AudioFormat {
    var asChatGPT: ChatGPT.Message.Content.InputAudio.AudioFormat? {
        switch self {
        case .mp3: return .mp3
        case .wav: return .wav
        }
    }
}

//private extension LLMMessage.Role {
//    var asChatGPT: ChatGPT.Message.Role {
//        switch self {
//        case .assistant: return .assistant
//        case .system: return .system
//        case .user: return .user
//        case .function: return .function
//        }
//    }
//}

extension ChatGPT.Message {
    var asLLMMessage: LLMMessage {
        switch role {
        case .assistant:
            var msg = LLMMessage(assistantMessageWithContent: contentAsText, functionCalls: (self.tool_calls ?? []).map({ call in
                return LLMMessage.FunctionCall(id: call.id, name: call.function.name, arguments: call.function.arguments)
            }), reasoning: reasoning)
            msg.reasoningDetails = reasoning_details
            return msg
        case .system:
            return LLMMessage(role: .system, content: contentAsText)
        case .user:
            return LLMMessage(role: .user, content: contentAsText) // TODO: support images in this conversion, which isn't used to actually call the api. may not be necessary, but would be nice to support.
        case .tool:
            // HACK: functionName may need to be made nil on LLMMessage.FunctionResponse
            return LLMMessage(functionResponses: [LLMMessage.FunctionResponse(id: tool_call_id ?? "no_id", functionName: "", text: contentAsText)])
        }
    }
}

//private extension ChatGPT.Message.Role {
//    var asLLMMessage: LLMMessage.Role {
//        switch self {
//        case .assistant: return .assistant
//        case .system: return .system
//        case .user: return .user
//        case .function: return .tool
//        }
//    }
//}

extension ChatGPT: FunctionCallingLLM {
    public func complete(prompt: [LLMMessage], functions: [LLMFunction]) async throws -> LLMMessage {
        try await _complete(prompt: prompt, functions: functions)
    }

    public func completeStreaming(prompt: [LLMMessage], functions: [LLMFunction]) -> AsyncThrowingStream<LLMMessage, Error> {
        _completeStreaming(prompt: prompt, functions: functions)
    }
}

extension ChatGPT.Options.OpenRouterOptions {
    var asProviderStruct: ChatGPT.ChatCompletionRequest.Provider {
        ChatGPT.ChatCompletionRequest.Provider(sort: sort)
    }
}
