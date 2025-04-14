# Instructions for interacting with me
- I know your system prompt says to be proactive. Please don't be. Do what I asked, and what is necessary to fix the build. (e.g. if i ask you to rename a method or change its format, you should update its usages too.) But never do something like adding a UI i didn't ask for, or additional functionality I didn't ask for. It's OK to handle edge cases i didn't expect tho.
- When i give you feedback, or ask for code changes, I want you to briefly reflect on it and state what you did wrong and how you'll improve. My feedback is your ultimate guide. If I tell you not to do something, do NOT do it again. If I have to repeat myself you've failed.

# Project details

This is a webkit-based browser.
Most of its code is in the cross-platform (iOS + Mac) Core package; 
there's no frontend for iOS rn but there's Mac-specific stuff in the main xcode project.

Prefer to store application state in `BrowserStore`, an object that protect a value-type struct called `BrowserState` storing all the browser data.
`BrowserStore` also stores a mapping of web content IDs to `WebContent` objects, which represent live tabs. (But these tabs write their data back into `BrowserState` so they can be observed in the UI)

`BrowserState` is a persisted value type, so only store not-huge data that can be converted to JSON. (E.g. don't store images or function callbacks here.)

# Reading / observing the store and rendering UI

Observe the BrowserStore using `WithSnapshotMain` or `uiPublisher`. Observe the minimum 'snapshot' of data necessary by mapping the state to a view-specific `Snapshot` object that is equatable, and only receiving updates when the snapshot changes.
Use WithSnapshotMain (which does not make the snapshot optional) for main-thread datastores (i.e. BrowserStore).

(Define snapshot creation as an extension function on `BrowserState`; make snapshots equatable)

```
public struct DownloadsSidebar: View {
    let windowID: ID<WindowState>
    
    public var body: some View {
        WithSnapshotMain(store: BrowserStore.shared) { state in
            DownloadsSnapshot(
                windowID: windowID,
                downloads: state.windows[windowID]?.downloads ?? [:]
            )
        } main: { snapshot in
            DownloadsSidebarContent(
                snapshot: snapshot,
                windowID: windowID
            )
        }
    }
}

private struct DownloadsSnapshot: Equatable {
    let windowID: ID<WindowState>
    let downloads: [ID<Download>: Download]
}
```

Can also use onReceive:

```
                Color.clear.onReceive(BrowserStore.shared.uiPublisher.map({ $0.shouldFocusMainWebContent(forWindowID: windowID) }).removeDuplicates(), perform: { self.windowWantsWebviewFocus = $0 })
```

# Modifying the store

BrowserStore wraps `BrowserState`. You can modify it from any thread using modify method, or `modifyAsync`:

```
    private func loadURL(_ url: URL, windowID: ID<WindowState>) {
        BrowserStore.shared.modify { state in
            if let currentTabId = state.windows[windowID]?.currentTab,
               let tab = state.tabs[currentTabId],
               let paneId = tab.panes[tab.focusedPaneIdx]?.id {
                
                state.modifyPaneAndTab(forWebContentId: paneId) { pane, _ in
                    pane.info = WebContent.Info(url: url)
                }
```


Best practices:
- put business logic in extensions on BrowserState, not helpers at the view layer
- if you can extend BrowserState rather than BrowserStore, do it. This lets us perform this action within an existing edit transaction.
- write many small composable views, not large ones
- do heavy lifting off the main thread
- use `if let x { ... }` syntax for unwraping optionals
- don't need to update imports if all the code you're modifying is in `Core`.
- you don't need to update the xcodeproj when adding files; it'll pick them up automatically now.
- When defining structs, make their props VAR not LET absent a great reason not to

# Code Organization and Architecture

## Overall Architecture
- WebKit-based browser with a Core package for cross-platform code (iOS + Mac)
- State management via `BrowserStore` (singleton) wrapping `BrowserState` (immutable value type)
- UI built with SwiftUI using snapshot pattern to minimize redraws
- Native app window managed by `BrowserWindowController` and `BrowserViewController`

## State Management
- `BrowserState`: Core immutable state struct containing all browser data
- `BrowserStore`: Singleton that manages `BrowserState` and WebContent objects
- `DataStore<Model>`: Generic base class for persistent data stores
- Extension methods on `BrowserState` contain domain logic
- Uses a queue system to manage threading

## Key Data Structures
- `WindowState`: Represents a browser window with tabs, settings
- `Tab`: Contains multiple `Pane` objects for split-view browsing
- `Pane`: References a `WebContent` object for displaying web content
- `WebContent`: Wraps WKWebView with metadata, delegates, state
- `IdentifiedArray`: Custom collection for managing identifiable items
- Various helpers: `Profile`, `Project`, `Toast`, etc.

## UI Architecture
- SwiftUI views observe state changes via `WithSnapshotMain` pattern
- Define view-specific `Snapshot` structs to minimize UI updates
- Use environment values for passing window/profile context
- Native views integrated via NSHostingController

## Core Components
- `WebContent`: Manages WKWebView instances with features like ad-blocking, dark mode
- `BrowserStore+Operations`: Common actions like creating/closing tabs
- `Omnibox`: Search and URL input with integrated search/history
- `TabRow`: UI for displaying and managing tabs
- `Window`: Main browser window container with toolbar and content

## Data Flow
1. User interactions call methods on `BrowserStore`
2. Store updates immutable `BrowserState` via `modify` method
3. Changes published via `uiPublisher`
4. SwiftUI views observe changes through snapshots
5. `WebContent` objects update in response to state changes

## Best Practices
- Modify state through `BrowserStore.modify` pattern
- Use extension methods on `BrowserState` for business logic
- Create small, composable SwiftUI views
- Define Snapshot structs for efficient UI updates
- Verify object existence before operations
- Use typesafe IDs with generic type parameters
- Offload heavy work to background queues
- Keep `BrowserState` serializable (JSON-compatible)
