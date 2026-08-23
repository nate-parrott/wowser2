import ChatToys

public enum LLMChoice: String, Equatable, Codable, CaseIterable {
    // Uses OpenAI API client w/ openrouter url
    case openrouter_gpt_5_4_nano // openai/gpt-5.4-nano
    case openrouter_gemini_2_flash // google/gemini-2.0-flash-001
    case openrouter_gpt_4o // openai/gpt-4o
    case openrouter_gpt_4o_mini // openai/gpt-4o-mini
    case openrouter_llama_33_70b // meta-llama/llama-3.3-70b-instruct
    case openrouter_haiku_35 // anthropic/claude-3.5-haiku
    case openrouter_custom

    // Uses OpenAI API client
    case openai_gpt_5_4_nano // gpt-5.4-nano-2026-03-17
    case openai_gpt4o_mini // gpt-4o-mini
    case openai_gpt4o // gpt-4o
    case openai_custom
    
    // Uses OpenAI API client w/ Ollama local url
    case ollama_gemma_3_1b // gemma3:1b
    case ollama_gemma_3_4b // gemma3:4b
    case ollama_gemma_3_4b_qat // gemma3:4b:qat
    case ollama_gemma_3_12b // gemma3:12b
    case ollama_custom
    
    case anthropic_haiku_35 // anthropic/claude-3.5-haiku
    case anthropic_custom
}

public extension LLMChoice {
    var displayName: String {
        switch self {
        case .openrouter_gpt_5_4_nano: return "OpenRouter - GPT-5.4 Nano"
        case .openrouter_gemini_2_flash: return "OpenRouter - Gemini 2 Flash"
        case .openrouter_gpt_4o: return "OpenRouter - GPT-4o"
        case .openrouter_gpt_4o_mini: return "OpenRouter - GPT-4o Mini"
        case .openrouter_llama_33_70b: return "OpenRouter - Llama 3.3 70B"
        case .openrouter_haiku_35: return "OpenRouter - Claude 3.5 Haiku"
        case .openrouter_custom: return "OpenRouter - Custom"

        case .openai_gpt_5_4_nano: return "OpenAI - GPT-5.4 Nano"
        case .openai_gpt4o_mini: return "OpenAI - GPT-4o Mini"
        case .openai_gpt4o: return "OpenAI - GPT-4o"
        case .openai_custom: return "OpenAI - Custom"

        case .ollama_gemma_3_1b: return "Ollama - Gemma 3 1B"
        case .ollama_gemma_3_4b: return "Ollama - Gemma 3 4B"
        case .ollama_gemma_3_4b_qat: return "Ollama - Gemma 3 4B Quantized"
        case .ollama_gemma_3_12b: return "Ollama - Gemma 3 12B"
        case .ollama_custom: return "Ollama - Custom"

        case .anthropic_haiku_35: return "Anthropic - Claude 3.5 Haiku"
        case .anthropic_custom: return "Anthropic - Custom"
        }
    }
}

enum LLMs {
    static func currentOrThrow(json: Bool) throws -> any ChatLLM {
        if let cur = current(json: json) {
            return cur
        }
        throw AIError.noModelChosen
    }
    
    static func currentOrThrow_fnCalling() throws -> any FunctionCallingLLM {
        if let cur = current_fnCalling() {
            return cur
        }
        throw AIError.noModelChosen
    }
    
    static func current(json: Bool) -> (any ChatLLM)? {
        guard let choice = LLMChoice(rawValue: DefaultsKeys.llmChoice.stringValue(defaultValue: LLMChoice.openai_gpt_5_4_nano.rawValue)),
              var model = model(for: choice, json: json) else {
            return nil
        }
        if var gpt = model as? ChatGPT {
            if gpt.options.baseURL == .openRouterOpenAIChatEndpoint {
                gpt.options.requestUsageAccounting = true // OpenRouter reports tokens + cost in the final stream chunk
            }
            gpt.reportUsage = { AIRequestLog.shared.recordUsage($0) }
            model = gpt
        }
        return LoggingLLM(inner: model, modelName: modelDescription(for: choice))
    }

    private static func modelDescription(for choice: LLMChoice) -> String {
        switch choice {
        case .openrouter_custom:
            return DefaultsKeys.openrouterCustomModel.stringValue().nilIfEmpty.map { "OpenRouter - \($0)" } ?? choice.displayName
        case .openai_custom:
            return DefaultsKeys.openAICustomModel.stringValue().nilIfEmpty.map { "OpenAI - \($0)" } ?? choice.displayName
        case .ollama_custom:
            return DefaultsKeys.ollamaCustomModel.stringValue().nilIfEmpty.map { "Ollama - \($0)" } ?? choice.displayName
        case .anthropic_custom:
            return DefaultsKeys.anthropicCustomModel.stringValue().nilIfEmpty.map { "Anthropic - \($0)" } ?? choice.displayName
        default:
            return choice.displayName
        }
    }

    private static func model(for choice: LLMChoice, json: Bool) -> (any ChatLLM)? {
        switch choice {
        case .openrouter_gpt_5_4_nano:
            if let key = DefaultsKeys.openrouterKey.stringValue().nilIfEmpty {
                return ChatGPT(
                    credentials: OpenAICredentials(apiKey: key),
                    options: .init(model: .custom2(ChatGPT.Model.CustomModel(name: "openai/gpt-5.4-nano", tokenLimit: 1_000_000)), jsonMode: json, baseURL: .openRouterOpenAIChatEndpoint)
                )
            }
            return nil
        case .openai_gpt_5_4_nano:
            if let key = DefaultsKeys.openAIKey.stringValue().nilIfEmpty {
                return ChatGPT(
                    credentials: OpenAICredentials(apiKey: key),
                    options: .init(model: .custom2(ChatGPT.Model.CustomModel(name: "gpt-5.4-nano-2026-03-17", tokenLimit: 1_000_000)), jsonMode: json)
                )
            }
            return nil
        case .openrouter_gemini_2_flash:
            if let key = DefaultsKeys.openrouterKey.stringValue().nilIfEmpty {
                return ChatGPT(
                    credentials: OpenAICredentials(apiKey: key),
                    options: .init(model: .custom2(ChatGPT.Model.CustomModel(name: "google/gemini-2.0-flash-001", tokenLimit: 1_000_000)), jsonMode: json, baseURL: .openRouterOpenAIChatEndpoint)
                )
            }
            return nil
        case .openrouter_gpt_4o:
            if let key = DefaultsKeys.openrouterKey.stringValue().nilIfEmpty {
                return ChatGPT(
                    credentials: OpenAICredentials(apiKey: key),
                    options: .init(model: .custom2(ChatGPT.Model.CustomModel(name: "openai/gpt-4o", tokenLimit: 1_000_000)), jsonMode: json, baseURL: .openRouterOpenAIChatEndpoint)
                )
            }
            return nil
        case .openrouter_gpt_4o_mini:
            if let key = DefaultsKeys.openrouterKey.stringValue().nilIfEmpty {
                return ChatGPT(
                    credentials: OpenAICredentials(apiKey: key),
                    options: .init(model: .custom2(ChatGPT.Model.CustomModel(name: "openai/gpt-4o-mini", tokenLimit: 1_000_000)), jsonMode: json, baseURL: .openRouterOpenAIChatEndpoint)
                )
            }
            return nil
        case .openrouter_llama_33_70b:
            if let key = DefaultsKeys.openrouterKey.stringValue().nilIfEmpty {
                return ChatGPT(
                    credentials: OpenAICredentials(apiKey: key),
                    options: .init(model: .custom2(ChatGPT.Model.CustomModel(name: "meta-llama/llama-3.3-70b-instruct", tokenLimit: 1_000_000)), jsonMode: json, baseURL: .openRouterOpenAIChatEndpoint)
                )
            }
            return nil
        case .openrouter_haiku_35:
            if let key = DefaultsKeys.openrouterKey.stringValue().nilIfEmpty {
                return ChatGPT(
                    credentials: OpenAICredentials(apiKey: key),
                    options: .init(model: .custom2(ChatGPT.Model.CustomModel(name: "anthropic/claude-3.5-haiku", tokenLimit: 1_000_000)), jsonMode: json, baseURL: .openRouterOpenAIChatEndpoint)
                )
            }
            return nil
        case .openrouter_custom:
            if let key = DefaultsKeys.openrouterKey.stringValue().nilIfEmpty,
               let model = DefaultsKeys.openrouterCustomModel.stringValue().nilIfEmpty {
                return ChatGPT(
                    credentials: OpenAICredentials(apiKey: key),
                    options: .init(model: .custom2(ChatGPT.Model.CustomModel(name: model, tokenLimit: 1_000_000)), jsonMode: json, baseURL: .openRouterOpenAIChatEndpoint)
                )
            }
            return nil
        case .openai_gpt4o_mini:
            if let key = DefaultsKeys.openAIKey.stringValue().nilIfEmpty {
                return ChatGPT(
                    credentials: OpenAICredentials(apiKey: key),
                    options: .init(model: .gpt4o_mini, jsonMode: json)
                )
            }
            return nil
        case .openai_gpt4o:
            if let key = DefaultsKeys.openAIKey.stringValue().nilIfEmpty {
                return ChatGPT(
                    credentials: OpenAICredentials(apiKey: key),
                    options: .init(model: .gpt4_omni, jsonMode: json)
                )
            }
            return nil
        case .openai_custom:
            if let key = DefaultsKeys.openAIKey.stringValue().nilIfEmpty,
               let model = DefaultsKeys.openAICustomModel.stringValue().nilIfEmpty {
                return ChatGPT(
                    credentials: OpenAICredentials(apiKey: key),
                    options: .init(model: .custom2(ChatGPT.Model.CustomModel(name: model, tokenLimit: 1_000_000)), jsonMode: json)
                )
            }
            return nil
        case .ollama_gemma_3_1b:
            return ChatGPT(
                credentials: OpenAICredentials(apiKey: ""),
                options: .init(model: .custom2(ChatGPT.Model.CustomModel(name: "gemma3:1b", tokenLimit: 32_000)), jsonMode: json, baseURL: .ollamaOpenAIChatEndpoint)
            )
        case .ollama_gemma_3_4b:
            return ChatGPT(
                credentials: OpenAICredentials(apiKey: ""),
                options: .init(model: .custom2(ChatGPT.Model.CustomModel(name: "gemma3:4b", tokenLimit: 128_000)), jsonMode: json, baseURL: .ollamaOpenAIChatEndpoint)
            )
        case .ollama_gemma_3_4b_qat:
            return ChatGPT(
                credentials: OpenAICredentials(apiKey: ""),
                options: .init(model: .custom2(ChatGPT.Model.CustomModel(name: "gemma3:4b-it-qat", tokenLimit: 128_000)), jsonMode: json, baseURL: .ollamaOpenAIChatEndpoint)
            )
        case .ollama_gemma_3_12b:
            return ChatGPT(
                credentials: OpenAICredentials(apiKey: ""),
                options: .init(model: .custom2(ChatGPT.Model.CustomModel(name: "gemma3:12b", tokenLimit: 128_000)), jsonMode: json, baseURL: .ollamaOpenAIChatEndpoint)
            )
        case .ollama_custom:
            if let model = DefaultsKeys.ollamaCustomModel.stringValue().nilIfEmpty {
                return ChatGPT(
                    credentials: OpenAICredentials(apiKey: ""),
                    options: .init(model: .custom2(ChatGPT.Model.CustomModel(name: model, tokenLimit: 128_000)), jsonMode: json, baseURL: .ollamaOpenAIChatEndpoint)
                )
            }
            return nil
        case .anthropic_haiku_35:
            if let key = DefaultsKeys.anthropicKey.stringValue().nilIfEmpty {
                // For anthropic models on all providers, implement json mode by prefilling ```\n{
                return Claude(
                    credentials: AnthropicCredentials(apiKey: key),
                    options: .init(model: .claude3_5Haiku, responsePrefix: json ? "```\n{" : "")
                )
            }
            return nil
        case .anthropic_custom:
            if let key = DefaultsKeys.anthropicKey.stringValue().nilIfEmpty,
               let model = DefaultsKeys.anthropicCustomModel.stringValue().nilIfEmpty {
                return Claude(
                    credentials: AnthropicCredentials(apiKey: key),
                    options: .init(model: .custom(model, 128_000), responsePrefix: json ? "```\n{" : "")
                )
            }
            return nil
        }
    }
    
    static func current_fnCalling() -> (any FunctionCallingLLM)? {
        // LoggingLLM always conforms to FunctionCallingLLM, so check the wrapped model
        guard let model = self.current(json: false) as? LoggingLLM, model.inner is FunctionCallingLLM else { return nil }
        return model
    }
}

enum AIError: Error {
    case noModelChosen
}
