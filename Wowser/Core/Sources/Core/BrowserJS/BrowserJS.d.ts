// BrowserJS — the privileged JS environment hosted by Wowser.
//
// You write code that runs INSIDE the Wowser app (not in any web page) via
// the `run_browser_js` MCP tool. A global `browser` object lets you drive
// real browser tabs (visual mode) or hit endpoints directly (synthetic mode).
//
// This declaration file is the source of truth — it is what `get_browser_js_docs`
// returns. Persisted helper files (saved via `save_browser_helper_file`) are
// concatenated in alphabetical order and prepended to every evaluation.
//
// ## Work in the background by default
//
// The user is usually doing something else in this browser while you work.
// Don't disturb them: open pages with `tabs.openGhost(url)` — a hidden "agent
// tab" that is fully functional (it renders at a 1280×800 viewport offscreen,
// so `content.read`, `content.screenshot`, `page.click/type/key/scroll` and
// `page.eval` all work exactly as on a visible tab). Only use `tabs.open` /
// `tabs.activate` when the user has asked to SEE the page or you're handing a
// result over to them, and `tabs.close` ghost tabs when you're done with them.
// To drive a tab the USER opened without bringing it forward, lease it first
// with `tabs.use(id)` — it keeps rendering offscreen for an hour.
//
// Typical computer-use loop on a ghost tab:
//   const id = await browser.tabs.openGhost("https://example.com");
//   await browser.page.waitFor(id, "document.readyState === 'complete'", 10000);
//   browser.viewImage(await browser.content.screenshot(id));   // look
//   const r = await browser.page.eval(id, "document.querySelector('input[name=q]').getBoundingClientRect().toJSON()");
//   await browser.page.click(id, r.x + r.width / 2, r.y + r.height / 2);   // act
//   await browser.page.type(id, "hello");
//   await browser.page.key(id, "Enter");
//   await browser.sleep(1500);
//   browser.viewImage(await browser.content.screenshot(id));   // verify
//   await browser.tabs.close(id);

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
  /** A sidebar folder id (see `browser.folders`). A folder is a pane-less
   *  tab in the tab strip, so this is also its SplitId. */
  type FolderId = string;

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
    /**
     * Unix seconds until which an agent holds this tab "in use" (see
     * `tabs.use`). While set, the tab keeps rendering offscreen and the
     * sidebar shows "Agent is using this tab".
     */
    agentActiveUntil?: number;
    /** The split this pane belongs to. Unsplit tabs still have one. */
    splitId?: SplitId;
    /** All pane ids in this pane's split, in display order (includes `id`).
     *  `length > 1` means the user sees this tab beside others. */
    splitTabIds: TabId[];
    /** Whether this pane is the visible/focused one within its split. */
    isFocusedInSplit: boolean;
    /** The space whose tab list contains this pane's tab. */
    spaceId?: SpaceId;
    /** The sidebar folder this tab belongs to, if any. */
    folderId?: FolderId;
  }

  /**
   * A sidebar folder: a non-selectable item in the tab strip (it can sit at
   * any position) that groups pinned tabs under ONE row. Members keep a saved
   * "pinned" URL; closing a member resets it to that URL and keeps it in the
   * folder. Members the user has opened since last closing them are listed
   * under the folder row.
   */
  /** A user-created toolbar button (see `browser.toolbar`). */
  interface ToolbarButton {
    id: string;
    label: string;
    /** SF Symbol name. */
    icon: string;
    /** Body of an async BrowserJS function, or null for an agent-backed button. */
    bjs: string | null;
    instructions?: string;
  }

  interface FolderInfo {
    id: FolderId;
    spaceId?: SpaceId;
    windowId?: WindowId;
    /** Position in the space's tab strip (reorder with `tabs.move`). */
    index?: number;
    name: string;
    /** Pane ids of every member, in folder order. */
    tabIds: TabId[];
    /** Pane ids of members currently open (shown under the folder row). */
    openTabIds: TabId[];
    /** Split ids of every member, in folder order. */
    splitIds: SplitId[];
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
    /** True when the browser is in chat mode (browser-wide: every sidebar = that space's coordinator thread). */
    chatMode: boolean;
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
      /**
       * Open a VISIBLE tab the user will see (it becomes the current tab unless
       * `background`). Use this only when the user asked to see the page or
       * you're presenting a finished result — for your own browsing, research,
       * or form-filling prefer `openGhost`, which the user isn't interrupted by.
       *
       * The tab lands in YOUR space (the one your terminal / chat lives in),
       * even if the user is currently looking at a different space. There is
       * no spaceId option and you never need `spaces.activate` first.
       */
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
       * PREFERRED way for an agent to open a page. Opens a hidden "ghost" agent
       * tab — live but not selected, audio/mic/camera muted, dimmed in the
       * sidebar with an "Agent tab" subtitle. The page renders offscreen at a
       * real 1280×800 viewport, so every `content.*` and `page.*` call
       * (screenshot, click, type, key, scroll, eval) works on it without the
       * user ever seeing it. If the user activates the tab themselves it's
       * promoted to a normal tab. Call `tabs.close(id)` when you're done, or
       * `tabs.activate(id)` to show it to the user. Like `open`, it lands in
       * YOUR space automatically — no spaceId needed.
       */
      openGhost(url: string, opts?: { windowId?: WindowId }): Promise<TabId>;
      /**
       * Lease a tab for active agent use. While leased the page is kept
       * mounted in the offscreen stage with `document.visibilityState ===
       * 'visible'`, so timers, rAF and "pause when hidden" sites keep running
       * even though the user isn't looking, and the sidebar labels it
       * "Agent is using this tab". Default lease: 60 minutes. `openGhost` and
       * every `page.*` / `content.*` call renew the lease implicitly, so you
       * only need this to (a) lease a tab the USER opened before driving it,
       * (b) hold a tab you'll come back to later without touching it, or
       * (c) release early with `{ minutes: 0 }`. Returns the expiry (unix s).
       */
      use(id: TabId, opts?: { minutes?: number }): Promise<number>;
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
       * Capture the tab's viewport as an image (works on hidden/ghost tabs too).
       * Pass the result to `browser.viewImage(...)` to surface it back to the
       * calling model. Coordinates you read off the screenshot are the same
       * CSS-pixel coordinates `page.click` takes.
       */
      screenshot(id: TabId): Promise<Image>;
      /** Only valid for openHTML / webapp tabs. (v1: not implemented.) */
      write(id: TabId, html: string): Promise<void>;
    };

    /**
     * In-page JS execution and computer-use input — runs against the page's
     * WKWebView, visible or not. Input is dispatched as real native events
     * (WebKit hit-testing, focus, default actions: Enter submits forms, clicking
     * a link navigates, framework handlers fire), so it behaves like a user.
     */
    page: {
      /**
       * Evaluate `js` in the page and return its value. A bare expression
       * (`document.title`, `(() => ({...}))()`, `JSON.stringify(x)`) is returned
       * directly; a multi-statement body needs its own `return`. Results must
       * be JSON-serializable (e.g. call `.toJSON()` on a DOMRect).
       */
      eval(id: TabId, js: string): Promise<any>;
      /** Polls `predicateJs` until it evaluates truthy or `timeoutMs` elapses. */
      waitFor(id: TabId, predicateJs: string, timeoutMs?: number): Promise<any>;
      /**
       * Click the page at CSS-pixel coordinates (x, y) from the viewport's
       * top-left — the same coordinates as a screenshot or
       * `getBoundingClientRect()`. Pass `clickCount: 2` for a double-click.
       * Clicking an input focuses it, so follow with `type`.
       */
      click(id: TabId, x: number, y: number, opts?: { button?: 'left' | 'right' | 'middle'; clickCount?: number }): Promise<void>;
      /** Type text into the focused element as real keystrokes ("\n" presses Enter). */
      type(id: TabId, text: string): Promise<void>;
      /**
       * Press one key: a character ("a", "/") or a name — "Enter", "Tab",
       * "Escape", "Backspace", "Delete", "ArrowUp/Down/Left/Right", "Home",
       * "End", "PageUp", "PageDown", "F1"… — with optional modifiers, e.g.
       * `key(id, "a", ["command"])` to select all.
       */
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
      /**
       * Turn chat mode on/off. Chat mode is browser-wide (the space id is
       * accepted but ignored): every space's sidebar becomes its coordinator
       * chat thread and tabs show as cards in it (see `present`).
       */
      setChatMode(spaceId: SpaceId, enabled: boolean): Promise<void>;
    };

    /**
     * Sidebar folders (see `FolderInfo`). A folder is a tab-strip item, so
     * `tabs.move(folderId, toIndex)` repositions it. `spaceId` defaults to
     * the current window's space.
     */
    folders: {
      list(opts?: { spaceId?: SpaceId; windowId?: WindowId }): Promise<FolderInfo[]>;
      get(folderId: FolderId): Promise<FolderInfo>;
      /** Create an empty folder at the end of the space's tab strip. Add tabs with `addTab`. */
      create(name: string, opts?: { spaceId?: SpaceId; windowId?: WindowId }): Promise<FolderId>;
      rename(folderId: FolderId, name: string): Promise<void>;
      /**
       * Delete a folder. Its members move back to the window's ordinary tab
       * list, or are closed when `closeTabs` is set.
       */
      delete(folderId: FolderId, opts?: { closeTabs?: boolean; windowId?: WindowId }): Promise<void>;
      /**
       * Move an existing tab into a folder, pinning its current URL as the
       * state it resets to when closed. `open` also lists it under the folder
       * row right away (otherwise it only appears in the folder's preview
       * until the user opens it).
       */
      addTab(tabId: TabId, folderId: FolderId, opts?: { open?: boolean }): Promise<void>;
      /** Drop a tab from its folder. The tab is closed. */
      removeTab(tabId: TabId): Promise<void>;
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
     * (~/Library/Application Support/Wowser/Apps/<slug>/) and opens it in
     * a new tab at `tang://<slug>/`. Some apps ship with the browser (e.g. the
     * Notes app at `tang://notes/`); writing an app with the same name
     * overrides the bundled one. `files` maps relative paths to contents and
     * MUST include an `index.html`. Pages loaded from tang:// receive the full
     * `window.browser` API (this same surface), so an app can drive the browser.
     *
     * ## manifest.json (optional)
     *
     * Include a `manifest.json` in `files` to give the app a title/metadata
     * and register entry points that surface it elsewhere in the browser:
     *
     *   {
     *     "title": "Weather",           // display name (Apps menu, etc.); defaults to the slug
     *     "description": "...",         // optional
     *     "icon": "🌤️",                 // optional emoji shown next to the title
     *     "entryPoints": [ ... ]        // optional, see below
     *   }
     *
     * Installed apps are listed in the "Apps" menu in the menu bar. Each entry
     * point is { kind, label, bjs, keyword? } where `bjs` is the BODY of an
     * async BrowserJS function (same environment as run_browser_js: `browser`
     * in scope, `await` allowed, explicit `return` if you want a result) plus
     * a kind-specific `args` object in scope:
     *
     * - kind "new": an item in the new-tab "…" menu, below "New Claude".
     *   args = { windowId: WindowId, profileId?: string }
     *   Example — open the app in a new tab:
     *     { "kind": "new", "label": "New Weather Note",
     *       "bjs": "await browser.tabs.open('tang://weather/new', { windowId: args.windowId });" }
     *
     * (To add a button to the toolbar of web tabs, use `browser.toolbar` below.)
     *
     * - kind "search": registers `keyword`; when an omnibox query starts with
     *   that word (e.g. keyword "weather" matches "weather" or "weather in sf"),
     *   a result titled `label` appears; selecting it runs `bjs`.
     *   args = { query: string, windowId: WindowId }
     *   Example:
     *     { "kind": "search", "keyword": "weather", "label": "Weather result",
     *       "bjs": "await browser.tabs.open('tang://weather/?q=' + encodeURIComponent(args.query), { windowId: args.windowId });" }
     */
    webapp: {
      create(opts: { name: string; files: Record<string, string>; exposeBrowserJS?: boolean }): Promise<TabId>;
    };

    /**
     * Notes: simple documents for the user — a comparison, a summary, a plan,
     * anything longer than a few lines of chat. `write` saves the note as a
     * file under `tang://notes/` (markdown is rendered to a clean HTML page
     * when served; `html` is served as-is) and, unless `show: 'none'`, presents
     * it like `present` does (default `'both'`: a card in your thread AND the
     * main view). Returns the note's url (open it again any time) and the tab
     * id it was shown in. Use markdown links for every page you reference.
     */
    notes: {
      write(opts: { title: string; markdown?: string; html?: string; show?: 'none' | 'card' | 'main' | 'both' }): Promise<{ url: string; tabId?: TabId }>;
    };

    /**
     * User-customizable buttons on the trailing edge of every web tab's
     * toolbar (right-click that area to reorder/hide them). A custom button is
     * { id, label, icon, bjs?, instructions? }: `icon` is an SF Symbol name,
     * `instructions` is what the user said the button should do, and `bjs` is
     * the BODY of an async BrowserJS function run when the button is clicked
     * (same environment as run_browser_js: `browser` in scope, `await`
     * allowed) with `args = { buttonId, tabId, url?, windowId, modifiers }`
     * (`modifiers` is e.g. ["shift","option"]) describing the click. When
     * `bjs` is null, clicking instead spawns a background agent that is given
     * the current page, the click details and `instructions` — use that for
     * buttons whose job needs judgment ("summarize this for my mom") rather
     * than code. If a button's bjs throws, the browser shows a toast and
     * spawns an agent to fix it.
     *
     * `update` leaves omitted fields alone; pass `bjs: null` to make the
     * button agent-backed. `click` runs a button as if the user clicked it in
     * `tabId` (default: your tab) — use it to test.
     *
     * Example — a button that opens the current page on archive.org:
     *   await browser.toolbar.update(id, {
     *     icon: 'clock.arrow.circlepath',
     *     bjs: "await browser.tabs.open('https://web.archive.org/web/*\/' + args.url, { windowId: args.windowId });"
     *   });
     */
    toolbar: {
      list(): Promise<ToolbarButton[]>;
      get(id: string): Promise<ToolbarButton | null>;
      create(opts: { label: string; icon?: string; bjs?: string; instructions?: string }): Promise<ToolbarButton>;
      update(id: string, opts: { label?: string; icon?: string; bjs?: string | null; instructions?: string }): Promise<ToolbarButton>;
      remove(id: string): Promise<void>;
      click(id: string, opts?: { tabId?: TabId }): Promise<void>;
    };

    /**
     * Durable per-site customization: CSS and JS that Wowser injects into
     * every page on `host` (a hostname like "x.com" or any URL; www. is
     * stripped; subdomains are separate hosts), now and on every future
     * visit. Use it to restyle a site, hide elements, or add behavior with
     * `js` (which can insert HTML). `js` runs after load and again whenever
     * the injection refreshes, so make it idempotent (check before you
     * insert). Open tabs on that host update immediately. In `set`, an
     * omitted field is left as-is and "" clears it; `get` returns the current
     * pair. Verify with a screenshot; the user can toggle it off per site
     * from the toolbar.
     */
    inject: {
      get(host: string): Promise<{ host: string; css?: string; js?: string }>;
      set(host: string, opts: { css?: string; js?: string }): Promise<{ host: string; css?: string; js?: string }>;
      clear(host: string): Promise<void>;
    };

    /**
     * Memory: an on-disk, full-text-indexed log of what happened in the
     * browser — page visits (with title/description and the tab they were
     * opened from), text seen on screen, terminal output, agent conversations,
     * downloads, text the user typed, clicks (the element's accessible name,
     * text and link) and HTML form submissions (field values, minus
     * passwords/cards). Every row carries `space_id` / `space`, the space it
     * happened in. One SQLite database per "scope" (a website data store;
     * several spaces can share one). Off unless the user enabled it for a
     * scope in Settings › Memory; disabled scopes have no data.
     *
     * `scope` defaults to the space you're running in, or the only enabled
     * scope. Call `schema()` first — it explains every table and column and
     * how to full-text search. `query` accepts read-only SQL only (SELECT /
     * WITH), with optional positional `?` params, capped at `limit` rows
     * (default 200) and a few seconds of CPU — always LIMIT and prefer
     * substr(text, 1, N) previews. `overview` is the human-readable memory
     * summary for the scope (markdown) plus when it was last edited;
     * `setOverview` replaces it (this is how the regenerate agent saves).
     */
    memory: {
      scopes(): Promise<{ id: string; names: string[]; enabled: boolean; eventCount?: number }[]>;
      schema(): Promise<string>;
      query(opts: { sql: string; scope?: string; params?: (string | number | null)[]; limit?: number }): Promise<Record<string, string | number | null>[]>;
      overview(opts?: { scope?: string }): Promise<{ scope: string; text: string; updatedAt?: string; status: 'idle' | 'queued' | 'running' | 'error'; statusDetail?: string }>;
      setOverview(opts: { text: string; scope?: string }): Promise<{ scope: string; text: string; updatedAt?: string; status: string }>;
    };

    /**
     * Scheduled tasks: jobs a background agent runs once (at given dates) or
     * on a cadence. They are defined in a JSON file — `list()` tells you where
     * — that YOU edit with `browser.fs.read`/`fs.write` (there is no
     * create/update API on purpose; the user cannot edit tasks in the UI, only
     * you can). The browser re-reads the file within a minute of any change
     * and runs whatever is due, one task at a time, in a background tab of the
     * active window, showing a toast when a run starts. Each run's agent is
     * given the task's `prompt` as its instructions plus a private data file
     * (`dataFilePath`) it reads at the start and writes JSON state to at the
     * end, so tasks can remember what they've already done between runs.
     *
     * File format:
     *   { "tasks": [ {
     *       "id": "morning-news",                 // stable slug you choose
     *       "title": "Morning news digest",        // shown in Settings › Tasks
     *       "prompt": "Check … and write a note …",// full instructions for the run agent;
     *                                              // tell it what to keep in its data file
     *       "fireDates": ["2026-09-21T09:00:00Z"], // optional one-off firings (ISO 8601, UTC ok);
     *                                              // the browser deletes each once fired
     *       "recurrence": { "kind": "daily", "hour": 9, "minute": 0 },
     *                                              // optional; kinds:
     *                                              //   { kind: 'interval', seconds }        (≥ 60)
     *                                              //   { kind: 'daily', hour, minute }      (local time)
     *                                              //   { kind: 'weekly', weekday, hour, minute } (1=Sun…7=Sat)
     *       "enabled": true                        // optional, default true
     *   } ] }
     * The browser adds `createdAt`, `lastRunAt`, `lastRunSummary`,
     * `lastRunWasError` and `lastRunAgentKey` to each task; preserve them when
     * rewriting the file (read → modify → write; never write from scratch).
     * A recurrence's next firing is computed from `lastRunAt` (or `createdAt`).
     * To delete a task, remove its entry. To run once ASAP, add a fireDate a
     * minute from now.
     */
    tasks: {
      /** The tasks.json path, the data-file directory, and every task with its computed schedule/next run (unix seconds). */
      list(): Promise<{
        filePath: string;
        dataDirectory: string;
        tasks: Array<{ id: string; title: string; enabled: boolean; schedule: string; nextRunAt?: number; lastRunAt?: number; lastRunSummary?: string; lastRunWasError: boolean; dataFilePath: string }>;
      }>;
    };

    /**
     * Local filesystem (the user's Mac, no sandbox). Paths are absolute or
     * `~`-relative. Text is read/written as UTF-8 strings by default; for
     * binary files pass `{ encoding: 'base64' }` and exchange base64 strings
     * (e.g. `fs.write('~/Desktop/shot.png', img.data, { encoding: 'base64' })`
     * with an `Image` from `content.screenshot`).
     */
    fs: {
      /** Read a file. Throws if it's missing, or if it isn't valid UTF-8 and you didn't ask for base64. */
      read(path: string, opts?: { encoding?: 'utf8' | 'base64' }): Promise<string>;
      /** Write (or `append` to) a file, creating parent directories as needed. */
      write(path: string, data: string, opts?: { encoding?: 'utf8' | 'base64'; append?: boolean }): Promise<void>;
      /** Directory entries, sorted by name. */
      list(path: string): Promise<Array<{ name: string; path: string; isDirectory: boolean; size?: number; modified?: number }>>;
      /** `exists: false` (rather than a throw) for a missing path. `modified` is unix seconds. */
      stat(path: string): Promise<{ path: string; exists: boolean; isDirectory: boolean; size?: number; modified?: number }>;
      /** Moves the file or directory to the Trash (recoverable). */
      remove(path: string): Promise<void>;
      /** mkdir -p. */
      mkdir(path: string): Promise<void>;
    };

    /**
     * AI agents. Create an agent session, send it messages (with optional
     * images — e.g. from `content.screenshot`), and read back its transcript.
     * Turns run asynchronously: `send` returns immediately; use `await` (waits
     * until idle, up to timeoutMs) or poll `messages`.
     *
     * By default (`exposeBrowserJS: true`) the agent itself gets a
     * `run_browser_js` tool + these docs, so it can drive the browser and see
     * screenshots it captures via `browser.viewImage(...)`.
     *
     * Typical chat loop, rendering progress as it happens:
     *   const id = await browser.agent.create({ key: 'my-chat', model: 'sonnet' });
     *   await browser.agent.send({ id, text: userInput });   // returns immediately
     *   let since = 0, r;
     *   do {
     *     r = await browser.agent.await({ id, since, timeoutMs: 30000 });
     *     for (const m of r.messages) render(m);   // assistant text, tool calls...
     *     since = r.nextIndex;
     *   } while (!r.done);
     *
     * Three things worth knowing:
     * - `send` does NOT wait for the agent to be free. Sending while it's
     *   working queues the message, which is how you steer it mid-task.
     * - `interrupt` stops the current turn (a Stop button); the turn ends with
     *   stopReason "interrupted" rather than an error.
     * - Pass `key` to get a durable session that survives reloads/restarts.
     */
    agent: {
      /**
       * Returns the agentId. Throws if no agent backend is available.
       *
       * With a `key`, returns the EXISTING agent for that key if there is one —
       * reconnecting to it if it's still live, otherwise resuming it so it
       * still remembers the conversation — instead of creating a second one.
       * Old messages are NOT replayed: a reattached agent starts with an empty
       * transcript, so `await`/`messages` only ever give you things you
       * haven't seen. Render your own history if you want it on screen.
       */
      create(opts?: {
        /** Stable name for a long-running session; reuse it to reattach. */
        key?: string;
        name?: string;
        /** 'opus' | 'sonnet' | 'haiku' | 'fable' | full model id. Default: the backend's default model. */
        model?: string;
        /** Reasoning effort: 'low' | 'medium' | 'high'. */
        effort?: string;
        systemPrompt?: string;
        /** Give the agent browser control via a run_browser_js tool (default true). */
        exposeBrowserJS?: boolean;
        /**
         * Also give the agent real filesystem/shell tools (read, write, edit,
         * bash) scoped to `workingDirectory`. Default false — browser agents
         * normally act through run_browser_js instead.
         */
        fileSystemTools?: boolean;
        /** Directory for the filesystem tools. Ignored unless fileSystemTools. */
        workingDirectory?: string;
        /**
         * Tools YOUR app implements. Declare them here, then implement them
         * with `agent.serve(id, handlers)` — that's how you let an agent act
         * on the app itself (add a row, run a query, change a setting) rather
         * than only talk about it.
         */
        tools?: Array<{ name: string; description: string; inputSchema?: object }>;
      }): Promise<string>;
      /**
       * Queue a message and return immediately — the turn runs in the
       * background. Safe to call while the agent is already working: the
       * message is delivered right away and answered in order, so this is how
       * you redirect an agent mid-task.
       */
      send(opts: { id: string; text: string; images?: Image[] }): Promise<void>;
      /**
       * Wait (up to timeoutMs, default 30000) for the agent to make progress:
       * resolves as soon as new transcript entries appear OR the turn ends,
       * whichever comes first — so you get tool calls and partial output live
       * rather than only a final answer. Pass `since` (start at 0) and feed
       * `nextIndex` back in on the next call.
       *
       * `done` is false when it returned because of progress or a timeout;
       * loop until it's true.
       */
      await(opts: { id: string; since?: number; timeoutMs?: number }): Promise<{
        done: boolean;
        status: string;
        text?: string;
        isError: boolean;
        messages: Array<{ index: number; role: string; text: string; toolName?: string }>;
        nextIndex: number;
        /**
         * Your app's tools that the agent is waiting on. The agent is BLOCKED
         * until each is answered with `respondTool`. Handed out once each —
         * prefer `serve()`, which handles this for you.
         */
        toolCalls: Array<{ callId: string; name: string; inputJSON: string }>;
      }>;
      /**
       * Answer a tool call from `await`. `result` can be a string or any
       * JSON-able value. Unanswered calls fail the tool after ~120s.
       */
      respondTool(opts: { callId: string; result?: any; isError?: boolean }): Promise<void>;
      /**
       * Implement your app's tools as ordinary async callbacks. Drives the
       * agent until it goes idle, dispatching each tool call to
       * `handlers[name](args)` and sending the return value back. A handler
       * that throws is reported to the agent as a tool error rather than
       * wedging the turn.
       *
       *   const id = await browser.agent.create({
       *     tools: [{ name: 'add_todo', description: 'Add a todo.',
       *               inputSchema: { type: 'object', properties: { title: { type: 'string' } } } }],
       *   });
       *   await browser.agent.send({ id, text: 'add milk to my list' });
       *   await browser.agent.serve(id, {
       *     add_todo: async ({ title }) => { todos.push(title); render(); return 'added'; },
       *   }, { onMessage: m => renderMessage(m) });
       */
      serve(
        id: string,
        handlers: Record<string, (args: any) => any>,
        opts?: { since?: number; timeoutMs?: number; onMessage?: (m: { index: number; role: string; text: string; toolName?: string }) => void }
      ): Promise<{ done: boolean; status: string; text?: string; isError: boolean; nextIndex: number }>;
      /** Transcript entries with index >= since. Roles: user | assistant | thinking | tool_use | tool_result | stopped | error. */
      messages(opts: { id: string; since?: number }): Promise<Array<{ index: number; role: string; text: string; toolName?: string }>>;
      /** Live agents plus saved sessions (status "saved") that can be reopened by key. */
      list(): Promise<Array<{ id: string; key?: string; name?: string; model?: string; status: string; messageCount: number }>>;
      /** Stop the current turn (a Stop button). The turn ends with stopReason "interrupted". */
      interrupt(id: string): Promise<void>;
      /** Shut the agent down and forget it, including any saved session. */
      dispose(id: string): Promise<void>;
    };

    /**
     * CHAT MODE — showing things to the user. In a chat-mode space the sidebar
     * is a chat thread (the "coordinator" agent) and every tab the user can
     * see is a CARD in that thread. `present` is how any agent puts a page in
     * front of the user:
     *   - `show: 'card'` (default) drops a tab card into the calling agent's
     *     thread — the user can click it to open the page. The tab is opened
     *     in the background if it doesn't exist yet (pass `url`).
     *   - `show: 'main'` makes the tab the current tab in the main content
     *     area. If YOU are a subagent whose own tab is what the user is
     *     looking at, the page opens as a split beside your tab instead, and
     *     the sidebar collapses to make room.
     *   - `show: 'both'` does both.
     * Pass an existing `tabId` (e.g. a ghost tab you researched on) or a
     * `url` to open. `note` is an optional caption shown with the card.
     * Returns the tab id shown.
     */
    present(opts: { tabId?: TabId; url?: string; show?: 'card' | 'main' | 'both'; note?: string }): Promise<{ tabId: TabId }>;

    /**
     * Subagents. A coordinator must never do slow work itself: anything that
     * takes more than a few seconds — research across several pages, coding,
     * a long terminal job — goes to a subagent. Each subagent is its own chat
     * TAB (it has a url and a tab id), so it can be presented like any page.
     * Subagents talk back to whoever spawned them with `agents.send`, and
     * get `present` too, so they can show the user pages directly.
     */
    agents: {
      /**
       * Spawn a subagent tab and give it `task`. `show` controls how it's
       * surfaced in your thread (default 'card'; 'none' keeps it hidden until
       * it reports back). `fileSystemTools` gives it real shell/file tools in
       * `workingDirectory`. Returns its key (use with `agents.send`), tab id,
       * and url. The subagent starts working immediately and will `agents.send`
       * you its result when done — you don't need to wait for it.
       */
      spawn(opts: { task: string; name?: string; model?: string; effort?: string; fileSystemTools?: boolean; workingDirectory?: string; show?: 'card' | 'main' | 'both' | 'none' }): Promise<{ key: string; tabId: TabId; url: string }>;
      /** Send a message to another agent by key (your parent, or a subagent you spawned). It starts a turn there. */
      send(opts: { key: string; text: string }): Promise<void>;
      /** Agents related to you: your parent and your subagents, with status. */
      list(): Promise<Array<{ key: string; name?: string; status: string; tabId?: TabId; url?: string; parentKey?: string; isSelf: boolean }>>;
      /** Read another agent's transcript (assistant text, tool calls…) from `since`. */
      transcript(opts: { key: string; since?: number }): Promise<Array<{ index: number; role: string; text: string; toolName?: string }>>;
    };

    /**
     * Terminal tabs. Open a shell (optionally running a command), read what
     * it printed, and type into it. `read` returns everything on screen plus
     * scrollback; pass the returned `token` back as `since` next time to get
     * only what changed. Long-running jobs (builds, `claude`, servers) belong
     * in a terminal tab; poll `read` rather than blocking.
     */
    terminal: {
      open(opts?: { cwd?: string; command?: string; show?: 'card' | 'main' | 'both' | 'none' }): Promise<TabId>;
      read(id: TabId, opts?: { since?: string; maxChars?: number }): Promise<{ text: string; token: string; running: boolean; command?: string; cwd?: string }>;
      /** Types `text` into the terminal as if entered by the user ("\n" presses Return). */
      write(id: TabId, text: string): Promise<void>;
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
