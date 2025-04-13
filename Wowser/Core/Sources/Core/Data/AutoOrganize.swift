import ChatToys
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
            if let tab = tabs[tabId], let aiTags = tab.aiTags {
                groupsMap[aiTags.groupName, default: []].append(tabId)
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
            
            // Step 2: Get existing group names to maintain consistency
            let existingGroupNames = await getExistingGroupNames(in: windowID)
            
            // Step 3: When ANY tab needs tagging, process ALL tabs with LLM to assign/update group names
            try await assignGroupNames(to: allWindowTabs.map(\.id), existingGroups: existingGroupNames)
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
    
    // Clear struct to represent tab information for organization
    private struct TabForOrganization {
        let actualId: ID<Tab>
        let simpleId: Int
        let url: String
        let title: String?
    }
    
    private func assignGroupNames(to tabIds: [ID<Tab>], existingGroups: [String]) async throws {
        // Skip if no tabs to process
        if tabIds.isEmpty { return }
        
        // Get tab information for the prompt with simple numeric IDs
        let tabInfo = await readAsync { state -> [TabForOrganization] in
            return tabIds.enumerated().compactMap { idx, tabId in
                guard let tab = state.tabs[tabId],
                      let firstPane = tab.panes.first,
                      let url = firstPane.info.url else {
                    return nil
                }
                
                return TabForOrganization(
                    actualId: tabId,
                    simpleId: idx + 1,
                    url: url.absoluteString,
                    title: firstPane.info.title
                )
            }
        }
        
        // Create prompt for the LLM
        let prompt = createGroupingPrompt(tabInfo: tabInfo, existingGroups: existingGroups)
        
        // Call the LLM to assign group names
        struct Response: Codable {
            var groups: [String: String]
        }
        
        let resp = try await LLMs.currentOrThrow(json: true).completeJSONObject(
            prompt: [LLMMessage(role: .user, content: prompt)],
            type: Response.self
        )
        
        print("[🤖 Auto-organize] Assigned groups: \(resp)")
        
        // Update tabs with their new AI tags
        await modifyAsync { state in
            for tabInfo in tabInfo {
                // Get the assigned group for this tab
                let simpleIdString = String(tabInfo.simpleId)
                
                if let groupName = resp.groups[simpleIdString],
                   let tabToUpdate = state.tabs[tabInfo.actualId],
                   let firstPaneUrl = tabToUpdate.panes.first?.info.url {
                    state.modifyTab(id: tabInfo.actualId) { tab in
                        tab.aiTags = AITags(
                            historyKeyWhenFetched: firstPaneUrl.historyKey,
                            groupName: groupName
                        )
                    }
                }
            }
        }
    }
    
    private func createGroupingPrompt(tabInfo: [TabForOrganization], existingGroups: [String]) -> String {
        let tabDataJSON = tabInfo.map { tab in
            """
            {
                "id": "\(tab.simpleId)",
                "url": "\(tab.url)",
                "title": \(tab.title != nil ? "\"\(tab.title!.truncateTailWithEllipsis(chars: 300))\"" : "null")
            }
            """
        }.joined(separator: ",\n")
        
        let existingGroupsJSON = existingGroups.map { "\"\($0)\"" }.joined(separator: ", ")
        
        return """
        Your job is to organize browser tabs into logical groups based on the associated topic, thing, activity or intent.
        
        I will give you a list of browser tabs (with URLs and titles), and you should assign each tab to a group.
        
        # Existing Groups
        These are the current group names already in use: [\(existingGroupsJSON)]
        
        # Guidelines
        1. Try to keep tabs in their existing groups when it makes sense
        2. Create new groups only when necessary
        3. Group names should be very short (1-3 words) and descriptive
        4. Related tabs should be in the same group
        5. Most tabs should be in a group with at least one other tab
        6. Consider the user's likely intent for having these tabs open together
        7. If many tabs would belong in a specific group, assign them to the specific group.
        8. Use broader, more generic grouping like "Shopping" or "Work" if you can't make specific groups with >1 item.
        9. Assign casual, sentence-case 1-2 word names. You can also use site names if you see several tabs with the same site name.
        10. If you see many tabs about a particular proper noun / entity, that's a good way to group.
        11. Do not assume groups need to comprise contiguous tabs.
        
        # Sample group names:
        Specific (ideal):
        - Chairs
        - Pizza places
        - Denver
        - Car insurance
        - Taxes
        - Youtube
        - John Denver
        
        Less specific (if necessary):
        - Recipes
        - Work
        - Personal
        - Programming
        
        # Response Format
        Respond in JSON only with this exact format:
        ```
        {
            "scratchpad": "", // brainstorm several POSSIBLE group names of varying specificities and identify how many tabs would fit. E.g. "Hikes - 3, Park Slope - 1, Brooklyn - 2"
            "groups": {
                "tab_id_1": "Group name",
                "tab_id_2": "Group name",
                ...
            }
        }
        ```
        
        # Tabs to organize
        [
        \(tabDataJSON)
        ]
        
        Now, assign each tab to a group. Choose group names that are concise and meaningful:
        """
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
