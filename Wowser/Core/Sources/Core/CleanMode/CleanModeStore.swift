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
        dict["cnn.com"] = CleanModeConfig(autoReaderRegexes: ["/.{5,}$"])
        dict["google.com"] = CleanModeConfig(autoReaderRegexes: [], injectCSS: "* { font-family: 'Comic Sans MS' !important; }")
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
    
    func cleanModeSnapshotForPane(id: ID<WebContent>) -> AnyPublisher<CleanModeSnapshotForPane, Never> {
        let adblockOn = DefaultsKeys.adblock.boolPublisher()
        struct TabData: Equatable {
            var url: URL?
            var readerAvail: Bool
        }
        let tabData: AnyPublisher<TabData, Never> = BrowserStore.shared.uiPublisher.map({
            if let pane = $0.pane(forId: id) {
                return TabData(url: pane.info.committedURL, readerAvail: pane.info.readerAvailable ?? false)
            }
            return TabData(readerAvail: false)
        }).eraseToAnyPublisher()
        return Publishers.CombineLatest3(adblockOn, uiPublisher, tabData)
            .map { tuple -> CleanModeSnapshotForPane in
                let (adblockOn, cleanModeState, tabData) = tuple
                
                guard let url = tabData.url else {
                    return CleanModeSnapshotForPane(wantsReader: false, readerReady: false, wantsCSS: nil, cssAvail: false, adblockEnabled: adblockOn)
                }
                
                let host = url.hostWithoutWWW
                let hostSettings: CleanModeConfig = cleanModeState.hostSettings[host] ?? CleanModeState.defaultHostSettings[host] ?? .init(autoReaderRegexes: [])
                let wantsReader = hostSettings.readerDisabled ? false : (hostSettings.autoReader(forURL: url))
                
                return CleanModeSnapshotForPane(
                    wantsReader: wantsReader,
                    readerReady: tabData.readerAvail,
                    wantsCSS: hostSettings.stylingDisabled ? nil : hostSettings.injectCSS,
                    cssAvail: hostSettings.injectCSS?.nilIfEmpty != nil,
                    adblockEnabled: adblockOn
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
}
