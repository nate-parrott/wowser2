This is a webkit-based browser. Most of its code is in the cross-platform (iOS + Mac) Core package; 
there's no frontend for iOS rn but there's Mac-specific stuff in the main xcode project.

Prefer to store application state in `BrowserStore`, an object that protect a value-type struct called `BrowserState` storing all the browser data.
`BrowserStore` also stores a mapping of web content IDs to `WebContent` objects, which represent live tabs. (But these tabs write their data back into `BrowserState` so they can be observed in the UI)

`BrowserState` is a persisted value type, so only store not-huge data that can be converted to JSON. (E.g. don't store images or function callbacks here.)

Observe the store using `WithSnapshotMain` or `uiPublisher`. Observe the minimum 'snapshot' of data necessary by mapping the state to a view-specific `Snapshot` object that is equatable, and only receiving updates when the snapshot changes.
Use WithSnapshotMain (which does not make the snapshot optional) for main-thread datastores (i.e. BrowserStore).

(Define snapshot creation as an extension function on `BrowserState`; make snapshots equatable)

Best practices:
- put business logic in extensions on BrowserState, not helpers at the view layer
- write many small composable views, not large ones
- do heavy lifting off the main thread
- use `if let x { ... }` syntax for unwraping optionals
