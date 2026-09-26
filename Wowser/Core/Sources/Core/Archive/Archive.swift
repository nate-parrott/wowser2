import SwiftUI

public struct ArchiveItem: Identifiable, Codable, Equatable {
    public var id: String {
        historyKey
    }
    var added: Date
    var url: URL
    var historyKey: String
    var title: String?
    var tidyTitle: String?
    var aiCategory: Category?
    var kind: Kind
    
    enum Kind: String, Equatable, Codable {
        case bookmark
        case autoArchivedTab
        case manuallyArchivedTab
    }
    
    enum Category: String, Equatable, Codable, CaseIterable {
        case work
        case personal
        case social
        case travel
        case news
    }
}

public struct ArchiveState: Equatable, Codable {
    var itemsByHistoryKey = [String: ArchiveItem]()
    
    mutating func cleanup() {
        // Identify items to keep: all bookmarks and the 80 most recent items per category
        var keepableIDs = Set<String>()
        
        // First, keep all bookmarks
        for (key, item) in itemsByHistoryKey where item.kind == .bookmark {
            keepableIDs.insert(key)
        }
        
        // Group auto-archived tabs by category
        var itemsByCategory: [ArchiveItem.Category?: [ArchiveItem]] = [:]
        for item in itemsByHistoryKey.values where item.kind == .autoArchivedTab {
            let category = item.aiCategory
            itemsByCategory[category, default: []].append(item)
        }
        
        // For each category, keep the 80 most recent items
        for (category, items) in itemsByCategory {
            let sortedItems = items.sorted(by: { $0.added > $1.added }) // Sort by date, newest first
            let keepItems = sortedItems.prefix(80) // Keep only the 80 most recent
            for item in keepItems {
                keepableIDs.insert(item.historyKey)
            }
        }
        
        // Remove items that are not in the keepable set
        itemsByHistoryKey = itemsByHistoryKey.filter { keepableIDs.contains($0.key) }
    }
}

extension Queue {
    static let archiveQueue = Queue(id: "ArchiveQueue", queue: DispatchQueue(label: "ArchiveQueue", qos: .default))
}

public class ArchiveStore: DataStore<ArchiveState> {
    public static let shared = ArchiveStore(persistenceKey: "ArchiveStore", defaultModel: .init(), queue: .historyQueue)
    
    public override func cleanup(model: inout ArchiveState) {
        model.cleanup()
    }
    
    /// Toggles bookmark status for a URL
    /// - Parameters:
    ///   - url: The URL to toggle bookmark status for
    ///   - title: The title of the page (optional)
    /// - Returns: The new bookmark status (true if bookmarked, false if not)
    public func toggleBookmark(url: URL?, title: String?) {
        guard let url = url else { return }
        Task { @MainActor in
            let bookmarked = await self.isItemBookmarked(url: url)
            if bookmarked {
                // Remove
                self.modify { state in
                    state.itemsByHistoryKey.removeValue(forKey: url.historyKey)
                }
            } else {
                // Add
                let item = ArchiveItem(added: Date(), url: url, historyKey: url.historyKey, title: title, kind: .bookmark)
                self.add(item: item)
                
                // Animate the bookmarks menu item
//                if let bookmarksMenuItem = ArchiveMenuManager.shared?.bookmarksMenuItem {
//                    bookmarksMenuItem.animateTextMessage(text: "✅ Bookmarked!", skipAnimation: true)
//                }
            }
        }
    }
    
    public func isItemBookmarked(url: URL) async -> Bool {
        await readAsync({ $0.itemsByHistoryKey[url.historyKey]?.kind == .bookmark })
    }
    
    func add(item: ArchiveItem) {
        modify { state in
            if var existing = state.itemsByHistoryKey[item.historyKey] {
                existing.title = item.title
                existing.url = item.url
                if item.kind == .bookmark {
                    existing.kind = .bookmark // bookmark beats auto-archived
                }
                state.itemsByHistoryKey[item.historyKey] = existing
            } else {
                state.itemsByHistoryKey[item.historyKey] = item
                Task {
                    do {
                        try await self.runAI(on: item)
                    } catch {
                        print("[🤖 Archive AI Error]: \(error)")
                    }
                }
            }
        }
    }
    
    private func runAI(on item: ArchiveItem) async throws {
        let resp = try await ArchiveTidyTask.run(title: item.title, url: item.url)
        print("[🤖 Archive classification] Finished:\n\(resp)")
        await self.modifyAsync { state in
            state.itemsByHistoryKey[item.historyKey]?.aiCategory = resp.category
            state.itemsByHistoryKey[item.historyKey]?.tidyTitle = resp.tidyTitle
        }
    }
}

