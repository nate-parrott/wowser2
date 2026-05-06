# Project details (may be out of date)

This is a webkit-based browser.
Most of its code is in the cross-platform (iOS + Mac) Core package; 
there's no frontend for iOS rn but there's Mac-specific stuff in the main xcode project.

Prefer to store application state in `BrowserStore`, an object that protect a value-type struct called `BrowserState` storing all the browser data.
`BrowserStore` also stores a mapping of web content IDs to `WebContent` objects, which represent live tabs. (But these tabs write their data back into `BrowserState` so they can be observed in the UI)

`BrowserState` is a persisted value type, so only store not-huge data that can be converted to JSON. (E.g. don't store images or function callbacks here.)

## No I/O in derived getters

Computed properties on data-model types (`BrowserState`, `Tab`, `Pane`, `WebContent.Info`, `NativePageKey`, etc.) and on snapshot structs MUST be pure functions of the receiver's stored fields. They must NEVER touch the disk, the network, the keychain, NSPasteboard, NSWorkspace, or any other external state. SwiftUI re-evaluates these on every snapshot equality check and body re-render, so even one syscall per access becomes a per-frame syscall in practice.

If a view needs filesystem (or other external) state, observe it at the view layer: use `@State` populated once on appear / on path change, an async task, or a `Combine` publisher that pushes updates. Do not bake the syscall into a getter and call it from `body`.

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

## Working with DefaultsKeys

Always use the DefaultsKeys enum for accessing UserDefaults:

```swift
// Reading values
let isEnabled = DefaultsKeys.autoArchiveTabs.boolValue()
let apiKey = DefaultsKeys.openAIKey.stringValue()
let lastDate = DefaultsKeys.lastAutoArchiveDate.dateValue()

// Writing values
DefaultsKeys.autoArchiveTabs.setBool(true) // add this method if needed
DefaultsKeys.lastAutoArchiveDate.setDate(Date())
```

Benefits:
- Type-safe key access
- Centralized key definitions
- Better auto-completion
- Prevents typos in string keys

## Keyboard focus

All focus logic lives in `BrowserState+KeyboardFocus.swift`. Do not invent
focus signals elsewhere. Do not gate focus on view-local booleans like
`isFocused && !shrunk` — encode the distinction as a `FocusTarget` case.

`BrowserState.focusState(windowID:) -> FocusSnap` is the source of truth.
A focusable view does two things, no more:

1. Observe the snap (`.onReceiveFocusSnap(windowID:)`); when target matches
   your case, call `view.wowser_becomeFirstResponder(asTarget:)`. Never raw
   `makeFirstResponder` for state-driven focus.
2. When AppKit tells you a focus event actually happened, call
   `state.didFocus(target:)` / `state.didLoseFocus(target:)`.

Commands (Cmd+L, "open new tab") mutate state fields directly
(`searchOverlayActive`, `findInPageActiveInPaneId`). They are NOT focus
events — do not call `didFocus` from them.

For elements without a clean focus hook (SwiftTerm, SwiftUI Tables), wrap
them in `WrapsContentReportingFirstResponder`.

## Closing Tabs

When closing tabs, follow these principles:

1. Identify tabs to close outside of the modify block to avoid nested transactions:
```swift
// Get tabs to close
let tabsToClose = self.model.tabsToClose(...)

// Close them outside the modify block
for (_, paneID, _, _) in tabsToClose {
    close(webContentId: paneID, removeIfPinned: false)
}
```

2. Use BrowserState extensions for listing tabs to close and BrowserStore methods for actually closing:
```swift
// In BrowserState extension:
func tabsToClose(...) -> [(tabID: ID<Tab>, paneID: ID<WebContent>, ...)]

// In BrowserStore:
func close(webContentId: ID<WebContent>, removeIfPinned: Bool)
```

3. Archive tabs before closing when appropriate

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
- Use URLComponents for URL manipulation, not string concatenation

## URL Handling
When manipulating URLs, always use URLComponents rather than string manipulation:

```swift
// DON'T do this - vulnerable to encoding issues
let url = URL(string: "https://example.com/search?q=\(query)")!

// DO this instead - properly handles special characters
var components = URLComponents()
components.scheme = "https"
components.host = "example.com"
components.path = "/search"
components.queryItems = [URLQueryItem(name: "q", value: query)]
let url = components.url!
```

Benefits of using URLComponents:
- Properly handles special characters (spaces, unicode, emoji, etc.)
- Correctly percent-encodes and decodes URL components
- Prevents URL injection vulnerabilities
- Maintains URL structure consistency
- Makes code more robust against edge cases
- Follows Apple's recommended best practices
