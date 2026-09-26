import Foundation
import Combine

// Browser-wide chat mode toggle + the always-on tab mirroring behind it.
//
// Chat mode is one flag for the whole browser (BrowserState.chatMode), but
// the threads are per space. So that the two modes stay in sync — a tab opened
// or closed while the tab list is showing must show up (or be marked closed)
// in that space's thread the next time chat mode is on — every space shown in
// a window has a live ChatSpaceSession tracking its tabs regardless of mode.
// Only the coordinator agent itself is lazy: it's created when the chat
// sidebar actually appears (ChatSpaceSession.attach).

extension BrowserStore {
    /// Sidebar width chat mode switches to on entry, if the sidebar is narrower.
    static let chatModeSidebarWidth: CGFloat = 300

    public func setChatMode(_ on: Bool) {
        if on, UIConstants.sidebarWidth < Self.chatModeSidebarWidth {
            UIConstants.setSidebarWidth(Self.chatModeSidebarWidth)
        }
        modify { state in
            state.chatMode = on ? true : nil
        }
    }

    /// Keep a ChatSpaceSession tracking tabs for every space a window is
    /// showing, in both modes.
    func setupChatThreadMirroring() {
        uiPublisher
            .map { state -> [ID<Profile>: ID<WindowState>] in
                // Most recent window per space wins.
                var out: [ID<Profile>: ID<WindowState>] = [:]
                for win in state.windowsMostRecentFirst.reversed() {
                    out[win.profile] = win.id
                }
                return out
            }
            .removeDuplicates()
            .receive(on: DispatchQueue.main)
            .sink { pairs in
                Task { @MainActor in
                    for (profileID, windowID) in pairs {
                        ChatSpaceSession.session(for: profileID).track(windowID: windowID)
                    }
                }
            }
            .store(in: &subscriptions)
    }
}
