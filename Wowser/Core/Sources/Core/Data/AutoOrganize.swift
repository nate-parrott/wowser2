import Foundation

public struct AutoOrganizeResult: Equatable, Codable {
    public var success: Bool
    public var reorganizedTabs: Int
    public var message: String
}

extension BrowserState {
    /// Gets all tab IDs in a window or in the window's focused project
    public func allOrganizableTabsInWindow(_ windowID: ID<WindowState>) -> [Tab] {
        guard let window = windows[windowID] else { return [] }
        
        if let focusedProject = window.focusedOnProject,
           let project = projects[focusedProject] {
            // Use tabs from the focused project
            return project.tabs.compactMap({ self.tabs[$0] })
        } else {
            // Use the main tabs in the window
            return window.tabs.compactMap({ self.tabs[$0] })
        }
    }
    
    /// Finds tab IDs that need their AI tags to be updated
//    public func tabIdsNeedingAITags(in windowID: ID<WindowState>) -> [ID<Tab>] {
//        let tabsToProcess = allOrganizableTabsInWindow(windowID)
//        
//        return tabsToProcess.filter { tabId in
//            guard let tab = tabs[tabId],
//                  let firstPane = tab.panes.first,
//                  let url = firstPane.info.url else {
//                return false
//            }
//            
//            return tab.needsAITag(forFirstPaneURL: url)
//        }
//    }
    
    /// Gets all existing group names from tabs in a window
    public func existingGroupNames(in windowID: ID<WindowState>) -> [String] {
        let allTabs = allOrganizableTabsInWindow(windowID)
        return allTabs.compactMap({ $0.aiTags?.groupName }).asSet.sorted()
    }
    
    mutating func orderTabIdsToColocateGroups(ids: inout [ID<Tab>]) {
        // Group tabs by their AI group names
        var groupsMap = [String: [ID<Tab>]]()
        var untaggedTabs = [ID<Tab>]()
        
        // First, collect tabs into their respective groups
        for tabId in ids {
            if let tab = tabs[tabId], let name = tab.aiTags?.groupName {
                groupsMap[name, default: []].append(tabId)
            } else {
                untaggedTabs.append(tabId)
            }
        }
        
        // Create the reordered list, keeping groups together
        var reorderedIds = [ID<Tab>]()
        
        // Add untagged tabs at the beginning
        reorderedIds.append(contentsOf: untaggedTabs)
        
        // Add each group's tabs in sequence
        for (_, groupTabs) in groupsMap.sorted(by: { $0.key < $1.key }) {
            reorderedIds.append(contentsOf: groupTabs)
        }
        
        // Replace the original array with our reordered one
        ids = reorderedIds
    }
    
    /// Clears all AI tags from tabs
    public mutating func clearAllAITags() {
        for tabId in tabs.keys {
            modifyTab(id: tabId) { tab in
                tab.aiTags = nil
            }
        }
    }
}

extension BrowserStore {
    public func autoOrganizeTabs(in windowID: ID<WindowState>) async -> AutoOrganizeResult {
        print("[🤖 AutoOrganize]: beginning")
        await MainActor.run { cleanupTabs(trigger: "organize") }
        do {
            // Step 1: Identify tabs that need AI tags
            let tabsNeedingAITags = await readAsync { $0.allOrganizableTabsInWindow(windowID).filter({ $0.needsAITag }) }
            
            if tabsNeedingAITags.isEmpty {
                // Skip AI processing if no tabs need tagging
                print("[🤖 AutoOrganize]: no need to re-tag tabs")
                return await reorganizeExistingGroups(in: windowID)
            }
            
            // Get all tabs in the window/project for processing
            let allWindowTabs = await readAsync { $0.allOrganizableTabsInWindow(windowID) }
            if allWindowTabs.count < UIConstants.autoOrgMinTabCount {
                print("[🤖 AutoOrganize]: not enough tabs")
                return await reorganizeExistingGroups(in: windowID)
            }
            
            // Step 2: Get existing group names to maintain consistency
            let existingGroupNames = await getExistingGroupNames(in: windowID)
            
            // Step 3: When ANY tab needs tagging, process ALL tabs with LLM to assign/update group names
            try await assignGroupNames(to: allWindowTabs.map(\.id), existingGroups: existingGroupNames, windowID: windowID)
            print("[🤖 AutoOrganize]: created AI tabs")
            
            // Step 4: Reorganize tabs based on their groups
            return await reorganizeExistingGroups(in: windowID)
        } catch {
            print("[🤖 AutoOrganize Error]: \(error)")
            return AutoOrganizeResult(
                success: false, 
                reorganizedTabs: 0, 
                message: "Failed to organize tabs: \(error.localizedDescription)"
            )
        }
    }
    
//    private func findTabsNeedingAITags(in windowID: ID<WindowState>) async -> [ID<Tab>] {
//        await readAsync { state in
//            state.tabIdsNeedingAITags(in: windowID)
//        }
//    }
    
    private func getExistingGroupNames(in windowID: ID<WindowState>) async -> [String] {
        await readAsync { state in
            state.existingGroupNames(in: windowID)
        }
    }
    
    private func assignGroupNames(to tabIds: [ID<Tab>], existingGroups: [String], windowID: ID<WindowState>) async throws {
        if tabIds.isEmpty { return }

        let tabInfo = await readAsync { state -> [(id: ID<Tab>, info: TabGroupsTask.TabInfo, historyKey: String)] in
            tabIds.compactMap { tabId in
                guard let pane = state.tabs[tabId]?.panes.first, let url = pane.info.url else { return nil }
                return (tabId, TabGroupsTask.TabInfo(title: pane.info.title, url: url), url.historyKey)
            }
        }
        let groups = try await TabGroupsTask.run(tabs: tabInfo.map(\.info), existingGroups: existingGroups)
        print("[🤖 Auto-organize] Assigned groups: \(groups)")

        await modifyAsync { state in
            var groupCounts = [String: Int]()
            for case let name? in groups { groupCounts[name, default: 0] += 1 }
            for (tab, group) in zip(tabInfo, groups) where state.tabs[tab.id] != nil {
                // Only keep a group name shared by more than one tab
                let finalGroupName = group.flatMap { groupCounts[$0, default: 0] > 1 ? $0 : nil }
                state.modifyTab(id: tab.id) { t in
                    t.aiTags = AITags(historyKeyWhenFetched: tab.historyKey, groupName: finalGroupName)
                }
            }
        }

        // Name the space (shown as the placeholder in the sidebar's space label
        // until the user sets their own title), then refresh its emoji + theme.
        // Skip when organizing a project's tabs: they don't represent the space.
        guard let profileID = await readAsync({ state -> ID<Profile>? in
            guard state.windows[windowID]?.focusedOnProject == nil else { return nil }
            return state.windows[windowID]?.profile
        }) else { return }
        if MicroAI.isAvailable(.spaceTitle),
           let name = try? await SpaceTitleTask.run(tabs: tabInfo.map(\.info)).nilIfEmpty {
            await modifyAsync { state in state.profiles[profileID]?.autoTitle = name }
        }
        await regenerateSpaceTheme(profileID: profileID)
    }

    private func reorganizeExistingGroups(in windowID: ID<WindowState>) async -> AutoOrganizeResult {
        var initialOrder: [ID<Tab>] = []
        var reorganizedCount = 0
        
        // Reorganize the tabs
        await modifyAsync { state -> Void in
            guard let window = state.windows[windowID] else { return }
            
            if let focusedProject = window.focusedOnProject,
               let project = state.projects[focusedProject] {
                // Capture initial order for comparison
                initialOrder = project.tabs
                
                // Reorder project tabs
                var projectTabs = project.tabs
                state.orderTabIdsToColocateGroups(ids: &projectTabs)
                state.projects[focusedProject]?.tabs = projectTabs
                
                // Calculate how many tabs were moved
                reorganizedCount = projectTabs.enumerated().filter { $0.element != initialOrder.get($0.offset) }.count
            } else {
                // Capture initial order for comparison
                initialOrder = window.tabs
                
                // Reorder window tabs
                var windowTabs = window.tabs
                state.orderTabIdsToColocateGroups(ids: &windowTabs)
                state.windows[windowID]?.tabs = windowTabs
                
                // Calculate how many tabs were moved
                reorganizedCount = windowTabs.enumerated().filter { $0.element != initialOrder.get($0.offset) }.count
            }
        }
        
        // Create a result message
        let message: String
        if reorganizedCount > 0 {
            message = "Organized \(reorganizedCount) tabs into groups"
        } else {
            message = "Tabs are already well organized"
        }
        
        return AutoOrganizeResult(
            success: true,
            reorganizedTabs: reorganizedCount,
            message: message
        )
    }
}

extension Tab {
    var needsAITag: Bool {
        if let aiTags, aiTags.historyKeyWhenFetched == panes.first?.info.url?.historyKey {
            return false
        }
        return panes.first?.info.url?.historyKey != nil
    }
}
