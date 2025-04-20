import Foundation
import WebKit
import Combine

enum Blocklist: Hashable, Codable {
    case ads
    case cookies
}

class AdblockManager {
    static let shared = AdblockManager()
    
    enum AdblockError: Error {
        case failedToRead
        case failedToCompile
    }

    static func getAdblockLists() async throws -> [Blocklist: WKContentRuleList] {
        func load(name: String) async throws -> WKContentRuleList {
            let listId = "com.nateparrott.wowser.\(name)"
            if let list = try? await WKContentRuleListStore.default().contentRuleList(forIdentifier: listId) {
                return list
            }
            guard let path = Bundle.module.url(forResource: "\(name).min", withExtension: "json") else {
                throw AdblockError.failedToRead
            }
            let string = try String(contentsOf: path)
            guard let list = try await WKContentRuleListStore.default().compileContentRuleList(forIdentifier: listId, encodedContentRuleList: string) else {
                throw AdblockError.failedToCompile
            }
            return list
        }
        
        return try await [
            Blocklist.ads: load(name: "easylist"),
            Blocklist.cookies: load(name: "easycookie"),
        ]
    }

    @Published var blocklists: [Blocklist: WKContentRuleList]?

    init() {
        Task {
            do {
                let lists = try await Self.getAdblockLists()
                DispatchQueue.main.async {
                    self.blocklists = lists
                }
            } catch {
                fatalError()
//                GeneralLogger(prefix: "Adblock").error("Failed to compile list: \(error)")
            }
        }
    }
}

private extension UserDefaults {
    @objc dynamic var adblock: Bool {
        return bool(forKey: DefaultsKeys.adblock.rawValue)
    }
}
