import Foundation
import Combine

public enum DefaultsKeys: String {
    case adblock // bool
    case cookieBannerBlock // bool
    case autoDarkMode
//    case topbarLocked // bool
    case animateNewTabs // bool
    case preserveWindowsAcrossRestarts // bool
    case autoOrganizeTabs // bool
    case autoArchiveTabs
    case cleanModeForRecipes
    case lastAutoArchiveDate // Date
    
    case homepagePrompt // string
    
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
    
    case enableGoDirectQueries // bool
    case lastShownWelcomePageForPageVersion
    case searchToolbarEnabled // bool

    case mcpServerURL // string — written by MCPServer when it binds, read by SettingsView
    case mcpServerToken // string — per-launch bearer token for the local MCP server
    case hasSeenTerminalUpsell // bool — set after the user dismisses the first-time terminal upsell
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
    
    func intValue() -> Int {
        return UserDefaults.standard.integer(forKey: rawValue)
    }
    
    func setInt(_ int: Int) {
        UserDefaults.standard.setValue(int, forKey: rawValue)
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
    
    func publisher() -> AnyPublisher<Any, Never> {
        let notificationPublisher = NotificationCenter.default.publisher(
            for: UserDefaults.didChangeNotification
        ).compactMap { _ in
            UserDefaults.standard.object(forKey: self.rawValue)
        }
        
        let currentValue = Just(UserDefaults.standard.object(forKey: self.rawValue))
            .compactMap { $0 }
        
        return currentValue.append(notificationPublisher).eraseToAnyPublisher()
    }
    
    func boolPublisher(defaultVal: Bool = false) -> AnyPublisher<Bool, Never> {
        publisher().map({ $0 as? Bool ?? defaultVal }).removeDuplicates().eraseToAnyPublisher()
    }
}

public enum SearchEngine: String, CaseIterable, Equatable, Hashable, Codable {
    case google
    case duckduckgo
    case kagi
    case clean
    case images
    
    static var current: SearchEngine {
        if let k = UserDefaults.standard.value(forKey: DefaultsKeys.searchEngine.rawValue) as? String {
            return SearchEngine(rawValue: k) ?? .google
        }
        return .google
    }
    
    func urlForQuery(_ query: String) -> URL {
        switch self {
        case .google:
            return .googleSearch(query)
        case .duckduckgo:
            var components = URLComponents()
            components.scheme = "https"
            components.host = "duckduckgo.com"
            components.path = "/"
            components.queryItems = [URLQueryItem(name: "q", value: query)]
            return components.url ?? .googleSearch(query)
        case .kagi:
            var components = URLComponents()
            components.scheme = "https"
            components.host = "kagi.com"
            components.path = "/search"
            components.queryItems = [URLQueryItem(name: "q", value: query)]
            return components.url ?? .googleSearch(query)
        case .clean:
            return GeneratedPageKey.webSearch(q: query).url
        case .images:
            return GeneratedPageKey.imageSearch(q: query, page: 0).url
        }
    }
}

public enum Chatbot: String, CaseIterable, Equatable, Hashable, Codable {
    case claude
    case chatgpt
    case perplexity
}
