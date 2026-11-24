# Customising the Wowser UI

The Wowser browser window — sidebar, tabs, toolbar, command bar, everything
around the web page, plus floating panels and overlays outside it — can be
drawn by a **branch**: a folder of views that you can read and change. This
guide is how to do that well. The API you write against follows it as
`wowser.d.ts`; treat that file as the source of truth for names and props.

## The model in one minute

- A **view** is two files with one name: `TabRow.xml` is the **template**
  (what is on screen, as a tree of tags) and `TabRow.ts` is the **logic**
  (state, derived values, handlers). The logic file is optional — many views
  are a template alone.
- There is **no DOM**. Tags are native views (`Row`, `Column`, `Stack`,
  `Text`, `Icon`, `TextInput`, …), native browser pieces (`native:Sidebar`,
  `native:Content`, …) and other views of the branch (`<TabRow tab="{t}"/>`).
- The code runs inside the browser, on its main thread, next to the browser's
  own state. Reading state is `$tabs` / `$pane` in a template or a hook
  (`useTabs()`, `usePane(id)`) in logic; changing it is a synchronous call
  (`tabs.close(id)`, `panes.back(id)`).
- A template renders by itself. Write the template first and look at it; add
  logic when it needs behaviour. If the logic file is missing or broken the
  view still shows (inert), with the error in `logs`.
- Every window runs its own copy. A reload (any file change) starts the code
  from scratch; only what you put in `storage` / `useStorage` survives.
- If a branch fails to load or its root throws, the window falls back to the
  built-in UI with a banner. One broken widget inside an `ErrorBoundary` only
  takes itself down.

## Where things are

```
<branches folder>/<branch>/
  manifest.json        name, description, entry per platform
  mac/index.xml        entry for macOS   → picks a layout
  ios/index.xml        entry for iOS
  layouts/             whole-window arrangements
    Classic              the stock look, built from native parts
    ClassicKit           the same look, every part written with primitives
    Chrome               tabs on top
    Mobile / MobileKit
    Playground           all the examples at once
  kit/                 browser parts written with primitives — edit these
    Sidebar, TabList, TabRow, Favorites, SpaceDots, TabStrip,
    Toolbar, AddressField, SuggestionList, CommandBar, Toasts, IconButton,
    commandBar.ts, tabMenu.ts, theme.ts      (plain modules, no template)
  examples/            small customisations to copy from (see its README)
```

`stock` is the built-in branch. It is **read-only** and is replaced when the
app updates. Never edit it: create a branch from it and edit that.

## Templates

```xml
<!-- kit/TabRow.xml.  Props: tab -->
<view>
  <Pressable group height="34" padding.horizontal="8" gap="8" align="center" cornerRadius="8"
             background="{tab.isCurrent ? 'accent/0.2' : 'clear'}" hover:background="primary/0.07"
             onPress="tabs.select(tab.id)">
    <TabIcon tabId="{tab.id}" size="16"/>
    <Text flex="1" lineLimit="1">{tab.title}</Text>
    <Icon if="{tab.isPinned}" name="pin.fill" size="9"/>
    <Pressable opacity="0" groupHover:opacity="1" onPress="tabs.close(tab.id)"><Icon name="xmark" size="9"/></Pressable>
  </Pressable>
</view>
```

- **Root** is `<view>`. Its children are what the view draws.
- **Attributes** are style keys and props, flat: `height="34"`,
  `padding.left="8"`, `shadow.radius="10"`, `margin="2 6"` (→ `[2, 6]`).
  Numbers and `true`/`false` are read as such; a bare attribute is `true`
  (`<Row group>`). State variants are prefixes: `hover:background`,
  `pressed:scale`, `groupHover:opacity`, `dropTarget:border.color`,
  `dark:color`.
- **`{…}`** is a JS expression: `title="{tab.title}"`, text content
  `{count} tabs`, mixed `testID="tab-{tab.id}"`. An object literal needs its
  own braces: `style="{{ opacity: 0.5 }}"`. In attribute values write `&lt;`
  and `&amp;&amp;` for `<` and `&&` — or keep the expression in logic.
- **What an expression can see**, nearest first: loop variables; `event`
  (inside handlers); what the logic returns; the view's own state; the
  view's props (by name, and as `props`); `<import>`ed names; browser state
  `$window $spaces $space $tabs $tab $pane $theme $toasts $mouse $screen`
  and `$tabById(id) $paneById(id) $tabsOf(spaceId) $setting(key)
  $storage(key, fallback)`; and the actions `tabs panes spaces folders
  window commandBar search toasts settings storage clipboard commands menus
  shell haptics mouse browser`. A view re-renders only when a `$…` it read
  changes.
- **Control flow** is attributes: `if="{…}"`, `else-if="{…}"`, `else`,
  `for="tab in tabs"` / `for="(tab, i) in tabs"` with `key="{tab.id}"`.
  Use `<Fragment if=…>` to switch several siblings at once.
- **Handlers** (`on…` attributes) are code that runs when the event fires:
  `onPress="tabs.close(tab.id)"`, `onHover="peek = event"`. `event` is the
  payload. If the value is just a function (`onChangeText="{setQuery}"`) it
  is called with the event's arguments.
- **State without logic**: `<view state="{ open: false }">` then
  `onPress="open = !open"`. Assigning to a name the logic returned calls its
  setter (`zen = true` → `setZen(true)`).
- **Other views** are tags. A tag resolves to an `<import name="X"
  from="./X"/>`, else a file of that name next to this one, else the one view
  with that name anywhere in the branch (`kit/` wins a tie). Attributes
  become its props; to pass style, use `style="{{ … }}"` or `style.width=`.
- **Children and slots**: `<children/>` is where the caller's content goes;
  `<slot name="chrome"/>` takes the caller's child marked `slot="chrome"`.
  Both may contain fallback content.
- **Menus**: a `<contextMenu>` child with `<item title icon onSelect>`,
  `<separator/>`, nested `<menu title>` — or `items="{expr}"`. `<Menu>`
  takes `<items>` the same way.
- **Imports**: `<import name="theme" from="./theme"/>` brings a module into
  scope as a value (`{theme.HEADER_HEIGHT}`), or names the view a tag means.
- `bind="{obj}"` spreads an object of props onto a tag. `ref="{r}"`.
- The parser is forgiving: a half-written template still renders what is
  there, and `check` reports the problems (in `logs`) with line numbers.

## Logic

```ts
// examples/ZenMode.ts — next to ZenMode.xml
import { useStorage, useHotkey } from "wowser";

export default function ZenMode({ hotkey = "cmd+shift+." }) {
  const [zen, setZen] = useStorage("zen", false);
  useHotkey(hotkey, () => setZen(!zen));
  return { zen, setZen };           // names the template can use
}
```

The default export gets the view's props and returns the template's scope.
It runs on every render of the view, so hooks work and derived values are
just expressions. Keep templates declarative: if a binding grows past a
short expression, compute it in logic and give it a name. Named exports of
the logic file are importable by other files (`import { useTabPalette } from
"./TabSearch"`).

A file may instead be a `.tsx` component (`export default function X(props)
{ return <Row>…</Row> }`). Templates and components use each other freely;
prefer templates so the UI stays readable and streamable.

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
2. `read` the files you'll touch. Start from the entry (`mac/index.xml`) and
   the layout it points to. Read the `kit/` view before replacing it.
   Write the template first; add a logic file only when it needs one.
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

1. **Native composites** (`<native:Name>`; `wowser/native` in code):
   `Sidebar`, `SpacePager`, `FavoritesGrid`, `TabList`, `TabRow`,
   `NewTabButton`, `SpaceDots`, `SpaceName`, `Content`, `Toolbar`,
   `CommandBar`, `Toasts`, `WindowBackground`, `LoadingBar`, `TabThumbnail`.
   These are the browser's real views: every interaction, animation and edge
   case already works, and they cost nothing in JS. Rearranging them is the
   cheapest customisation.
2. **Primitives** and the **kit** built from them. When a native piece
   doesn't bend far enough — tabs across the top, a different tab row, your
   own toolbar — swap it for its `kit/` twin and edit that. The kit is
   ordinary views in the branch; it is yours.
3. **`<WebIsland>`**: a transparent web view running an HTML file from the
   branch, for canvas, WebGL, or a real web framework. Feed it `props`,
   listen with `onMessage`. Also how you embed a remote site in the chrome
   (a "web panel").

`<native:Content>` is the web page area (split panes included). With
`toolbar="hidden"` it shows only pages, and you draw the toolbar and command
bar yourself (`kit/Toolbar`, `kit/CommandBar`, driven by `useCommandBar()`).

## Layout: SwiftUI rules, not CSS

- `Row` lays out left→right, `Column` top→bottom, `Stack` back→front.
- A box **hugs its content** unless something inside wants to grow. `flex`,
  `width/height="fill"`, `Spacer`, `ScrollView`, `WebPane`, `WebIsland` and
  `Content` grow; a box containing one grows with it.
- `flex` siblings split leftover space **equally** (the number isn't a
  weight). Cap with `maxWidth`.
- A `Column` centres its children horizontally by default. For a list of
  full-width rows use `align="stretch"`.
- Overlays: put things in a `Stack` and position with `alignSelf`
  (`"topTrailing"`, `"bottom"`, …) and `offset`. Later children draw on top.
- The window root should be `<Stack flex="1">` with
  `<native:WindowBackground flex="1"/>` as its first child; put two growing
  things in one `Column` only if you mean them to split the space.
- macOS draws no system traffic lights: place `<WindowControls/>` exactly
  once (the native `Sidebar` and `Toolbar` include it), and mark the empty
  part of your title bar `windowDrag`.

## Looks that respond instantly

Hover, pressed, focused, disabled and drop-target looks are **style
variants**, resolved natively on the same frame as the pointer:

```xml
<Pressable group cornerRadius="8" hover:background="primary/0.07" pressed:scale="0.97" animate="snappy">
  <Text>Row</Text>
  <Icon name="xmark" opacity="0" groupHover:opacity="1"/>
</Pressable>
```

Don't keep a `hovered` state to change a colour. Use `onHover` only when
hovering should *do* something. `animate` on a node animates its own style
changes and its children being added / removed (`transition` on the child
says how it appears). Because template elements keep their identity by
position, an `if` that turns on animates in without disturbing its siblings.

Colours are tokens: `"primary"`, `"secondary"`, `"accent"`, `"onAccent"`,
`"background"`, hex — each optionally with alpha: `"accent/0.5"`. Use tokens
so light / dark mode and the space's colour just work. Materials:
`background.material="glass" background.tint="accent/0.5"`.

## State

- Read the narrowest thing, as low in the tree as possible. `$pane` /
  `useCurrentPane()` change many times a second while a page loads: read
  them in the small view that shows progress, not at the root.
- `useWindow(w => w.sidebarVisible)` re-renders only when that field changes.
- Lists: give rows a `key`. A row that is its own view re-renders only when
  its props change.
- `useStorage(key, initial)` / `$storage(key)` for anything that should
  survive a reload or a restart; `useState` / `<view state>` for the rest.
- Don't animate by `setInterval` + `setState`. Use `animate`, a native
  component, or a `WebIsland`.

## The command bar

`useCommandBar()` (kit/commandBar.ts) owns the query, suggestions and key
handling; `AddressField`, `CommandBar` and `SuggestionList` render it.
`search.suggest(query)` is synchronous and local (open tabs, top history,
typed URL, actions) — call it on every keystroke; `useSuggestions` merges in
the slow sources when they arrive. `search.open(suggestion)` runs one.
A `TextInput` holds keyboard focus until it blurs; `panes.focus(id)` gives the
keyboard back to the page.

## Windows, panels and overlays

`<Window>` draws its children in their own native window. Mount it to show
the window, unmount it (`if="{…}"`) to close it; it is otherwise an ordinary
part of the view, with the same state and handlers.

```xml
<Window if="{open}" kind="panel" width="384" height="216" anchor="bottomTrailing" inset="24"
        resizable autosave="pip" onClose="open = false">
  <WebPane paneId="{paneId}" cropTo="video" flex="1"/>
</Window>
```

- `kind="panel"` (default): floating, borderless, doesn't take focus —
  picture-in-picture, palettes. `kind="window"`: a normal titled window — a
  pop-out. `kind="overlay"`: borderless, above every app, on every desktop —
  launchers, HUDs, cursor effects; add `clickThrough` for decoration, or
  `activates` when it contains a `TextInput`.
- Place with `anchor` + `inset` (within the screen, or `relativeTo="window"`)
  or `x`/`y`. Screen coordinates are points from the top-left of the primary
  display; `$screen` / `useScreen()` give the current screen's frame.
- On `<Window>`, `width`/`height`/`x`/`y`/`anchor` are the window's, not
  style. Style the content inside it.
- Always handle `onClose` (the user pressed Esc or the close button) by
  unmounting it.

## Web contents: scale, crop, watch

- `<WebPane paneId>` shows a pane's live page. `viewport="{{ width: 1200 }}"`
  lays the page out at that width and scales it to fit (thumbnails, mini
  windows). `crop="{{ x, y, width, height }}"` shows one rectangle of it;
  `cropTo="video"` follows an element, natively, as the page moves.
  `interactive="{false}"` makes it display-only.
- A page is on screen in **one place at a time**. A pop-out shows a pane that
  isn't the window's current one — typically a background tab (see
  `examples/PopOutVideo`).
- `useWatch(paneId, js)` is the live value of an expression inside the page
  (`"document.title"`, "is the video playing"); `useElementRect(paneId,
  selector)` is where an element is. `panes.watch(…)` is the same outside a
  view. `panes.eval(paneId, js)` runs something once.
- `on("navigate")` / `on("load")` observe and steer navigation;
  `panes.setInjection(host, { css, js })` changes a site persistently.

## Pointer and keys

- `$mouse` / `useMouse()`: the pointer in the window (`x`, `y`, `inside`),
  tracked slightly past the window's edges — edge reveals without hover
  strips (`examples/EdgePeek`). Only views that read it re-render.
- On any box: `onHover`, `onMouseMove` (position in the box), `onPan`
  (drags), `onScrollWheel`, `onMagnify` (pinch), `onPress` with
  `event.modifiers` / `event.x` / `event.y`, `onDoublePress`, `onLongPress`,
  drag and drop (`draggable`, `dropTypes`, `onDrop`), `cursor`, and
  `pointerEvents="none"` to let the pointer through.
- `mouse.location()` and `mouse.onGlobalMove(fn)` / `on("globalMouse")`: the
  pointer anywhere on screen, in any app (`examples/CursorHalo`).
- `useHotkey("cmd+shift+k", fn)` while the window is key;
  `useGlobalHotkey("ctrl+alt+space", fn)` everywhere, even with another app
  in front (`examples/GlobalSwitcher`). `window.activate()` brings the
  browser forward.

## Behaviour without UI

Export `setup()` from the entry's logic file (`mac/index.ts`); it runs once
per window:

```ts
export function setup() {
  const off = on("navigate", (e) => (e.url.includes("ads.") ? { cancel: true } : null));
  const unregister = commands.register({ id: "tidy", title: "Tidy Tabs", hotkey: "cmd+shift+y", run: () => { … } });
  return () => { off(); unregister(); };
}
```

Events: `navigate` (may return `{ cancel: true }` or `{ redirect: url }`),
`load`, `tabCreated`, `tabClosed`, `tabActivated`, `spaceActivated`,
`windowKey`, `globalMouse`. The whole agent-facing API is available too, as
`browser.*` (async).

## Debugging

- A load error names the file and line. A render error also lists the view
  stack. Fix the first error; later ones are usually fallout.
- A binding that throws (`{tab.title}` while `tab` is undefined) renders as
  empty and logs one warning with the template line — check `logs` when
  something is blank.
- An unknown tag draws a labelled placeholder box: the view wasn't found
  (wrong name, or two views share the name — add an `<import>`).
- `logs` shows `console.log` output. `eval` lets you poke at the running UI:
  `__shell.require("wowser").tabs.visibleOrder()`.
- "Cannot find module": imports are relative to the importing file, or from
  the branch root without a leading `./` (`from "kit/theme"`).
- Nothing shows / everything is squeezed to one corner: a box isn't growing.
  The root or a wrapper is missing `flex="1"`, or a `Column` needs
  `align="stretch"`. `inspect` shows the frames.
- A hover look doesn't apply: `groupHover:` needs an ancestor with `group`;
  on another *view's* tag a style attribute is a prop — pass `style=`.
- A `<Window>` came out the wrong size: its `width`/`height` are attributes
  of the tag itself, not of a child.

## Rules

- Never edit `stock`. Never `activate` a branch you haven't previewed.
- Keep the user's browser usable: there must always be a way to see tabs,
  open the command bar and reach the page. Don't remove `Content`.
- Global hotkeys and overlays reach outside the browser: add them only when
  asked, pick combinations other apps don't use, and make every overlay
  dismissable (Esc / `onClose`). Never leave a full-screen overlay up that
  isn't `clickThrough`.
- Page watches run inside the user's pages. Read only what the feature
  needs, and never send page content anywhere.
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
- Global *keyboard* monitoring beyond registered hotkeys, clicks in other
  apps, changing other apps' windows.
- Showing one page in two places at once (a page has one web view).
- Global hotkeys, overlays and scroll-wheel events on iOS (`<Window>` is a
  sheet there).
