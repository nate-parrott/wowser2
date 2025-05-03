import Combine
import Foundation

struct CleanModeConfig: Equatable, Codable {
    var autoReaderRegexes: [String] // Apply auto-reader mode to paths that match this prefix
    var injectCSS: String?
    var readerDisabled = false
    
    func autoReader(forURL url: URL) -> Bool {
        let path = url.path()
        return autoReaderRegexes.contains { regexStr in
            guard let regex = try? NSRegularExpression(pattern: regexStr) else { return false }
            let range = NSRange(location: 0, length: path.utf16.count)
            return regex.firstMatch(in: path, options: [], range: range) != nil
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
        return dict
    }()
}

class CleanModeStore: DataStore<CleanModeState> {
    static let shared = CleanModeStore(persistenceKey: "CleanModeStore", defaultModel: .init(), queue: .main)
    
    func cleanModeSnapshotForPane(id: ID<WebContent>) -> AnyPublisher<CleanModeSnapshotForPane, Never> {
        let adblockOn = DefaultsKeys.adblock.boolPublisher()
        let url = BrowserStore.shared.uiPublisher.map({ $0.pane(forId: id)?.info.url })
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
