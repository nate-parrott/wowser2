import Foundation

public enum DefaultsKeys: String {
    case openrouterKey
    case openAIKey
    case adblock // bool
    case autoDarkMode
}

public extension DefaultsKeys {
    func boolValue(defaultValue def: Bool = false) -> Bool {
        return UserDefaults.standard.bool(forKey: rawValue)
    }

    func stringValue(defaultValue def: String = "") -> String {
        return UserDefaults.standard.string(forKey: rawValue) ?? def
    }
}
