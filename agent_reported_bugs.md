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
