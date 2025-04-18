import Foundation

public enum DefaultsKeys: String {
    case adblock // bool
    case autoDarkMode
    case topbarLocked // bool
    case animateNewTabs // bool
    case preserveWindowsAcrossRestarts // bool
    case autoOrganizeTabs // bool
    case autoArchiveTabs
    
    case llmChoice // LLMChoice
    case ollamaCustomModel // string
    case openrouterCustomModel // string
    case openAICustomModel // string
    case anthropicCustomModel // string
    
    case openrouterKey
    case openAIKey
    case anthropicKey
    
    case searchEngine // SearchEngine
    case Chatbot // Chatbot
}

public extension DefaultsKeys {
    func boolValue(defaultValue def: Bool = false) -> Bool {
        return UserDefaults.standard.bool(forKey: rawValue)
    }

    func stringValue(defaultValue def: String = "") -> String {
        return UserDefaults.standard.string(forKey: rawValue) ?? def
    }
}

public enum SearchEngine: String, CaseIterable, Equatable, Hashable, Codable {
    case google
    case duckduckgo
    case kagi
}

public enum Chatbot: String, CaseIterable, Equatable, Hashable, Codable {
    case claude
    case chatgpt
    case perplexity
}
