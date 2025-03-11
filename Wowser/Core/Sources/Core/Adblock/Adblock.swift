import Foundation
import WebKit
import Combine

class AdblockManager {
    static let shared = AdblockManager()
    
    enum AdblockError: Error {
        case failedToRead
        case failedToCompile
    }

    static func getAdblockList() async throws -> WKContentRuleList {
        assertNotOnMainThread()
        let listId = "com.nateparrott.feeeed.adblock"
        if let list = try? await WKContentRuleListStore.default().contentRuleList(forIdentifier: listId) {
            return list
        }
        guard let path = Bundle.module.url(forResource: "easylist.min", withExtension: "json") else {
            throw AdblockError.failedToRead
        }
        let string = try String(contentsOf: path)
        guard let list = try await WKContentRuleListStore.default().compileContentRuleList(forIdentifier: listId, encodedContentRuleList: string) else {
            throw AdblockError.failedToCompile
        }
        return list
    }

    @Published var blocklist: WKContentRuleList?

    init() {
        Task {
            do {
                let list = try await Self.getAdblockList()
                DispatchQueue.main.async {
                    self.blocklist = list
                }
            } catch {
                fatalError()
//                GeneralLogger(prefix: "Adblock").error("Failed to compile list: \(error)")
            }
        }
    }

//    var activeBlocklist: AnyPublisher<WKContentRuleList?, Never> {
//        let enabled = UserDefaults.standard.publisher(for: \.adblock)
//        return Publishers
//            .CombineLatest(enabled, $blocklist)
//            .map { tuple in
//                let (enabled, list) = tuple
//                return enabled ? list : nil
//            }
//            .eraseToAnyPublisher()
//    }
}

//private extension UserDefaults {
//    @objc dynamic var adblock: Bool {
//        return bool(forKey: DefaultsKeys.adblock.rawValue)
//    }
//}
