import Foundation

public enum DefaultsKeys: String {
    case adblock // bool
    case autoDarkMode
    case topbarLocked // bool
    
    case llmChoice // LLMChoice
    case ollamaCustomModel // string
    case openrouterCustomModel // string
    case openAICustomModel // string
    case anthropicCustomModel // string
    
    case openrouterKey
    case openAIKey
    case anthropicKey
}

public extension DefaultsKeys {
    func boolValue(defaultValue def: Bool = false) -> Bool {
        return UserDefaults.standard.bool(forKey: rawValue)
    }

    func stringValue(defaultValue def: String = "") -> String {
        return UserDefaults.standard.string(forKey: rawValue) ?? def
    }
}
