import Foundation

public enum DefaultsKeys: String {
    case adblock // bool
    case autoDarkMode
    case topbarLocked // bool
    case animateNewTabs // bool
    case preserveWindowsAcrossRestarts // bool
    case autoOrganizeTabs // bool
    case autoArchiveTabs
    case lastAutoArchiveDate // Date
    
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
    
    func dateValue() -> Date? {
        return UserDefaults.standard.object(forKey: rawValue) as? Date
    }
    
    func setDate(_ date: Date) {
        UserDefaults.standard.set(date, forKey: rawValue)
    }
    
    func setBool(_ value: Bool) {
        UserDefaults.standard.set(value, forKey: rawValue)
    }
    
    func setString(_ value: String) {
        UserDefaults.standard.set(value, forKey: rawValue)
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
