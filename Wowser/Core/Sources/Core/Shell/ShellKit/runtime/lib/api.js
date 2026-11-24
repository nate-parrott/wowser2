// The imperative half of the `wowser` module: everything a UI can *do*.
//
// Calls are synchronous (`host.call`) unless they inherently take time.
// The UI context shares the main thread with the browser model, so an event
// handler can mutate state and read the result in the same turn — no promise
// round-trips for "close this tab" or "what matches this query?".
"use strict";

const host = globalThis.__host;
const ERR = "\u0001";

function call(name, args) {
  const out = host.call(name, args === undefined ? "" : JSON.stringify(args));
  if (out == null || out === "") return null;
  if (out.charCodeAt(0) === 1) throw new Error(name + ": " + out.slice(1));
  return JSON.parse(out);
}

let nextAsync = 1;
const pending = new Map();

function callAsync(name, args) {
  return new Promise((resolve, reject) => {
    const id = nextAsync++;
    pending.set(id, { resolve, reject, name });
    try {
      host.callAsync(id, name, args === undefined ? "" : JSON.stringify(args));
    } catch (e) {
      pending.delete(id);
      reject(e);
    }
  });
}

function _settle(id, ok, payload) {
  const p = pending.get(id);
  if (!p) return;
  pending.delete(id);
  if (ok) p.resolve(payload == null || payload === "" ? null : JSON.parse(payload));
  else p.reject(new Error(p.name + ": " + payload));
}

// ---------------------------------------------------------------- events

// Named native → JS callbacks. Each name has an ordered listener list; for
// intercepting events (e.g. "navigate") the first non-null return value wins.
const listeners = new Map();

function on(name, fn) {
  let list = listeners.get(name);
  if (!list) {
    list = [];
    listeners.set(name, list);
    host.call("events.listen", JSON.stringify({ name, on: true }));
  }
  list.push(fn);
  return () => {
    const l = listeners.get(name);
    if (!l) return;
    const i = l.indexOf(fn);
    if (i >= 0) l.splice(i, 1);
    if (!l.length) {
      listeners.delete(name);
      host.call("events.listen", JSON.stringify({ name, on: false }));
    }
  };
}

function _emit(name, payload) {
  const list = listeners.get(name);
  if (!list) return null;
  let result = null;
  const copy = list.slice();
  for (let i = 0; i < copy.length; i++) {
    try {
      const r = copy[i](payload);
      if (result == null && r != null) result = r;
    } catch (e) {
      console.error('Error in "' + name + '" listener: ' + (e && e.stack ? e.message + "\n" + e.stack : e));
    }
  }
  return result;
}

// ---------------------------------------------------------------- namespaces

const tabs = {
  /** Open a tab. No `url` → an empty tab with the command bar open. */
  create: (opts) => call("tabs.create", opts || {}),
  close: (tabId) => call("tabs.close", { tabId }),
  /** Make `tabId` the window's current tab. */
  activate: (tabId) => call("tabs.activate", { tabId }),
  /** What clicking a tab row does: activate — or, with a modifier held,
   *  open beside the current tab; pip tabs toggle their panel. */
  select: (tabId, opts) => call("tabs.select", Object.assign({ tabId }, opts)),
  /** Move a tab. `to`: "tabs" | "pinned" | "folder" | "space". */
  move: (tabId, dest) => call("tabs.move", Object.assign({ tabId }, dest)),
  pin: (tabId, before) => call("tabs.move", { tabId, to: "pinned", before }),
  unpin: (tabId, before) => call("tabs.move", { tabId, to: "tabs", before }),
  rename: (tabId, title) => call("tabs.rename", { tabId, title: title == null ? null : title }),
  setEmoji: (tabId, emoji) => call("tabs.setEmoji", { tabId, emoji: emoji == null ? null : emoji }),
  duplicate: (tabId) => call("tabs.duplicate", { tabId }),
  reopenClosed: () => call("tabs.reopenClosed"),
  resetToPinnedURL: (tabId) => call("tabs.resetToPinnedURL", { tabId }),
  /** Merge `tabId`'s panes into `intoTabId` as a split. */
  splitWith: (tabId, intoTabId) => call("tabs.splitWith", { tabId, intoTabId }),
  separateSplit: (tabId) => call("tabs.separateSplit", { tabId }),
  setPip: (tabId, on) => call("tabs.setPip", { tabId, on: !!on }),
  /** Close every unpinned tab in the current space (they are archived). */
  closeAll: () => call("tabs.closeAll"),
  /** Tab ids in the order the built-in sidebar shows them. */
  visibleOrder: () => call("tabs.visibleOrder"),
  /** Tab ids, most recently used first. */
  recent: (max) => call("tabs.recent", { max: max || 12 }),
  /** The native tab context menu, as menu items; run one with `tabs.runMenuAction`. */
  contextMenu: (tabId) => call("tabs.contextMenu", { tabId }),
};

const panes = {
  /** Navigate a pane. `text` may be a URL or a search query. */
  load: (paneId, text) => call("panes.load", { paneId, text }),
  back: (paneId) => call("panes.back", { paneId }),
  forward: (paneId) => call("panes.forward", { paneId }),
  reload: (paneId) => call("panes.reload", { paneId }),
  stop: (paneId) => call("panes.stop", { paneId }),
  close: (paneId) => call("panes.close", { paneId }),
  focus: (paneId) => call("panes.focus", { paneId }),
  zoomIn: (paneId) => call("panes.zoom", { paneId, dir: 1 }),
  zoomOut: (paneId) => call("panes.zoom", { paneId, dir: -1 }),
  resetZoom: (paneId) => call("panes.zoom", { paneId, dir: 0 }),
  setFindOpen: (paneId, open) => call("panes.find", { paneId, open: open !== false }),
  /** Resize two adjacent split panes. */
  setWeights: (tabId, leftIndex, leftWeight, rightWeight) =>
    call("panes.setWeights", { tabId, leftIndex, leftWeight, rightWeight }),
  /** Evaluate JS in the page (isolated world). */
  eval: (paneId, js) => callAsync("panes.eval", { paneId, js }),
  /** Persistent per-host CSS / JS (the same store Clean Mode uses). */
  setInjection: (host_, opts) => callAsync("panes.setInjection", Object.assign({ host: host_ }, opts)),
  copyURL: (paneId) => call("panes.copyURL", { paneId }),
  toggleBookmark: (paneId) => call("panes.toggleBookmark", { paneId }),
};

const spaces = {
  activate: (spaceId) => call("spaces.activate", { spaceId }),
  create: (opts) => call("spaces.create", opts || {}),
  rename: (spaceId, title) => call("spaces.rename", { spaceId, title }),
  setEmoji: (spaceId, emoji) => call("spaces.setEmoji", { spaceId, emoji: emoji == null ? null : emoji }),
  setTheme: (spaceId, theme) => call("spaces.setTheme", { spaceId, theme }),
  move: (spaceId, beforeSpaceId) => call("spaces.move", { spaceId, before: beforeSpaceId }),
  hide: (spaceId) => call("spaces.hide", { spaceId }),
  delete: (spaceId) => call("spaces.delete", { spaceId }),
  showNewSpacePage: () => call("spaces.showNewSpacePage"),
};

const folders = {
  create: (name) => call("folders.create", { name }),
  rename: (folderId, name) => call("folders.rename", { folderId, name }),
  delete: (folderId) => call("folders.delete", { folderId }),
  addTab: (folderId, tabId, opts) => call("folders.addTab", Object.assign({ folderId, tabId }, opts)),
  removeTab: (tabId) => call("folders.removeTab", { tabId }),
  putAway: (folderId) => call("folders.putAway", { folderId }),
};

const win = {
  get id() {
    return host.windowId;
  },
  toggleSidebar: () => call("window.setSidebar", { visible: null }),
  setSidebarVisible: (visible) => call("window.setSidebar", { visible: !!visible }),
  newWindow: () => call("window.new"),
  close: () => call("window.close"),
  minimize: () => call("window.minimize"),
  zoom: () => call("window.zoom"),
  toggleFullscreen: () => call("window.toggleFullscreen"),
  /** Configure the native window frame: where the traffic lights sit (or
   *  that the UI draws its own with <WindowControls/>), minimum size. */
  configure: (opts) => call("window.configure", opts || {}),
};

const commandBar = {
  /** Open the command bar. `prefillURL` starts with the current URL selected. */
  open: (opts) => call("commandBar.set", Object.assign({ open: true }, opts)),
  close: () => call("commandBar.set", { open: false }),
};

const search = {
  /** Instant suggestions from local sources: open tabs, top history, typed
   *  URL / search, actions. Synchronous — call it on every keystroke. */
  suggest: (query, opts) => call("search.suggest", Object.assign({ query }, opts)) || [],
  /** Slower sources (full history, search-engine completions). Resolves with
   *  the complete merged list for `query`. */
  suggestMore: (query, opts) => callAsync("search.suggestMore", Object.assign({ query }, opts)),
  /** Run a suggestion returned by `suggest` / `suggestMore`. */
  open: (suggestion, opts) =>
    call("search.open", Object.assign({ id: typeof suggestion === "string" ? suggestion : suggestion.id }, opts)),
  /** Go to whatever `text` means (URL, search, …) without a suggestion list. */
  go: (text, opts) => call("search.go", Object.assign({ text }, opts)),
  topSites: (limit) => call("search.topSites", { limit: limit || 8 }) || [],
};

const toasts = {
  show: (toast) => call("toasts.show", typeof toast === "string" ? { message: toast } : toast),
  dismiss: (id) => call("toasts.dismiss", { id: id == null ? null : id }),
  performAction: (id, index) => call("toasts.performAction", { id, index }),
};

const settings = {
  get: (key) => call("settings.get", { key }),
  set: (key, value) => call("settings.set", { key, value }),
};

/** Small JSON key/value store private to this branch; survives restarts. */
const storage = {
  get: (key, fallback) => {
    const v = call("storage.get", { key });
    return v == null ? (fallback === undefined ? null : fallback) : v;
  },
  set: (key, value) => call("storage.set", { key, value }),
  remove: (key) => call("storage.set", { key, value: null }),
};

const clipboard = {
  writeText: (text) => call("clipboard.write", { text: String(text) }),
  readText: () => call("clipboard.read"),
};

// ---------------------------------------------------------------- commands

const commandTable = new Map();
let commandListening = false;

const commands = {
  /** Register a command: it appears in the command bar and the app menu,
   *  and `hotkey` ("cmd+shift+k") binds it while this window is key.
   *  Returns an unregister function. */
  register(cmd) {
    if (!cmd || !cmd.id || typeof cmd.run !== "function") {
      throw new Error("commands.register needs { id, title, run }");
    }
    if (!commandListening) {
      commandListening = true;
      on("command", (e) => {
        const c = commandTable.get(e.id);
        if (!c) return null;
        c.run(e);
        return true;
      });
    }
    commandTable.set(cmd.id, cmd);
    call("commands.register", {
      id: cmd.id,
      title: cmd.title || cmd.id,
      icon: cmd.icon || null,
      hotkey: cmd.hotkey || null,
      keywords: cmd.keywords || null,
    });
    return () => {
      if (commandTable.get(cmd.id) === cmd) {
        commandTable.delete(cmd.id);
        call("commands.unregister", { id: cmd.id });
      }
    };
  },
  /** Run a command by id — one registered here or a built-in
   *  ("builtin:newTab", "builtin:reload", …; see `commands.list()`). */
  run: (id, args) => {
    const c = commandTable.get(id);
    if (c) return c.run(args || {});
    return call("commands.run", { id, args: args || null });
  },
  list: () => call("commands.list") || [],
};

// ---------------------------------------------------------------- menus

/** Turn a menu description whose items carry `onSelect` closures into plain
 *  data plus one dispatcher: `[items, (id) => void]`. Ids default to the
 *  item's position ("0", "2.1"), so the data is stable across renders. */
function compileMenu(items) {
  const handlers = new Map();
  const walk = (list, prefix) =>
    (list || []).filter(Boolean).map((item, i) => {
      if (item === "-" || item.separator) return { separator: true };
      const out = {
        id: item.id || prefix + i,
        title: item.title,
      };
      if (item.icon) out.icon = item.icon;
      if (item.checked) out.checked = true;
      if (item.disabled) out.disabled = true;
      if (item.destructive) out.destructive = true;
      if (item.native) out.native = item.native;
      if (item.children) out.children = walk(item.children, out.id + ".");
      if (typeof item.onSelect === "function") handlers.set(out.id, item.onSelect);
      return out;
    });
  const data = walk(items, "");
  return [
    data,
    (id) => {
      const fn = handlers.get(typeof id === "string" ? id : id && id.id);
      if (fn) fn();
    },
  ];
}

const menus = {
  /** Pop up a native menu at the pointer (or `at: {x, y}` in window coords). */
  show(items, opts) {
    const [data, run] = compileMenu(items);
    return callAsync("menus.show", Object.assign({ items: data }, opts)).then((id) => {
      if (id != null) run(id);
      return id;
    });
  },
  compile: compileMenu,
};

// ---------------------------------------------------------------- BrowserJS

// The agent-facing `browser.*` API (tabs, content, page, net, fs, agent, …),
// reachable from UI code too. Every call is async. See BrowserJS.d.ts.
function bjsNamespace(prefix) {
  return new Proxy(function () {}, {
    get(_, prop) {
      if (typeof prop !== "string" || prop === "then") return undefined;
      return bjsNamespace(prefix ? prefix + "." + prop : prop);
    },
    apply(_, __, args) {
      return callAsync("bjs", { fn: prefix, args });
    },
  });
}
const browser = bjsNamespace("");

const shell = {
  get platform() {
    return host.platform;
  },
  get branch() {
    return host.branch;
  },
  /** Re-read this branch from disk and remount. */
  reload: () => call("shell.reload"),
  /** Read a text file from the branch folder. */
  readFile: (path) => call("shell.readFile", { path }),
  openSettings: () => call("shell.openSettings"),
};

const haptics = {
  tap: (kind) => call("haptics.tap", { kind: kind || "generic" }),
};

module.exports = {
  call,
  callAsync,
  on,
  tabs,
  panes,
  spaces,
  folders,
  window: win,
  commandBar,
  search,
  toasts,
  settings,
  storage,
  clipboard,
  commands,
  menus,
  browser,
  shell,
  haptics,
  _settle,
  _emit,
};
