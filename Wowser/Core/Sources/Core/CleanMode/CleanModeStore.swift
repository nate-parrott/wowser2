import Combine
import Foundation

struct CleanModeConfig: Equatable, Codable {
    var autoReaderRegexes: [String] // Apply auto-reader mode to paths that match this prefix
    var injectCSS: String?
    var readerDisabled = false
    
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
}

class CleanModeStore: DataStore<CleanModeState> {
    static let shared = CleanModeStore(persistenceKey: "CleanModeStore", defaultModel: .init(), queue: .main)
    
    func cleanModeSnapshotForPane(id: ID<WebContent>) -> AnyPublisher<CleanModeSnapshotForPane, Never> {
        let adblockOn = DefaultsKeys.adblock.boolPublisher()
        let url = BrowserStore.shared.uiPublisher.map({ $0.pane(forId: id)?.info.committedURL })
        return Publishers.CombineLatest3(adblockOn, uiPublisher, url)
            .map { tuple -> CleanModeSnapshotForPane in
                let (adblockOn, cleanModeState, url) = tuple
                
                guard let url else {
                    return CleanModeSnapshotForPane(wantsReader: false, adblockEnabled: adblockOn)
                }
                
                let host = url.hostWithoutWWW
                let hostSettings: CleanModeConfig = cleanModeState.hostSettings[host] ?? CleanModeState.defaultHostSettings[host] ?? .init(autoReaderRegexes: [])
                let wantsReader = hostSettings.readerDisabled ? false : (hostSettings.autoReader(forURL: url))
                
                return CleanModeSnapshotForPane(wantsReader: wantsReader, wantsCSS: hostSettings.injectCSS, adblockEnabled: adblockOn)
            }
            .removeDuplicates()
            .eraseToAnyPublisher()
    }
}

struct CleanModeSnapshotForPane: Equatable {
    var wantsReader: Bool
    var wantsCSS: String?
    var adblockEnabled: Bool
}
