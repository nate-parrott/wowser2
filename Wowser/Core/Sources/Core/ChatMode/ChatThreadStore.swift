import Foundation

// Persisted chat-mode threads, one per space (profile).
//
// The coordinator agent's transcript lives in BrowserAgentManager only while
// the app runs (and the harness never replays it), so the sidebar keeps its
// own durable copy: every entry that arrives from the manager is mirrored
// here, plus the tab cards and event notes the browser itself inserts. This is
// what the chat-mode sidebar renders, so a thread survives restarts.
//
// Kept out of BrowserState on purpose: threads can grow large and change on
// every streamed token, and nothing else in the app needs to observe them.

public struct ChatThreadEntry: Equatable, Codable, Identifiable {
    public var id: String
    /// user | assistant | thinking | tool_use | tool_result | error | stopped |
    /// tab_card | peer | event
    public var role: String
    public var text: String
    public var toolName: String?
    /// For `tab_card`: the tab this card stands for. The tab may since have
    /// been closed — `url`/`title` let the card still render and reopen it.
    public var tabID: Core.ID<Tab>?
    public var url: URL?
    public var title: String?
    public var date: Date

    public init(id: String = UUID().uuidString, role: String, text: String, toolName: String? = nil, tabID: Core.ID<Tab>? = nil, url: URL? = nil, title: String? = nil, date: Date = Date()) {
        self.id = id; self.role = role; self.text = text; self.toolName = toolName
        self.tabID = tabID; self.url = url; self.title = title; self.date = date
    }
}

public struct ChatThread: Equatable, Codable {
    public var entries: [ChatThreadEntry] = []

    static let maxEntries = 3000

    mutating func append(_ entry: ChatThreadEntry) {
        entries.append(entry)
        if entries.count > Self.maxEntries {
            entries.removeFirst(entries.count - Self.maxEntries)
        }
    }

    /// True if a card for `tabID` already exists anywhere in the thread.
    func hasCard(for tabID: ID<Tab>) -> Bool {
        entries.contains { $0.role == "tab_card" && $0.tabID == tabID }
    }
}

public struct ChatThreadsState: Equatable, Codable {
    public var threads: [ID<Profile>: ChatThread] = [:]
    public init() {}
}

public final class ChatThreadStore: DataStore<ChatThreadsState> {
    public static let shared = ChatThreadStore(persistenceKey: "ChatThreads", defaultModel: .init(), queue: .main)

    public func thread(for profileID: ID<Profile>) -> ChatThread {
        model.threads[profileID] ?? ChatThread()
    }

    public func append(_ entry: ChatThreadEntry, to profileID: ID<Profile>) {
        modify { state in
            var thread = state.threads[profileID] ?? ChatThread()
            thread.append(entry)
            state.threads[profileID] = thread
        }
    }

    public func clear(profileID: ID<Profile>) {
        modify { state in
            state.threads[profileID] = ChatThread()
        }
    }

    /// Update the cached title/url on every card for `tabID` (titles arrive
    /// after the page loads).
    public func updateCard(tabID: ID<Tab>, url: URL?, title: String?) {
        modify { state in
            guard var thread = state.threads.values.first(where: { $0.hasCard(for: tabID) }),
                  let key = state.threads.first(where: { $0.value == thread })?.key else { return }
            var changed = false
            for i in thread.entries.indices where thread.entries[i].role == "tab_card" && thread.entries[i].tabID == tabID {
                if let url, thread.entries[i].url != url { thread.entries[i].url = url; changed = true }
                if let title, thread.entries[i].title != title { thread.entries[i].title = title; changed = true }
            }
            if changed { state.threads[key] = thread }
        }
    }
}
