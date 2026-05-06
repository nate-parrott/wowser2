# Super-App Browser — Technical Spec

**Purpose:** Feed this to a coding agent. It describes how to extend an existing
Swift/WKWebView browser into a super-app with terminal, VS Code, file-browser,
and generative-app tabs, fronted by an MCP server that exposes a JS automation
environment called **BrowserJS**.

**Legend:**

- **[SPEC]** = decision/requirement stated by the project owner. Treat as authoritative.
- **[RESEARCH]** = implementation detail supplied by the assistant from docs/web. Feel free to do it differently if there's a good readson.

-----

## 0. Existing baseline [SPEC]

- Native macOS app, Swift, AppKit/SwiftUI.
- Browser tabs are `WKWebView` instances.
- There is already a custom JS↔Swift bridge and a VFS-based session system.
- Tab container/chrome already exists; new tab *content types* slot into it.

-----

## 1. Terminal tabs — SwiftTerm

### Decisions [SPEC]

- Use **SwiftTerm** for the terminal content view. Do **not** use libghostty for now.
- Terminal tabs are first-class tab content alongside web tabs.

### Implementation notes [RESEARCH]

- Package: `https://github.com/migueldeicaza/SwiftTerm` (SPM).
- Use `LocalProcessTerminalView` (AppKit `NSView` subclass) — it owns the PTY
  and spawns the shell for you. Wrap in `NSViewRepresentable` if the tab
  container is SwiftUI.
- Minimal embed:
  
  ```swift
  import SwiftTerm
  
  final class TerminalTabView: NSView, LocalProcessTerminalViewDelegate {
      let term = LocalProcessTerminalView(frame: .zero)
      init(cwd: String, env: [String: String]) {
          super.init(frame: .zero)
          term.processDelegate = self
          addSubview(term); term.frame = bounds
          term.autoresizingMask = [.width, .height]
          var envArr = Terminal.getEnvironmentVariables(termName: "xterm-256color")
          env.forEach { envArr.append("\($0.key)=\($0.value)") }
          term.startProcess(
              executable: "/bin/zsh",
              args: ["-l"],
              environment: envArr,
              execName: nil,
              currentDirectory: cwd
          )
      }
      required init?(coder: NSCoder) { fatalError() }
      // delegate stubs: sizeChanged / setTerminalTitle / hostCurrentDirectoryUpdate / processTerminated
  }
  ```
- To spawn **Claude Code** inside a terminal tab, call `startProcess` with
  `executable: "/bin/zsh", args: ["-lc", "claude <flags>"]` so PATH is resolved.
- Resize: forward container size changes; `LocalProcessTerminalView` handles
  `TIOCSWINSZ` internally.

-----

## 2. VS Code tabs — `code serve-web` from existing install

### Decisions [SPEC]

- Require VS Code to already be installed on the machine. Do **not** bundle
  code-server or openvscode-server.
- A “VS Code tab” is a `WKWebView` pointed at a locally spawned `code serve-web`
  instance.
- This is what provides the file sidebar, ⌘P quick-open, command palette, and
  other “VS Code goodies” — we are not reimplementing them natively.

### Implementation notes [RESEARCH]

- CLI binary location (macOS): typically
  `/Applications/Visual Studio Code.app/Contents/Resources/app/bin/code`.
  Fallbacks: `which code`, then
  `mdfind "kMDItemCFBundleIdentifier == com.microsoft.VSCode"`.
- Spawn:
  
  ```swift
  func launchVSCodeServer(folder: URL, dataDir: URL) throws -> (Process, URL) {
      let p = Process()
      p.executableURL = URL(fileURLWithPath: codeBinaryPath)
      p.arguments = [
          "serve-web",
          "--host", "127.0.0.1",
          "--port", "0",                      // OS picks free port
          "--without-connection-token",
          "--accept-server-license-terms",
          "--user-data-dir", dataDir.path,
          folder.path
      ]
      let out = Pipe(); p.standardOutput = out; p.standardError = out
      try p.run()
      // Read stdout until line matching:  Web UI available at http://127.0.0.1:<port>
      let url = try parseServeWebURL(from: out)
      return (p, url)
  }
  ```
- Load `url` in a `WKWebView`. Terminate the `Process` when the tab closes.
- First run downloads server bits (~100 MB) into
  `~/.vscode/cli/serve-web/<commit>/`; subsequent runs are instant. Surface a
  spinner on first launch.
- License: VS Code Server is single-user, not redistributable. Acceptable for a
  personal tool; do not ship this configuration commercially.
- Isolation: use a distinct `--user-data-dir` per tab if independent
  windows/extensions are desired; share one to share state.

-----

## 3. File-browser tabs

### Decisions [SPEC]

- Provide a file-browser tab content type.
- The heavy “sidebar + quick-open + palette” experience is delegated to the
  VS Code tab (Section 2). The native file-browser tab is a lighter view.

### Implementation notes [RESEARCH]

- No good drop-in library. Build on:
  - `NSOutlineView` (or SwiftUI `List` + `OutlineGroup` / `DisclosureGroup`)
    backed by `FileManager` enumeration with lazy children.
  - `QLPreviewView` for the right-hand preview pane.
  - Optional: `amosavian/FileProvider` to abstract local / iCloud / SMB / WebDAV
    if remote roots are wanted later.
- Expose “Open in VS Code tab” / “Open terminal here” context actions that
  spawn the corresponding tab types at the selected path.

-----

## 4. MCP server (Swift) + channels

### Decisions [SPEC]

- The app runs an MCP server so agents (Claude Code in a terminal tab, or
  external) can drive the browser.
- The MCP surface is intentionally small (Section 6). All real capability lives
  inside the **BrowserJS** runtime (Section 5); the agent writes JS, not dozens
  of bespoke tool calls.
- Support **channels** so the browser can push events (tab opened, navigation
  finished, network request captured) into the agent session unprompted.

### Implementation notes [RESEARCH]

- Library: official **`modelcontextprotocol/swift-sdk`** (SPM,
  `import MCP`). Provides `Server`, `Tool`, `StdioTransport`, `HTTPTransport`.
- Run the server on `127.0.0.1:<randomPort>` with HTTP transport so multiple
  clients can attach (terminal-tab Claude Code, external agents).
- Wiring into Claude Code spawned in a terminal tab — two supported routes:
1. Pass `--mcp-config '<inline JSON>'` (and optionally `--strict-mcp-config`)
   on the `claude` command line:
   
   ```json
   {"mcpServers":{"superapp":{"type":"http","url":"http://127.0.0.1:PORT/mcp"}}}
   ```
1. Or write a `.mcp.json` in the working directory using env-var expansion and
   export `SUPERAPP_MCP_URL` into the spawned process:
   
   ```json
   {"mcpServers":{"superapp":{"type":"http","url":"${SUPERAPP_MCP_URL}"}}}
   ```
- Channels: declare the `claude/channel` capability on the server; spawn
  `claude` with `--channels`. Push via the channel when `WKNavigationDelegate`
  fires `didFinish`, when a tab is created/closed, or when the proxy logs a
  matching request (Section 7).

-----

## 5. BrowserJS runtime

### Concept [SPEC]

- **BrowserJS** is an async JS environment, hosted by the Swift app, that the
  agent executes code inside via the `run_browser_js` MCP tool.
- It is **not** the page’s JS context. It is a privileged orchestration context
  with a global `browser` object whose methods are backed by Swift.
- Two operating modes the agent can mix freely:
  - **Visual / JS-based browser use** — open real tabs, run JS inside their
    `WKWebView`s, read back DOM/content. The user sees it happen.
  - **Synthetic browser use** — skip rendering; hit HTTP endpoints directly
    using cookies/headers captured by the proxy (Section 7). Faster and
    headless.
- **Helper files** (Section 6) are JS preambles injected at the top of every
  BrowserJS evaluation, so the agent can persist reusable functions across
  calls.
- **Webapps**: the agent can create a new tab whose content is static HTML it
  supplies, and that HTML has BrowserJS available (via the bridge) so the page
  itself can orchestrate the browser. This is the “generative apps” tab type.

### Required `browser.*` surface [SPEC]

The owner specified these capability buckets. Exact names below are a proposal;
keep the buckets.

```ts
// Tabs — open / move / inspect
browser.tabs.list(): Promise<TabInfo[]>
browser.tabs.open(url: string, opts?: {background?: boolean}): Promise<TabId>
browser.tabs.openHTML(html: string, opts?: {title?: string}): Promise<TabId>
browser.tabs.close(id: TabId): Promise<void>
browser.tabs.activate(id: TabId): Promise<void>
browser.tabs.move(id: TabId, toIndex: number): Promise<void>
browser.tabs.get(id: TabId): Promise<TabInfo>        // url, title, kind, index

// Content — read / write
browser.content.read(id: TabId, opts?: {as?: "text"|"html"|"markdown"}): Promise<string>
browser.content.write(id: TabId, html: string): Promise<void>   // only valid for html/webapp tabs
browser.content.screenshot(id: TabId): Promise<string /* base64 png */>

// In-page JS execution (visual mode)
browser.page.eval(id: TabId, js: string): Promise<any>          // runs in the page's WKWebView
browser.page.waitFor(id: TabId, predicateJs: string, timeoutMs?: number): Promise<any>

// Webapps (generative app tabs)
browser.webapp.create(opts: {
  name: string,
  html: string,                 // static HTML entrypoint
  exposeBrowserJS?: boolean     // default true: page gets window.browser
}): Promise<TabId>

// Network log + synthetic requests (backed by proxy, Section 7)
browser.net.log(filter?: {tabId?: TabId, urlRegex?: string, method?: string,
                          since?: number, limit?: number}): Promise<NetEntry[]>
browser.net.grep(pattern: string, where?: "url"|"reqBody"|"resBody"|"headers"): Promise<NetEntry[]>
browser.net.fetch(req: {
  url: string, method?: string, headers?: Record<string,string>,
  body?: string,
  cookiesFrom?: TabId | "domain"   // attach captured cookies for that origin
}): Promise<{status:number, headers:Record<string,string>, body:string}>
browser.net.replay(entryId: string, overrides?: Partial<NetEntry["request"]>): Promise<...>

// Misc
browser.sleep(ms: number): Promise<void>
browser.log(...args: any[]): void   // surfaces in MCP tool result
```

### Host implementation notes [RESEARCH]

- Host the BrowserJS context in either:
  - a hidden `WKWebView` with `about:blank` (simplest; reuse existing bridge), or
  - an embedded `JavaScriptCore` `JSContext` (lighter, no DOM, fine since
    BrowserJS doesn’t need one).
- Each `browser.*` method posts to Swift via
  `webkit.messageHandlers.browserjs.postMessage({id, fn, args})` (or
  `JSContext` native callbacks), Swift performs the action, resolves the
  promise by calling back with `{id, ok, value|error}`.
- `browser.page.eval` → `webView.callAsyncJavaScript(_:arguments:in:in:)` on the
  target tab’s `WKWebView`.
- `browser.tabs.openHTML` / `browser.webapp.create` → `webView.loadHTMLString`.
  For webapps with `exposeBrowserJS`, inject the BrowserJS client shim as a
  `WKUserScript` at `.atDocumentStart`.
- `browser.content.read(as:"markdown")` → run a Readability + Turndown snippet
  via `page.eval`, or do it Swift-side.

-----

## 6. MCP tool surface

### Tools [SPEC]

Exactly these four tools are exposed over MCP:

|Tool                      |Args                               |Returns                                           |Semantics                                                                                                                                                                      |
|--------------------------|-----------------------------------|--------------------------------------------------|-------------------------------------------------------------------------------------------------------------------------------------------------------------------------------|
|`run_browser_js`          |`{ code: string }`                 |`{ result?: any, logs: string[], error?: string }`|Prepend all helper files (alpha order), then `code`, evaluate in the BrowserJS context, await the final expression, JSON-serialize.                                            |
|`save_browser_helper_file`|`{ name: string, content: string }`|`{ ok: true }`                                    |Persist a helper. Helpers are JS source prepended to every `run_browser_js` evaluation and to every webapp’s BrowserJS shim. Overwrites by name.                               |
|`read_browser_helper_file`|`{ name?: string }`                |`{ files: {name,content}[] }`                     |Return one helper or list all.                                                                                                                                                 |
|`get_browser_js_docs`     |`{}`                               |`{ dts: string }`                                 |Return the commented TypeScript declaration source for the `browser.*` API (the block in Section 5, kept in-repo as `BrowserJS.d.ts`). Agents call this first to learn the API.|

### Notes [RESEARCH]

- Store helpers on disk (e.g.
  `~/Library/Application Support/<app>/browserjs/helpers/*.js`) so they survive
  restarts. Concatenate in stable order.
- `run_browser_js` should wrap `code` in an async IIFE so top-level `await`
  works:
  
  ```js
  (async () => { /* helpers */; /* code */ })()
  ```
- Cap result payload size; truncate with a note rather than blowing up the MCP
  transport.

-----

## 7. Local intercepting proxy (network capture)

### Decisions [SPEC]

- Run a local HTTP(S) proxy inside the app and **force all `WKWebView` traffic
  through it**.
- The proxy is **trusted-by-default for our own webviews only** — no system
  keychain modification, no admin auth. We override
  `WKNavigationDelegate.webView(_:didReceive:completionHandler:)` (and the
  matching `URLSessionDelegate` callback) to accept our private CA. The CA
  lives in the app's data dir; the rest of the OS never sees it.
- **Capture is opt-in per origin.** By default the proxy passes traffic
  through and logs nothing. There is a hidden allowlist of origins for which
  we record traffic to encrypted SQLite. BrowserJS exposes a hook
  (`browser.net.captureOrigin(origin: string, enabled: boolean)` etc.) to
  add/remove entries. Rationale: privacy by default — we don't want raw
  request/response bodies for the user's banking, email, work SSO sitting on
  disk just because they happened to load.
- **Apple-property denylist.** Apple-controlled hosts (iCloud, App Store,
  push.apple.com, gsa.apple.com, Mac App Store services, …) are pinned by
  WebKit and cannot be MITM'd; our proxy bypasses them (passes the CONNECT
  through unmodified) instead of generating broken TLS. Other cert-pinning
  failures we encounter at runtime get added to a runtime denylist for the
  session.
- The capture log feeds BrowserJS `browser.net.*` for read/grep and for
  synthesizing new requests using cookies captured from real browser
  traffic (synthetic browser use).
- Storage at rest: SQLite encrypted with a key stored in the macOS Keychain
  (per-user, app-scoped). Bodies > 5 MB and audio/video MIME types are
  dropped at capture time; time-based eviction at 24h, with a user-visible
  "clear network log" button.

### Implementation notes [RESEARCH]

- Forcing the proxy (macOS 14+):
  
  ```swift
  let endpoint = NWEndpoint.hostPort(host: "127.0.0.1",
                                     port: NWEndpoint.Port(integerLiteral: proxyPort))
  let cfg = ProxyConfiguration(httpCONNECTProxy: endpoint)
  let store = WKWebsiteDataStore.default()   // or .nonPersistent()
  store.proxyConfigurations = [cfg]
  webViewConfiguration.websiteDataStore = store
  ```
  
  This routes **all** subresource traffic — fetch, XHR, images, WebSockets —
  through the proxy. `WKNavigationDelegate` alone does **not** see XHR/fetch.
- Proxy implementation options:
  - Pure Swift: `swift-nio` + `swift-nio-ssl`. Handle `CONNECT`, terminate TLS
    with a per-host leaf cert signed by a locally generated CA, re-originate
    upstream. (~200–400 LoC for a minimal MITM.)
  - Subprocess: bundle/spawn `mitmproxy` (`mitmdump --listen-port N -s addon.py`)
    and have the addon POST entries to the app over a localhost socket. Faster
    to stand up; adds a Python dependency.
- CA trust: generate a root CA on first run, store in Keychain, add to system
  trust (requires user approval once). Without this, HTTPS bodies are opaque.
- Storage: append entries to SQLite
  (`id, ts, tabId?, method, url, status, reqHeaders, reqBody, resHeaders, resBody, cookieJarSnapshot`).
  Index `url` and `ts`. `browser.net.grep` = `LIKE`/FTS query.
- Correlating entry → tab: inject a per-tab `WKUserScript` that sets a custom
  header (e.g. `X-SuperApp-Tab: <id>`) on `fetch`/XHR; the proxy reads it. Main
  document loads can be tagged via a custom UA suffix or by setting the header
  in `decidePolicyFor`. Not 100% (some opaque subresources won’t carry it) —
  acceptable.
- `browser.net.fetch` with `cookiesFrom`: read the `WKHTTPCookieStore` for the
  target origin (or the latest `Set-Cookie` seen by the proxy for that domain),
  attach as `Cookie:` header, perform the request with `URLSession` from Swift
  (bypassing the webview entirely). This is the synthetic path.

### Implementation spec details

We have an existing system for rendering native pages by defining special url schemes, parsing them, and producing native overlays. We should use this.

We should add search providers that search for folders and allow opening in the file browser, coding agent or terminal, and also special actions for opening 'terminal' and file browser.

-----

## 8. Open questions for the project owner

Answer inline (delete the bullet, write the answer, or annotate `[A: …]`).
Each block ends with a "default if unanswered" — what the agent should
assume so it can keep moving.

### 8.1 Sandbox / distribution — blocking

`Wowser.entitlements` currently has `com.apple.security.app-sandbox = true`
plus Hardened Runtime. **Most of this spec is incompatible with the sandbox:**

- SwiftTerm spawning `/bin/zsh` via `posix_spawn` — sandbox blocks arbitrary
  process spawn (only narrowly allowed via `NSTask` to bundled helpers).
- Spawning `code serve-web` from `/Applications/...` — outside container,
  blocked.
- Spawning `mitmproxy` — same.
- Installing a MITM root CA into the System keychain trust store —
  requires `SecTrustSettingsSetTrustSettings` admin auth, not possible
  from a sandboxed app.
- Reading arbitrary file paths for the file browser — only via
  user-selected security-scoped bookmarks.

Questions:

- **Q1.** Drop the App Sandbox entirely for this build (notarized + Developer
  ID signed, distributed outside MAS)? This is what Warp / iTerm / VS Code /
  Cursor do.
  [A: YES! Drop sandbox.]
- **Q2.** If we drop the sandbox, do we still want Hardened Runtime + the
  `allow-jit`, `allow-unsigned-executable-memory`,
  `allow-dyld-environment-variables`, `inherit` entitlements that subprocesses
  may need? Or full unrestricted runtime?
  [A: You tell me; probably want to drop all of them.]
- **Q3.** Is Mac App Store distribution a non-goal forever, or just for the
  super-app build? Should we have two targets / two configurations?

  [A: MAS is a non-goal]
- **Q4.** Are you OK with the user being prompted once for admin auth on
  first run to install the MITM root CA?
  [A: Sure, but is that necessary? Do we really need admin to trust the cert for our own app's webviews?]

### 8.2 Existing JS bridge / VFS — clarification needed

§0 says "There is already a custom JS↔Swift bridge and a VFS-based session
system." I cannot find either in `Core`:

- No `WKScriptMessageHandler` / `messageHandlers` / `WKUserContentController`
  usage other than ad-block rule lists.
- No `WKURLSchemeHandler` / `setURLSchemeHandler`.
- No `postMessage` plumbing.
- "GeneratedPages" exists (`GeneratedPageKey`, `ByInjectingGeneratedPages`)
  but it works by `evaluateJavaScript` mutating `document.documentElement.innerHTML`
  on `about:blank?...` URLs — not a bidirectional bridge.

Questions:

- **Q5.** Where is the bridge? Branch, sibling repo, or planned-but-not-built?
[A: Sorry, it's not built, you should build it!]

- **Q6.** What is the "VFS-based session system" — `WKWebsiteDataStore(forIdentifier:)`
  per-profile (which I see), or a separate file-system abstraction?
[A: Sorry, not present and i don't even know why we need this. Drop it?]

- **Q7.** If neither exists yet, is building the bridge for BrowserJS in
  scope for this project, or is there prior art we should pull in?
  [A: in scope]

### 8.3 Tab-content model refactor — design choice

Today every tab is web: `Tab.panes: IdentifiedArray<Pane>`, each `Pane` has
`info: WebContent.Info` keyed by URL, and live tabs are `WebContent` objects
in `BrowserStore.liveWebContents`. There is no notion of a non-web tab kind,
and `WebContent` directly owns a `WKWebView`.

Questions:

- **Q8.** Preferred refactor strategy for non-web tabs?
  - **(a)** Add `enum PaneKind { case web(...); case terminal(...); case vscode(...); case files(...); case webapp(...) }` and refactor `WebContent` into a `TabContent` protocol with multiple implementations. *Most invasive, cleanest.*
  - **(b)** Keep `WebContent` but back terminal/files/etc. with a hidden WKWebView and treat the AppKit overlay (SwiftTerm, NSOutlineView) as a sibling layer per-tab. *Less invasive, awkward.*
  - **(c)** Render *everything* in WKWebView — terminal via xterm.js, VS Code already is, files via a custom HTML page. *Trades native quality for uniformity.*

[A: let's use B. Look at how GeneratedPageKey works and parses a key from a URL, and how the Reader overlay works. Add a new NativePageKey enum that represents these content types and converts to/from URL; when the webview navigates to such a URL, display the native UI as an overlay, the same way we do for Reader. intercept and add overlay in WrappedWebView. Then update tabAppearance to render these as special tab appearances]

- **Q9.** Should non-web tabs be splittable (mix a terminal pane next to a web pane)? If yes, does the existing `panes: IdentifiedArray<Pane>` need to hold heterogeneous kinds?
[A: yes, we get this with the approach above for free]

- **Q10.** What restores after app restart for each non-web kind?
  - Terminal: cwd + last command? cwd only? Don't restore?
  - VS Code: folder URL only (server respawns)?
  - File browser: last directory + selection?
  - Webapp: persisted HTML + tab metadata?

[A: Whatever works for free; dont worry too mcuh abt it]

- **Q11.** Per CLAUDE.md, `BrowserState` is JSON-persisted. Webapp HTML can be large. Store HTML inline, or in a side store keyed by webapp ID (like `GeneratedPageStore`)?

[A: store on disk at hidden paths]

### 8.4 iOS scope

`Core` is cross-platform (`#if os(iOS)` branches throughout) and there's a
`TangerineMobile` target. None of the proposed features have iOS analogues
(no PTY, no `code serve-web`, no `proxyConfigurations` parity, no fs access).

- **Q12.** Is this whole project Mac-only? Should new code live entirely
  outside iOS compilation, or do we keep stubs/no-ops for iOS?

*Default if unanswered:* Mac-only; all new code under `#if os(macOS)` or in
a Mac-only sub-module.

[A: mac only (but dont break the ios build)]

### 8.5 BrowserJS runtime — host & semantics

- **Q13.** Host the BrowserJS context in `JavaScriptCore` (`JSContext`) or a
  hidden `WKWebView`? `JSContext` is lighter and lets us bind Swift functions
  directly via `JSExport`; hidden WKWebView reuses the bridge but pulls in DOM.
  Preference?

[A: use JSContext; expose bridge methods to run JS in a webview, though.]

- **Q14.** One BrowserJS context shared across all MCP clients, or one per
  client/session? (Affects whether helpers and global state are shared.)

[A: shared across all clients]

- **Q15.** What window is "the active window" for `browser.tabs.open` etc.
  when called from MCP? Most-recently-focused window? The window the agent
  was spawned from (terminal-tab parent)? Should every call optionally take
  `windowId`?

[A: ideally terminal-tab parent, but window ID should be an optional arg so we can act on different windows. or maybe we have a browserWindow object and can call getWindowById() or getCurrentWindow() to grab the releavnt window?]

- **Q16.** Concurrency: should two simultaneous `run_browser_js` calls run
  in parallel, or be serialized through a queue? Parallel is faster but
  shared mutable state in helpers gets weird.

[A: serial single threaded; should hvae support for async calls]

- **Q17.** Time/size caps: max execution time per `run_browser_js`? Max
  result-payload bytes before truncation? Max log lines? Specify or take
  defaults (e.g. 60s / 1 MB / 1000 lines)?

[A: something reasonable]

- **Q18.** Helper-file load order: alpha as specified — fine for hygiene,
  but what about a helper that depends on another? Is `// @requires foo.js`
  in scope or should helpers be flat?

  [A: alpha]

### 8.6 MCP server lifecycle & auth

- **Q19.** Transport: spec says HTTP for multi-client. Confirm — vs.
  preferring `stdio` for the in-app terminal-tab Claude Code and HTTP only
  for external? Mixed is supported by `swift-sdk` but adds work.

    [A: http, but dont allow connections from other clients]

- **Q20.** Auth: bind to `127.0.0.1` only, no token? Or generate a per-launch
  bearer token and require it? Loopback-only is normally fine but other
  local apps could probe it.
- **Q21.** Server lifecycle: start at app launch and live forever? Lazy on
  first agent connection? Survive app backgrounding? Behavior on app quit
  with active sessions?

[A: start at launchm live forever]

- **Q22.** Is "claude/channel" really the agreed name and shape? The
  Claude Code public docs don't yet describe a stable `claude/channel`
  capability or a `--channels` flag — I want to confirm before we lean on
  it. If unconfirmed, what's the fallback for server→agent push (e.g.
  emit MCP `notifications/...` and rely on the agent polling, or a separate
  WebSocket tap)?

  [A: let's ignroe channel for now]

*Default if unanswered:* HTTP-only on `127.0.0.1:<random>`, per-launch
bearer token in env var, started at launch, killed on app quit, channels
treated as a stretch goal — phase 1 ships push via MCP `notifications/`
plus agent-side polling.

### 8.7 Network proxy — scope & privacy

- **Q23.** Pure-Swift NIO MITM (~few hundred LoC) or bundle/spawn `mitmproxy`?
  Pure-Swift avoids a Python dep but is more code to maintain.
  [A: pure-swift]
- **Q24.** Per-profile data stores: do we install the proxy config on
  *every* profile's `WKWebsiteDataStore`, or only the active one?
  (Profiles are per-`Profile.dataStoreUUID` per `WebContent.swift`.)
  [A: all]
- **Q25.** Cert-pinning sites (Apple ID, banks, App Store) will refuse
  MITM. Need an allowlist domain that bypasses the proxy, or just accept
  breakage?
  [A: let's discuss... are there ways around this? I just want to be able to intercept network traffic in the browser so the agent can talk backend protocols directly]
- **Q26.** Proxy log retention:
  - Cap on body size per entry (e.g. drop bodies >5 MB; never store
    video/audio MIME types)?
    [A: soundds right]
  - Time-based eviction (e.g. last 24h) or size-based (e.g. 1 GB ring)?
  - User-visible "clear network log" button?
  - Encrypted at rest, or plain SQLite?
  [A: simple encryption via keychain]
- **Q27.** Tab correlation via injected `X-SuperApp-Tab` header on
  fetch/XHR — accept that main document loads & opaque subresources won't
  carry it, or invest in `decidePolicyFor` UA-suffix tagging too?
  [A: let's not worry abt tab correlation]
- **Q28.** Synthetic `browser.net.fetch` runs as `URLSession` from the
  app process: do we want it to **also** be visible in the proxy log
  (route through the local proxy too) for consistency, or skip the proxy
  on synthetic fetches?
  [A: run via proxy too]

### 8.8 BrowserJS API surface — gaps & ambiguities

- **Q29.** Should there be a separate top-level `browser.screenshot` or
  is `browser.content.screenshot(id)` enough? (Agents may want a
  full-window screenshot, not per-tab.)
  [A: dont want full window screenshot; just per content view]
- **Q30.** `browser.content.read(as:"markdown")` — Reeeed (already a dep)
  + an HTML→MD path (Ink is also a dep) seems natural. Confirm we should
  use those two?
  [A: yes]
- **Q31.** `browser.page.eval` runs in the page's WKWebView. Page CSP /
  same-origin — do we use `WKContentWorld.defaultClient` or `.world(name:)`
  to keep our injection isolated from page JS?
  [A: default client]
- **Q32.** Cookies: `browser.net.fetch({cookiesFrom: tabId})` — is the
  agent allowed to read raw cookies for an arbitrary origin (e.g. a
  `browser.cookies.get(origin)` API)? Reading arbitrary auth cookies is a
  privacy/sec footgun even though it's "the agent's" browser.
  [A: dont need to offer cookie access; just expose a fetch fn that automsticlaly uses logged-in cookies]
- **Q33.** Should the agent be able to **navigate** the active page
  (e.g. `browser.tabs.navigate(id, url)`), or is `browser.tabs.open` /
  `tabs.activate` + `page.eval('location=...')` sufficient?
  [A: add nav]
- **Q34.** `browser.webapp.create({html})` — does the agent serve a
  multi-file webapp (HTML + JS + CSS) or only a single self-contained HTML
  string? If multi-file, we need a virtual origin (`wowser-app://<id>/...`)
  with a `WKURLSchemeHandler`.
  [A: lets start with single file]
- **Q35.** `browser.tabs.openHTML` vs. `browser.webapp.create` — both load
  HTML; what's the distinguishing semantic? My read: `openHTML` is a
  one-shot scratch tab without `window.browser` exposure; `webapp.create`
  is named, persisted, with bridge access. Confirm?
  [A: openHTML does not have acccess to the window.browser. Your intuition is correct here.]

### 8.9 Webapp storage / lifecycle

- **Q36.** Webapps survive across app restarts? If yes, are they listed
  somewhere (a "My apps" panel)? Or do they decay with the originating
  agent session?
  [A: let's make em searchable + pinnable (should get both for free via existing systems); otherwise no need to support this.]
- **Q37.** Where does the user see them as URLs? Synthesized
  `wowser-app://<id>` shown in the omnibox, or a friendlier `app:<name>`?
  [A: friendly name]
- **Q38.** Can a webapp be re-opened from the omnibox/searcher (i.e.
  search-provider integration)?
  [A: yes, via standard history store searhc provider]

### 8.10 VS Code tab specifics

- **Q39.** Single shared `--user-data-dir` (one VS Code "instance" with
  shared settings/extensions across tabs) or per-tab (independent)?
  Shared is much cheaper (~100 MB vs. 100×N MB) and matches user
  expectation; per-tab is more isolated.
  [A: Shared]
- **Q40.** When the *last* VS Code tab closes, kill `code serve-web`?
  If yes, are we OK with the cold-start delay on the next open?
  [A: keep running after initial load]
- **Q41.** What happens if VS Code isn't installed at all? Hard error,
  silent disable of the tab kind, or in-app UI prompting "install VS Code"?
  [A: show error overlay prompting installatiojn with retry btn.]
- **Q42.** Multiple VS Code tabs on the *same* folder — same server, same
  workspace, same UI in two webviews? (Fine, but worth confirming the
  expected behavior.)
  [A: yes]

### 8.11 Terminal tab specifics

- **Q43.** Default shell — `/bin/zsh -l` (current `getenv("SHELL")` fallback,
  user-customizable)?
  [A: whatevr system uses; login shell]
- **Q44.** "Coding agent in terminal tab" — invoked how? A toolbar button
  that runs `claude` with the MCP env var pre-set? A first-class "new coding
  agent tab" type that's literally a terminal tab with `claude` as PID 1?
  [A: yeah btn that runs `claude`; dont worry abt the MCP env bar]
- **Q45.** Restoration after app quit: PTYs can't be persisted. Drop the
  tab, recreate empty in the same cwd, or recreate and replay history-as-text?
  [A: empty w same cwd]
- **Q46.** Should `claude` invocations get a working dir injection? Tying
  the terminal tab cwd to a "current Project" (existing `Project` entity in
  `BrowserState`) would be powerful but is also a separate feature.
  [A: dont worry abt projects]

### 8.12 File-browser tab specifics

- **Q47.** Read-only or read-write (rename / move / delete / drag-out)?
[A: read + simple write]
- **Q48.** Drag-and-drop affordances:
  - Drop a folder onto a terminal tab → `cd <folder>` ?
  - Drop a folder onto a VS Code tab → open it ?
  - Drop a file onto a web tab → upload? Open? Nothing?
  [A: dont need to handle cross tab drops]
- **Q49.** Roots: just `~`, or any user-selected folder via security-scoped
  bookmark?
  [A: any user-selectable; start with ~; support path completion in search]
- **Q50.** Network volumes / `~/iCloud Drive` — explicitly supported, or
  punted to a `FileProvider`-based v2?
  [A: punt]

### 8.13 Search-provider integration

The "Implementation spec details" stub says: "search providers that search
for folders and allow opening in the file browser, coding agent or terminal,
and also special actions for opening 'terminal' and file browser."

`Core/Search/Searcher.swift` + `SearchableItem+Actions.swift` is the right
hook. Today `SearchAction` has `clearAllTabs / organizeTabs / openURL`.

- **Q51.** Folder-search index source — Spotlight (`NSMetadataQuery` /
  `mdfind`)? Manual roots configured in settings? Recent-cwd from terminal
  tabs? All of the above?
  [A: no spotlight; just see if current query is prefix of a valid path, also have a basic list of default dirs (Documents, etc). when we visit a folder, emit a visit event to the history store so we can return later]
- **Q52.** "Coding agent" in this stub means a terminal tab spawning
  `claude` at the chosen folder, right? Or a VS Code tab? Or "user picks"?
- **Q53.** New static actions to add to `staticActionItems`:
  - "Open Terminal"
  - "Open File Browser"
  - "Open VS Code"
  - "Open Coding Agent"
  [A: vs code, terminal, claude string are the only ones we should handle]
  - … any others?
- **Q54.** Multi-action results: when the user types a folder name, we
  could surface "Open in File Browser / Terminal / VS Code / Agent" as
  four results, or one result with a sub-menu. Preference?
  [A: 3 results; dont include agent.]

### 8.14 Native overlays via URL schemes

Stub says: "We have an existing system for rendering native pages by
defining special url schemes, parsing them, and producing native overlays.
We should use this." That maps to `GeneratedPageKey` + `ByInjectingGeneratedPages`,
which currently uses `about:blank?...` querystrings.

- **Q55.** Should new tab kinds (terminal / vscode / files / webapp) be
  addressable via this scheme system (e.g. `about:blank?terminal=...`,
  `about:blank?app=<id>`), so that omnibox typing / history / favorites
  all "just work"? Or are they a parallel system addressed by tab kind?
  [A: the former]
- **Q56.** If yes, do we extend `GeneratedPageKey` or introduce a sibling
  `NativeTabKey` enum to keep the AI-generated and native-content
  pathways separate?
  [A: new key]
- **Q57.** Should we move off `about:blank?` to a real custom scheme like
  `wowser:` so the UA is honest in `webview.url`? This would require a
  `WKURLSchemeHandler` registration but is more durable.
  [A: keep abt blank]

### 8.15 Misc

- **Q58.** What's the smallest viable v1? My read: terminal tabs + MCP
  server + BrowserJS over existing web tabs (no proxy, no vscode, no
  files, no webapps). Confirm v1 cut, or specify your own?
  [A: sounds good]
- **Q59.** Telemetry / debug logging — where does it go? Console.app
  via `os_log`, in-app debug pane, or stderr only?
  [A: stderr only]
- **Q60.** Versioning: BrowserJS `.d.ts` is in-repo. When we change the
  surface, helpers may break. Do we need a version field returned from
  `get_browser_js_docs` so agents can adapt?
  [A: dont orry abt backwards compat for now]
- **Q61.** Anything in `nat_docs/` or other ambient docs I should be
  reading that pre-answers any of the above?
  [A: nope]


