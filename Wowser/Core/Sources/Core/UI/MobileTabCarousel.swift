import SwiftUI

/// A horizontal carousel displaying tab thumbnails in recency order.
/// Used in the mobile interface to quickly switch between tabs.
public struct MobileTabCarousel: View {
    let windowID: ID<WindowState>
    
    @State private var thumbnailSize: CGSize = CGSize(width: 220, height: 150)
    
    public init(windowID: ID<WindowState>) {
        self.windowID = windowID
    }
    
    public var body: some View {
        WithSnapshotMain(store: BrowserStore.shared) { state in
            MobileTabCarouselSnapshot(
                windowID: windowID,
                tabIDs: tabIDsInRecencyOrder(state)
            )
        } main: { snapshot in
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 12) {
                    ForEach(snapshot.tabIDs, id: \.self) { tabID in
                        tabThumbnailView(for: tabID)
                    }
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 8)
            }
        }
    }
    
    private func tabIDsInRecencyOrder(_ state: BrowserState) -> [ID<Tab>] {
        guard let window = state.windows[windowID] else { return [] }
        
        // Sort tabs by lastAccessed date (most recent first)
        return window.tabs.compactMap { tabID in
            state.tabs[tabID]
        }
        .sorted { $0.lastAccessed > $1.lastAccessed }
        .map { $0.id }
    }
    
    private func tabThumbnailView(for tabID: ID<Tab>) -> some View {
        WithSnapshotMain(store: BrowserStore.shared) { state in
            TabThumbnailSnapshot(
                tabID: tabID,
                tab: state.tabs[tabID],
                isCurrentTab: state.windows[windowID]?.currentTab == tabID
            )
        } main: { snapshot in
            if let tab = snapshot.tab {
                Button {
                    // Switch to this tab when tapped
                    BrowserStore.shared.modify { state in
                        state.activate(tabId: tabID, in: windowID)
                    }
                } label: {
                    VStack(spacing: 8) {
                        // Tab thumbnail with WebContent preview
                        if let pane = tab.panes.first {
                            ZStack {
                                // Thumbnail image
                                WithThumbnail(id: pane.id) { image in
                                    if let image = image {
                                        Image(uiImage: image)
                                            .resizable()
                                            .aspectRatio(contentMode: .fill)
                                            .frame(width: thumbnailSize.width, height: thumbnailSize.height)
                                            .clipShape(RoundedRectangle(cornerRadius: 8))
                                    } else {
                                        // Placeholder when no thumbnail is available
                                        placeholderView(for: pane)
                                    }
                                }
                                
                                // Selection indicator
                                if snapshot.isCurrentTab {
                                    RoundedRectangle(cornerRadius: 8)
                                        .stroke(Color.accentColor, lineWidth: 3)
                                        .frame(width: thumbnailSize.width, height: thumbnailSize.height)
                                }
                            }
                            
                            // Tab title
                            Text(tabTitle(for: pane))
                                .font(.system(size: 13))
                                .lineLimit(1)
                                .truncationMode(.tail)
                                .frame(width: thumbnailSize.width)
                                .foregroundColor(.primary)
                        }
                    }
                }
                .buttonStyle(PlainButtonStyle())
            }
        }
    }
    
    private func placeholderView(for pane: Pane) -> some View {
        ZStack {
            Color(UIColor.systemGray6)
                .frame(width: thumbnailSize.width, height: thumbnailSize.height)
                .clipShape(RoundedRectangle(cornerRadius: 8))
            
            if let url = pane.info.url {
                // Show favicon if available
                FaviconView(url: url, faviconURL: pane.info.favicon, size: 32)
            } else {
                // Show globe icon if no URL
                Image(systemName: "globe")
                    .font(.system(size: 32))
                    .foregroundColor(.secondary)
            }
        }
    }
    
    private func tabTitle(for pane: Pane) -> String {
        return pane.info.title ?? pane.info.url?.displayString ?? "New Tab"
    }
}

// Snapshot structs
private struct MobileTabCarouselSnapshot: Equatable {
    let windowID: ID<WindowState>
    let tabIDs: [ID<Tab>]
}

private struct TabThumbnailSnapshot: Equatable {
    let tabID: ID<Tab>
    let tab: Tab?
    let isCurrentTab: Bool
}

// Helper extension to get a display string for URLs
private extension URL {
    var displayString: String {
        guard let host = self.host else { return self.absoluteString }
        return host
    }
}