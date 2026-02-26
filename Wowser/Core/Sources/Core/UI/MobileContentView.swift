import SwiftUI
import WebKit
import Combine

/// A mobile-optimized content view that displays a WebView with a floating search button.
/// This component supports:
/// - A floating search button in the corner
/// - Swipe up on the search button to reveal tab thumbnails
/// - A mobile-friendly search overlay
public struct MobileContentView: View {
    let windowID: ID<WindowState>
    
    @Environment(\.windowID) private var environmentWindowID
    @Environment(\.profileID) private var profileID
    private let browserStore = BrowserStore.shared
    
    @State private var searchOverlayActive = false
    @State private var tabCarouselVisible = false
    @State private var dragStartLocation: CGPoint?
    @State private var dragCurrentLocation: CGPoint?
    
    private var resolvedWindowID: ID<WindowState> {
        windowID
    }
    
    public init(windowID: ID<WindowState>? = nil) {
        self.windowID = windowID ?? .assign()
    }
    
    public var body: some View {
        ZStack(alignment: .bottom) {
            // Main web content
            contentView
                .ignoresSafeArea()
            
            // Floating search button
            searchButton
            
            // Tab carousel (initially hidden, revealed by swiping up)
            if tabCarouselVisible {
                tabCarouselView
                    .transition(.move(edge: .bottom).combined(with: .opacity))
                    .zIndex(1)
            }
            
            // Search overlay
            if searchOverlayActive {
                mobileSearchOverlay
                    .transition(.opacity)
                    .zIndex(2)
            }
        }
        .animation(.spring(), value: tabCarouselVisible)
        .animation(.easeInOut(duration: 0.2), value: searchOverlayActive)
    }
    
    // MARK: - Content
    
    private var contentView: some View {
        WithSnapshotMain(store: browserStore) { state in
            WebContentSnapshot(
                windowID: resolvedWindowID,
                webContentID: state.windows[resolvedWindowID]?.currentTab.flatMap { tabId in
                    state.tabs[tabId]?.panes[state.tabs[tabId]?.focusedPaneIdx ?? 0]?.id
                }
            )
        } main: { snapshot in
            WebContentView(snapshot: snapshot, windowID: resolvedWindowID)
        }
    }
    
    // MARK: - Search Button
    
    private var searchButton: some View {
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
            // Show search overlay
            searchOverlayActive = true
        }
        .gesture(
            DragGesture(minimumDistance: 10, coordinateSpace: .global)
                .onChanged { value in
                    if dragStartLocation == nil {
                        dragStartLocation = value.startLocation
                    }
                    dragCurrentLocation = value.location
                    
                    // If dragged upward by enough distance, show tab carousel
                    if let start = dragStartLocation,
                       let current = dragCurrentLocation,
                       current.y < start.y - 50 {
                        // Show tab carousel when dragged up
                        tabCarouselVisible = true
                    }
                }
                .onEnded { _ in
                    dragStartLocation = nil
                    dragCurrentLocation = nil
                }
        )
    }
    
    // MARK: - Tab Carousel
    
    private var tabCarouselView: some View {
        VStack {
            Spacer()
            
            // Tab carousel
            MobileTabCarousel(windowID: resolvedWindowID)
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
    
    // MARK: - Mobile Search Overlay
    
    private var mobileSearchOverlay: some View {
        MobileSearchOverlay(
            windowID: resolvedWindowID,
            isPresented: $searchOverlayActive
        )
    }
}

// MARK: - WebContent Snapshot and View

private struct WebContentSnapshot: Equatable {
    let windowID: ID<WindowState>
    let webContentID: ID<WebContent>?
}

private struct WebContentView: View {
    let snapshot: WebContentSnapshot
    let windowID: ID<WindowState>
    
    var body: some View {
        Group {
            if let webContentID = snapshot.webContentID,
               let webContent = BrowserStore.shared.getOrCreateWebContent(
                forId: webContentID,
                toBeActiveInWindow: windowID
               ) {
                WebViewWrapper(webContent: webContent)
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
}

// WebViewWrapper to host the WebContent webview
private struct WebViewWrapper: View {
    let webContent: WebContent
    
    var body: some View {
        WrappedWebView(webview: webContent.webview)
            .onAppear {
                // Ensure the webview is fully visible and configured for mobile
                #if os(iOS)
                webContent.scrollEnabled = true
                #endif
            }
    }
}