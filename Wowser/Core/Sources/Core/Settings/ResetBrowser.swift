import SwiftUI

// "Reset Browser…" (Settings › General): back to a fresh install.
//
// Erased: every space, tab (including favorites/pinned tabs), sidebar folder,
// project and window (BrowserState), toolbar customization, space background
// images, cookies/site data (logins) and browsing history for every space,
// space chat threads, Old Tabs / bookmarks (ArchiveStore), per-site tweaks
// (`browser.inject` CSS/JS and clean-mode settings, CleanModeStore) and the
// new-tab menu's quick action. Onboarding is marked incomplete and reopened.
//
// Kept: settings, saved passwords and autofill, AI agent chat sessions,
// memory index files, scheduled tasks, extensions and MCP setup.

extension BrowserState {
    /// Replaces everything with a fresh install's state: one new space (the
    /// default profile, with a brand-new website data store) and one empty
    /// window. `keepingWindowID` reuses that window's id so its on-screen
    /// window stays open instead of closing and reopening.
    mutating func resetToFreshInstall(keepingWindowID: ID<WindowState>?) -> ID<WindowState> {
        self = .defaultState
        let window = WindowState(id: keepingWindowID ?? .assign(), profile: .defaultProfile, lastActive: Date())
        windows[window.id] = window
        return window.id
    }

    /// What a reset has to clean up outside `BrowserState`.
    struct ResetLeftovers {
        var paneIDs: [ID<WebContent>]
        var dataStoreUUIDs: Set<UUID>
        var backgroundImageFiles: [URL]
    }

    var resetLeftovers: ResetLeftovers {
        ResetLeftovers(
            paneIDs: tabs.values.flatMap { $0.panes.asArray.map(\.id) },
            dataStoreUUIDs: Set(profiles.values.map(\.dataStoreUUID)),
            backgroundImageFiles: profiles.values.compactMap { $0.imageInfo?.fileURL }
        )
    }
}

extension BrowserStore {
    /// Erases browser state back to a fresh install (see the top of
    /// ResetBrowser.swift for exactly what goes) and reopens onboarding in
    /// the frontmost window.
    @MainActor
    public func resetBrowser() async {
        let old = model
        let leftovers = old.resetLeftovers
        let keepWindow = old.activeWindow?.id

        DefaultsKeys.hasCompletedOnboarding.setBool(false)
        var windowID: ID<WindowState>?
        modify { state in
            windowID = state.resetToFreshInstall(keepingWindowID: keepWindow)
        }
        // The tabs are gone from state; drop their live web views now rather
        // than waiting for the cleaner.
        for paneID in leftovers.paneIDs {
            unloadWebContent(forId: paneID)
        }

        ChatThreadStore.shared.modify { $0 = ChatThreadsState() }
        ArchiveStore.shared.modify { $0 = ArchiveState() }
        CleanModeStore.shared.resetToDefault()
        DefaultsKeys.newMenuQuickAction.setString("")
        let dataStores = leftovers.dataStoreUUIDs
        Queue.historyQueue.run {
            for uuid in dataStores {
                HistoryStore.historyStoreForStoreUUID_historyQueueOnly(uuid).modify { $0 = HistoryState() }
            }
        }
        let files = leftovers.backgroundImageFiles
        DispatchQueue.global(qos: .utility).async {
            for file in files {
                try? FileManager.default.removeItem(at: file)
            }
        }

        applyDefaultSpaceBackground(profileID: .defaultProfile)
        showOnboarding(windowID: windowID)

        for uuid in dataStores {
            await clearWebsiteData(dataStoreUUID: uuid)
        }
    }
}

/// Settings › General: "Reset Browser…" with a confirmation listing what's
/// erased.
struct ResetBrowserRow: View {
    @State private var confirming = false
    @State private var resetting = false

    var body: some View {
        LabeledContent {
            HStack {
                if resetting {
                    ProgressView().controlSize(.small)
                }
                Button("Reset Browser…", role: .destructive) { confirming = true }
                    .disabled(resetting)
            }
        } label: {
            Text("Reset browser")
            Text("Start over as if Wowser were freshly installed, then go through setup again.")
        }
        .confirmationDialog("Reset Wowser to a fresh install?", isPresented: $confirming) {
            Button("Reset Browser", role: .destructive, action: reset)
        } message: {
            Text("""
            This erases all spaces, tabs, favorites, folders and windows, space backgrounds, browsing history, Old Tabs and bookmarks, space chats, site tweaks, and cookies and site data (you'll be logged out of every site). This can't be undone.

            Kept: your settings, saved passwords and autofill, agent chats, memory, scheduled tasks and extensions.
            """)
        }
    }

    private func reset() {
        resetting = true
        Task {
            await BrowserStore.shared.resetBrowser()
            resetting = false
        }
    }
}
