# The shell: a browser UI you can rewrite

The browser window can be drawn by a **branch** — a folder of TS/JSX in
Application Support — instead of the built-in SwiftUI. Branches are edited by
the user or by an agent, previewed in a second window, undone, and swapped.

Status: **the JS half is tested; the Swift half has never been compiled.**
Read "Bring-up on a Mac" before anything else.

- `Wowser/Core/Sources/Core/Shell/` — Swift host
- `Wowser/Core/Sources/Core/Shell/ShellKit/` — bundled resource: JS runtime,
  transpiler, seed branches, docs for agents
- `scripts/shell/` — tests, fake browser, DOM simulator (bun / node)

Off by default. `DefaultsKeys.shellBranch` empty ⇒ nothing changes.

## How it fits together

```
 branch files (TSX)                                   BrowserStore / BrowserState
      │  ShellTranspiler (Sucrase in its own JSContext, cached)       ▲      │
      ▼                                                               │      │ uiPublisher
 ┌─ JSContext (one per window) ───────────────────────┐   ShellActions│      ▼
 │  bootstrap.js   modules, timers, console           │ ◀── host.call ┘  ShellSlices
 │  lib/reconciler hooks, keys, memo, boundaries      │ ◀── slices(key, json) ──┘
 │  lib/store      useSlice                           │
 │  lib/api        tabs / panes / search / commands   │ ── host.commit(ops) ──▶ ShellTree (@Observable nodes)
 │  lib/index      "wowser" · lib/native "wowser/native"                          │
 └────────────────────────────────────────────────────┘ ◀─ dispatch(node, event) ─┤
                                                                                   ▼
                                                        ShellNodeView (SwiftUI) per node
```

- **`ShellEngine`** owns the context. Everything is main-thread: the UI code
  shares it with the browser model, so `search.suggest()` and `tabs.close()`
  are plain synchronous calls. A reload throws the context away.
- **Ops.** The reconciler emits `create / update / children / remove`; only
  changed props cross the bridge, and functions never do (a handler is sent
  as `true`; events are routed by node id).
- **Slices** (`ShellSlices`) are the read side: pure functions of
  `BrowserState` returning JSON, recomputed on `uiPublisher` and pushed only
  when changed. `window`, `spaces`, `tabs`, `tab|{id}`, `pane|{id}`, `theme`,
  `toasts`, `setting|{key}`, `storage|{key}`.
- **Actions** (`ShellActions`) are the write side: a string switch onto the
  same `BrowserState` / `BrowserStore` operations the built-in UI calls.
- **Renderer.** `row`/`column` are HStack/VStack; `stack` is
  `ShellStackLayout`; every node is sized by `ShellSizeLayout` (CSS-like
  min/max/fill). `hover` / `pressed` / `focused` / `dropTarget` /
  `groupHover` style variants are resolved in SwiftUI, never in JS.
- **Native composites** (`ShellNatives`) are the existing views (`Sidebar`,
  `TabStack3D`, `ToolbarView`, …) behind `<Native name>`. A layout made of
  them is pixel-identical to the built-in UI because it *is* the built-in UI,
  rearranged.
- **Web islands** (`ShellWebIsland`): transparent `WKWebView`s serving branch
  files over `wowser-shell://`, with a `window.wowser` bridge. Remote URLs
  get no bridge.
- **Routing** (`ShellRouter`): `activeBranch` for normal windows, per-window
  overrides for previews. `ShellWindowHost` sits in `BrowserWindow.body` and
  `MobileContentView.body` and falls back to the built-in content.

Changes outside `Shell/` are small and marked with a comment mentioning
`Core/Shell`:

| File | Change |
| --- | --- |
| `UI/Window.swift` | `ShellWindowHost` around `WindowContent`; `WindowContent`, `WindowBG`, `SpaceUISchemeOverride` made internal |
| `MobileUI/MobileContentView.swift` | same switch; built-in UI extracted to `MobileNativeContentView` |
| `UI/PaneView.swift` | honours `\.shellOwnsToolbar` (page only, no toolbar / command bar) |
| `UI/SwipeableProfileSidebar.swift` | `ProfilePageView` internal, with `showFavorites` / `showTabs` |
| `Data/BrowserState+KeyboardFocus.swift`, `BrowserState.swift` | `FocusTarget.shellInput`, `WindowState.shellFocusedInput`; `navigate` / `load` hooks in the `WebContentDelegate` |
| `BrowserJS/*` | `browser.shell(action, args)` |
| `MCP/MCPServer.swift` | `shell`, `shell_docs` tools |
| `Settings`, `ToolbarTrailingItems.swift` | Settings → Customize |
| `Data/DefaultsKeys.swift` | `shellBranch`, `shellStartingBranch` |
| `Init.swift`, `Package.swift` | seed branches at launch; `.copy("Shell/ShellKit")` |

## Safety net

1. **Opt-in.** No branch selected ⇒ built-in UI, no JS context.
2. **Fallback.** Load error or root render error ⇒ built-in UI plus a banner
   (Undo / Restore last working version / Fix with agent / Use built-in).
3. **Error boundaries** in the kit layouts isolate sidebar and content.
4. **Checkpoints.** Every agent `write` snapshots the branch first; `undo` /
   `redo` swap snapshots. A branch that runs 3 s without a fatal error is
   recorded as "last working".
5. **Hang guard.** A 5 s execution limit per JS entry (private JSC symbol,
   looked up at runtime, skipped if absent). A branch that was mid-load when
   the app died is switched off at next launch (`shellStartingBranch`).
6. **`stock` is read-only** and refreshed from the bundle on launch.
7. **Headless `check`** runs a branch with mutating calls suppressed.

## Bring-up on a Mac

None of the Swift has been through a compiler. Expect a round of fixes; the
likely kinds, in order: SwiftUI overloads / availability in
`ShellRenderer.swift`, `ShellLeafViews.swift`, `ShellInteractions.swift`;
result-builder type inference; `@Observable` + `@ObservationIgnored`
details; ScreenCaptureKit signatures.

1. `cd Wowser/Core && swift build` — fix until green, then build the app in
   Xcode (CLAUDE.md: never two builds at once).
2. `cd scripts/shell && bun install && bun test` — should already pass (33).
3. Launch. Nothing should look different. Settings → Customize should list
   **Stock** and **Top Tabs**.
4. Click **Preview** on Stock. A second window opens. It should be
   indistinguishable from the first. Check, in the preview:
   - sidebar toggle, and the hover-reveal sidebar + inset page when hidden
   - toolbar auto-hide with the sidebar hidden
   - tab selection, drag-reorder, favorites, space switching
   - ⌘L / ⌘T focus the native command bar; typing works; Esc returns focus
     to the page
   - light / dark, a space with a background image, fullscreen
5. Edit the preview branch's entry to the kit layout (create a branch first —
   Stock is read-only): in `mac/index.tsx`,
   `export { default } from "../layouts/ClassicKit";`. The window should
   reload by itself. Check against `scripts/shell/out` simulator renders
   (`node sim/shot.js <branch> --entry layouts/ClassicKit`):
   - rows: hover reveals ×, selected row is tinted glass, drag a row onto
     another, context menu
   - address field: click → text field focused with URL selected; type →
     suggestions appear on the same keystroke; ↑↓ Enter Esc; clicking the
     page closes it and the page takes the keyboard again
   - empty tab (⌘T): centred command bar, Esc closes the tab
   - sidebar resize handle; favorites; space dots
6. Preview **Top Tabs**: tab strip drags the window from empty space,
   traffic lights sit in the strip, tabs shrink as they're added, drop on the
   trailing half of a tab inserts after it.
7. Break it on purpose: add `throw new Error("x")` to the layout → built-in
   UI + banner; **Undo Last Change** (after an agent write) or fix the file →
   recovers. Add `while (true) {}` → should hit the watchdog, not freeze.
8. Agent loop (Settings → MCP installed): in a terminal tab run `claude`,
   ask *"add a clock to my sidebar"*. Expect: `shell_docs`, `shell create`,
   `shell write` (with `check.ok`), `shell preview`, `shell screenshot`.
   Without screen-recording permission screenshots use the drawing fallback
   (materials flat); grant it for pixel-true captures.
9. Point & comment: Settings → Customize → Point at Something… → click a tab
   row → note → **Ask Agent**. The prompt should name the file and line.
10. `layouts/Playground` exercises every example at once, including the
    `navigate` hook (twitter.com → x.com), commands with hotkeys, a web
    panel and the canvas island.
11. iOS: set `shellBranch` to a branch whose `ios/index.tsx` exports
    `layouts/MobileKit`; check the bottom bar, tab sheet, keyboard focus.

Things I'd look at first if they misbehave:

- **Pressed looks on draggable nodes** use `onLongPressGesture(pressing:)`
  alongside `onTapGesture`; if they fight, drop the pressed state there.
- **`ShellSizeLayout`** places its child with `anchor`; a `Row` wider than
  its content anchors by `justify`/`align`. If rows look centred when they
  should be leading, that mapping is where to look.
- **Transparent web islands on macOS** rely on a guarded
  `setDrawsBackground:`; without it the island is opaque.
- **Focus**: `TextInput` reports `FocusTarget.shellInput`, which `focusState`
  returns ahead of the omnibox. If the page keeps the keyboard, check
  `InputTextField`'s `focusDate`.
- **`uiPublisher` cadence**: slices publish at most once per frame, plus
  once immediately after any JS-initiated action.

## Did the primitives cover real ideas?

Each row was either built (`examples/`, `layouts/`, with a test in
`scripts/shell/test`) or checked against the API.

| Idea (where it comes from) | How | Status |
| --- | --- | --- |
| Tabs on top (Chrome, Safari) | `kit/TabStrip` + `Content toolbar="hidden"` | built: `layouts/Chrome` |
| Vertical tabs restyled (Arc) | edit `kit/TabRow` | built: `layouts/ClassicKit` |
| Bookmarks bar | pinned tabs as a `Row` | built: `layouts/Chrome` |
| Tab search / quick switcher | `useHotkey`, overlay `Stack`, `TextInput` | built: `examples/TabSearch` |
| Group tabs by site, collapse (tree tabs lite) | derived data + `useStorage` | built: `examples/DomainGroups` |
| Zen / focus mode | hover zone + `animate` | built: `examples/ZenMode` |
| Status bar with progress + zoom (Vivaldi) | `useCurrentPane`, `panes.zoom*` | built: `examples/StatusBar` |
| Speed dial on new tab (Opera/Vivaldi) | `search.topSites()` | built: `examples/SpeedDial` |
| Reading list by drag & drop | `dropTypes`, `onDrop`, `useStorage` | built: `examples/ReadingList` |
| Web panels (Vivaldi) | `<WebIsland src="https://…" mobile>` | built: `examples/WebPanel` |
| Animated / canvas widgets | `<WebIsland>` + props/messages | built: `examples/Orb` |
| Redirect rules, block hosts | `on("navigate")` | built: `examples/behaviours` |
| Per-site CSS / userscripts | `panes.setInjection` | built: `examples/behaviours` |
| Custom commands + hotkeys | `commands.register` | built: `examples/behaviours` |
| Close duplicates / sort tabs | `readSlice("tabs")`, `tabs.move` | built: `examples/behaviours` |
| Phone layout with tab sheet | same hooks, different arrangement | built: `layouts/MobileKit` |
| Clock, pomodoro, notes, weather in sidebar | `useNow`, `useStorage`, `browser.net.fetch` | clock built; rest are the same shape |
| Workspace switcher as a menu / segmented control | `useSpaces`, `spaces.activate`, `Menu` | built into `layouts/Chrome` |
| Compact / density modes, custom colours | `kit/theme.ts`, tokens | API |
| Tab previews on hover | `Popover` + `TabThumbnail` (native) | API |
| Split-view tiling buttons | `tabs.splitWith`, `panes.setWeights` | API |
| Auto-hide toolbar | `Content toolbar="auto"` or own hover zone | API |
| Sidebar on the right | swap order in the `Row` | API (native `Sidebar` assumes leading edge for its resize handle; use `kit/Sidebar`) |
| Session buttons ("close all", "reopen") | `tabs.closeAll`, `tabs.reopenClosed` | API |
| Picture-in-picture shelf | `tab.isPip`, `tabs.setPip` | API |
| Ask-the-agent button, AI sidebar | `browser.agent.*` | API |

Gaps found while doing this, not yet filled:

- **Tab stacks / tree hierarchy as data**: only folders exist in the model.
  A real tree needs a parent pointer on `Tab` (and a sync decision).
- **Audio indicators / mute**: `WebContent` doesn't track playing state.
- **Downloads shelf**: downloads are tabs here; there is no `downloads`
  slice. Easy to add from `pane.download`.
- **Page context menu, menu-bar items**: not bridged.
- **Link-hover status text**: needs an injected listener; no event yet.
- **Weighted `flex`, grid**: stacks split equally. A flex `Layout` would fix
  it; the algorithm should be written as a pure function so it can be tested
  off-device (see `ShellSizeLayout`).
- **Mouse gestures, per-tab zoom memory, custom new-tab content types**: no
  primitives.
- **Commands in the native omnibox / app menu**: registered commands only
  appear in kit command bars.
- **iOS agent loop**: MCP is macOS-only; on iOS branches arrive by sync or
  file sharing, and there is no on-device preview tool.
- **Sync**: branches are not synced. `WindowState.shellFocusedInput` is
  transient and unsynced; nothing else persisted was added.

## Extending it

- **A new primitive prop**: `wowser.d.ts` → `ShellStyle` (parse) →
  `ShellStyledView` (apply) → `scripts/shell/sim/render.js` (approximate).
- **A new native component**: a case in `ShellNativeView`, a wrapper in
  `lib/native.js`, a declaration in `wowser.d.ts`.
- **A new slice**: `ShellSlices.compute`, a hook in `lib/index.js`, types in
  `wowser.d.ts`, the same shape in `scripts/shell/lib/fakeBrowser.js`.
- **A new action**: `ShellActions.perform`, a function in `lib/api.js`,
  `wowser.d.ts`, `fakeBrowser.js`. Put behaviour in a `BrowserState`
  extension, not in the switch.
- **A new event**: call `engine.emit(name, payload)` (or add a hook on
  `ShellRouter` for web-content events), document it in `EventMap`.
- After changing anything under `ShellKit/runtime`, run `bun test` in
  `scripts/shell`. After bumping Sucrase: `bun run build:transpiler`.
