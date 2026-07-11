// BrowserJS — the privileged JS environment hosted by Wowser.
//
// You write code that runs INSIDE the Wowser app (not in any web page) via
// the `run_browser_js` MCP tool. A global `browser` object lets you drive
// real browser tabs (visual mode) or hit endpoints directly (synthetic mode).
//
// This declaration file is the source of truth — it is what `get_browser_js_docs`
// returns. Persisted helper files (saved via `save_browser_helper_file`) are
// concatenated in alphabetical order and prepended to every evaluation.

declare global {
  /** A tab id (= per-pane WKWebView id). */
  type TabId = string;
  /** A window id. */
  type WindowId = string;

  /**
   * A split-view group id. A "split" is one tab holding several panes
   * side-by-side; each pane is addressable as a TabId. Every TabId belongs to
   * exactly one SplitId (of size 1 when the tab isn't split).
   */
  type SplitId = string;
  /** A space id. Spaces are the profiles in the sidebar carousel. */
  type SpaceId = string;

  interface TabInfo {
    id: TabId;
    windowId?: WindowId;
    url?: string;
    title?: string;
    /** Position within the window's tab strip (top-level tabs only). */
    index?: number;
    /** "web" | "terminal" | "webapp" — useful when filtering. */
    kind: string;
    /** True for agent-opened "ghost" tabs (live but not selected, muted). */
    isGhost: boolean;
    /** The split this pane belongs to. Unsplit tabs still have one. */
    splitId?: SplitId;
    /** All pane ids in this pane's split, in display order (includes `id`).
     *  `length > 1` means the user sees this tab beside others. */
    splitTabIds: TabId[];
    /** Whether this pane is the visible/focused one within its split. */
    isFocusedInSplit: boolean;
    /** The space whose tab list contains this pane's tab. */
    spaceId?: SpaceId;
  }

  /** One tab holding one or more panes. Single-pane tabs are splits of size 1. */
  interface SplitInfo {
    id: SplitId;
    windowId?: WindowId;
    spaceId?: SpaceId;
    /** Index in the window's tab strip. */
    index?: number;
    /** Pane ids, left-to-right. Each is a valid TabId elsewhere in this API. */
    tabIds: TabId[];
    focusedTabId?: TabId;
    title?: string;
  }

  /**
   * A space (a profile). Note `tabIds` / `splitIds` / `isCurrent` are relative
   * to the window they were resolved against — a space holds a DIFFERENT tab
   * list in each window.
   */
  interface SpaceInfo {
    id: SpaceId;
    /** User-entered title, if any. */
    title?: string;
    /** AI-generated title, shown as a placeholder when `title` is empty. */
    autoTitle?: string;
    /** What the UI shows: `title ?? autoTitle ?? "Space N"`. */
    displayName: string;
    emoji?: string;
    /** Creation order — position in the sidebar carousel. */
    index: number;
    hidden: boolean;
    /** True if the resolved window is currently displaying this space. */
    isCurrent: boolean;
    /** Every window currently displaying this space. */
    windowIds: WindowId[];
    /** Pane ids of this space's tabs, in the resolved window. */
    tabIds: TabId[];
    /** Split ids of this space's tabs, in the resolved window. */
    splitIds: SplitId[];
  }

  interface WindowInfo {
    id: WindowId;
    tabIds: TabId[];
    currentTabId?: TabId;
    /** The space this window currently displays. `tabIds` are that space's tabs. */
    spaceId?: SpaceId;
    /** Split ids in the window's tab strip, in order. */
    splitIds?: SplitId[];
  }

  interface Image {
    /** MIME type, e.g. "image/png". */
    mime: string;
    /** Base64-encoded bytes. */
    data: string;
  }

  interface NetEntry {
    id: string;
    /** Unix timestamp (seconds) the entry was recorded. */
    ts: number;
    url: string;
    method: string;
    status: number;
    request: { headers: Record<string, string>; body?: string };
    response: { headers: Record<string, string>; body?: string };
  }
  interface NetFetchResponse {
    status: number;
    headers: Record<string, string>;
    body: string;
  }

  /** Top-level entrypoint. All methods are async (return Promises). */
  const browser: {
    tabs: {
      /**
       * `spaceId` defaults to each window's currently-displayed space — i.e. the
       * only tabs the user can actually see. Pass a spaceId to enumerate the
       * tabs sitting in a background space.
       */
      list(opts?: { windowId?: WindowId; spaceId?: SpaceId }): Promise<TabInfo[]>;
      open(url: string, opts?: { background?: boolean; windowId?: WindowId }): Promise<TabId>;
      /**
       * Open `url` as a new PANE beside an existing tab (split view), rather
       * than as a new tab. The pane joins the split containing `besideTabId`
       * (default: the window's current tab).
       *
       * Returns the new pane's TabId. To build a master/detail app, keep that
       * id and `tabs.navigate(paneId, url)` on later clicks — otherwise every
       * click stacks another pane into the split.
       */
      openSplit(url: string, opts?: { besideTabId?: TabId; activate?: boolean; windowId?: WindowId }): Promise<TabId>;
      /**
       * Open a "ghost" agent tab — live but not selected, audio/mic/camera muted,
       * dimmed in the sidebar with an "Agent tab" subtitle. As soon as the user
       * activates the tab themselves, the ghost flag is cleared and the tab is
       * promoted to a normal foreground tab.
       */
      openGhost(url: string, opts?: { windowId?: WindowId }): Promise<TabId>;
      /** Loads inline HTML in a new tab. The page does NOT get window.browser. */
      openHTML(html: string, opts?: { title?: string; windowId?: WindowId }): Promise<TabId>;
      close(id: TabId): Promise<void>;
      /** Brings the tab forward AND focuses this pane within its split. */
      activate(id: TabId): Promise<void>;
      move(id: TabId, toIndex: number): Promise<void>;
      get(id: TabId): Promise<TabInfo>;
      navigate(id: TabId, url: string): Promise<void>;
    };

    content: {
      /** Read the tab content. `as: 'text' | 'html' | 'markdown'` — default 'text'. */
      read(id: TabId, opts?: { as?: 'text' | 'html' | 'markdown' }): Promise<string>;
      /**
       * Capture the tab's visible content as an image. Pass the result to
       * `browser.viewImage(...)` to surface it back to the calling model.
       */
      screenshot(id: TabId): Promise<Image>;
      /** Only valid for openHTML / webapp tabs. (v1: not implemented.) */
      write(id: TabId, html: string): Promise<void>;
    };

    /** In-page JS execution — runs inside the page's WKWebView. */
    page: {
      eval(id: TabId, js: string): Promise<any>;
      /** Polls `predicateJs` until it evaluates truthy or `timeoutMs` elapses. */
      waitFor(id: TabId, predicateJs: string, timeoutMs?: number): Promise<any>;
      /**
       * Click the page at content coordinates (x, y). Dispatches synthetic
       * mousedown/mouseup/click events to whatever element is at that point.
       * Pass `clickCount: 2` for a double-click.
       */
      click(id: TabId, x: number, y: number, opts?: { button?: 'left' | 'right' | 'middle'; clickCount?: number }): Promise<void>;
      /** Type a string of text into whatever input is currently focused. */
      type(id: TabId, text: string): Promise<void>;
      /** Press a single named key with optional modifiers. */
      key(id: TabId, key: string, modifiers?: Array<'shift' | 'control' | 'option' | 'command'>): Promise<void>;
      /** Scroll the page by (dx, dy) content pixels. */
      scroll(id: TabId, dx: number, dy: number): Promise<void>;
    };

    windows: {
      list(): Promise<WindowInfo[]>;
      /** The current focused window (or the agent's parent window if known). */
      getCurrent(): Promise<WindowInfo | null>;
      getById(id: WindowId): Promise<WindowInfo | null>;
    };

    /** Introspect split view. Create splits with `tabs.openSplit`. */
    splits: {
      /** Every split in the window — including single-pane tabs. */
      list(opts?: { windowId?: WindowId; spaceId?: SpaceId }): Promise<SplitInfo[]>;
      /** The split containing this pane. */
      get(tabId: TabId): Promise<SplitInfo>;
      /** Tear a split apart into one tab per pane. Returns the pane ids, in order.
       *  Pane ids are preserved, so previously-held TabIds stay valid. */
      separate(tabId: TabId): Promise<TabId[]>;
    };

    /**
     * Spaces = the profiles in the sidebar carousel. Each space keeps its own
     * tab list PER WINDOW, so `tabIds` and `isCurrent` are always reported
     * relative to `windowId` (default: the current window).
     */
    spaces: {
      /** In carousel order. Hidden spaces are omitted unless `includeHidden`. */
      list(opts?: { windowId?: WindowId; includeHidden?: boolean }): Promise<SpaceInfo[]>;
      getCurrent(opts?: { windowId?: WindowId }): Promise<SpaceInfo | null>;
      /** Switch a window to display `spaceId`. Throws if the space is hidden. */
      activate(spaceId: SpaceId, opts?: { windowId?: WindowId }): Promise<void>;
    };

    /**
     * Network capture & synthesis. Capture is OPT-IN per origin: nothing is
     * recorded until you call `captureOrigin(origin, true)`. The proxy logs
     * plaintext HTTP requests; for HTTPS introspection, use `fetch` (which
     * round-trips via URLSession and records into the same log).
     */
    net: {
      log(filter?: { tabId?: TabId; urlRegex?: string; method?: string; since?: number; limit?: number }): Promise<NetEntry[]>;
      grep(pattern: string, where?: 'url' | 'reqBody' | 'resBody' | 'headers'): Promise<NetEntry[]>;
      fetch(req: {
        url: string;
        method?: string;
        headers?: Record<string, string>;
        body?: string;
        cookiesFrom?: TabId | 'domain';
      }): Promise<NetFetchResponse>;
      replay(entryId: string, overrides?: { url?: string; method?: string; headers?: Record<string, string>; body?: string; cookiesFrom?: TabId | 'domain' }): Promise<NetFetchResponse>;
      /** Add/remove an origin from the capture allowlist. */
      captureOrigin(origin: string, enabled: boolean): Promise<void>;
    };

    /**
     * Local "tang://" webapps. `create` writes a folder of files to disk
     * (~/Library/Application Support/Wowser/Tangerine/<slug>/) and opens it in
     * a new tab at `tang://<slug>/`. `files` maps relative paths to contents and
     * MUST include an `index.html`. Pages loaded from tang:// receive the full
     * `window.browser` API (this same surface), so an app can drive the browser.
     */
    webapp: {
      create(opts: { name: string; files: Record<string, string>; exposeBrowserJS?: boolean }): Promise<TabId>;
    };

    sleep(ms: number): Promise<void>;
    log(...args: any[]): void;
    /**
     * Attach an image to the MCP tool output so the calling model can
     * actually see it (vision input). Call after `content.screenshot(...)`.
     * Accepts an `Image` object or a bare base64 string (assumed PNG).
     */
    viewImage(img: Image | string): void;
  };
}

export {};
