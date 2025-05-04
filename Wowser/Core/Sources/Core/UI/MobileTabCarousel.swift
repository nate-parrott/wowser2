import SwiftUI

/// A horizontal carousel displaying tab thumbnails for mobile interface
struct MobileTabCarousel: View {
    let windowID: ID<WindowState>
    
    @State private var thumbnailSize: CGSize = CGSize(width: 220, height: 150)
    
    init(windowID: ID<WindowState>) {
        self.windowID = windowID
    }
    
    var body: some View {
        WithSnapshotMain(store: BrowserStore.shared) { state in
            state.mobileTabCarouselSnapshot(windowID: windowID)
        } main: { snapshot in
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 12) {
                    ForEach(snapshot.tabs, id: \.id) { tabData in
                        tabThumbnailView(tabData: tabData)
                    }
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 8)
            }
        }
    }
    
    private func tabThumbnailView(tabData: MobileTabData) -> some View {
        Button {
            // Switch to this tab when tapped
            BrowserStore.shared.modify { state in
                state.activate(tabId: tabData.id, in: windowID)
            }
        } label: {
            VStack(spacing: 8) {
                // Tab thumbnail
                ZStack {
                    if let paneId = tabData.mainPaneId {
                        // Thumbnail image
                        WithThumbnail(id: paneId) { image in
                            if let image = image {
                                Image(uiImage: image)
                                    .resizable()
                                    .aspectRatio(contentMode: .fill)
                                    .frame(width: thumbnailSize.width, height: thumbnailSize.height)
                                    .clipShape(RoundedRectangle(cornerRadius: 8))
                            } else {
                                // Placeholder
                                placeholderView(url: tabData.url, favicon: tabData.favicon)
                            }
                        }
                    } else {
                        // No pane available
                        placeholderView(url: nil, favicon: nil)
                    }
                    
                    // Selection indicator
                    if tabData.isCurrentTab {
                        RoundedRectangle(cornerRadius: 8)
                            .stroke(Color.accentColor, lineWidth: 3)
                            .frame(width: thumbnailSize.width, height: thumbnailSize.height)
                    }
                }
                
                // Tab title
                Text(tabData.title)
                    .font(.system(size: 13))
                    .lineLimit(1)
                    .truncationMode(.tail)
                    .frame(width: thumbnailSize.width)
                    .foregroundColor(.primary)
            }
        }
        .buttonStyle(PlainButtonStyle())
    }
    
    private func placeholderView(url: URL?, favicon: URL?) -> some View {
        ZStack {
            Color(UIColor.systemGray6)
                .frame(width: thumbnailSize.width, height: thumbnailSize.height)
                .clipShape(RoundedRectangle(cornerRadius: 8))
            
            if let url = url {
                // Show favicon if available
                FaviconView(url: url, faviconURL: favicon, size: 32)
            } else {
                // Show globe icon if no URL
                Image(systemName: "globe")
                    .font(.system(size: 32))
                    .foregroundColor(.secondary)
            }
        }
    }
}

// MARK: - Data Models

/// Data needed for a single tab in the carousel
struct MobileTabData: Equatable, Identifiable {
    let id: ID<Tab>
    let title: String
    let mainPaneId: ID<WebContent>?
    let url: URL?
    let favicon: URL?
    let isCurrentTab: Bool
}

/// Snapshot for mobile tab carousel view
struct MobileTabCarouselSnapshot: Equatable {
    let tabs: [MobileTabData]
}

// MARK: - BrowserState Extensions

extension BrowserState {
    /// Creates a snapshot for the mobile tab carousel
    func mobileTabCarouselSnapshot(windowID: ID<WindowState>) -> MobileTabCarouselSnapshot {
        guard let window = windows[windowID] else { return MobileTabCarouselSnapshot(tabs: []) }
        
        // Sort tabs by last accessed date
        let sortedTabIds = tabsInRecencyOrder(forWindow: windowID)
        
        // Create tab data for each tab
        let tabData = sortedTabIds.compactMap { tabId -> MobileTabData? in
            guard let tab = tabs[tabId] else { return nil }
            
            // Get main pane
            let pane = tab.panes.first
            let paneId = pane?.id
            
            return MobileTabData(
                id: tabId,
                title: pane?.info.title ?? pane?.info.url?.host ?? "New Tab",
                mainPaneId: paneId,
                url: pane?.info.url,
                favicon: pane?.info.favicon,
                isCurrentTab: window.currentTab == tabId
            )
        }
        
        return MobileTabCarouselSnapshot(tabs: tabData)
    }
    
    /// Get tab IDs sorted by recency (most recently accessed first)
    func tabsInRecencyOrder(forWindow windowID: ID<WindowState>) -> [ID<Tab>] {
        guard let window = windows[windowID] else { return [] }
        
        return window.tabs.compactMap { tabID in
            tabs[tabID]
        }
        .sorted { $0.lastAccessed > $1.lastAccessed }
        .map { $0.id }
    }
}