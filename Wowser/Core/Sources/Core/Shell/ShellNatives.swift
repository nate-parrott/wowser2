import SwiftUI
import Combine

/// `<Native name="…">` — the built-in browser views a branch can place.
///
/// These are the same SwiftUI views the built-in UI is made of, so a layout
/// assembled from them is pixel-identical to it and never re-renders through
/// JS. To add one: add a case here, a wrapper in ShellKit/runtime/lib/native.js
/// and a declaration in wowser.d.ts.
struct ShellNativeView: View {
    let node: ShellNode
    @Environment(\.windowID) private var windowID
    @Environment(\.profileID) private var profileID
    @Environment(ShellEngine.self) private var engine

    var body: some View {
        Group {
            if let windowID {
                content(windowID: windowID)
            } else {
                Color.clear
            }
        }
        .shellStyled(node)
    }

    private var spaceID: ID<Profile> {
        node.string("spaceId").map { ID<Profile>(raw: $0) } ?? profileID ?? .defaultProfile
    }

    private var paneID: ID<WebContent>? {
        node.string("paneId").map { ID<WebContent>(raw: $0) }
    }

    @ViewBuilder
    private func content(windowID: ID<WindowState>) -> some View {
        switch node.string("name") ?? "" {
        case "ClassicBrowser":
            ShellClassicBrowser(windowID: windowID)
        case "Sidebar":
            if node.bool("floating") {
                Sidebar(floating: true).withFloatingSidebarContainer()
            } else {
                Sidebar(floating: false)
            }
        case "SpacePager":
            SidebarSwipeView(windowID: windowID)
        case "FavoritesGrid":
            ProfilePageView(windowID: windowID, profileID: spaceID, showFavorites: true, showTabs: false)
        case "TabList":
            ProfilePageView(windowID: windowID, profileID: spaceID, showFavorites: false, showTabs: true)
        case "TabRow":
            ShellNativeTabRow(tabID: ID<Tab>(raw: node.string("tabId") ?? ""), windowID: windowID)
        case "NewTabButton":
            #if os(macOS)
            FancyPlus(windowID: windowID)
            #else
            EmptyView()
            #endif
        case "SpaceDots":
            ProfilePagingDots(windowID: windowID)
        case "SpaceName":
            SpaceNameLabel(windowID: windowID, profileID: spaceID)
        case "Content":
            ShellContentView(windowID: windowID, toolbar: node.string("toolbar") ?? "auto")
        case "Toolbar":
            ShellOmniboxHost(windowID: windowID, paneID: paneID) { pane, coordinator, active, scheme in
                ToolbarView(webContentID: pane, coordinator: coordinator, colorScheme: scheme)
                    .overlay(alignment: .bottom) {
                        (scheme?.foreground.color ?? Color.black).opacity(0.1).frame(height: 1)
                    }
                    .overlay(alignment: .top) {
                        if active {
                            OmniboxDropdown(coordinator: coordinator).padding(.top, UIConstants.macHeaderHeight)
                        }
                    }
            }
        case "CommandBar":
            ShellOmniboxHost(windowID: windowID, paneID: paneID) { pane, coordinator, _, _ in
                NewTabCommandBar(paneID: pane, coordinator: coordinator)
            }
        case "Toasts":
            ToastViewer()
        case "WindowBackground":
            ShellNativeWindowBackground(windowID: windowID)
        case "LoadingBar":
            ShellNativeLoadingBar(windowID: windowID, paneID: paneID)
        case "TabThumbnail":
            ShellNativeThumbnail(tabID: ID<Tab>(raw: node.string("tabId") ?? ""))
        case "MobileBrowser":
            MobileNativeContentView(windowID: windowID)
        case "ErrorScreen":
            // The root error boundary rendered: switch to the built-in UI
            // with the failure banner (see ShellWindowView).
            Color.clear.onAppear {
                engine.rootDidFail(
                    message: node.string("message") ?? "The UI failed to render.",
                    stack: node.string("stack") ?? "",
                    componentStack: node.props["componentStack"]?.array?.compactMap(\.string) ?? []
                )
            }
        default:
            Text("Unknown native view “\(node.string("name") ?? "")”")
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
                .padding(6)
        }
    }
}

/// The whole built-in window, unchanged.
private struct ShellClassicBrowser: View {
    let windowID: ID<WindowState>

    var body: some View {
        WithSnapshotMain(store: BrowserStore.shared, snapshot: { WindowSnapshot(state: $0, id: windowID) }) { snapshot in
            WindowContent(snapshot: snapshot)
                .withBrowserContext(windowID: windowID, profileID: snapshot.profileID)
        }
    }
}

private struct ShellNativeWindowBackground: View {
    let windowID: ID<WindowState>

    private struct Snapshot: Equatable {
        var theme: SpaceTheme?
        var imageInfo: SpaceImageInfo?
    }

    var body: some View {
        WithSnapshotMain(store: BrowserStore.shared, snapshot: { state -> Snapshot in
            guard let window = state.windows[windowID], window.showingNewProfilePage != true else { return Snapshot() }
            let profile = state.profiles[window.profile]
            return Snapshot(theme: profile?.theme, imageInfo: profile?.imageInfo)
        }) { snapshot in
            WindowBG(theme: snapshot.theme, imageInfo: snapshot.imageInfo, windowID: windowID)
        }
    }
}

private struct ShellNativeTabRow: View {
    let tabID: ID<Tab>
    let windowID: ID<WindowState>

    var body: some View {
        WithSnapshotMain(store: BrowserStore.shared, snapshot: { $0.windows[windowID]?.currentTab == tabID }) { selected in
            RegularTabRow(tabID: tabID, isSelected: selected, windowID: windowID)
        }
    }
}

private struct ShellNativeLoadingBar: View {
    let windowID: ID<WindowState>
    let paneID: ID<WebContent>?

    var body: some View {
        WithSnapshotMain(store: BrowserStore.shared, snapshot: { state -> Double? in
            guard let id = paneID ?? state.currentPane(forWindow: windowID)?.id else { return nil }
            return state.loadingProgress(webContentId: id)
        }) { progress in
            LoadingIndicator(progress: progress == 1 ? nil : progress)
        }
    }
}

private struct ShellNativeThumbnail: View {
    let tabID: ID<Tab>
    @State private var image: UINSImage?

    var body: some View {
        Group {
            if let image {
                Image(uinsImage: image).resizable().aspectRatio(contentMode: .fill)
            } else {
                Color.primary.opacity(0.06)
            }
        }
        .onReceive(ThumbnailCache.shared.$cacheUpdateCount) { _ in refresh() }
        .onAppear { refresh() }
    }

    private func refresh() {
        guard let pane = BrowserStore.shared.model.tabs[tabID]?.focusedPane?.id else { return }
        image = ThumbnailCache.shared.getThumbnail(for: pane)
    }
}

/// The content area as the built-in window shows it: the current tab's panes
/// (split aware), the tab switcher, split drop targets.
private struct ShellContentView: View {
    let windowID: ID<WindowState>
    /// "auto" | "always" | "hidden"
    let toolbar: String
    @State private var topHovered = false

    var body: some View {
        WithSnapshotMain(store: BrowserStore.shared, snapshot: { WindowSnapshot(state: $0, id: windowID) }) { snapshot in
            let visible = toolbarVisible(snapshot)
            TabStack3D(snapshot: snapshot, topbarVisible: visible)
                .urlSplitDropTarget(windowID: windowID)
                .environment(\.shellOwnsToolbar, toolbar == "hidden")
                .background {
                    if toolbar == "auto" {
                        // Same reveal zone as the built-in window: the top
                        // edge, staying open while the pointer is near the bar.
                        Color.clear.trackMouseOutsideWindow { point, rect in
                            let zone = CGRect(x: 0, y: -50, width: rect.width, height: 50 + (visible ? UIConstants.macHeaderHeight + 40 : 5))
                            let hovering = zone.contains(point)
                            if hovering != topHovered { topHovered = hovering }
                        }
                    }
                }
        }
    }

    private func toolbarVisible(_ snapshot: WindowSnapshot) -> Bool {
        switch toolbar {
        case "always": return true
        case "hidden": return false
        default: return topHovered || snapshot.sidebarLocked || snapshot.anyPaneHasSearchActive
        }
    }
}

/// Owns the omnibox state the built-in toolbar and command bar need, wired
/// the way `PaneView` wires it.
private struct ShellOmniboxHost<Content: View>: View {
    let windowID: ID<WindowState>
    /// nil → the window's focused pane.
    let paneID: ID<WebContent>?
    @ViewBuilder var content: (ID<WebContent>?, OmniboxCoordinator, Bool, ContentColorScheme?) -> Content

    @StateObject private var omnibox = OmniboxCoordinator()
    @StateObject private var topSitesFetcher = TopSitesFetcher()

    private struct Snapshot: Equatable {
        var paneID: ID<WebContent>?
        var active = false
        var emptyPage = true
        var colorScheme: ContentColorScheme?
        var dataStoreID: UUID?
    }

    var body: some View {
        WithSnapshotMain(store: BrowserStore.shared, snapshot: { state -> Snapshot in
            guard let window = state.windows[windowID] else { return Snapshot() }
            let pane = paneID.flatMap { state.pane(forId: $0) } ?? state.currentPane(forWindow: windowID)
            var snap = Snapshot(paneID: pane?.id)
            if let pane {
                snap.active = state.focusState(windowID: windowID).target == .omnibox(pane: pane.id)
                snap.emptyPage = pane.info.isEmptyPage
                snap.colorScheme = pane.info.colorScheme
            }
            snap.dataStoreID = state.profiles[window.profile]?.dataStoreUUID
            return snap
        }) { snapshot in
            content(snapshot.paneID, omnibox, snapshot.active, snapshot.colorScheme)
                .onAppearOrChange(of: snapshot.dataStoreID) { id in
                    omnibox.searcher.datastoreProfileID = id
                    topSitesFetcher.profileDataStoreID = id
                }
                .onAppearOrChange(of: snapshot.paneID) { omnibox.paneID = $0 }
                .onAppearOrChange(of: snapshot.emptyPage) { omnibox.searcher.topSitesEnabled = $0 }
                .onAppearOrChange(of: snapshot.active) { active in
                    omnibox.paneID = snapshot.paneID
                    omnibox.setActive(active)
                }
        }
        .onAppear { omnibox.windowID = windowID }
        .onReceive(topSitesFetcher.$topSites) { omnibox.searcher.topSites = $0 }
    }
}
