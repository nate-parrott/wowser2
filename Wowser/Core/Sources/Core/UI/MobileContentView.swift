import SwiftUI
import WebKit
import Combine

/// A mobile-optimized content view that displays a WebView with a floating search button
struct MobileContentView: View {
    @Environment(\.windowID) private var windowID
    
    @State private var searchOverlayActive = false
    @State private var tabCarouselVisible = false
    
    var body: some View {
        WithSnapshotMain(store: BrowserStore.shared) { state in
            MobileContentSnapshot(
                windowID: windowID,
                webContentID: state.activeWebContentId(forWindowID: windowID),
                currentTabId: state.windows[windowID]?.currentTab
            )
        } main: { snapshot in
            ZStack(alignment: .bottom) {
                // Main web content
                contentView(snapshot)
                    .ignoresSafeArea()
                
                // Floating search button
                FloatingSearchButton(
                    onTap: { searchOverlayActive = true },
                    onSwipeUp: { tabCarouselVisible = true }
                )
                
                // Tab carousel
                if tabCarouselVisible {
                    tabCarouselView
                        .transition(.move(edge: .bottom).combined(with: .opacity))
                        .zIndex(1)
                }
                
                // Search overlay
                if searchOverlayActive {
                    MobileSearchOverlay(
                        windowID: windowID,
                        isPresented: $searchOverlayActive
                    )
                    .transition(.opacity)
                    .zIndex(2)
                }
            }
            .animation(.spring(), value: tabCarouselVisible)
            .animation(.easeInOut(duration: 0.2), value: searchOverlayActive)
        }
    }
    
    // MARK: - Content View
    
    private func contentView(_ snapshot: MobileContentSnapshot) -> some View {
        Group {
            if let webContentID = snapshot.webContentID,
               let webContent = BrowserStore.shared.getOrCreateWebContent(
                forId: webContentID,
                toBeActiveInWindow: windowID
               ) {
                WebView(webContent: webContent)
                    .onAppear {
                        #if os(iOS)
                        webContent.scrollEnabled = true
                        #endif
                    }
            } else {
                // Placeholder for when no web content is available
                VStack {
                    Image(systemName: "globe")
                        .font(.system(size: 64))
                        .foregroundColor(.secondary)
                    Text("No web content to display")
                        .font(.headline)
                        .foregroundColor(.secondary)
                        .padding(.top)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .background(Color(.systemBackground))
            }
        }
    }
    
    // MARK: - Tab Carousel
    
    private var tabCarouselView: some View {
        VStack {
            Spacer()
            
            // Tab carousel
            MobileTabCarousel(windowID: windowID)
                .frame(height: 160)
                .padding(.bottom, 100) // Leave space for the search button
                .background(
                    RoundedRectangle(cornerRadius: 16)
                        .fill(Color(UIColor.systemBackground).opacity(0.95))
                        .shadow(color: Color.black.opacity(0.15), radius: 8, x: 0, y: -2)
                )
            
            // Dismiss button
            Button {
                tabCarouselVisible = false
            } label: {
                Image(systemName: "chevron.down")
                    .font(.system(size: 18, weight: .semibold))
                    .foregroundColor(.secondary)
                    .frame(width: 60, height: 30)
                    .background(
                        Capsule()
                            .fill(Color(UIColor.systemBackground))
                            .shadow(color: Color.black.opacity(0.1), radius: 2)
                    )
            }
            .padding(.bottom, 10)
        }
        .edgesIgnoringSafeArea(.bottom)
    }
}

// MARK: - Floating Search Button Component

struct FloatingSearchButton: View {
    let onTap: () -> Void
    let onSwipeUp: () -> Void
    
    @State private var dragStartLocation: CGPoint?
    @State private var dragCurrentLocation: CGPoint?
    
    var body: some View {
        ZStack {
            Circle()
                .fill(Color(UIColor.systemBackground))
                .shadow(color: Color.black.opacity(0.2), radius: 5, x: 0, y: 2)
            
            Image(systemName: "magnifyingglass")
                .font(.system(size: 20, weight: .semibold))
                .foregroundColor(.accentColor)
        }
        .frame(width: 60, height: 60)
        .padding(.bottom, 16)
        .padding(.trailing, 16)
        .frame(maxWidth: .infinity, alignment: .trailing)
        .contentShape(Rectangle())
        .onTapGesture {
            onTap()
        }
        .gesture(
            DragGesture(minimumDistance: 10, coordinateSpace: .global)
                .onChanged { value in
                    if dragStartLocation == nil {
                        dragStartLocation = value.startLocation
                    }
                    dragCurrentLocation = value.location
                    
                    // If dragged upward by enough distance, trigger swipe up
                    if let start = dragStartLocation,
                       let current = dragCurrentLocation,
                       current.y < start.y - 50 {
                        onSwipeUp()
                    }
                }
                .onEnded { _ in
                    dragStartLocation = nil
                    dragCurrentLocation = nil
                }
        )
    }
}

// MARK: - Data Models

/// Snapshot for mobile content view
struct MobileContentSnapshot: Equatable {
    let windowID: ID<WindowState>?
    let webContentID: ID<WebContent>?
    let currentTabId: ID<Tab>?
}

// MARK: - BrowserState Extensions

extension BrowserState {
    /// Gets the active web content ID for a window
    func activeWebContentId(forWindowID windowID: ID<WindowState>?) -> ID<WebContent>? {
        guard let windowID = windowID,
              let window = windows[windowID],
              let currentTabId = window.currentTab,
              let tab = tabs[currentTabId],
              let paneId = tab.panes[tab.focusedPaneIdx ?? 0]?.id else {
            return nil
        }
        
        return paneId
    }
}