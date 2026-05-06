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
  }

  interface WindowInfo {
    id: WindowId;
    tabIds: TabId[];
    currentTabId?: TabId;
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
      list(opts?: { windowId?: WindowId }): Promise<TabInfo[]>;
      open(url: string, opts?: { background?: boolean; windowId?: WindowId }): Promise<TabId>;
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

    /** Generative app tabs. v1: stubbed — throws "not implemented". */
    webapp: {
      create(opts: { name: string; html: string; exposeBrowserJS?: boolean }): Promise<TabId>;
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
