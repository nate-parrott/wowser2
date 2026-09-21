import Foundation
import Combine

public enum DefaultsKeys: String {
    case adblock // bool
    case chromiumEngine // bool — new tabs use the Chromium (CEF) engine, when the build includes it (see Core/Package.swift)
    case cookieBannerBlock // bool
    case autoDarkMode
//    case topbarLocked // bool
    case animateNewTabs // bool
    case preserveWindowsAcrossRestarts // bool
    case autoOrganizeTabs // bool
    case autoArchiveTabs
    case cleanModeForRecipes
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
    
    case enableGoDirectQueries // bool
    case lastShownWelcomePageForPageVersion // int
    case searchToolbarEnabled // bool
    case hiddenTrailingToolbarItems // string — comma-separated ToolbarTrailingItem raw values hidden from the toolbar's trailing edge (right-click the trailing buttons to toggle)

    case mcpServerURL // string — written by MCPServer when it binds, read by SettingsView

    case disableNetworkProxy // bool — when true, webviews bypass the local capturing proxy entirely (no HTTP capture, no HTTPS MITM)
    
    case mcpServerTokenDev // string — per-launch bearer token for the local MCP server
    case mcpServerTokenProd
    static var mcpServerToken: DefaultsKeys {
        isProd() ? mcpServerTokenProd : mcpServerTokenDev
    }
    
    case hasSeenTerminalUpsell // bool — set after the user dismisses the first-time terminal upsell

    case spaceThemeIntensity // double 0–2 — scales the space theme's background gradient opacity (1 = default)
    case spaceBackgroundDebugView // bool — outline the space background image's blur regions + show the recompute counter

    case devModeDomains // string — JSON [domain: DevModeDomainConfig]; see DevMode.swift

    case lastAIRequest // string — JSON AIRequestRecord; see AIRequestLog.swift

    case dictationCleanup // bool — run dictated text (into web text fields) through the configured LLM before inserting
    case dictationButton // bool — experimental: show the microphone button in the toolbar (default off)

    case hideSiriAIOnTextSelection // bool (default on) — opt out of Writing Tools (writingToolsBehavior = .none) in webviews + native text fields, which also suppresses macOS 27's floating Siri button on text selection

    case autofillEnabled // bool (default on) — suggestion menu under form fields + agent credential hooks; see AutofillSettings
    case autofillRememberForms // bool (default on) — remember logins / name / address from submitted forms
    case autofillSearchableSelects // bool (default on) — replace the native <select> popup with a searchable menu
    case autofillShareWithAgents // bool (default on) — put the profile's name / email / address in agents' system prompts
    case autofillAgentPasswordFill // bool (default on) — allow browser.credentials.fillPassword from BrowserJS

    case vscodeUpdaterPID // int — pid of the background serve-web updater; killed at next launch if it orphaned (app quit mid-download). 0 = none.
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

    func doubleValue(defaultValue def: Double = 0) -> Double {
        return UserDefaults.standard.object(forKey: rawValue) as? Double ?? def
    }

    func setDouble(_ value: Double) {
        UserDefaults.standard.set(value, forKey: rawValue)
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
