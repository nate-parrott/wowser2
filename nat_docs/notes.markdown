This is a browser. Most of the logic is in Core. We care primarily about macOS, but cross-platform code is good, too.

We use data stores — threadsafe objects that wrap a struct state, which is a value type. You can modify these objects synchronously using store.model from their own queue, or async using store.asyncRead() or store.modify() or store.uiPublisher. You can only put plain old data in there — no classes or functions or callbacks. Observe state using WithSnapshot or the publisher. 

The most important data store is in BrowserState.

WebContent objects represent live tabs; the source of truth for tabs is in browser state. WebContents are created on-demand.

Tabs support multiple panes for split view. Every window has a profile.



