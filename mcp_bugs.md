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
- **Likely cause:** the listen socket fd is leaking into forked children. `lsof -iTCP:48197` shows the same listen fd (fd 16, one shared device handle) inherited by a swarm of `zsh` and MCP-client child processes, several with live `ESTABLISHED` connections — one of them squats the single session slot. Missing `FD_CLOEXEC` / close-on-exec on the listening socket when spawning shells/subprocesses.
- **Workaround:** quit & relaunch Tangerine, then `/mcp` reconnect (or restart the Claude Code session).
- **Fixes:** (a) set close-on-exec on the listen socket so children don't inherit it; (b) support multiple concurrent MCP sessions (or at least evict/replace a stale one) instead of hard-rejecting with "Session already initialized".

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
