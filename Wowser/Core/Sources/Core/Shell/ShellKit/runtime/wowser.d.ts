// The Wowser shell API — everything a branch's UI code can import.
//
// A *branch* is a folder of TS/JS files that draws the whole browser window.
// Its entry module (see manifest.json) default-exports a component:
//
//   import { Row, useWindow } from "wowser";
//   import { Sidebar, Content } from "wowser/native";
//   export default function Browser() {
//     const win = useWindow();
//     return <Row style={{ flex: 1 }}>{win.sidebarVisible && <Sidebar />}<Content /></Row>;
//   }
//
// The code runs in JavaScriptCore on the app's main thread, next to the
// browser model. There is no DOM, no `window`, no `fetch`. What you render is
// a tree of native views. Files may be .tsx / .ts / .jsx / .js; JSX needs no
// import. Types are documentation: nothing type-checks at load time.
//
// Mental model, three layers — reach for the highest one that fits:
//   1. "wowser/native"  whole browser pieces (tab list, toolbar, web content),
//                       implemented natively, pixel-identical to the built-in UI.
//   2. primitives       Row / Column / Stack / Text / Icon / TextInput / …
//                       Looks for hover, press, focus and drop-target are part
//                       of `style`, resolved natively — never set state on hover
//                       just to change a colour.
//   3. <WebIsland>      a transparent web view running your own HTML, for
//                       canvas / WebGL / a real web framework.
//
// Performance rules of thumb:
//   - Read state with the narrowest hook: `usePane(id)` in the one component
//     that shows progress, not `useTabs()` at the root.
//   - Give list children a `key` and wrap rows in `memo`.
//   - Anything that animates continuously belongs in a native component, a
//     `style.animate`, or a WebIsland — not in a `setInterval` + setState loop.

declare module "wowser" {
  // ================================================================ React-shaped core

  export type Key = string | number;
  export interface Element {
    readonly $$shell: true;
  }
  export type Child = Element | string | number | boolean | null | undefined;
  export type Children = Child | Children[];
  export type Component<P = {}> = (props: P & { children?: Children }) => Children;

  export function h(type: string | Component<any>, props?: object | null, ...children: Children[]): Element;
  export const createElement: typeof h;
  export const Fragment: unique symbol;

  /** Contains render errors. `fallback` gets the error and a `reset` that
   *  re-renders the children. Wrap independent regions (a widget, the
   *  sidebar) so one bug can't blank the window. */
  export const ErrorBoundary: Component<{
    fallback: Children | ((error: Error, reset: () => void) => Children);
  }>;

  export function useState<T>(initial: T | (() => T)): [T, (next: T | ((prev: T) => T)) => void];
  export function useReducer<S, A>(reducer: (state: S, action: A) => S, initial: S): [S, (action: A) => void];
  /** Runs after the tree is committed. All effects are synchronous. */
  export function useEffect(effect: () => void | (() => void), deps?: readonly unknown[]): void;
  export const useLayoutEffect: typeof useEffect;
  export function useMemo<T>(compute: () => T, deps: readonly unknown[]): T;
  export function useCallback<F extends Function>(fn: F, deps: readonly unknown[]): F;
  export function useRef<T>(initial: T): { current: T };
  export function useId(): string;
  export interface Context<T> {
    Provider: Component<{ value: T }>;
  }
  export function createContext<T>(defaultValue: T): Context<T>;
  export function useContext<T>(context: Context<T>): T;
  export function useSyncExternalStore<T>(subscribe: (onChange: () => void) => () => void, getSnapshot: () => T): T;
  /** Skip re-rendering when props are unchanged. Plain-data props (a tab
   *  object, a style) compare structurally; functions compare by identity. */
  export function memo<P>(component: Component<P>, areEqual?: (prev: P, next: P) => boolean): Component<P>;
  export function deepEqual(a: unknown, b: unknown): boolean;

  // ================================================================ Style

  /**
   * A colour. One of:
   *  - a semantic name that follows light/dark mode and the space's theme:
   *    "primary" (text), "secondary", "tertiary", "accent" (the space accent),
   *    "onAccent" (text on accent), "background" (page-chrome background),
   *    "separator", "clear", "white", "black", "red", "orange", "yellow",
   *    "green", "blue", "purple", "pink", "gray"
   *  - hex: "#rgb", "#rrggbb", "#rrggbbaa"
   *  - any of the above with an alpha suffix: "primary/0.07", "accent/0.5",
   *    "#000/0.1"
   */
  export type Color = string;

  export type Length = number | "fill";
  export type Edges =
    | number
    | [vertical: number, horizontal: number]
    | { top?: number; bottom?: number; left?: number; right?: number; horizontal?: number; vertical?: number };

  export type Material = "glass" | "ultraThin" | "thin" | "regular" | "thick" | "ultraThick" | "bar" | "sidebar";
  export type Background =
    | Color
    | { gradient: Color[]; from?: Alignment; to?: Alignment }
    /** A translucent system material. "glass" is Liquid Glass; `tint` colours
     *  it; `interactive` makes it react to touch. "sidebar" is the
     *  behind-window blur used for the window backdrop. */
    | { material: Material; tint?: Color; interactive?: boolean };

  export type Alignment =
    | "center"
    | "top"
    | "bottom"
    | "leading"
    | "trailing"
    | "topLeading"
    | "topTrailing"
    | "bottomLeading"
    | "bottomTrailing";

  /** How a value change animates. `true` is a short default ease. */
  export type Animation =
    | boolean
    | "default"
    | "snappy"
    | "smooth"
    | "bouncy"
    | { type: "spring"; duration?: number; bounce?: number }
    | { type: "ease" | "easeIn" | "easeOut" | "linear"; duration?: number };

  /** How a node appears / disappears when it is added to or removed from its
   *  parent (the parent needs `animate`). */
  export type Transition =
    | "opacity"
    | "scale"
    | "slide"
    | { type: "move"; edge: "top" | "bottom" | "leading" | "trailing" }
    | { type: "scale"; scale?: number; anchor?: Alignment }
    | { type: "offset"; x?: number; y?: number };

  /** Visual properties shared by every node. */
  export interface BaseStyle {
    // ---- size (points)
    width?: Length;
    height?: Length;
    minWidth?: number;
    maxWidth?: Length;
    minHeight?: number;
    maxHeight?: Length;
    /** Take a share of the free space along the parent's axis (like CSS
     *  flex-grow with basis 0). In a Stack: fill both axes. */
    flex?: number;
    /** Which sibling gets space first when there isn't enough. Default 0. */
    layoutPriority?: number;
    aspectRatio?: number;
    // ---- spacing
    padding?: Edges;
    /** Space outside the background / border. */
    margin?: Edges;
    // ---- placement inside a Stack parent
    /** Where in the Stack this child sits (default: the Stack's `align`). */
    alignSelf?: Alignment;
    /** Shift the drawn position without affecting layout. */
    offset?: { x?: number; y?: number };
    zIndex?: number;
    // ---- appearance
    background?: Background;
    /** Text / icon colour for this node and its descendants. */
    color?: Color;
    opacity?: number;
    /** Corner radius; corners are continuous ("squircle") by default. */
    cornerRadius?: number | { topLeft?: number; topRight?: number; bottomLeft?: number; bottomRight?: number };
    cornerStyle?: "continuous" | "circular";
    border?: { color: Color; width?: number };
    shadow?: { color?: Color; radius: number; x?: number; y?: number };
    /** Clip children to the (rounded) bounds. */
    clip?: boolean;
    blur?: number;
    scale?: number;
    /** Stretch along one axis (a progress bar: `scaleX: progress`). */
    scaleX?: number;
    scaleY?: number;
    /** Degrees. */
    rotate?: number;
    /** The fixed point for scale / rotate. Default "center". */
    anchor?: Alignment;
    hidden?: boolean;
    cursor?: "arrow" | "pointer" | "text" | "resizeLeftRight" | "resizeUpDown" | "grab";
    // ---- motion
    /** Animate changes to this node's style (including the state variants
     *  below) and to its child list. */
    animate?: Animation;
    transition?: Transition;
    // ---- text (inherited by descendants)
    fontSize?: number;
    fontWeight?: "ultraLight" | "thin" | "light" | "regular" | "medium" | "semibold" | "bold" | "heavy" | "black";
    fontDesign?: "default" | "rounded" | "monospaced" | "serif";
    italic?: boolean;
  }

  /** Looks that apply while a condition holds. Resolved natively, so they
   *  respond on the same frame as the pointer — never emulate these with
   *  onHover + setState. */
  export interface StateStyles<S> {
    /** Pointer is over this node. */
    hover?: Partial<S>;
    /** Being pressed. */
    pressed?: Partial<S>;
    /** `disabled` prop is set. */
    disabled?: Partial<S>;
    /** This node (a TextInput) or a descendant has keyboard focus. */
    focused?: Partial<S>;
    /** A compatible drag is over this node (needs `dropTypes`). */
    dropTarget?: Partial<S>;
    /** The nearest ancestor with `group` is hovered / pressed. Use for
     *  "show the close button while the row is hovered". */
    groupHover?: Partial<S>;
    groupPressed?: Partial<S>;
    /** Dark appearance. */
    dark?: Partial<S>;
  }

  export interface BoxOnlyStyle {
    /** Space between children. */
    gap?: number;
    /** Cross-axis alignment of children (Row: vertical; Column: horizontal).
     *  For a Stack: where children sit, as an Alignment. Default "center". */
    align?: "start" | "center" | "end" | "stretch" | "baseline" | Alignment;
    /** Main-axis distribution of children. Default "start". */
    justify?: "start" | "center" | "end" | "between" | "around" | "evenly";
  }
  export interface BoxStyle extends BaseStyle, BoxOnlyStyle, StateStyles<BaseStyle & BoxOnlyStyle> {}

  export interface TextOnlyStyle {
    /** Max lines; text truncates beyond. */
    lineLimit?: number;
    truncate?: "tail" | "middle" | "head";
    textAlign?: "leading" | "center" | "trailing";
    letterSpacing?: number;
    lineSpacing?: number;
    underline?: boolean;
    strikethrough?: boolean;
    /** Digits don't change width as they change (clocks, counters). */
    monospacedDigits?: boolean;
    selectable?: boolean;
  }
  export interface TextStyle extends BaseStyle, TextOnlyStyle, StateStyles<BaseStyle & TextOnlyStyle> {}

  // ================================================================ Interaction

  export interface Modifiers {
    cmd: boolean;
    shift: boolean;
    alt: boolean;
    ctrl: boolean;
  }
  export interface PressEvent {
    modifiers: Modifiers;
    /** Location in the node's own coordinates. */
    x: number;
    y: number;
  }

  /** What a draggable node carries. "tab" drags interoperate with the
   *  built-in sidebar, split drop targets and other windows. */
  export type DragItem =
    | { type: "tab"; id: TabId }
    | { type: "url"; url: string; title?: string }
    | { type: "text"; text: string }
    | { type: "space"; id: SpaceId };

  export type DropType = "tab" | "url" | "file" | "text" | "image" | "space";
  export interface DropEvent {
    type: DropType;
    /** tab / space id */
    id?: string;
    url?: string;
    /** local file path */
    path?: string;
    text?: string;
    /** Pointer position in the node's coordinates, plus the node's size, so
     *  you can tell "dropped on the leading half". */
    x: number;
    y: number;
    width: number;
    height: number;
  }

  export interface MenuItem {
    title: string;
    /** SF Symbol name. */
    icon?: string;
    checked?: boolean;
    disabled?: boolean;
    destructive?: boolean;
    children?: MenuEntry[];
    onSelect?: () => void;
    /** Stable id (defaults to the item's position). */
    id?: string;
  }
  export type MenuEntry = MenuItem | "-" | null | false | undefined;

  /** Props every box (Row / Column / Stack / Pressable) accepts. */
  export interface BoxProps {
    style?: BoxStyle;
    children?: Children;
    key?: Key;
    ref?: Ref;
    onPress?: (e: PressEvent) => void;
    onDoublePress?: (e: PressEvent) => void;
    onLongPress?: (e: PressEvent) => void;
    /** Pointer entered / left. For *behaviour* (prefetch, open a preview);
     *  for looks use `style.hover`. */
    onHover?: (hovering: boolean) => void;
    disabled?: boolean;
    /** Marks this node as the reference for descendants' `groupHover` /
     *  `groupPressed` styles. */
    group?: boolean;
    /** Help tag shown after a hover delay. */
    tooltip?: string;
    /** Accessibility label / role. */
    label?: string;
    role?: "button" | "tab" | "image" | "header" | "none";
    /** Dragging this node carries `draggable`. */
    draggable?: DragItem;
    /** Accept drops of these types. */
    dropTypes?: DropType[];
    /** Return false to reject the drop. */
    onDrop?: (e: DropEvent) => boolean | void;
    /** Right-click / long-press menu, as data; see `useContextMenu`. */
    contextMenu?: object[];
    onContextMenuSelect?: (id: string) => void;
    /** Dragging this region moves the window; double-click zooms it (macOS). */
    windowDrag?: boolean;
    /** Names this node as a scroll target; see ScrollView `scrollTo`. */
    anchorId?: string;
    /** Reports this node's frame in window coordinates whenever it changes. */
    onLayout?: (frame: Frame) => void;
    /** Swipe / pan. `axis` picks the direction; values are points. */
    onPan?: (e: { phase: "began" | "changed" | "ended"; dx: number; dy: number; vx: number; vy: number }) => void;
    testID?: string;
  }

  export interface Frame {
    x: number;
    y: number;
    width: number;
    height: number;
  }
  /** Handle to a native node, from `ref`. */
  export interface NodeHandle {
    id: number;
    focus(): void;
    blur(): void;
    /** Frame in window coordinates; null before first layout. */
    measure(): Frame | null;
    command(name: string, args?: unknown): unknown;
  }
  export type Ref = { current: NodeHandle | null } | ((handle: NodeHandle | null) => void);

  // ================================================================ Primitives

  /** Stacks children top → bottom. */
  export const Column: Component<BoxProps>;
  /** Alias of Column. */
  export const View: Component<BoxProps>;
  /** Lays children out leading → trailing. */
  export const Row: Component<BoxProps>;
  /** Layers children back → front. Position a child with `style.alignSelf`
   *  and `style.offset`. A Stack is as big as its biggest child. */
  export const Stack: Component<BoxProps>;
  /** A box that reads as a button to assistive tech. `layout` picks the
   *  arrangement (default "row"). */
  export const Pressable: Component<BoxProps & { layout?: "row" | "column" | "stack" }>;
  /** Empty space that grows along the parent's axis. */
  export const Spacer: Component<{ style?: { minWidth?: number; minHeight?: number }; key?: Key }>;
  /** A hairline across the parent's axis. */
  export const Divider: Component<{ style?: BaseStyle; key?: Key }>;

  /** Text. Children: strings, numbers, and nested <Text style> runs.
   *  A bare string inside a box is the same as <Text>{string}</Text>. */
  export const Text: Component<{
    style?: TextStyle;
    children?: Children;
    key?: Key;
    onPress?: (e: PressEvent) => void;
    tooltip?: string;
    testID?: string;
  }>;

  /** An SF Symbol (https://developer.apple.com/sf-symbols/). */
  export const Icon: Component<{
    name: string;
    /** Point size. Default 13. */
    size?: number;
    weight?: BaseStyle["fontWeight"];
    /** Fill variant / hierarchical rendering. */
    variant?: "fill" | "none";
    style?: BaseStyle;
    key?: Key;
  }>;

  /** An image. `src`: an http(s) URL, a path inside the branch
   *  ("images/logo.png"), or "asset:<Name>" for an image bundled with the app. */
  export const Image: Component<{
    src: string;
    contentMode?: "fit" | "fill";
    /** Draw as a template tinted with `style.color`. */
    template?: boolean;
    style?: BaseStyle;
    key?: Key;
  }>;

  /** The favicon for a page URL. */
  export const Favicon: Component<{ url: string | null; size?: number; style?: BaseStyle; key?: Key }>;

  /** The built-in icon for a tab: favicon, emoji, terminal chip, agent
   *  avatar, attention badge — whatever the native sidebar would show. */
  export const TabIcon: Component<{ tabId: TabId; size?: number; style?: BaseStyle; key?: Key }>;

  export interface ScrollViewProps {
    /** Default "vertical". */
    axis?: "vertical" | "horizontal";
    showsIndicators?: boolean;
    /** Snap page by page (children are the pages). */
    paging?: boolean;
    /** Controlled page index when `paging`. */
    page?: number;
    onPageChange?: (page: number) => void;
    /** Scroll until the descendant with this `anchorId` is visible, whenever
     *  the value changes. */
    scrollTo?: string | null;
    /** Arrangement of the content. */
    contentStyle?: BoxOnlyStyle & { padding?: Edges };
    style?: BoxStyle;
    children?: Children;
    key?: Key;
    ref?: Ref;
  }
  export const ScrollView: Component<ScrollViewProps>;

  export interface KeyEvent {
    key: "up" | "down" | "left" | "right" | "enter" | "escape" | "tab" | "backspace" | string;
    modifiers: Modifiers;
  }
  export interface TextInputProps {
    /** Controlled value. */
    value: string;
    onChangeText?: (text: string) => void;
    placeholder?: string;
    /** Enter. */
    onSubmit?: (text: string, e: { modifiers: Modifiers }) => void;
    /** Return true to consume the key (arrow keys for a suggestion list,
     *  escape to close). Called synchronously before the field handles it. */
    onKey?: (e: KeyEvent) => boolean | void;
    onFocus?: () => void;
    onBlur?: () => void;
    /** Take keyboard focus when mounted. */
    autoFocus?: boolean;
    selectAllOnFocus?: boolean;
    multiline?: boolean;
    secure?: boolean;
    style?: TextStyle & { placeholderColor?: Color };
    key?: Key;
    ref?: Ref;
    testID?: string;
  }
  /** A text field. `ref.focus()` / `ref.blur()` move keyboard focus. While it
   *  is focused the page does not get keystrokes; when it blurs, focus
   *  returns to the page. */
  export const TextInput: Component<TextInputProps>;

  /** A button that opens a native pull-down menu. Children are its label. */
  export const Menu: Component<{ items: MenuEntry[]; style?: BoxStyle; children?: Children; key?: Key; tooltip?: string }>;

  /** A native popover attached to `anchor`. */
  export const Popover: Component<{
    open: boolean;
    onClose: () => void;
    anchor: Children;
    edge?: "top" | "bottom" | "leading" | "trailing";
    style?: BoxStyle;
    contentStyle?: BoxStyle;
    children?: Children;
    key?: Key;
  }>;

  /** The live content of one pane: the page, plus its native overlays
   *  (find bar, reader, terminal, load failures, autofill menus). Does *not*
   *  include a toolbar. For a whole tab with split panes use `Content` from
   *  "wowser/native" with `toolbar="hidden"`. */
  export const WebPane: Component<{ paneId: PaneId; style?: BaseStyle; key?: Key }>;

  /**
   * A web view that is part of the chrome rather than a tab.
   *  - `src` inside the branch ("widgets/clock.html"): transparent by
   *    default, and the page gets `window.wowser`:
   *        wowser.props                    latest `props`
   *        wowser.onProps(cb)              called on every change
   *        wowser.post(message)            → `onMessage`
   *        wowser.call(name, args)         → Promise; the same API as `call()` here
   *  - `src` an http(s) URL: an ordinary page (a "web panel"); no bridge.
   */
  export const WebIsland: Component<{
    src: string;
    props?: unknown;
    onMessage?: (message: any) => void;
    /** Default true for branch files, false for remote URLs. */
    transparent?: boolean;
    /** Let clicks through where the page is transparent. Default false. */
    passthrough?: boolean;
    /** Use a phone user agent (web panels). */
    mobile?: boolean;
    style?: BaseStyle;
    key?: Key;
    ref?: Ref;
  }>;

  /** macOS close / minimise / zoom buttons, for UIs that place them.
   *  Renders nothing on iOS and in fullscreen. 68×28. */
  export const WindowControls: Component<{ style?: BaseStyle; key?: Key }>;

  /** Embed a native view by name (see "wowser/native"). */
  export const Native: Component<{ name: string; style?: BaseStyle; key?: Key; [prop: string]: unknown }>;

  // ================================================================ Browser state

  export type TabId = string;
  export type PaneId = string;
  export type SpaceId = string;
  export type WindowId = string;

  export type IconInfo =
    | { kind: "favicon"; url: string }
    | { kind: "symbol"; name: string }
    | { kind: "emoji"; value: string }
    /** Something only <TabIcon> can draw (terminal chip, agent avatar, …). */
    | { kind: "native" };

  export interface WindowInfo {
    id: WindowId;
    /** "mac" | "ios" */
    platform: string;
    spaceId: SpaceId;
    currentTabId: TabId | null;
    /** The focused pane of the current tab. */
    focusedPaneId: PaneId | null;
    /** The user's sidebar toggle. What "hidden" looks like is up to the UI. */
    sidebarVisible: boolean;
    /** The command bar is open (⌘L, ⌘T, an empty tab). */
    commandBarOpen: boolean;
    /** It was opened to edit the current URL (⌘L) rather than to start fresh. */
    commandBarPrefillsURL: boolean;
    isFullscreen: boolean;
    isKey: boolean;
    showingNewSpacePage: boolean;
    chatMode: boolean;
  }

  export interface SpaceInfo {
    id: SpaceId;
    /** What to display: title, else the AI title, else "Space N". */
    name: string;
    title: string | null;
    emoji: string | null;
    isCurrent: boolean;
    /** Theme hue in degrees, if the space has a colour theme. */
    hue: number | null;
    secondaryHue: number | null;
    hasImage: boolean;
    /** The coding folder attached to the space, if any. */
    folderPath: string | null;
  }

  export interface TabInfo {
    id: TabId;
    title: string;
    /** Status line ("Downloading… 40%", "Agent is using this tab"). */
    subtitle: string | null;
    url: string | null;
    icon: IconInfo;
    isCurrent: boolean;
    isPinned: boolean;
    isLoading: boolean;
    /** Opened by an agent in the background. */
    isGhost: boolean;
    /** Unloaded to save memory; reloads when selected. */
    isUnloaded: boolean;
    isPip: boolean;
    isSplit: boolean;
    badge: "dot" | "cursor" | null;
    /** AI-assigned group name (tabs of a group are adjacent). */
    group: string | null;
    /** "web" | "terminal" | "vscode" | "files" | "agent" | "welcome" */
    kind: string;
    hasCustomTitle: boolean;
    paneIds: PaneId[];
    focusedPaneId: PaneId | null;
    /** Set when this entry *is* a folder (it then has no panes). */
    folder: { name: string; tabIds: TabId[]; openTabIds: TabId[] } | null;
    /** Set when this tab is an open member of a folder. */
    folderId: TabId | null;
  }

  export interface TabStrip {
    spaceId: SpaceId;
    currentTabId: TabId | null;
    /** Favorites / pinned tabs. */
    pinned: TabInfo[];
    /** Ordinary tabs in display order; open folder members follow their folder. */
    tabs: TabInfo[];
  }

  export interface PaneInfo {
    id: PaneId;
    tabId: TabId;
    url: string | null;
    /** Short form for an address field: the host, or the query on a search page. */
    displayURL: string;
    title: string | null;
    isLoading: boolean;
    /** 0…1 */
    progress: number;
    canGoBack: boolean;
    canGoForward: boolean;
    isSecure: boolean;
    /** An empty new tab (nothing loaded). */
    isEmpty: boolean;
    favicon: string | null;
    kind: string;
    /** Relative width in a split. */
    weight: number;
    /** The focused pane of the window's current tab. */
    isFocused: boolean;
    findOpen: boolean;
    commandBarOpen: boolean;
    /** Dominant colour of the top of the page, for tinting chrome. */
    topColor: string | null;
    /** Whether that colour reads as light or dark. */
    scheme: "light" | "dark" | null;
    failed: { url: string; error: string } | null;
  }

  export interface ThemeInfo {
    scheme: "light" | "dark";
    /** The space accent, already tuned for contrast in this scheme. The
     *  colour names "accent" / "onAccent" resolve to these. */
    accent: string;
    onAccent: string;
    hue: number | null;
    secondaryHue: number | null;
    /** The space's backdrop gradient (top-leading → bottom-trailing). */
    gradient: string[] | null;
    /** file:// URL of the space's background image, if any. */
    backgroundImage: string | null;
  }

  export interface ToastInfo {
    id: string;
    title: string | null;
    message: string;
    /** SF Symbol */
    icon: string;
    /** Button titles; run one with `toasts.performAction(id, index)`. */
    actions: string[];
    sticky: boolean;
  }

  export function useWindowId(): WindowId;
  export function useWindow(): WindowInfo;
  /** Re-render only when the selected part changes. */
  export function useWindow<T>(selector: (w: WindowInfo) => T): T;
  export function useSpaces(): SpaceInfo[];
  /** A space; default: the window's current one. */
  export function useSpace(spaceId?: SpaceId): SpaceInfo | null;
  /** The tab strip of a space; default: the current one. */
  export function useTabs(spaceId?: SpaceId): TabStrip;
  export function useTab(tabId: TabId | null): (TabInfo & { panes: PaneInfo[] }) | null;
  export function usePane(paneId: PaneId | null): PaneInfo | null;
  export function useCurrentTab(): (TabInfo & { panes: PaneInfo[] }) | null;
  /** The focused pane of the current tab. Changes often while a page loads:
   *  call it low in the tree. */
  export function useCurrentPane(): PaneInfo | null;
  export function useTheme(): ThemeInfo;
  export function useToasts(): ToastInfo[];
  /** A browser preference by its DefaultsKeys name ("toolbarAtBottom",
   *  "sidebarWidth", …). */
  export function useSetting<T = unknown>(key: string): [T | null, (value: T) => void];
  /** State saved in this branch's private store; survives restarts. */
  export function useStorage<T>(key: string, initial: T): [T, (value: T | ((prev: T) => T)) => void];
  /** Low level: subscribe to a named slice of browser state. */
  export function useSlice<T = any, R = T>(name: string, arg?: object | null, selector?: (value: T) => R): R;
  export function readSlice<T = any>(name: string, arg?: object | null): T;

  // ================================================================ Behaviour hooks

  export interface Command {
    id: string;
    title: string;
    /** SF Symbol */
    icon?: string;
    /** "cmd+shift+k", "ctrl+tab", "cmd+alt+left". Active while this window is key. */
    hotkey?: string;
    keywords?: string[];
    run: (e?: object) => void;
  }
  /** Register a command while mounted: it shows in the command bar and the
   *  Shell menu, and its hotkey works. */
  export function useCommand(command: Command): void;
  export function useHotkey(combo: string, run: () => void): void;
  /** `<Row {...useContextMenu([{ title: "Close", onSelect }])}>` */
  export function useContextMenu(items: MenuEntry[]): { contextMenu: object[]; onContextMenuSelect: (id: string) => void };
  export function useInterval(fn: () => void, ms: number | null): void;
  /** `Date.now()`, re-rendering every `everyMs` (default 1000). */
  export function useNow(everyMs?: number): number;

  export interface Suggestion {
    id: string;
    /** "url" | "search" | "tab" | "history" | "action" | "agent" | "suggestion" | "terminal" */
    kind: string;
    title: string;
    subtitle: string | null;
    url?: string | null;
    tabId?: TabId;
    icon: IconInfo;
    /** Typing more should complete to this (the top hit is a direct match). */
    isTopHit?: boolean;
  }
  /** Suggestions for `query`: instant local results on the same frame, slower
   *  sources merged in when they arrive. */
  export function useSuggestions(
    query: string,
    opts?: { limit?: number; instantOnly?: boolean }
  ): Suggestion[];

  /** Native events. Listeners for the starred ones may return a value. */
  export interface EventMap {
    /** ★ A main-frame navigation is about to start in one of this window's
     *  panes. Return `{ cancel: true }` to block it or `{ redirect: url }`. */
    navigate: { paneId: PaneId; tabId: TabId | null; url: string; isUserInitiated: boolean; opensNewWindow: boolean };
    /** A page finished loading. */
    load: { paneId: PaneId; url: string; title: string | null };
    /** ★ A page wants to open a new tab / window. Return `{ cancel: true }`,
     *  or `{ disposition: "background" | "split" | "current" }`. */
    newTab: { fromPaneId: PaneId; url: string | null };
    tabCreated: { tabId: TabId };
    tabClosed: { tabId: TabId; url: string | null };
    tabActivated: { tabId: TabId | null; previousTabId: TabId | null };
    spaceActivated: { spaceId: SpaceId };
    /** ★ A key the page did not handle and no menu item claimed. Return true
     *  to consume it. */
    key: KeyEvent;
    /** A download started. */
    download: { paneId: PaneId; url: string; filename: string };
    /** The window became / stopped being key. */
    windowKey: { isKey: boolean };
  }
  export function useEvent<K extends keyof EventMap>(name: K, listener: (e: EventMap[K]) => unknown): void;
  /** Like `useEvent`, outside a component (in `setup`). Returns an unsubscribe. */
  export function on<K extends keyof EventMap>(name: K, listener: (e: EventMap[K]) => unknown): () => void;

  // ================================================================ Actions (synchronous unless they return a Promise)

  export const tabs: {
    /** Open a tab. Without `url`: an empty tab with the command bar open. */
    create(opts?: { url?: string; activate?: boolean; inSplit?: boolean }): TabId;
    /** Close a tab. A pinned tab resets to its pinned URL instead. */
    close(tabId: TabId): void;
    activate(tabId: TabId): void;
    /** What clicking a tab does: activate; with a modifier held, open beside
     *  the current tab; a pip tab toggles its panel. */
    select(tabId: TabId, opts?: { modifiers?: Modifiers }): void;
    move(
      tabId: TabId,
      dest:
        | { to: "tabs"; before?: TabId }
        | { to: "pinned"; before?: TabId }
        | { to: "folder"; folderId: TabId; before?: TabId }
        | { to: "space"; spaceId: SpaceId }
    ): boolean;
    pin(tabId: TabId, before?: TabId): boolean;
    unpin(tabId: TabId, before?: TabId): boolean;
    /** `null` clears the custom title. */
    rename(tabId: TabId, title: string | null): void;
    setEmoji(tabId: TabId, emoji: string | null): void;
    duplicate(tabId: TabId): TabId;
    reopenClosed(): TabId | null;
    resetToPinnedURL(tabId: TabId): void;
    splitWith(tabId: TabId, intoTabId: TabId): void;
    separateSplit(tabId: TabId): void;
    setPip(tabId: TabId, on: boolean): void;
    /** Archive and close every unpinned tab in the current space. */
    closeAll(): void;
    visibleOrder(): TabId[];
    recent(max?: number): TabId[];
  };

  export const panes: {
    /** Navigate. `text` is a URL or a search query. */
    load(paneId: PaneId, text: string): void;
    back(paneId: PaneId): void;
    forward(paneId: PaneId): void;
    reload(paneId: PaneId): void;
    stop(paneId: PaneId): void;
    close(paneId: PaneId): void;
    /** Give the page keyboard focus. */
    focus(paneId: PaneId): void;
    zoomIn(paneId: PaneId): void;
    zoomOut(paneId: PaneId): void;
    resetZoom(paneId: PaneId): void;
    setFindOpen(paneId: PaneId, open?: boolean): void;
    setWeights(tabId: TabId, leftIndex: number, leftWeight: number, rightWeight: number): void;
    copyURL(paneId: PaneId): void;
    toggleBookmark(paneId: PaneId): void;
    /** Evaluate JS in the page (isolated world). */
    eval(paneId: PaneId, js: string): Promise<unknown>;
    /** Persistent CSS / JS for a host; applied on every load. */
    setInjection(host: string, opts: { css?: string; js?: string }): Promise<void>;
  };

  export const spaces: {
    activate(spaceId: SpaceId): void;
    create(opts?: { title?: string; shareLoginsWith?: SpaceId }): SpaceId;
    rename(spaceId: SpaceId, title: string): void;
    setEmoji(spaceId: SpaceId, emoji: string | null): void;
    setTheme(spaceId: SpaceId, theme: { hue: number; secondaryHue?: number } | null): void;
    move(spaceId: SpaceId, beforeSpaceId: SpaceId): void;
    hide(spaceId: SpaceId): void;
    delete(spaceId: SpaceId): void;
    showNewSpacePage(): void;
  };

  export const folders: {
    create(name: string): TabId | null;
    rename(folderId: TabId, name: string): void;
    delete(folderId: TabId): void;
    addTab(folderId: TabId, tabId: TabId, opts?: { before?: TabId; open?: boolean }): void;
    removeTab(tabId: TabId): void;
    putAway(folderId: TabId): void;
  };

  export const window: {
    readonly id: WindowId;
    toggleSidebar(): void;
    setSidebarVisible(visible: boolean): void;
    newWindow(): void;
    close(): void;
    minimize(): void;
    zoom(): void;
    toggleFullscreen(): void;
    /** Native window frame options (macOS). `trafficLights`: "native" keeps
     *  the system buttons at `{ x, y }` from the top-left; "custom" hides them
     *  so the UI can place <WindowControls/>. */
    configure(opts: {
      trafficLights?: "custom" | { x: number; y: number };
      minWidth?: number;
      minHeight?: number;
    }): void;
  };

  export const commandBar: {
    open(opts?: { prefillURL?: boolean }): void;
    close(): void;
  };

  export const search: {
    /** Instant, local suggestions. Cheap enough for every keystroke. */
    suggest(query: string, opts?: { limit?: number }): Suggestion[];
    /** The complete list including slow sources. */
    suggestMore(query: string, opts?: { limit?: number }): Promise<Suggestion[]>;
    /** Run a suggestion. */
    open(suggestion: Suggestion | string, opts?: { newTab?: boolean }): void;
    /** Go to whatever `text` means, without showing suggestions. */
    go(text: string, opts?: { newTab?: boolean }): void;
    topSites(limit?: number): Suggestion[];
  };

  export const toasts: {
    show(toast: string | { message: string; title?: string; icon?: string; sticky?: boolean }): string;
    /** No id: dismiss the frontmost. */
    dismiss(id?: string): void;
    performAction(id: string, index: number): void;
  };

  export const settings: { get(key: string): unknown; set(key: string, value: unknown): void };
  export const storage: { get<T>(key: string, fallback?: T): T; set(key: string, value: unknown): void; remove(key: string): void };
  export const clipboard: { writeText(text: string): void; readText(): string };

  export const commands: {
    register(command: Command): () => void;
    /** Run a registered command, or a built-in: see `list()` for ids such as
     *  "builtin:newTab", "builtin:reload", "builtin:toggleSidebar". */
    run(id: string, args?: object): void;
    list(): { id: string; title: string; hotkey: string | null }[];
  };

  export const menus: {
    /** Pop up a menu at the pointer, or at `at` (window coordinates). */
    show(items: MenuEntry[], opts?: { at?: { x: number; y: number } }): Promise<string | null>;
  };

  export const shell: {
    /** "mac" | "ios" */
    readonly platform: string;
    /** This branch's name. */
    readonly branch: string;
    reload(): void;
    readFile(path: string): string | null;
    openSettings(): void;
  };

  export const haptics: { tap(kind?: "generic" | "alignment" | "levelChange"): void };

  /**
   * The agent-facing BrowserJS API — `browser.tabs`, `browser.content`,
   * `browser.page`, `browser.net`, `browser.fs`, `browser.agent`, … — also
   * usable from UI code. Every call returns a Promise. See BrowserJS.d.ts
   * (the `get_browser_js_docs` tool) for the surface.
   */
  export const browser: any;

  /** Escape hatches: call a host function by name. */
  export function call(name: string, args?: object): any;
  export function callAsync(name: string, args?: object): Promise<any>;
}

declare module "wowser/native" {
  import type { BaseStyle, Component, Key, PaneId, SpaceId, TabId } from "wowser";
  type N<P = {}> = Component<P & { style?: BaseStyle; key?: Key }>;

  /** The whole built-in window: sidebar, content, toasts, backdrop, hover
   *  reveals. A reference point — it has no parts to rearrange. */
  export const ClassicBrowser: N;
  /** The whole built-in sidebar: window controls, space name, swipeable
   *  favorites + tabs, new-tab button, space dots. `floating` draws the
   *  hover-reveal card look. Sizes itself to the user's sidebar width. */
  export const Sidebar: N<{ floating?: boolean }>;
  /** Swipeable pages of favorites + tabs, one per space, with paging dots. */
  export const SpacePager: N;
  /** The favorites grid. */
  export const FavoritesGrid: N<{ spaceId?: SpaceId }>;
  /** The vertical tab list: rows, AI groups, folders, drag & drop. Scrolls. */
  export const TabList: N<{ spaceId?: SpaceId }>;
  /** One built-in tab row. */
  export const TabRow: N<{ tabId: TabId }>;
  /** The new-tab / quick-action button cluster. */
  export const NewTabButton: N;
  export const SpaceDots: N;
  export const SpaceName: N;
  /**
   * The content area: the current tab's panes (split aware, resizable), each
   * with its toolbar and command bar, plus the 3D tab switcher and split drop
   * targets.
   *  - toolbar "auto" (default): the built-in toolbar; it tucks away when
   *    the sidebar is hidden and returns on hover.
   *  - toolbar "always": the built-in toolbar, always shown.
   *  - toolbar "hidden": no native toolbar or command bar — draw your own
   *    (see kit/Toolbar and kit/CommandBar).
   */
  export const Content: N<{ toolbar?: "auto" | "always" | "hidden" }>;
  /** The built-in toolbar for a pane (default: the focused one). */
  export const Toolbar: N<{ paneId?: PaneId }>;
  /** The built-in command bar card (input + suggestions). */
  export const CommandBar: N<{ paneId?: PaneId }>;
  export const Toasts: N;
  /** Behind-window blur plus the space's gradient or image. */
  export const WindowBackground: N;
  /** The page-load progress bar. */
  export const LoadingBar: N<{ paneId?: PaneId }>;
  /** A live thumbnail of a tab's page. */
  export const TabThumbnail: N<{ tabId: TabId }>;
  /** The whole built-in iOS UI (page card, puck, tray, command bar). */
  export const MobileBrowser: N;
  /** Wrap any registered native view by name. */
  export function native(name: string): N<Record<string, unknown>>;
}
