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
    case sortExternalLinksIntoSpaces // bool (default on) — links opened from other apps are classified by an LLM and moved into the best-fitting space; see BrowserStore+ExternalLinkSpaces
    case cleanupTabs // bool (default on) — background close of stale empty/duplicate/meeting/idle-terminal/ghost-agent tabs; see BrowserStore+Cleanup
    case allWindowsShareTabs // bool (default on) — every window's sidebar lists the space's tabs from all windows; selecting a tab that lives in another window moves it here. See BrowserState.sharedSidebarTabIDs / activate(tabId:in:)
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
//    case Chatbot // Chatbot
    
    case enableGoDirectQueries // bool (default off)
    case lastShownWelcomePageForPageVersion // int
    case searchToolbarEnabled // bool

    case mcpServerURL // string — written by MCPServer when it binds, read by SettingsView

    case disableNetworkProxy // bool — when true, webviews bypass the local capturing proxy entirely (no HTTP capture, no HTTPS MITM)
    
    case mcpServerTokenDev // string — per-launch bearer token for the local MCP server
    case mcpServerTokenProd
    static var mcpServerToken: DefaultsKeys {
        isProd() ? mcpServerTokenProd : mcpServerTokenDev
    }
    
    case hasSeenTerminalUpsell // bool — set after the user dismisses the first-time terminal upsell

    case sidebarWidth // double — user-dragged sidebar width in points (see UIConstants.sidebarWidth)
    case spaceThemeIntensity // double 0–2 — scales the space theme's background gradient opacity (1 = default)

    case devModeDomains // string — JSON [domain: DevModeDomainConfig]; see DevMode.swift

    case lastAIRequest // string — JSON AIRequestRecord; see AIRequestLog.swift

    case microAIBackends // string — JSON [MicroAIFeature: MicroAIBackend]; see MicroAI.swift

    case dictationHotkey // string — DictationHotkey raw value (push-to-talk shortcut); empty = default (hold ⌘⌥)
    case dictationCleanup // bool — run dictated text (into web text fields) through the configured LLM before inserting

    case hideSiriAIOnTextSelection // bool (default on) — opt out of Writing Tools (writingToolsBehavior = .none) in webviews + native text fields, which also suppresses macOS 27's floating Siri button on text selection

    case agentHarness // string — AgentHarness raw value for chat/ask agents: "claude" (default) | "local" (on-device)
    case agentShellTools // bool (default off) — Claude Code agents get the harness's Bash/Read/Write/Edit/Glob/Grep tools (permissions bypassed); see ClaudeCodeAgentProvider
    case memoryEnabledScopes // [string] — dataStoreUUIDs whose memory store (event log) is on; see MemoryStore.swift
    case autofillEnabled // bool (default on) — suggestion menu under form fields + agent credential hooks; see AutofillSettings
    case autofillRememberForms // bool (default on) — remember logins / name / address from submitted forms
    case autofillSearchableSelects // bool (default off, experimental) — replace the native <select> popup with a searchable menu
    case autofillShareWithAgents // bool (default on) — put the profile's name / email / address in agents' system prompts
    case autofillAgentPasswordFill // bool (default on) — allow browser.credentials.fillPassword from BrowserJS

    case vscodeUpdaterPID // int — pid of the background serve-web updater; killed at next launch if it orphaned (app quit mid-download). 0 = none.
    case newMenuQuickAction // string — NewMenuItem raw value; the quick-action segment of the sidebar's FancyPlus. Set to the last non-tab item picked from its overflow menu.
}

public extension DefaultsKeys {
    func boolValue(defaultValue def: Bool = false) -> Bool {
        return UserDefaults.standard.object(forKey: rawValue) as? Bool ?? def
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

    func stringArrayValue() -> [String] {
        return UserDefaults.standard.stringArray(forKey: rawValue) ?? []
    }

    func setStringArray(_ value: [String]) {
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

//public enum Chatbot: String, CaseIterable, Equatable, Hashable, Codable {
//    case claude
//    case chatgpt
//    case perplexity
//}
