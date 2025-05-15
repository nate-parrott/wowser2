import Combine
import Foundation

struct CleanModeConfig: Equatable, Codable {
    var autoReaderRegexes: [String] // Apply auto-reader mode to paths that match this prefix
    var injectCSS: String?
    var readerDisabled = false
    var stylingDisabled = false
    
    func autoReader(forURL url: URL) -> Bool {
        let path = url.path().nilIfEmpty ?? "/"
        return autoReaderRegexes.contains { regexStr in
            guard let regex = try? NSRegularExpression(pattern: regexStr) else { return false }
            let range = NSRange(location: 0, length: path.utf16.count)
            return regex.firstMatch(in: path, options: [], range: range) != nil
        }
    }
    
    mutating func addPathToAutoReaderRegexes(url: URL) {
        if autoReader(forURL: url) {
            return // already added
        }
        
        if url.pathComponents.count <= 1 || url.path.isEmpty || url.path == "/" {
            // URL is at the root of domain, add pattern to match any path on the domain
            autoReaderRegexes.append("/.*")
        } else {
            // Not at root, add a generic pattern that matches any non-root path
            autoReaderRegexes.append("/.+$")
        }
    }
}

struct CleanModeState: Equatable, Codable {
    // Keys are `hostWithoutWWW`
    var hostSettings = [String: CleanModeConfig]()
}

extension CleanModeState {
    static var defaultHostSettings: [String: CleanModeConfig] = {
        var dict = [String: CleanModeConfig]()
        dict["mail.google.com"] = CleanModeConfig(autoReaderRegexes: [], injectCSS: "iframe[name=callout] { display: none !important; }")
        dict["cnn.com"] = CleanModeConfig(autoReaderRegexes: ["/.{5,}$"])
        dict["google.com"] = CleanModeConfig(autoReaderRegexes: [], injectCSS: "* { font-family: 'Comic Sans MS' !important; }")
        dict["medium.com"] = CleanModeConfig(autoReaderRegexes: [], injectCSS: """
        #credential_picker_container { display: none !important }
        div[style^='top']:has(button) { display: none !important; }
        """)
        dict["x.com"] = CleanModeConfig(autoReaderRegexes: [], injectCSS: """
        [aria-label='Verified account'] { display: none !important; }
        [aria-label='Timeline: Trending now'] { display: none !important; }
        [data-testid='super-upsell-UpsellCardRenderProperties'] { display: none !important; }
        button[aria-label='Grok actions'] { display: none !important; }
        [aria-label='Primary'] [aria-label='Grok'] { display: none !important; }
        [aria-label='Primary'] [aria-label='Premium'] { display: none !important; }
        [data-testid='GrokDrawer'] { display: none !important; }
        """)
        return dict
    }()
    
    mutating func updateSettings(host: String, update: (inout CleanModeConfig) -> Void) {
        if hostSettings[host] != nil {
            update(&(hostSettings[host]!))
        } else {
            var val = Self.defaultHostSettings[host] ?? .init(autoReaderRegexes: [])
            update(&val)
            hostSettings[host] = val
        }
    }
    
    mutating func setReaderModeEnabled(_ enable: Bool, onURL url: URL) {
        updateSettings(host: url.hostWithoutWWW) { config in
            if enable {
                config.addPathToAutoReaderRegexes(url: url)
                config.readerDisabled = false
            } else {
                config.readerDisabled = true
            }
        }
    }
    
    mutating func setStylingEnabled(_ enable: Bool, onURL url: URL) {
        updateSettings(host: url.hostWithoutWWW) { config in
            config.stylingDisabled = !enable
        }
    }
}

class CleanModeStore: DataStore<CleanModeState> {
    static let shared = CleanModeStore(persistenceKey: "CleanModeStore", defaultModel: .init(), queue: .main)
    
    func cleanModeSnapshotForFocusedPane(windowID: ID<WindowState>) -> AnyPublisher<CleanModeSnapshotForPane, Never> {
        BrowserStore.shared.uiPublisher.map({ $0.currentPane(forWindow: windowID)?.id }).removeDuplicates()
            .map({ CleanModeStore.shared.cleanModeSnapshotForPane(id: $0) })
            .switchToLatest()
            .removeDuplicates()
            .eraseToAnyPublisher()
    }
    
    func cleanModeSnapshotForPane(id: ID<WebContent>?) -> AnyPublisher<CleanModeSnapshotForPane, Never> {
        guard let id else {
            return Just(CleanModeSnapshotForPane(wantsReader: false, readerReady: false, cssAvail: false, adblockEnabled: false, hasURL: false)).eraseToAnyPublisher()
        }
        
        let adblockOn = DefaultsKeys.adblock.boolPublisher()
        let recipeCleanEnabled = DefaultsKeys.cleanModeForRecipes.boolPublisher()
        struct TabData: Equatable {
            var url: URL?
            var readerAvail: Bool
            var recipeDetected: Bool
        }
        let tabData: AnyPublisher<TabData, Never> = BrowserStore.shared.uiPublisher.map({
            if let pane = $0.pane(forId: id) {
                return TabData(
                    url: pane.info.committedURL,
                    readerAvail: pane.info.readerAvailable ?? false,
                    recipeDetected: pane.info.recipeDetected ?? false
                )
            }
            return TabData(readerAvail: false, recipeDetected: false)
        }).eraseToAnyPublisher()
        
        return Publishers.CombineLatest4(adblockOn, recipeCleanEnabled, uiPublisher, tabData)
            .map { tuple -> CleanModeSnapshotForPane in
                let (adblockOn, recipeCleanEnabled, cleanModeState, tabData) = tuple
                
                guard let url = tabData.url else {
                    return CleanModeSnapshotForPane(wantsReader: false, readerReady: false, wantsCSS: nil, cssAvail: false, adblockEnabled: adblockOn, hasURL: false, hostWithoutWWW: nil)
                }
                
                let host = url.hostWithoutWWW
                let hostSettings: CleanModeConfig = cleanModeState.hostSettings[host] ?? CleanModeState.defaultHostSettings[host] ?? .init(autoReaderRegexes: [])
                let autoRecipe = recipeCleanEnabled && tabData.recipeDetected
                let wantsReader = !hostSettings.readerDisabled && (
                    autoRecipe || hostSettings.autoReader(forURL: url)
                )
                
                return CleanModeSnapshotForPane(
                    wantsReader: wantsReader,
                    readerReady: tabData.readerAvail,
                    wantsCSS: hostSettings.stylingDisabled ? nil : hostSettings.injectCSS,
                    cssAvail: hostSettings.injectCSS?.nilIfEmpty != nil,
                    adblockEnabled: adblockOn,
                    hasURL: true,
                    disableCleanMode: GeneratedPageKey(url: url) != nil, // disable for internal pages
                    hostWithoutWWW: host
                )
            }
            .removeDuplicates()
            .eraseToAnyPublisher()
    }
}

struct CleanModeSnapshotForPane: Equatable {
    var wantsReader: Bool
    var readerReady: Bool
    var wantsCSS: String?
    var cssAvail: Bool
    var adblockEnabled: Bool
    var hasURL: Bool
    var disableCleanMode: Bool = false // e.g. for internal pages
    var hostWithoutWWW: String?
}
