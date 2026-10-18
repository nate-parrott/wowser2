import SwiftUI

extension EnvironmentValues {
    /// The agent chat pane a view is rendered inside (set by AgentChatOverlay),
    /// so a tab card tapped in the transcript knows which chat to return to.
    @Entry var chatHostPaneID: ID<WebContent>?
}

/// Phone "Back to chat" pill: when a tab is opened from a chat's tab card, the
/// pill offers a way back to that chat for as long as the opened tab stays
/// current. Ephemeral UI state, so it lives here rather than in BrowserState.
@MainActor
final class MobileChatReturn: ObservableObject {
    static let shared = MobileChatReturn()

    struct Entry: Equatable {
        var chatPaneID: ID<WebContent>
        var openedTabID: ID<Tab>
    }

    @Published private(set) var entries: [ID<WindowState>: Entry] = [:]

    func noteOpenedFromChat(chatPaneID: ID<WebContent>, openedTabID: ID<Tab>, windowID: ID<WindowState>) {
        entries[windowID] = Entry(chatPaneID: chatPaneID, openedTabID: openedTabID)
    }

    /// The entry to show for `windowID`, or nil once the user has moved off
    /// the opened tab (which also forgets it).
    func entry(windowID: ID<WindowState>, currentTabID: ID<Tab>?) -> Entry? {
        guard let entry = entries[windowID] else { return nil }
        return entry.openedTabID == currentTabID ? entry : nil
    }

    func forgetIfLeft(windowID: ID<WindowState>, currentTabID: ID<Tab>?) {
        if let entry = entries[windowID], entry.openedTabID != currentTabID {
            entries[windowID] = nil
        }
    }

    func returnToChat(windowID: ID<WindowState>) {
        guard let entry = entries[windowID] else { return }
        entries[windowID] = nil
        BrowserStore.shared.modify { state in
            if let tabID = state.paneToTabMapping[entry.chatPaneID] {
                state.activate(tabId: tabID, in: windowID)
            }
        }
    }
}
