# Agent-reported bugs & friction (Wowser MCP / BrowserJS)

Field notes from agents driving the browser via `run_browser_js`. Append new entries at the bottom.

## 2026-08-22 — Debugging a Render.com dashboard (Claude Code session)

Task: open dashboard.render.com, find a service, read its events/metrics/logs, use the web shell.

### What worked
- `tabs.open` → `content.read` → `content.screenshot` + `viewImage`: clean loop, screenshots legible enough to read charts.
- `page.eval` to scrape `href`s from the DOM (`/project/prj-…`, `/web/srv-…`) — reliable, faster than clicking.
- Being logged in via the real browser session is the big win over a headless tool.
- `get_browser_js_docs` was sufficient to get the API right on the first try.

### Bugs
1. **Background tabs vanish.** `await Promise.all([tabs.open(a,{background:true}), tabs.open(b,{background:true}), tabs.open(c,{background:true})])` returned three TabIds, but `content.read(id)` on them ~9 s later threw `tab not found: <id>`. Opening pages sequentially in one tab worked fine. Suspect a race when several background tabs are created at once.
2. **`page.eval` `.click()` is a no-op on React-handled elements.** `[...document.querySelectorAll('a')].find(...)?.click()` on the Render project card did nothing (handler probably lives on an ancestor). Had to fall back to reading the `href` and `tabs.navigate`. `page.click(x,y)` presumably works but needs coordinates, which means a screenshot round-trip first.

### Friction / feature requests
- `content.read` returns the entire page including sidebar/nav chrome every time — several KB of identical boilerplate per call. A `read(id, {selector})` or a "main content only" mode would cut token use a lot.
- No "wait for page settled / network idle" helper. SPA charts took ~7 s to render; I guessed with `sleep`. `waitFor(predicate)` exists but you have to know what to wait for.
- `page.type` into a web terminal (xterm.js) for the Render shell was blocked by Claude Code's auto-mode permission classifier, not by Wowser — but worth knowing that "type a shell command into a web terminal" reads as high-risk to the harness. A dedicated, allowlist-able helper might be friendlier than generic keystroke injection.


## 2026-10-03 13:01 — page.* / tabs.navigate fail with "tab not found" for tabs in a space the window isn't displaying (incl. fresh ghost tabs)

Setup: one window (58FF936E…) displaying space "wowser" (A74237AB…). The agent's terminal tab lives in space "neweveryday" (6B3D19B8…), which no window is currently displaying. Tab 891CBD4A… (appstoreconnect.apple.com, opened earlier via tabs.open, normal not ghost) is in the neweveryday space.

On 891CBD4A (off-screen space):
- tabs.get → OK
- tabs.list({spaceId}) → lists it
- content.read → OK (returns page text)
- content.screenshot → OK
- tabs.use → OK (returns lease expiry)
- page.eval(id, "1+1") → Error: tab not found: 891CBD4A…
- page.scroll → Error: tab not found
- page.waitFor(id, "true", 1000) → times out ("predicate never became truthy: true"), i.e. eval silently failing inside the poll instead of surfacing tab-not-found
- tabs.navigate → Error: tab not found (earlier in session)
- tabs.use did NOT fix page.eval

Ghost tabs: browser.tabs.openGhost("https://example.com", {windowId: 58FF936E…}) returns an id (lands in agent's space neweveryday); tabs.get works and shows url/title loaded, but page.eval on it → tab not found. Earlier an openGhost'd tab immediately failed screenshot with tab not found too. tabs.close(ghostId) returned OK but the ghost was still in tabs.list({spaceId}) afterwards (leaked).

Expected: openGhost/leased tabs are drivable regardless of which space the window is showing (docs say they render offscreen at 1280×800). Inconsistent: read/screenshot work while eval/click/navigate don't, so the webview evidently exists but the page.* lookup resolves tabs only within the displayed space.

Also: waitFor should propagate "tab not found" rather than masking it as a timeout.

Workaround: ask the user to switch the window to the agent's space.


## 2026-10-03 13:02 — Follow-up: confirmed page.* failures are space-visibility dependent; leaked ghost's page became about:blank

Follow-up to the "tab not found for tabs in a non-displayed space" report, same session, same tab ids.

After the user switched window 58FF936E… to space "neweveryday" (6B3D19B8…), with NO other changes:
- page.eval(891CBD4A…, "location.href") → "https://appstoreconnect.apple.com/apps" (previously: tab not found)
- page.scroll(891CBD4A…) → ok (previously: tab not found)
- fresh openGhost("https://example.com") + page.eval → works; tabs.close → removed from tabs.list (previously the close returned ok but the tab stayed listed)
So the failure is 100% determined by whether the tab's space is the one a window is currently displaying. tabs.use() lease (agentActiveUntil set) did NOT keep it drivable while off-screen, contradicting the docs ("keeps rendering offscreen").

Leaked ghost 9D01B674… (opened with openGhost("https://example.com", {windowId}) while the space was off-screen; tabs.get then reported url https://example.com/ and title "Example Domain"; tabs.close returned ok but it stayed in tabs.list): once the space was displayed, page.eval(location.href) returned "about:blank" — i.e. the page never actually loaded/was torn down while tabs.get kept reporting the stale URL/title. A second tabs.close then removed it properly.

Hypothesis: page.*, tabs.navigate and tabs.close look up the live WKWebView via the window's current-space pane registry; content.read/screenshot and tabs.get go through a different (model/snapshot) path. Off-screen-space webviews are unmounted/suspended, and openGhost in an off-screen space creates the model entry without a live webview.

Repro:
1. Agent terminal lives in space A. User switches the window to space B.
2. const g = await browser.tabs.openGhost("https://example.com"); await browser.sleep(1500);
3. browser.tabs.get(g) → shows example.com; browser.page.eval(g, "1") → "tab not found"; browser.page.waitFor(g, "true", 1000) → timeout instead of tab-not-found.
4. browser.tabs.close(g) → ok, but tabs.list({spaceId: A}) still contains g.
5. Switch window back to space A: eval(g) → "about:blank".

Expected: agent/ghost/leased tabs in any space are fully drivable without the user changing what's on screen (that's the whole point of ghost tabs while the user works elsewhere).


## 2026-10-03 13:03 — Follow-up 2: every per-tab API fails for tabs in non-displayed spaces (web, webapp, terminal); tabs.use doesn't help; terminal.read says "not a terminal tab"

Systematic test, user's single window 58FF936E… displaying space "neweveryday" (6B3D19B8…); I probed every tab in the other non-empty spaces ("wowser" A74237AB…, "feeeed" 5B9EB7C4…). All non-destructive calls. Same window id for all tabs.

kind=web, user-opened, not ghost:
- C149D88A… (wowser space, https://dash.cloudflare.com/login?...)
- 1C9D0948… (feeeed space, https://developer.apple.com/)
For both:
  tabs.get → OK (correct url)
  content.read → "tab not found"
  content.screenshot → "tab not found"
  page.eval("location.href") → "tab not found"
  page.scroll(0,0) → "tab not found"
  page.waitFor("true", 1500) → TIMEOUT after ~1530ms (masks tab-not-found)
  tabs.use({minutes:5}) → OK, returns expiry (lease "succeeds")
  page.eval("document.visibilityState") right after use → still "tab not found"
All errors return in 0–1ms, so nothing is being mounted/attempted.

kind=webapp: 9AB52C94… (wowser space, tang://notes/?id=musmc5pt): content.read and page.eval → "tab not found".

kind=terminal: 0320CB70…, 81E758E6…, 0982403D… (wowser), 52E995E1… (feeeed): tabs.list reports kind "terminal" with url about:blank?native=terminal&cwd=…, but browser.terminal.read(id) → "invalid args: <id> is not a terminal tab"; content.read/page.eval → "tab not found".

Contrast with earlier in this session: when the agent's OWN space (neweveryday) was off-screen, a tab the agent had opened there (891CBD4A…, via tabs.open) still allowed content.read + content.screenshot + tabs.get + tabs.use, but page.eval/scroll/navigate failed. So there seem to be three tiers: (1) displayed space: everything works; (2) agent's own off-screen space, agent-opened tab: read/screenshot work (webview alive), page.*/navigate fail; (3) other off-screen spaces: only tabs.get/list/use work.

Net effect for agents: tabs.use and openGhost do not deliver their documented promise ("keeps rendering offscreen", "fully functional"); the agent can't work in the background unless the user is looking at the agent's space. Also tabs.use should fail (or actually mount the tab) rather than return a lease that does nothing.

Suggested fix: resolve page.*/content.*/navigate/terminal.* by tab id across all spaces' pane registries (not just the window's current space), and when the target's webview is unmounted, mount it in the offscreen stage (like ghost tabs) for the lease duration.


## 2026-10-03 13:07 — page.type sends keystrokes to the user's focused tab (a terminal) instead of the target tab; target only gets the first character

Severity: high. Agent input leaks into whatever the user has focused, which could be a shell.

Setup: window 58FF936E… shows space "neweveryday". The user's foreground/focused tab is the agent's own terminal tab D547D538… (Claude Code running). The target tab 891CBD4A… (appstoreconnect.apple.com, a normal non-ghost tab in the same space, not selected) has a "New App" modal open.

Calls, all in one run_browser_js:
  await browser.page.click(id, 381, 174);   // iOS checkbox → worked (checked)
  await browser.page.click(id, 640, 256);   // focus #name input
  await browser.page.type(id, "New Every Day");
  await browser.page.click(id, 640, 518);   // focus #sku input
  await browser.page.type(id, "neweveryday");
  await browser.page.click(id, 521, 590);   // radio → worked

Result: in the target, #name.value === "e" and #sku.value === "w". The user reports the rest of the typed text showed up in the foreground terminal tab (the Claude Code prompt). Looks like the first keystroke goes to the target webview and the rest go to the key window's first responder, i.e. the synthesized key events are sent through NSApp/the key window instead of straight to the target WKWebView. Clicks were delivered correctly.

This also explains the CLAUDE.md lore elsewhere that "the first typed keystroke is sometimes dropped": it's not dropped, input is going to the wrong view.

Expected: page.type/page.key deliver every event only to the target tab's webview, whether or not it's selected or focused, and never to another tab. Typing into a terminal is especially dangerous (input plus "\n" runs commands).

Workaround I used: set values with page.eval via the native HTMLInputElement/HTMLSelectElement value setter and dispatch input/change events (works with React).
