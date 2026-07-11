# Wowser MCP (tangerine / BrowserJS) — Bugs, Issues & Observations

Running log of problems and notes found while exercising the `tangerine` MCP
(`browser.*` BrowserJS API). Newest entries can go at the top of each section.

Last systematic sweep: 1–2 calls per tool, all wrapped in try/catch.

---

## Bugs

### 0. MCP server only allows ONE session — second client gets "Session already initialized" → Claude Code shows "Failed to connect"
- **Severity:** High — locks out new sessions entirely; tangerine's tools never register, so screenshots/tab control are unavailable even though the app is running fine.
- **Repro:** With Tangerine running and one MCP client already attached, start a new Claude Code session (or `claude mcp list`). tangerine reports `✘ Failed to connect`. A manual handshake against the endpoint confirms why:
  - `curl -X POST .../mcp/<token> -H 'Accept: application/json, text/event-stream' -d '{...initialize...}'` →
    `{"error":{"message":"Invalid Request: Bad Request: Session already initialized","code":-32600}}`
  - Plain GET returns `406` (expected for streamable-HTTP without the SSE Accept header) — server is alive.
- **ROOT CAUSE (confirmed 2026-07-10, supersedes the fd-leak theory below):** `MCPServer.start()` constructs a **`StatefulHTTPServerTransport`** (`MCPServer.swift:66`) — even though the file's own header comment (`MCPServer.swift:10`) says it uses `StatelessHTTPServerTransport`. The stateful transport holds a single `private var sessionID: String?` (swift-sdk `StatefulHTTPServerTransport.swift:43`). `handleInitializationRequest` rejects with 400 whenever `sessionID != nil` (`:243`), and **nothing anywhere ever assigns `sessionID = nil`**. So the first client to `initialize` owns the session for the entire lifetime of the app process; every later client is locked out permanently.
  - `DELETE` is not an escape hatch: it routes to `terminate()`, which sets `terminated = true` (`:546`) and makes *all* subsequent requests 404 "Session has been terminated". It bricks the server rather than freeing the slot.
- **Why it looks like an *auth* failure (red herring):** Claude Code's HTTP transport runs with `hasAuthProvider: true`. When the `initialize` POST fails for *any* reason, it falls back to OAuth discovery → `GET /.well-known/oauth-authorization-server`. `MCPHTTPHandler.handle` 404s every path except `/mcp/<key>` and sends `body: nil` (`MCPServer.swift:324`), so the client tries to JSON-parse a zero-byte body and reports:
  `SDK auth error: HTTP 404: Invalid OAuth error response: SyntaxError: JSON Parse error: Unexpected EOF. Raw body:` → surfaced as "SDK auth failed".
  Nothing is wrong with the path token. Auth is a *symptom* of the 400, not the cause.
- **SECOND, INDEPENDENT LOCKOUT (found while verifying the fix):** swapping the transport alone is **not sufficient**. `Server.start()` installs a default `initialize` handler that does `guard await !self.isInitialized` and throws `MCPError.invalidRequest("Server is already initialized")` (`Server.swift:893`). With the stateless transport the second client gets HTTP **200** carrying a JSON-RPC *error* body — which still fails the handshake, and still trips Claude Code's OAuth fallback. Anything asserting only on HTTP status will report a false PASS here.
- **Fix (both layers, `MCPServer.start()`):**
  1. `StatefulHTTPServerTransport` → `StatelessHTTPServerTransport`; drop `SessionValidator()`; `AcceptHeaderValidator(mode: .jsonOnly)` since stateless never opens an SSE stream. (Stateless is what the file's header comment already claimed.)
  2. Override the `initialize` handler with `server.withMethodHandler(Initialize.self)` **after** `server.start()` (start() is what registers the default, so registering before is overwritten). Return `Initialize.Result` unconditionally.
  - Safe because `Server.Configuration.default` is non-strict — the `isInitialized` flag the override skips setting only gates requests when `configuration.strict == true`. Enabling strict mode later would break this.
  - `Version.negotiate` is internal, so the override reimplements it: `Version.supported.contains(requested) ? requested : Version.latest`. Both are public.
- **Verified (2026-07-10)** with an isolated harness against swift-sdk 0.12.0 (`exact: "0.12.0"`, the pinned rev), asserting on JSON-RPC bodies:
  - stateful (shipped): client 2 `initialize` → HTTP 400 "Session already initialized"
  - stateless only: client 2 → HTTP 200 + JSON-RPC error "Server is already initialized" ← half-fix, still broken
  - stateless + override: clients 1–3 each `initialize` **and** `tools/list` cleanly
  - `GET` → 405 (spec-permitted; the SSE channel is optional and Claude Code tolerates it)
- **Note:** `OriginValidator.localhost()` rejects a browser-style `Origin` header. Claude Code is a CLI and sends none — probes must omit it or they'll get a misleading 403.
- **Secondary (real, but a *different* bug):** the listen socket does leak into forked children — missing `FD_CLOEXEC`. Verified: `zsh` PID 151 has PPID 98748 = the Tangerine app (spawned via TerminalOverlay), and holds listen fd 19 (shared device handle) plus server-side `ESTABLISHED` connections. This does **not** cause "Session already initialized" (that state is in-process). What it *does* cause: after Tangerine quits, the port stays bound by the surviving children, so a relaunched app fails to bind 48197 and silently falls back to a random port (`MCPServer.swift:96-97`) — invalidating the stable URL baked into the `claude mcp add` command in Settings.
- **Workaround (until fixed):** quit & relaunch Tangerine, then `/mcp` reconnect. Only one Claude Code session can hold tangerine at a time.

### 1. `browser.page.eval` does not return the evaluated value — FIXED (2026-06-28)
- **Fix:** `callAsyncJavaScript` treats the snippet as an async-function *body*, so a bare expression returns nothing. Added `WKWebView.evalReturningValue` (BrowserJSLiveHost.swift): a single trailing expression is now wrapped as `return (...)` REPL-style, so `document.title` / `1+2` return values without an explicit `return`. Snippets with a top-level `return` or multiple statements still run verbatim. `page.waitFor` was also rewired to eval the predicate directly (it previously wrapped predicates in a return-less IIFE → always undefined → never resolved).
- **Severity:** High — in-page JS execution is core functionality and is effectively unusable for reading data back.
- **Repro (foreground, fully-loaded tab):**
  - `page.eval(id, "document.title")` → `null`
  - `page.eval(id, "1+2")` → `null`
  - `page.eval(id, "return document.title;")` → `""` (empty string, not null)
- **Expected:** Return the value of the final expression (title string, `3`, etc.).
- **Actual:** `null` for bare expressions; `""` when an explicit `return` is used.
- **Notes:** The `""`-with-`return` vs `null`-without case suggests the JS is being wrapped in a function and the wrapper's completion value / serialization is dropped. `page.scroll/click/type/key` all return `"ok"` (they don't need a return value), and `content.read` works on the same tab — so the tab is healthy; the defect is specific to returning a value from `eval`.
- **Likely related:** `page.waitFor` returns `null` even when the predicate is satisfied (probably shares eval's return-value path).

### 2. Background / non-foreground tabs: empty text read & 0-byte screenshot — FIXED (2026-06-28)
- **Fix (text):** `content.read(as:'text')` now falls back to DOM-derived text (via `outerHTML` → `htmlToMarkdown`) when `innerText` is empty, so background tabs return real text instead of `""`. **Fix (screenshot):** `content.screenshot` now throws an explicit `screenshot unavailable — tab not rendered (activate it first)` error instead of silently returning a 0-byte PNG when the tab hasn't been rendered. (Forcing an offscreen render was not attempted — the explicit error is the safe fix.)
- **Severity:** Medium — surprising and easy to hit (opening with `{background:true}` or just before activating).
- **Repro:** `tabs.open(url, {background:true})`, then immediately:
  - `content.read(id, {as:'text'})` → `""`
  - `content.read(id, {as:'markdown'})` → `""`
  - `content.screenshot(id)` → `{mime:'image/png', bytes:0}` (0-length data!)
  - BUT `content.read(id, {as:'html'})` → returns real DOM markup.
- **After `tabs.activate(id)` + brief sleep:** text read returns "Example Domain…", screenshot returns ~110KB. All good.
- **Diagnosis:** Text extraction and screenshot appear to require the WKWebView to be rendered/visible; background tabs aren't rendered, so they yield empty/zero output. `html` read works because it reads the DOM directly.
- **Suggested fixes:** Either (a) force an offscreen render for `screenshot`/text reads on background tabs, or (b) document that text/screenshot require a foreground tab, or (c) return an explicit error rather than silent empty string / 0-byte image.

### 3. `run_browser_js` intermittently returns `null` for a valid final value (REPRODUCED)
- **Severity:** Medium — intermittent but recurring; makes results unreliable.
- **Occurrence 1:** A multi-statement script ending in a bare `results;` (array of ~11 plain objects) returned `null`. Re-running ending in `JSON.stringify(results)` returned the data.
- **Occurrence 2:** A script that opened `http://neverssl.com`, did `sleep(2500)` + `activate` + `sleep(1500)`, then ended in `JSON.stringify({...})` — returned `null` (and `JSON.stringify` can NEVER return null, so the result was dropped post-evaluation). Re-running just the read-only portion (no tab open, no long sleeps) returned the data correctly.
- **Correlation:** Both failures were longer scripts that opened tabs and/or had multiple seconds of `sleep` and many awaits. Short scripts and the isolated `[{a:1},...]` literal test always worked. Smells like a timeout or the result bridge resolving before/after the async work settles on longer-running evaluations.
- **Workaround:** Keep scripts short; do mutations and reads in separate calls; re-run on a `null`.
- **Action:** Check the MCP host's eval timeout / how the final value is captured for scripts with top-level `await` + `sleep`.

---

## Observations / Limitations (working as documented, but worth noting)

### Passive network capture (`net.captureOrigin`/`net.log`/`net.grep`) sees NO live tab traffic — proxy is not wired up
- **Severity:** High — the whole passive-capture feature is non-functional in the running app, for **both HTTP and HTTPS**.
- **Root cause (code):** Capture depends on `LocalProxy` (`Core/Sources/Core/Network/LocalProxy.swift`) sitting in front of the webviews. Its doc comment says webviews are "pointed at this proxy via `WKWebsiteDataStore.proxyConfigurations`" — but **nothing ever sets that**. `LocalProxy.shared.start()` is never called from app code, and `WKWebsiteDataStore.proxyConfigurations`/`ProxyConfiguration` is never assigned anywhere (only in comments). The webview data store is created plainly in `WebContent.swift:140` with no proxy. The proxy is only instantiated/started inside the two unit tests, which drive a `URLSession` (with `connectionProxyDictionary`) through it manually — so the tests pass while live tabs capture nothing.
- **Correction to earlier note:** This was previously logged as "only logs plaintext HTTP / HTTPS is the broken case." That's wrong — neither scheme is captured from real tabs. HTTPS wasn't the special failure; the proxy simply isn't attached. (The scheme/port allowlist logic in `NetworkCaptureStore.isCaptureEnabledForOrigin` is actually fine — it falls back to a host-only suffix match that ignores scheme, so an allowlisted `example.com` covers both `http://` and `https://`.)
- **Empirical confirmation (HTTP):** Loaded `http://httpforever.com` in a foreground tab (verified it rendered — title "HTTP Forever", full page text read back) with capture enabled for the origin. Log showed **0** entries for httpforever (grep=0); the only entries present were the 3 earlier synthetic `net.fetch` calls to example.com. So plaintext HTTP from a live tab is NOT captured — HTTP is not a working case either. (`neverssl.com` was tried first but never actually loaded in the browser; `httpforever.com` did load and still wasn't captured.)
- **Only working capture path:** `browser.net.fetch` (synthetic, `source:"synth"`), which records directly into the store and bypasses the proxy.
- **Workarounds for inspecting page activity:** `net.fetch`; read the tab URL via `tabs.get`/`tabs.list`; `content.read(as:'text')`.
- **Fix (HTTP):** start `LocalProxy.shared` at launch and set each profile's `WKWebsiteDataStore.proxyConfigurations` to a `ProxyConfiguration` pointing at `127.0.0.1:boundPort` when building the data store in `WebContent.swift`. (Implemented 2026-06-27.)

### HTTPS MITM capture is blocked by WebKit: no app trust hook for proxied TLS
- **Severity:** High — HTTPS passive capture cannot be made to work with the MITM-via-`ProxyConfiguration` design.
- **What was tried (2026-06-27):** Wired `WKWebsiteDataStore.proxyConfigurations` → `LocalProxy`, plus a `WKNavigationDelegate` server-trust handler that accepts LocalCA-forged leaf certs via `LocalCATrust`.
- **Empirically confirmed with a real WKWebView test:**
  - The webview **does** route through the proxy: proxy logs `LocalProxy CONNECT <ip>:<port> -> captured=true` and `MITM swap done`. Proxy wiring is correct.
  - The load then fails with `NSURLErrorDomain Code=-1200` ("A TLS error caused the secure connection to fail").
  - **The nav delegate's server-trust challenge is NEVER called** — verified with *both* the async `webView(_:respondTo:)` and the older `webView(_:didReceive:completionHandler:)` variants. Neither fires; only `didFailProvisionalNavigation` fires.
  - `LocalCATrust.trustIsValid` itself is correct (unit-tested: accepts our forged leaf for DNS and IP hosts, rejects a foreign CA). It's just never consulted.
- **Conclusion:** WebKit validates a **proxied** origin's TLS cert against the **system trust store only**, with no `WKNavigationDelegate` override hook. Forged MITM certs are rejected and the app cannot opt into trusting them from code.
- **Regression risk:** With the proxy attached, *allowlisting an HTTPS origin actively breaks it* — the page fails to load (-1200) instead of loading uncaptured. MITM must NOT be enabled for HTTPS until trust is solved.
- **Only known fix:** install the LocalCA **root** into the system/login keychain marked trusted for SSL (the Charles/Proxyman model). Then WebKit's internal validation passes without a delegate. Security-sensitive; needs explicit user consent (admin/keychain trust).
- **Implemented (2026-06-27):** `LocalCA.installRootAsTrusted()` / `uninstallRootTrust()` / `isRootTrusted()` (uses `SecTrustSettingsSetTrustSettings(.user)`; app is not sandboxed so this is allowed, prompts for Touch ID/password). Settings → MCP has an "HTTPS capture" section with an Install/Remove button + status. The proxy now gates MITM on `allowlisted && ca.isRootTrusted()` — so until the user installs trust, allowlisted HTTPS is **blind-tunnelled (loads fine, uncaptured)**, fixing the regression above. **Pending manual end-to-end verification**: click Install, load an HTTPS site with capture enabled, confirm `net.log` shows `proxy-tls` entries (can't be automated — the keychain trust prompt requires interactive auth).
- **Tests added:** `WebviewProxyCaptureTests` (proxy-config helper; `LocalCATrust` accept-ours/reject-foreign). Proxy MITM+capture remains covered by `HTTPSCaptureTests`. A real-WKWebView E2E isn't committable: WebKit bypasses the proxy for loopback origins, and the trust block prevents a green end-to-end run anyway.

### `content.read(as:'markdown')` leaks `<script>` / `<style>` content — FIXED (2026-06-28)
- On Google results, markdown was mostly inline `<script>` source (google.kEI bootstrap).
- On example.com, markdown included CSS: `Example Domainbody{background:#eee;...}`.
- `as:'text'` is clean on the same pages.
- **Fix:** `htmlToMarkdown` (BrowserJSLiveHost.swift) now removes the *contents* of `<script>`/`<style>`/`<noscript>`/`<template>` blocks before tag-stripping (tag-stripping alone left the bodies behind).

### Dark mode is applied to screenshots/rendering
- example.com screenshot came back rendered in dark mode (Wowser's dark-mode feature). Not a bug — just note that screenshots reflect Wowser's applied appearance, not the site's default.

---

## Things confirmed working

**Tabs:** `list`, `open` (fg + `{background:true}`), `openGhost`, `openHTML`, `get`, `navigate`, `move`, `activate` — all OK.
**Windows:** `list`, `getCurrent`, `getById` — all OK.
**Content:** `read(text)`, `read(html)`, `read(markdown)`, `screenshot` — OK on **foreground** tabs (see bug #2).
**Page (no-return actions):** `scroll`, `click`, `type`, `key` — return `"ok"` without error.
**Net:** `captureOrigin`, `fetch` (HTTPS, status 200, body + headers), `fetch({cookiesFrom:'domain'})`, `log` (records fetches), `grep`, `replay` — all OK.
**Misc:** `sleep`, `log`, `viewImage` (image surfaced to model correctly).
**Helper files:** `save_browser_helper_file` + `read_browser_helper_file` — saved helper is prepended and its fns/globals are available in subsequent runs (`mcpTestHelperFn()` → "helper-works", global `42`).

## Documented stubs (not bugs)
- `content.write` → throws `not implemented in v1: content.write`.
- `webapp.create` → **now implemented** (tang:// webapps). Takes `{name, files: Record<string,string>, exposeBrowserJS?}` (multi-file, must include `index.html`); writes to `~/Library/Application Support/Wowser/Tangerine/<slug>/` and opens `tang://<slug>/`. Pages get the full `window.browser`. (`exposeBrowserJS` flag is currently a no-op — always exposed.)

## Note: no helper-file delete
- There's no tool to delete a saved helper; overwrote `zz_mcp_test_helper` with a no-op comment to neutralize the test helper. A delete affordance would be nice.

## Missing surface: no spaces / profiles API (2026-07-11)
- `Object.keys(browser)` → `tabs, content, page, windows, net, webapp, sleep, log, viewImage`.
- Spaces (`Profile` in `BrowserState`: `title`, `autoTitle`, `emoji`, `creationOrder`) are unreachable from BrowserJS, so a tang:// app can't list or switch spaces. `windows.list()` only gives tab ids — no profile grouping.
- Asked for "an app that lists my spaces"; had to fall back to listing tabs. A `browser.spaces.list()` (+ `activate`?) would close this.

---

## Session 2026-07-11: tang:// webapp storage + `page.eval` semantics

Context: built `tang://tabs/` (a webapp listing live tabs) and probed what
persistence a tang app can rely on. Findings below are empirical unless noted.

### `page.eval` runs in a DIFFERENT content world than the page — BUG
- `browser.page.eval(id, 'typeof window.browser')` → `"undefined"`, on a tang://
  page whose own scripts use `browser.tabs.list()` successfully.
- Same for `typeof window.webkit` → `"undefined"`, and page-defined globals
  (`typeof render` → `"undefined"` for a fn declared in `index.html`).
- The DOM *is* shared (`document.querySelectorAll("li").length` → 10).
- **Cause:** `TangBridge.install` adds the `window.browser` user script + message
  handler in `contentWorld: .page`, but `WKWebView.evaluateAsyncJS`
  (BrowserJSLiveHost.swift) calls `callAsyncJavaScript(..., in: .defaultClient)`.
- **Impact:** you cannot use `page.eval` to inspect or drive a tang app's own JS
  state, or to call `browser.*` from inside a page. The `.d.ts` says "runs inside
  the page's WKWebView", which reads like the page context. Either switch to
  `.page` or document the isolation.

### `page.eval` silently returns `null` for any snippet containing `;` or a newline — FOOTGUN
- `browser.page.eval(id, '1+1')` → `2`. `'(function(){ return "x"; })()'` → `null`.
- **Cause:** `evalReturningValue`'s `looksLikeSingleExpression` check bails if the
  snippet contains `;` or `\n`, then runs it as a `callAsyncJavaScript` *body*,
  where a bare trailing expression yields nothing. So IIFEs and any multi-statement
  probe quietly evaluate to `null` instead of erroring or returning their value.
- Workaround: comma-sequence expressions (`localStorage.setItem("k","v"), localStorage.getItem("k")`)
  or an explicit `return`. Not mentioned in the `.d.ts`.

### A JS exception inside `page.eval` aborts the whole `run_browser_js` with a useless message
- Error surfaced as `A JavaScript exception occurred\n__nativeReject@` — no
  `ReferenceError: Can't find variable: browser`, no line info. Made the content-world
  bug above take several rounds to isolate. Should propagate the underlying JS error.

### Storage available to tang:// apps — WORKS (answers "can I build a todo list?")
- `localStorage`: **works and persists.** Round-trips, and a value written before
  closing the tab was still there after `tabs.open('tang://tabs/')` reopened it.
  Origin is `tang://tabs` (per-app, since the slug is the host). Survives navigation.
  *Unverified:* persistence across a full app relaunch (very likely — it's the
  default persistent WKWebsiteDataStore, not ephemeral).
- `indexedDB`: present, `indexedDB.open()` succeeds on the custom-scheme origin.
- `caches`: present. `fetch`: present.
- `document.cookie`: **silently non-functional** — writes are dropped, reads return
  `""`. Expected for a custom scheme; worth a doc note.
- `browser.webapp.create` is exposed to tang pages, so an app can rewrite its own
  files on disk — but it replaces the whole app folder, so it's not a sane
  key/value store. Use `localStorage`.
- **Verdict:** a todo list should use `localStorage` (or IndexedDB for anything
  bigger). No dedicated storage API is needed, but the `.d.ts` says nothing about
  what a tang page may rely on — worth documenting.

### tang app driving a ghost tab — WORKS (built `tang://unread/`, 2026-07-11)
- A tang page can call `browser.tabs.openGhost()` + `page.waitFor()` + `page.eval()` to
  scrape a live site and render the result. Ghost tab is correctly flagged `isGhost: true`
  and stays separate from the user's own tab on the same origin. `page.waitFor(id, expr, ms)` OK.
- `page.eval`'s content-world isolation (see bug above) is *fine* for DOM scraping — it just
  means you can never reach the target page's own JS state.
- **Shortcoming: no page lifecycle hook.** A tang page has no unload/teardown callback, so an
  app that spawns a ghost tab can't close it when the app tab closes — ghosts accumulate.
  Something like `browser.onUnload(cb)`, or auto-reaping ghosts owned by a closed tang tab.
- **Escaping footgun:** eval'd JS embedded as a string has to survive Swift → page JS → eval.
  Storing the snippet in a `<script type="text/plain">` block and reading `.textContent`
  avoids the double-escape entirely. Worth putting in the docs.
