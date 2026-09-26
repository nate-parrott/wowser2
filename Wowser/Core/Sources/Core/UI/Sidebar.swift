import SwiftUI
import WebKit

public struct Sidebar: View {
    var floating: Bool
    @Environment(\.windowID) private var windowID
    @Environment(\.profileID) private var profileID
    private let browserStore = BrowserStore.shared
    @AppStorage(DefaultsKeys.sidebarWidth.rawValue) private var storedWidth = Double(UIConstants.defaultSidebarWidth)
    @AppStorage(DefaultsKeys.allWindowsShareTabs.rawValue) private var allWindowsShareTabs = true

    #if os(macOS)
    @State private var hostWindow: NSWindow?
    @State private var measuredFrame: CGRect = .zero
    #endif

    public var body: some View {
        // Use the snapshot pattern to observe only necessary data
        WithSnapshotMain(store: browserStore) { state in
            // Create a minimal snapshot for sidebar data
            SidebarSnapshot(
                windowID: windowID ?? ID<WindowState>(raw: ""),
                profileID: nil, // Use window's current profile
                windows: state.windows,
                tabs: state.tabs,
                profiles: state.profiles,
                shareTabsAcrossWindows: allWindowsShareTabs,
                state: state
            )
        } main: { snapshot in
            SidebarContent(snapshot: snapshot, floating: floating)
                .frame(width: UIConstants.clampSidebarWidth(CGFloat(storedWidth)))
                #if os(macOS)
                .overlay(alignment: .trailing) { SidebarResizeHandle() }
                #endif
                .modifier(SidebarFramePublisher())
        }
    }
}

#if os(macOS)
/// Publishes the sidebar's frame in the BrowserWindowRoot coordinate space
/// to the host BrowserNSWindow's `sidebarFrameInWindow` prop. The window's
/// sendEvent override consults this to gate split-view drop targets.
private struct SidebarFramePublisher: ViewModifier {
    @State private var hostWindow: NSWindow?
    @State private var measuredFrame: CGRect = .zero

    func body(content: Content) -> some View {
        content
            .background(WindowAccessor { window in
                if hostWindow !== window {
                    hostWindow = window
                    publish()
                }
            })
            .measureFrame(coordinateSpace: .named("BrowserWindowRoot")) { frame in
                if frame != measuredFrame {
                    measuredFrame = frame
                    publish()
                }
            }
    }

    private func publish() {
        (hostWindow as? SidebarFrameHostingWindow)?.sidebarFrameInWindow = measuredFrame
    }
}
#else
private struct SidebarFramePublisher: ViewModifier {
    func body(content: Content) -> some View { content }
}
#endif

// Helper struct to represent a tab group for the sidebar
struct TabGroup: Equatable, Identifiable {
    var id: String
    var name: String?
    var tabIDs: [ID<Tab>]
}

// Define a minimal snapshot struct for sidebar data
private struct SidebarSnapshot: Equatable {
    let windowID: ID<WindowState>
    let profileID: ID<Profile>
    
    // List of favorite and regular tab IDs
    let favoriteTabIDs: [ID<Tab>]
    let regularTabGroups: [TabGroup]
    
    // Current tab ID
    let currentTabID: ID<Tab>?
    
    // Whether the current space has a dropped background image (for the
    // "Background Image Mode" / "Remove Background Image" context menu items)
    let hasBackgroundImage: Bool
    let backgroundImageMode: SpaceBackgroundMode
    // Folder attached to the current space ("Add Folder…" / "Change Folder…")
    let folderPath: String?
    // Chat mode (browser-wide): the sidebar shows the space's coordinator thread.
    // The editable space name only appears once there's more than one space.
    let showSpaceTitle: Bool

    init(windowID: ID<WindowState>, 
         profileID: ID<Profile>?, // Can be nil, will use window's current profile
         windows: [ID<WindowState>: WindowState],
         tabs: [ID<Tab>: Tab],
         profiles: [ID<Profile>: Profile],
         shareTabsAcrossWindows: Bool,
         state: BrowserState) {
        
        self.windowID = windowID
        
        // Use provided profileID if not nil, otherwise use window's current profile
        let window = windows[windowID]
        let effectiveProfileID = profileID ?? window?.profile ?? .defaultProfile
        self.profileID = effectiveProfileID
        
        // Get per-profile data from window state
        let perProfileData = window?.perProfileData[effectiveProfileID]
        
        // Get profile-specific current tab
        self.currentTabID = perProfileData?.currentTab
        
        // Extract favorites
        var favoriteIDs = [ID<Tab>]()
        if let profile = profiles[effectiveProfileID] {
            favoriteIDs = profile.manualFavorites + profile.autoFavorites
        }
        self.favoriteTabIDs = favoriteIDs
        self.hasBackgroundImage = profiles[effectiveProfileID]?.imageInfo != nil
        self.backgroundImageMode = profiles[effectiveProfileID]?.imageInfo?.effectiveMode ?? .fade
        self.folderPath = profiles[effectiveProfileID]?.folderPath
        self.showSpaceTitle = profiles.values.filter({ !$0.isHidden }).count > 1

        // Process tabs in their original order but add headers when group changes
        let regularTabIDs = shareTabsAcrossWindows
            ? state.sharedSidebarTabIDs(windowID: windowID, profileID: effectiveProfileID)
            : (perProfileData?.tabs ?? [])
        var tabGroups: [TabGroup] = []
        var currentGroupName: String? = nil
        var currentGroupTabs: [ID<Tab>] = []
        
        if regularTabIDs.count < UIConstants.autoOrgMinTabCount {
            tabGroups = [TabGroup(id: "0", tabIDs: regularTabIDs)]
        } else {
            // we have enough to make groups
            // Go through tabs one by one in their original order
            for tabID in regularTabIDs {
                let tabGroupName = tabs[tabID]?.aiTags?.groupName
                
                // If the group changed or this is the first tab
                if tabGroupName != currentGroupName {
                    // Save the previous group if it has tabs
                    if !currentGroupTabs.isEmpty {
                        tabGroups.append(TabGroup(
                            id: "group-\(currentGroupName ?? "")-\(tabGroups.count)", // Make ID unique with count
                            name: currentGroupName,
                            tabIDs: currentGroupTabs
                        ))
                    }
                    
                    // Start a new group
                    currentGroupName = tabGroupName
                    currentGroupTabs = [tabID]
                } else {
                    // Add to current group
                    currentGroupTabs.append(tabID)
                }
            }
            
            // Add the last group if it has tabs
            if !currentGroupTabs.isEmpty {
                let name = currentGroupName
                tabGroups.append(TabGroup(
                    id: "group-\(name ?? "")-\(tabGroups.count)",
                    name: name,
                    tabIDs: currentGroupTabs
                ))
            }
        }
        
        self.regularTabGroups = tabGroups
    }
}

private struct SidebarContent: View {
    var snapshot: SidebarSnapshot
    var floating: Bool

    var body: some View {
        VStack(spacing: 0) {
//            if floating {
//                Spacer().frame(height: 30)
//            }
            
            HStack(spacing: 4) {
                MacWindowControlsIfValidElse {
                    EmptyView()
                }
                // Space name + icon share the chrome row with the traffic lights;
                // it swaps with a quick fade when the current space changes.
                if snapshot.showSpaceTitle {
                    SpaceNameLabel(windowID: snapshot.windowID, profileID: snapshot.profileID)
                        .id(snapshot.profileID)
                        .transition(.opacity)
                        .frame(maxWidth: .infinity)
                        .padding(.trailing, -2)
                } else {
                    Spacer()
                }
                topButtons
            }
            .padding(6)
            .animation(.easeInOut(duration: 0.12), value: snapshot.profileID)

            // Swipeable profile content (favorites and tabs)
            SidebarSwipeView(windowID: snapshot.windowID)

            Spacer()
            
//            // Bottom buttons
//            SidebarBottomButtons(windowID: snapshot.windowID)
//                .padding(.bottom, 8)
        }
        .contextMenu {
            #if os(macOS)
            Button(snapshot.folderPath == nil ? "Add Folder…" : "Change Folder…") {
                SpaceMenu.pickFolder(profileID: snapshot.profileID, currentPath: snapshot.folderPath)
            }
            #endif
            if snapshot.hasBackgroundImage {
                Divider()
                // A Picker inside a context menu renders as a submenu with a
                // checkmark on the selected item (Label images don't reliably
                // show in macOS menus).
                Picker("Background Image Mode", selection: Binding(
                    get: { snapshot.backgroundImageMode },
                    set: { BrowserStore.shared.setSpaceBackgroundMode($0, profileID: snapshot.profileID) }
                )) {
                    ForEach(SpaceBackgroundMode.allCases, id: \.self) { mode in
                        Text(mode.title).tag(mode)
                    }
                }
                Button("Remove Background Image") {
                    BrowserStore.shared.clearSpaceBackgroundImage(profileID: snapshot.profileID)
                }
            }
        }
    }

    
    @ViewBuilder private var topButtons: some View {
        HStack {
//            if showChatButton, !snapshot.isChatMode {
//                Button(action: openChatSplit) {
//                    Image(systemName: "bubble.left")
//                        .font(.system(size: 12, weight: .medium))
//                        .foregroundStyle(.secondary)
//                        .help("Open Chat Beside This Tab")
//                        .frame(both: 26)
//                }
//                .buttonStyle(GhostButtonStyle())
//            }
            Button(action: toggleSidebarLocked) {
                Image(systemName: "sidebar.left")
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(.secondary)
                    .help("Toggle Sidebar Hidden")
                    .frame(both: 26)
            }
            .buttonStyle(GhostButtonStyle())
        }
//        .frame(height: 28)
//        .edgesIgnoringSafeArea(.all)
    }
    
    func toggleSidebarLocked() {
        BrowserStore.shared.modify { state in
            state.windows[snapshot.windowID]?.sidebarLocked.toggle()
        }
    }
}

#if os(macOS)
/// Invisible strip along the sidebar's trailing edge that drags the sidebar
/// width. Only the cursor changes on hover; a faint line shows while dragging.
private struct SidebarResizeHandle: View {
    @State private var dragStartWidth: CGFloat?

    var body: some View {
        Color.clear
            .frame(width: 6)
            .contentShape(Rectangle())
            .overlay(alignment: .trailing) {
                if dragStartWidth != nil {
                    Rectangle()
                        .fill(Color.primary.opacity(0.15))
                        .frame(width: 2)
                }
            }
            .pointerStyle(.columnResize)
            .gesture(
                DragGesture(minimumDistance: 1, coordinateSpace: .global)
                    .onChanged { value in
                        let start = dragStartWidth ?? UIConstants.sidebarWidth
                        dragStartWidth = start
                        UIConstants.setSidebarWidth(start + value.translation.width)
                    }
                    .onEnded { _ in dragStartWidth = nil }
            )
    }
}
#endif

private struct GroupHeader: View {
    var name: String
    let tabGroup: TabGroup
    
    @State private var isHovered = false
    
    var body: some View {
        HStack {
            Text(name)
                .font(.system(size: 11, weight: .medium))
                .foregroundColor(.secondary)
                .padding(.leading, 12)
                .frame(maxWidth: .infinity, alignment: .leading)
            
            if isHovered {
                Button(action: {
                    closeTabGroup(tabGroup: tabGroup)
                }) {
                    Image(systemName: "xmark")
                        .font(.system(size: 10, weight: .heavy))
                        .foregroundColor(.secondary)
                        .frame(both: 18)
                        .help("Close tabs in this group")
                }
                .padding(-4)
                .buttonStyle(GhostButtonStyle())
                .padding(.trailing, 16)
            }
        }
        .padding(.top, 12)
        .padding(.bottom, 4)
        .contentShape(Rectangle())
        .onHover { hovering in
            isHovered = hovering
        }
    }
    
    private func closeTabGroup(tabGroup: TabGroup) {
        for tabID in tabGroup.tabIDs {
            closeTab(tabID: tabID)
        }
    }
}

private enum TabListCell: Equatable, Identifiable {
    case header(id: String, name: String?, tabGroup: TabGroup) // if name is nil, .render as divider
    case tabID(ID<Tab>)
    
    var id: String {
        switch self {
        case .header(let id, _, _):
            return id
        case .tabID(let id):
            return id.raw
        }
    }
    
    static func cellsFrom(groups: [TabGroup]) -> [TabListCell] {
        var cells = [TabListCell]()
        var isFirst = true
        for group in groups {
            if let name = group.name {
                cells.append(.header(id: "header:" + group.id, name: name, tabGroup: group))
            } else if !isFirst {
                // Append non-textual (divider) header
                cells.append(.header(id: "header:" + group.id, name: nil, tabGroup: group))
            }
            cells += group.tabIDs.map { TabListCell.tabID($0) }
            isFirst = false
        }
        return cells
    }
}

// Grouped tabs section
struct GroupedTabsView: View {
    /// Folder tabs in the list, keyed by tab id; rendered in place of the row.
    var folders: [ID<Tab>: FolderSnapshot] = [:]
    let tabGroups: [TabGroup]
    let currentTabID: ID<Tab>?
    let windowID: ID<WindowState>
    let profileID: ID<Profile>
    
    var body: some View {
        let cells: [TabListCell] = TabListCell.cellsFrom(groups: tabGroups)
        ScrollViewReader { scrollProxy in
            ScrollView {
                VStack(alignment: .leading, spacing: isMobile() ? 4 : 0) {
                    ForEach(cells) { cell in
                        switch cell {
                        case .header(id: _, name: let name, tabGroup: let tabGroup):
                            if let name {
                                GroupHeader(name: name, tabGroup: tabGroup)
                            } else {
                                Divider()
                                    .padding(.horizontal, 14)
                                    .padding(.vertical, 6)
                            }
                        case .tabID(let tabID):
                            if let folder = folders[tabID] {
                                FolderSection(
                                    folder: folder,
                                    currentTabID: currentTabID,
                                    windowID: windowID
                                )
                                .sidebarDropTarget { _, _ in
                                    .folder(folderTab: folder.id, before: nil, open: false)
                                }
                            } else {
                            RegularTabRow(
                                tabID: tabID,
                                isSelected: tabID == currentTabID,
                                windowID: windowID
                            )
                            .sidebarDropTarget { point, bounds in
                                // Drop before this tab in the window's regular tabs
                                return .ordinaryTabs(window: windowID, before: tabID)
                            }
                            }
                        }
                    }
                    FancyPlus(windowID: windowID)
                        .padding(4)
                        .frame(maxWidth: .infinity)
//                    NewTabCell(windowID: windowID)
                }
                .padding(isMobile() ? 12 : 0)
                .frame(maxWidth: .infinity)
                .animation(.niceDefault(duration: 0.12), value: tabGroups)
            }
            .scrollBounceBehavior(.basedOnSize)
            // Background drop target for the entire area
            .sidebarDropTarget { point, bounds in
                // Drop at the end of the window's regular tabs
                return .ordinaryTabs(window: windowID, before: nil)
            }
            .onChange(of: currentTabID) { newTabID in
                if let newTabID = newTabID {
                    withAnimation(.niceDefault) {
                        scrollProxy.scrollTo(newTabID, anchor: nil)
                    }
                }
            }
            .onAppear {
                if let currentTabID {
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
                        withAnimation {
                            scrollProxy.scrollTo(currentTabID, anchor: nil)
                        }
                    }
                }
            }
        }
    }
}

// Extension to apply tab style to any shape
extension Shape {
    @ViewBuilder
    func applyTabStyle(isSelected: Bool, isHovered: Bool) -> some View {
        if isSelected {
            self.fill(
                LinearGradient(colors: [
                    Color("TabBackground", bundle: .module),
                    Color("TabBackground", bundle: .module).opacity(0.7),
                ], startPoint: .top, endPoint: .bottom)
            )
            .darkModeConditional({ view, dark in
                view.shadow(color: (dark ? Color.white.opacity(0.2) : Color.black.opacity(0.1)), radius: 2, x: 0, y: 1)
            })
        } else {
            self.fill(Color.primary.opacity(isHovered ? 0.12 : 0.07))
        }
    }
}

public struct Sidebar_Previews: PreviewProvider {
    public static var previews: some View {
        Sidebar(floating: true)
            .frame(width: 200, height: 500)
            .withBrowserContext(
                windowID: ID<WindowState>(raw: "w0"),
                profileID: .defaultProfile
            )
    }
}
