import ChatToys

public enum LLMChoice: String, Equatable, Codable, CaseIterable {
    // Uses OpenAI API client w/ openrouter url
    case openrouter_gemini_2_flash // google/gemini-2.0-flash-001
    case openrouter_gpt_4o // openai/gpt-4o
    case openrouter_gpt_4o_mini // openai/gpt-4o-mini
    case openrouter_llama_33_70b // meta-llama/llama-3.3-70b-instruct
    case openrouter_haiku_35 // anthropic/claude-3.5-haiku
    case openrouter_custom

    // Uses OpenAI API client
    case openai_gpt4o_mini // gpt-4o-mini
    case openai_gpt4o // gpt-4o
    case openai_custom
    
    // Uses OpenAI API client w/ Ollama local url
    case ollama_gemma_3_1b // gemma3:1b
    case ollama_gemma_3_4b // gemma3:4b
    case ollama_gemma_3_12b // gemma3:12b
    case ollama_custom
    
    case anthropic_haiku_35 // anthropic/claude-3.5-haiku
    case anthropic_custom
}

enum LLMs {
    static func currentOrThrow(json: Bool) throws -> any ChatLLM {
        if let cur = current(json: json) {
            return cur
        }
        throw AIError.noModelChosen
    }
    
    static func current(json: Bool) -> (any ChatLLM)? {
        guard let choice = LLMChoice(rawValue: DefaultsKeys.llmChoice.stringValue()) else {
            return nil
        }
        switch choice {
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
                credentials: OpenAICredentials(apiKey: "gemma3:1b"),
                options: .init(model: .custom2(ChatGPT.Model.CustomModel(name: "", tokenLimit: 1_000_000)), jsonMode: json, baseURL: .ollamaOpenAIChatEndpoint)
            )
        case .ollama_gemma_3_4b:
            return ChatGPT(
                credentials: OpenAICredentials(apiKey: "gemma3:4b"),
                options: .init(model: .custom2(ChatGPT.Model.CustomModel(name: "", tokenLimit: 1_000_000)), jsonMode: json, baseURL: .ollamaOpenAIChatEndpoint)
            )
        case .ollama_gemma_3_12b:
            return ChatGPT(
                credentials: OpenAICredentials(apiKey: "gemma3:12b"),
                options: .init(model: .custom2(ChatGPT.Model.CustomModel(name: "", tokenLimit: 1_000_000)), jsonMode: json, baseURL: .ollamaOpenAIChatEndpoint)
            )
        case .ollama_custom:
            if let model = DefaultsKeys.ollamaCustomModel.stringValue().nilIfEmpty {
                return ChatGPT(
                    credentials: OpenAICredentials(apiKey: model),
                    options: .init(model: .custom2(ChatGPT.Model.CustomModel(name: "", tokenLimit: 1_000_000)), jsonMode: json, baseURL: .ollamaOpenAIChatEndpoint)
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
}

enum AIError: Error {
    case noModelChosen
}
