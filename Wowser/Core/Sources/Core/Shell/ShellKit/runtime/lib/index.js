// `import { … } from "wowser"` — the kit of parts a browser UI is built from.
//
// Three layers, top to bottom:
//   1. "wowser/native": whole browser pieces implemented natively (tab list,
//      toolbar, command bar, web content). Fastest, least flexible.
//   2. The primitives here: boxes, text, images, inputs, scroll views. Styled
//      declaratively, including hover / pressed / drop-target looks, so the
//      common interactions never round-trip through JS.
//   3. <WebIsland>: a transparent web view running your own HTML, for canvas,
//      WebGL or a real web framework.
"use strict";
const R = require("./reconciler");
const store = require("./store");
const api = require("./api");

const host = globalThis.__host;
const h = R.h;

// ---------------------------------------------------------------- primitives

/** A box that stacks its children top to bottom. */
const Column = "column";
/** A box that lays its children out left to right. */
const Row = "row";
/** A box that layers its children back to front. */
const Stack = "stack";
/** Alias of Column, for React Native muscle memory. */
const View = "column";
/** Flexible empty space along the parent's axis. */
const Spacer = "spacer";
/** A hairline separator, perpendicular to the parent's axis. */
const Divider = "divider";
/** An SF Symbol: <Icon name="plus" size={12} weight="medium" />. */
const Icon = "icon";
/** An image from a URL, a file in the branch ("images/a.png") or an asset. */
const Image = "image";
/** A site favicon for a page URL (cached natively). */
const Favicon = "favicon";
/** The native icon for a tab (favicon, emoji, terminal chip, …). */
const TabIcon = "tabicon";
/** A scrolling container. `axis`: "vertical" (default) | "horizontal". */
const ScrollView = "scroll";
/** A single- or multi-line text field. */
const TextInput = "textinput";
/** The live web content of one pane (a tab, or one side of a split). */
const WebPane = "webpane";
/** A transparent web view running a file from this branch. */
const WebIsland = "webisland";
/** macOS traffic lights, for UIs that put them somewhere of their own. */
const WindowControls = "windowcontrols";

function flattenText(children, out, style) {
  if (children == null || typeof children === "boolean") return;
  if (Array.isArray(children)) {
    for (let i = 0; i < children.length; i++) flattenText(children[i], out, style);
    return;
  }
  if (typeof children === "string" || typeof children === "number") {
    const last = out[out.length - 1];
    if (last && last.style === style) last.text += String(children);
    else out.push({ text: String(children), style });
    return;
  }
  if (R.isElement(children) && (children.type === Text || children.type === "text")) {
    const p = children.props;
    const merged = p.style ? Object.assign({}, style, p.style) : style;
    if (p.text != null) flattenText(p.text, out, merged);
    flattenText(p.children, out, merged);
    return;
  }
  throw new Error("<Text> can only contain strings, numbers and nested <Text>.");
}

/** Text. Children are strings and nested <Text style> runs. */
function Text(props) {
  const rest = {};
  for (const k in props) if (k !== "children") rest[k] = props[k];
  const runs = [];
  flattenText(props.children, runs, undefined);
  if (runs.length <= 1 && (!runs[0] || runs[0].style === undefined)) {
    rest.text = runs[0] ? runs[0].text : props.text != null ? String(props.text) : "";
  } else {
    rest.runs = runs.map((r) => (r.style ? { text: r.text, style: r.style } : { text: r.text }));
  }
  return h("text", rest);
}

/** A tappable box. Same props as Row / Column / Stack; pick with `layout`. */
function Pressable(props) {
  const rest = {};
  let layout = "row";
  for (const k in props) {
    if (k === "layout") layout = props[k];
    else rest[k] = props[k];
  }
  if (rest.role == null) rest.role = "button";
  return h(layout === "column" ? "column" : layout === "stack" ? "stack" : "row", rest);
}

/** A native pull-down menu. Children are the label; `items` the entries. */
function Menu(props) {
  const [items, run] = api.menus.compile(props.items);
  const rest = {};
  for (const k in props) if (k !== "items" && k !== "children") rest[k] = props[k];
  rest.items = items;
  rest.onSelect = run;
  return h("menu", rest, props.children);
}

/** A popover anchored to `anchor`. Controlled: `open` + `onClose`. */
function Popover(props) {
  return h(
    "popover",
    { open: !!props.open, onClose: props.onClose, edge: props.edge || "bottom", style: props.style },
    h("stack", { key: "a" }, props.anchor),
    h("column", { key: "c", style: props.contentStyle }, props.open ? props.children : null)
  );
}

/** Embed a native view by name; see "wowser/native" for the catalogue. */
function Native(props) {
  return h("native", props);
}

// ---------------------------------------------------------------- state hooks

const WindowContext = R.createContext(null);

/** The id of the window this UI is drawn in. */
function useWindowId() {
  return host.windowId;
}

/** Window-level state: current space and tab, sidebar, command bar, focus. */
function useWindow(selector) {
  return store.useSlice("window", null, selector);
}

/** Every visible space, in order. */
function useSpaces() {
  return store.useSlice("spaces") || [];
}

/** One space (default: the window's current one). */
function useSpace(spaceId) {
  const current = useWindow((w) => (w ? w.spaceId : null));
  const id = spaceId || current;
  return useSpaces().find((s) => s.id === id) || null;
}

/** The tab strip of a space (default: current): `{ pinned, tabs, currentTabId }`.
 *  Each entry is a light TabInfo; `useTab(id)` has the full detail. */
function useTabs(spaceId) {
  return (
    store.useSlice("tabs", spaceId ? { space: spaceId } : null) || { pinned: [], tabs: [], currentTabId: null }
  );
}

/** One tab, including its panes. Null once it is closed. */
function useTab(tabId) {
  return store.useSlice("tab", tabId ? { id: tabId } : { id: "" });
}

/** One pane: URL, title, loading progress, back/forward state. */
function usePane(paneId) {
  return store.useSlice("pane", paneId ? { id: paneId } : { id: "" });
}

function useCurrentTab() {
  const id = useWindow((w) => (w ? w.currentTabId : null));
  return useTab(id);
}

function useCurrentPane() {
  const id = useWindow((w) => (w ? w.focusedPaneId : null));
  return usePane(id);
}

/** Colours of the current space: accent, onAccent, scheme, background. */
function useTheme() {
  return store.useSlice("theme") || { accent: "#0a84ff", onAccent: "#ffffff", scheme: "light" };
}

function useToasts() {
  return store.useSlice("toasts") || [];
}

/** A browser setting (a DefaultsKeys name). Returns `[value, set]`. */
function useSetting(key) {
  const value = store.useSlice("setting", { key });
  const set = R.useCallback((v) => api.settings.set(key, v), [key]);
  return [value, set];
}

/** State persisted in this branch's private storage. Returns `[value, set]`. */
function useStorage(key, initial) {
  const stored = store.useSlice("storage", { key });
  const value = stored == null ? initial : stored;
  const ref = R.useRef(value);
  ref.current = value;
  const set = R.useCallback(
    (v) => api.storage.set(key, typeof v === "function" ? v(ref.current) : v),
    [key]
  );
  return [value, set];
}

// ---------------------------------------------------------------- behaviour hooks

/** Listen for a native event while mounted. The listener may return a value
 *  for intercepting events ("navigate" → `{ cancel: true }`). */
function useEvent(name, fn) {
  const ref = R.useRef(fn);
  ref.current = fn;
  R.useEffect(() => api.on(name, (e) => ref.current(e)), [name]);
}

/** Register a command (command bar + menu + optional hotkey) while mounted. */
function useCommand(cmd) {
  const ref = R.useRef(cmd);
  ref.current = cmd;
  R.useEffect(
    () =>
      api.commands.register({
        id: cmd.id,
        title: cmd.title,
        icon: cmd.icon,
        hotkey: cmd.hotkey,
        keywords: cmd.keywords,
        run: (e) => ref.current.run(e),
      }),
    [cmd.id, cmd.title, cmd.icon, cmd.hotkey]
  );
}

let hotkeySeq = 1;
/** Bind a key combination ("cmd+shift+k", "ctrl+tab") while mounted. */
function useHotkey(combo, fn) {
  const id = R.useMemo(() => "hotkey:" + hotkeySeq++, []);
  useCommand({ id, title: "", hotkey: combo, run: fn });
}

/** Menu props for any box: `<Row {...useContextMenu(items)}>`. */
function useContextMenu(items) {
  const [data, run] = api.menus.compile(items);
  return { contextMenu: data, onContextMenuSelect: run };
}

function useInterval(fn, ms) {
  const ref = R.useRef(fn);
  ref.current = fn;
  R.useEffect(() => {
    if (ms == null) return undefined;
    const id = setInterval(() => ref.current(), ms);
    return () => clearInterval(id);
  }, [ms]);
}

/** The current time, re-rendering every `everyMs`. */
function useNow(everyMs) {
  const [now, setNow] = R.useState(() => Date.now());
  useInterval(() => setNow(Date.now()), everyMs || 1000);
  return now;
}

/** Command-bar suggestions for `query`: the instant local results now, the
 *  slower sources (history scan, search-engine completions) merged in when
 *  they arrive. */
function useSuggestions(query, opts) {
  const limit = (opts && opts.limit) || 6;
  const scope = opts && opts.scope;
  const instant = R.useMemo(() => api.search.suggest(query, { limit, scope }), [query, limit, scope]);
  const [more, setMore] = R.useState(null);
  R.useEffect(() => {
    let live = true;
    setMore(null);
    if (!query || (opts && opts.instantOnly)) return undefined;
    api.search
      .suggestMore(query, { limit, scope })
      .then((r) => {
        if (live && r) setMore({ query, results: r });
      })
      .catch(() => {});
    return () => {
      live = false;
    };
  }, [query, limit, scope]);
  return more && more.query === query ? more.results : instant;
}

// ---------------------------------------------------------------- fallback

/** What the root shows if the branch's UI throws while rendering. The
 *  native error screen offers undo / stock UI / "fix with agent". */
function RootErrorFallback(error) {
  return h("native", {
    name: "ErrorScreen",
    message: error && error.message ? String(error.message) : String(error),
    stack: error && error.stack ? String(error.stack) : "",
    componentStack: (error && error.shellStack) || [],
    style: { flex: 1 },
  });
}

module.exports = Object.assign(
  {
    // React-shaped core
    h,
    createElement: h,
    Fragment: R.Fragment,
    ErrorBoundary: R.ErrorBoundary,
    useState: R.useState,
    useReducer: R.useReducer,
    useEffect: R.useEffect,
    useLayoutEffect: R.useLayoutEffect,
    useMemo: R.useMemo,
    useCallback: R.useCallback,
    useRef: R.useRef,
    useId: R.useId,
    useContext: R.useContext,
    createContext: R.createContext,
    useSyncExternalStore: R.useSyncExternalStore,
    memo: R.memo,
    deepEqual: R.deepEqual,
    // primitives
    View,
    Column,
    Row,
    Stack,
    Spacer,
    Divider,
    Text,
    Icon,
    Image,
    Favicon,
    TabIcon,
    Pressable,
    ScrollView,
    TextInput,
    Menu,
    Popover,
    WebPane,
    WebIsland,
    WindowControls,
    Native,
    // state
    WindowContext,
    useSlice: store.useSlice,
    readSlice: store.read,
    useWindowId,
    useWindow,
    useSpaces,
    useSpace,
    useTabs,
    useTab,
    usePane,
    useCurrentTab,
    useCurrentPane,
    useTheme,
    useToasts,
    useSetting,
    useStorage,
    // behaviour
    useEvent,
    useCommand,
    useHotkey,
    useContextMenu,
    useInterval,
    useNow,
    useSuggestions,
    on: api.on,
    RootErrorFallback,
  },
  {
    tabs: api.tabs,
    panes: api.panes,
    spaces: api.spaces,
    folders: api.folders,
    window: api.window,
    commandBar: api.commandBar,
    search: api.search,
    toasts: api.toasts,
    settings: api.settings,
    storage: api.storage,
    clipboard: api.clipboard,
    commands: api.commands,
    menus: api.menus,
    browser: api.browser,
    shell: api.shell,
    haptics: api.haptics,
    call: api.call,
    callAsync: api.callAsync,
  }
);
