# Customising the Wowser UI

The Wowser browser window — sidebar, tabs, toolbar, command bar, everything
around the web page — can be drawn by a **branch**: a folder of TypeScript /
JSX that you can read and change. This guide is how to do that well. The API
you write against follows it as `wowser.d.ts`; treat that file as the source
of truth for names and props.

## The model in one minute

- A branch's entry file default-exports a component that draws the whole
  window. It is React-shaped (function components, hooks, JSX) but there is
  **no DOM**: you render native views (`Row`, `Column`, `Stack`, `Text`,
  `Icon`, `TextInput`, …) and native browser pieces (`Sidebar`, `TabList`,
  `Content`, …).
- The code runs inside the browser, on its main thread, next to the browser's
  own state. Reading state is a hook (`useTabs()`, `usePane(id)`); changing it
  is a synchronous call (`tabs.close(id)`, `panes.back(id)`).
- Every window runs its own copy. A reload (any file change) starts the code
  from scratch; only what you put in `storage` / `useStorage` survives.
- If a branch fails to load or its root throws, the window falls back to the
  built-in UI with a banner. One broken widget inside an `ErrorBoundary` only
  takes itself down.

## Where things are

```
<branches folder>/<branch>/
  manifest.json        name, description, entry per platform
  mac/index.tsx        entry for macOS   → picks a layout
  ios/index.tsx        entry for iOS
  layouts/             whole-window arrangements
    Classic.tsx          the stock look, built from native parts
    ClassicKit.tsx       the same look, every part written with primitives
    Chrome.tsx           tabs on top
    Mobile.tsx / MobileKit.tsx
    Playground.tsx       all the examples at once
  kit/                 browser parts written with primitives — edit these
    Sidebar, TabList, TabRow, Favorites, SpaceDots, TabStrip,
    Toolbar, AddressField, SuggestionList, CommandBar, commandBar.ts,
    Toasts, IconButton, tabMenu.ts, theme.ts
  examples/            small customisations to copy from (see its README)
```

`stock` is the built-in branch. It is **read-only** and is replaced when the
app updates. Never edit it: create a branch from it and edit that.

## The tool

Everything goes through one tool with an `action` and `args`:

- MCP: `shell` (and `shell_docs`, which returns this guide).
- BrowserJS: `await browser.shell(action, args)`.

| action | args | result |
| --- | --- | --- |
| `docs` | – | `{ guide, types }` |
| `branches` | – | `{ folder, active, previewWindows, branches[] }` |
| `create` | `{ name, from?, title?, description? }` | the new branch (`from` defaults to `"stock"`) |
| `delete` | `{ name }` | |
| `files` | `{ branch }` | paths |
| `read` | `{ branch, path }` or `{ branch, paths }` | `{ files: { path: content } }` |
| `write` | `{ branch, files: { path: content \| null }, summary }` | `{ check }` — `null` deletes a file |
| `check` | `{ branch }` | `{ ok, failure?, errors?, logs?, nodes }` — loads the branch headlessly |
| `undo` / `redo` | `{ branch }` | what was undone, plus a `check` |
| `history` | `{ branch }` | the undo stack |
| `preview` | `{ branch }` | `{ windowId, status }` — opens a window drawn by that branch |
| `closePreview` | `{ windowId }` | |
| `windows` | – | windows currently drawn by a branch |
| `screenshot` | `{ windowId? }` | an image of the window (1 px = 1 pt) |
| `inspect` | `{ windowId?, depth? }` | the rendered node tree with frames `[x, y, w, h]` |
| `describe` | `{ windowId?, nodeId }` | where a node comes from: file, line, owning components |
| `logs` | `{ windowId?, limit? }` | `console.*` output and errors |
| `eval` | `{ windowId?, code }` | run JS in the UI context (`__shell.require("wowser")` gets the API) |
| `event` | `{ windowId?, nodeId \| testID, event, payload? }` | fire `onPress` etc. on a node |
| `feedback` | `{ resolve? }` | notes the user left by pointing at things |
| `inspectMode` | `{ windowId?, on? }` | turn point-and-comment on for the user |
| `activate` | `{ branch }` (or `{}` for built-in) | make a branch the UI of every window |

`windowId` defaults to a preview window if one is open.

You can also edit the files directly on disk (the `folder` from `branches`):
the browser reloads a branch whenever its files change. `write` is better for
agent edits because each call is one **undo step** and tells you immediately
whether the branch still loads.

## How to work

1. `branches` — see what exists and what is active. If the user is on the
   built-in UI or on `stock`, `create` a branch (ask what to call it, or pick
   a short name).
2. `read` the files you'll touch. Start from the entry (`mac/index.tsx`) and
   the layout it points to. Read the `kit/` component before replacing it.
3. Make one change at a time with `write`. Look at `check` in the reply:
   `ok: false` comes with the error and a `file:line`.
4. `preview` the branch and take a `screenshot`. **Look at it.** Compare with
   what the user asked for. Use `inspect` when something is the wrong size or
   in the wrong place — frames tell you which box is wrong — and `event` to
   click through a flow.
5. Iterate. When it's right, tell the user and offer to `activate`. Don't
   activate a branch you haven't seen working in a preview.
6. If you made things worse, `undo` instead of patching forward.

When the user leaves point-and-comment notes, `feedback` returns them with the
node's source location — fix those, then `feedback { resolve: id }`.

## Three layers — use the highest one that does the job

1. **Native composites** (`wowser/native`): `Sidebar`, `SpacePager`,
   `FavoritesGrid`, `TabList`, `TabRow`, `NewTabButton`, `SpaceDots`,
   `SpaceName`, `Content`, `Toolbar`, `CommandBar`, `Toasts`,
   `WindowBackground`, `LoadingBar`, `TabThumbnail`. These are the browser's
   real views: every interaction, animation and edge case already works, and
   they cost nothing in JS. Rearranging them is the cheapest customisation.
2. **Primitives** (`wowser`) and the **kit** built from them. When a native
   piece doesn't bend far enough — tabs across the top, a different tab row,
   your own toolbar — swap it for its `kit/` twin and edit that. The kit is
   ordinary code in the branch; it is yours.
3. **`<WebIsland>`**: a transparent web view running an HTML file from the
   branch, for canvas, WebGL, or a real web framework. Feed it `props`,
   listen with `onMessage`. Also how you embed a remote site in the chrome
   (a "web panel").

`Content` is the web page area (split panes included). With
`toolbar="hidden"` it shows only pages, and you draw the toolbar and command
bar yourself (`kit/Toolbar`, `kit/CommandBar`, driven by `useCommandBar()`).

## Layout: SwiftUI rules, not CSS

- `Row` lays out left→right, `Column` top→bottom, `Stack` back→front.
- A box **hugs its content** unless something inside wants to grow. `flex`,
  `width/height: "fill"`, `Spacer`, `ScrollView`, `WebPane`, `WebIsland` and
  `Content` grow; a box containing one grows with it.
- `flex` siblings split leftover space **equally** (the number isn't a
  weight). Cap with `maxWidth`.
- A `Column` centres its children horizontally by default. For a list of
  full-width rows use `align: "stretch"`.
- Overlays: put things in a `Stack` and position with `alignSelf`
  (`"topTrailing"`, `"bottom"`, …) and `offset`. Later children draw on top.
- The window root should be `<Stack style={{ flex: 1 }}>` with a
  `<WindowBackground style={{ flex: 1 }} />` as its first child; put two
  growing things in one `Column` only if you mean them to split the space.
- macOS draws no system traffic lights: place `<WindowControls />` exactly
  once (the native `Sidebar` and `Toolbar` include it), and mark the empty
  part of your title bar `windowDrag`.

## Looks that respond instantly

Hover, pressed, focused, disabled and drop-target looks are **part of
`style`** and are resolved natively:

```tsx
<Pressable group style={{ cornerRadius: 8, hover: { background: "primary/0.07" }, pressed: { scale: 0.97 }, animate: "snappy" }}>
  <Text>Row</Text>
  <Icon name="xmark" style={{ opacity: 0, groupHover: { opacity: 1 } }} />
</Pressable>
```

Don't keep a `hovered` state to change a colour. Use `onHover` only when
hovering should *do* something. `animate` on a node animates its own style
changes and its children being added / removed (`transition` on the child
says how it appears).

Colours are tokens: `"primary"`, `"secondary"`, `"accent"`, `"onAccent"`,
`"background"`, hex — each optionally with alpha: `"accent/0.5"`. Use tokens
so light / dark mode and the space's colour just work. Materials:
`background: { material: "glass", tint: "accent/0.5" }`.

## State

- Read the narrowest slice, as low in the tree as possible. `useCurrentPane()`
  changes many times a second while a page loads: use it in the small
  component that shows progress, not at the root.
- `useWindow(w => w.sidebarVisible)` re-renders only when that field changes.
- Lists: give rows a `key` and wrap the row component in `memo`.
- `useStorage(key, initial)` for anything that should survive a reload or a
  restart; `useState` for the rest.
- Don't animate by `setInterval` + `setState`. Use `style.animate`, a native
  component, or a `WebIsland`.

## The command bar

`useCommandBar()` (kit/commandBar.ts) owns the query, suggestions and key
handling; `AddressField`, `CommandBar` and `SuggestionList` render it.
`search.suggest(query)` is synchronous and local (open tabs, top history,
typed URL, actions) — call it on every keystroke; `useSuggestions` merges in
the slow sources when they arrive. `search.open(suggestion)` runs one.
A `TextInput` holds keyboard focus until it blurs; `panes.focus(id)` gives the
keyboard back to the page.

## Behaviour without UI

Export `setup()` from the entry module; it runs once per window:

```ts
export function setup() {
  const off = on("navigate", (e) => (e.url.includes("ads.") ? { cancel: true } : null));
  const unregister = commands.register({ id: "tidy", title: "Tidy Tabs", hotkey: "cmd+shift+y", run: () => { … } });
  return () => { off(); unregister(); };
}
```

Events: `navigate` (may return `{ cancel: true }` or `{ redirect: url }`),
`load`, `tabCreated`, `tabClosed`, `tabActivated`, `spaceActivated`,
`windowKey`. Per-site CSS / JS: `panes.setInjection(host, { css, js })`.
The whole agent-facing API is available too, as `browser.*` (async).

## Debugging

- A load error names the file and line. A render error also lists the
  component stack. Fix the first error; later ones are usually fallout.
- `logs` shows `console.log` output. `eval` lets you poke at the running UI:
  `__shell.require("wowser").tabs.visibleOrder()`.
- "Objects are not valid as a child": you rendered an object or a function;
  render a string or an element.
- "Cannot find module": imports are relative to the importing file, or from
  the branch root without a leading `./` (`import … from "kit/TabRow"`).
- Nothing shows / everything is squeezed to one corner: a box isn't growing.
  The root or a wrapper is missing `flex: 1`, or a `Column` needs
  `align: "stretch"`. `inspect` shows the frames.
- A hover look doesn't apply: the variant is in `style`, not a prop, and
  `groupHover` needs an ancestor with the `group` prop.

## Rules

- Never edit `stock`. Never `activate` a branch you haven't previewed.
- Keep the user's browser usable: there must always be a way to see tabs,
  open the command bar and reach the page. Don't remove `Content`.
- Keep changes small and reversible; say what you changed and how to undo it
  (`undo`, or Settings → Customize).
- Prefer moving and wrapping existing pieces over rewriting them.
- Don't put secrets in a branch, and don't make network requests from UI
  code unless the user asked for the feature that needs them.
- Test on the platform you changed: `mac/` and `ios/` are separate entries.

## Not possible yet (say so rather than fake it)

- Menu-bar items and the right-click menu inside web pages.
- New kinds of tab content (a tab is a web page or one of the built-in
  native pages).
- Weighted `flex`, CSS grid, arbitrary shapes or drawing — use a `WebIsland`.
- Changing other apps' windows, or anything outside the browser.
