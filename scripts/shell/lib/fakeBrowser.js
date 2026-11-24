// A tiny in-memory browser model that answers the same slice subscriptions
// and action calls as the Swift host (ShellSlices.swift / ShellActions.swift).
// Tests and the DOM simulator run real branches against it.
//
// Keep the JSON shapes here identical to the Swift side: wowser.d.ts is the
// contract for both.
"use strict";

function hostOf(url) {
  try {
    return new URL(url).host.replace(/^www\./, "");
  } catch (_) {
    return "";
  }
}

function createFakeBrowser(seed) {
  let nextId = 1;
  const newId = (p) => p + nextId++;

  const state = {
    window: {
      id: "w1",
      spaceId: "s1",
      sidebarVisible: true,
      commandBarOpen: false,
      commandBarPrefillsURL: false,
      isFullscreen: false,
      isKey: true,
      showingNewSpacePage: false,
      chatMode: false,
    },
    spaces: [
      { id: "s1", title: "Home", emoji: "🏡", hue: 214, tabs: [], pinned: [], currentTabId: null },
      { id: "s2", title: "Work", emoji: "💼", hue: 140, tabs: [], pinned: [], currentTabId: null },
    ],
    tabs: {},
    toasts: [],
    settings: { toolbarAtBottom: false, sidebarWidth: 200 },
    storage: {},
    closed: [],
    scheme: "light",
  };

  function makeTab(url, title, extra) {
    const id = newId("t");
    const paneId = newId("p");
    state.tabs[id] = Object.assign(
      {
        id,
        customTitle: null,
        emoji: null,
        group: null,
        isPip: false,
        badge: null,
        focusedPane: 0,
        panes: [
          {
            id: paneId,
            url: url || null,
            title: title || (url ? hostOf(url) : ""),
            isLoading: false,
            progress: 1,
            canGoBack: false,
            canGoForward: false,
            history: url ? [url] : [],
            historyIndex: url ? 0 : -1,
            weight: 1,
            findOpen: false,
          },
        ],
      },
      extra
    );
    return state.tabs[id];
  }

  const seedTabs = (seed && seed.tabs) || [
    ["https://news.ycombinator.com/", "Hacker News"],
    ["https://github.com/nate-parrott/wowser2", "nate-parrott/wowser2: a webkit browser"],
    ["https://developer.apple.com/documentation/javascriptcore", "JavaScriptCore | Apple Developer Documentation"],
    ["https://en.wikipedia.org/wiki/Tangerine", "Tangerine - Wikipedia"],
    ["https://www.figma.com/files", "Figma"],
  ];
  const s1 = state.spaces[0];
  seedTabs.forEach(([u, t]) => s1.tabs.push(makeTab(u, t).id));
  [
    ["https://mail.google.com/", "Gmail"],
    ["https://calendar.google.com/", "Calendar"],
    ["https://claude.ai/", "Claude"],
  ].forEach(([u, t]) => s1.pinned.push(makeTab(u, t).id));
  s1.currentTabId = s1.tabs[1];
  const s2 = state.spaces[1];
  s2.tabs.push(makeTab("https://linear.app/", "Linear").id);
  s2.currentTabId = s2.tabs[0];

  const history = [
    ["https://news.ycombinator.com/", "Hacker News"],
    ["https://github.com/", "GitHub"],
    ["https://www.youtube.com/", "YouTube"],
    ["https://en.wikipedia.org/wiki/WebKit", "WebKit - Wikipedia"],
    ["https://developer.mozilla.org/en-US/docs/Web/CSS/flex", "flex - CSS | MDN"],
    ["https://www.nytimes.com/", "The New York Times"],
  ];

  // ------------------------------------------------------------ queries

  const curSpace = () => state.spaces.find((s) => s.id === state.window.spaceId);
  const spaceOfTab = (tabId) => state.spaces.find((s) => s.tabs.includes(tabId) || s.pinned.includes(tabId));
  const tabOfPane = (paneId) => Object.values(state.tabs).find((t) => t.panes.some((p) => p.id === paneId));
  const paneById = (paneId) => {
    const t = tabOfPane(paneId);
    return t ? t.panes.find((p) => p.id === paneId) : null;
  };

  function tabInfo(tab, space) {
    const pane = tab.panes[tab.focusedPane] || tab.panes[0];
    const url = pane ? pane.url : null;
    const isPinned = !!space && space.pinned.includes(tab.id);
    return {
      id: tab.id,
      title: tab.customTitle || (pane && pane.title) || (url ? hostOf(url) : "New Tab"),
      subtitle: null,
      url,
      icon: tab.emoji
        ? { kind: "emoji", value: tab.emoji }
        : url
        ? { kind: "favicon", url }
        : { kind: "symbol", name: "plus" },
      isCurrent: !!space && space.currentTabId === tab.id,
      isPinned,
      isLoading: !!(pane && pane.isLoading),
      isGhost: false,
      isUnloaded: false,
      isPip: tab.isPip,
      isSplit: tab.panes.length > 1,
      badge: tab.badge,
      group: tab.group,
      kind: "web",
      hasCustomTitle: !!tab.customTitle,
      paneIds: tab.panes.map((p) => p.id),
      focusedPaneId: pane ? pane.id : null,
      folder: null,
      folderId: null,
    };
  }

  function paneInfo(pane) {
    const tab = tabOfPane(pane.id);
    const space = spaceOfTab(tab.id);
    return {
      id: pane.id,
      tabId: tab.id,
      url: pane.url,
      displayURL: pane.url ? hostOf(pane.url) : "",
      title: pane.title,
      isLoading: pane.isLoading,
      progress: pane.progress,
      canGoBack: pane.historyIndex > 0,
      canGoForward: pane.historyIndex < pane.history.length - 1,
      isSecure: !!pane.url && pane.url.startsWith("https:"),
      isEmpty: !pane.url,
      favicon: pane.url ? new URL("/favicon.ico", pane.url).href : null,
      kind: "web",
      weight: pane.weight,
      isFocused:
        !!space &&
        space.id === state.window.spaceId &&
        space.currentTabId === tab.id &&
        tab.panes[tab.focusedPane] === pane,
      findOpen: pane.findOpen,
      commandBarOpen: state.window.commandBarOpen && tab.panes[tab.focusedPane] === pane,
      topColor: null,
      scheme: null,
      failed: null,
    };
  }

  function hsb(h, s, b) {
    const f = (n) => {
      const k = (n + h / 60) % 6;
      return Math.round(255 * (b - b * s * Math.max(0, Math.min(k, 4 - k, 1))));
    };
    return "#" + [f(5), f(3), f(1)].map((v) => v.toString(16).padStart(2, "0")).join("");
  }

  function slice(key) {
    const bar = key.indexOf("|");
    const name = bar < 0 ? key : key.slice(0, bar);
    const arg = bar < 0 ? {} : JSON.parse(key.slice(bar + 1));
    switch (name) {
      case "window": {
        const sp = curSpace();
        const tab = sp && sp.currentTabId ? state.tabs[sp.currentTabId] : null;
        return Object.assign({}, state.window, {
          currentTabId: tab ? tab.id : null,
          focusedPaneId: tab ? tab.panes[tab.focusedPane].id : null,
          platform: "sim",
        });
      }
      case "spaces":
        return state.spaces.map((s, i) => ({
          id: s.id,
          name: s.title || "Space " + (i + 1),
          title: s.title,
          emoji: s.emoji,
          isCurrent: s.id === state.window.spaceId,
          hue: s.hue,
          secondaryHue: (s.hue + 22) % 360,
          hasImage: false,
          folderPath: null,
        }));
      case "tabs": {
        const sp = arg.space ? state.spaces.find((s) => s.id === arg.space) : curSpace();
        if (!sp) return null;
        return {
          spaceId: sp.id,
          currentTabId: sp.currentTabId,
          pinned: sp.pinned.map((id) => tabInfo(state.tabs[id], sp)),
          tabs: sp.tabs.map((id) => tabInfo(state.tabs[id], sp)),
        };
      }
      case "tab": {
        const tab = state.tabs[arg.id];
        if (!tab) return null;
        return Object.assign(tabInfo(tab, spaceOfTab(tab.id)), { panes: tab.panes.map(paneInfo) });
      }
      case "pane": {
        const p = paneById(arg.id);
        return p ? paneInfo(p) : null;
      }
      case "theme": {
        const sp = curSpace();
        const dark = state.scheme === "dark";
        return {
          scheme: state.scheme,
          accent: hsb(sp.hue, 0.65, dark ? 0.9 : 0.72),
          onAccent: "#ffffff",
          hue: sp.hue,
          secondaryHue: (sp.hue + 22) % 360,
          gradient: [hsb((sp.hue + 22) % 360, 0.5, 0.9) + "0d", hsb(sp.hue, 0.55, 0.85) + "21"],
          backgroundImage: null,
        };
      }
      case "toasts":
        return state.toasts;
      case "setting":
        return state.settings[arg.key] === undefined ? null : state.settings[arg.key];
      case "storage":
        return state.storage[arg.key] === undefined ? null : state.storage[arg.key];
      default:
        return null;
    }
  }

  // ------------------------------------------------------------ search

  function suggest(query, limit) {
    const q = (query || "").trim().toLowerCase();
    const out = [];
    if (!q) {
      history.slice(0, limit).forEach(([url, title]) =>
        out.push({ id: "h:" + url, kind: "history", title, subtitle: hostOf(url), url, icon: { kind: "favicon", url } })
      );
      return out;
    }
    const looksLikeURL = /^[\w-]+(\.[\w-]+)+(\/.*)?$/.test(q) || /^https?:\/\//.test(q);
    if (looksLikeURL) {
      const url = /^https?:\/\//.test(q) ? q : "https://" + q;
      out.push({ id: "u:" + url, kind: "url", title: q, subtitle: "Go to site", url, icon: { kind: "symbol", name: "globe" } });
    }
    Object.values(state.tabs).forEach((t) => {
      const info = tabInfo(t, spaceOfTab(t.id));
      if ((info.title + " " + (info.url || "")).toLowerCase().includes(q)) {
        out.push({ id: "t:" + t.id, kind: "tab", title: info.title, subtitle: "Switch to tab", url: info.url, tabId: t.id, icon: info.icon });
      }
    });
    history.forEach(([url, title]) => {
      if ((title + " " + url).toLowerCase().includes(q)) {
        out.push({ id: "h:" + url, kind: "history", title, subtitle: hostOf(url), url, icon: { kind: "favicon", url } });
      }
    });
    out.push({
      id: "s:" + query,
      kind: "search",
      title: query,
      subtitle: "Search the web",
      url: "https://duckduckgo.com/?q=" + encodeURIComponent(query),
      icon: { kind: "symbol", name: "magnifyingglass" },
    });
    return out.slice(0, limit);
  }

  // ------------------------------------------------------------ actions

  function navigate(pane, url) {
    pane.history = pane.history.slice(0, pane.historyIndex + 1).concat(url);
    pane.historyIndex = pane.history.length - 1;
    pane.url = url;
    pane.title = hostOf(url);
  }

  function closeTab(tabId) {
    const sp = spaceOfTab(tabId);
    if (!sp) return;
    const tab = state.tabs[tabId];
    if (sp.pinned.includes(tabId)) return; // pinned tabs reset rather than close
    const idx = sp.tabs.indexOf(tabId);
    sp.tabs.splice(idx, 1);
    state.closed.push(tab.panes[0].url);
    delete state.tabs[tabId];
    if (sp.currentTabId === tabId) sp.currentTabId = sp.tabs[Math.min(idx, sp.tabs.length - 1)] || sp.pinned[0] || null;
  }

  const commandsRegistered = new Map();
  const listening = new Set();
  const calls = [];

  function call(name, a) {
    a = a || {};
    const sp = curSpace();
    calls.push([name, a]);
    switch (name) {
      case "tabs.create": {
        const tab = makeTab(a.url || null, null);
        sp.tabs.push(tab.id);
        if (a.activate !== false) sp.currentTabId = tab.id;
        if (!a.url) state.window.commandBarOpen = true;
        return tab.id;
      }
      case "tabs.close":
        return closeTab(a.tabId);
      case "tabs.activate":
      case "tabs.select": {
        const s = spaceOfTab(a.tabId);
        if (s) {
          s.currentTabId = a.tabId;
          state.window.spaceId = s.id;
        }
        return null;
      }
      case "tabs.move": {
        const s = spaceOfTab(a.tabId);
        if (!s) return false;
        s.tabs = s.tabs.filter((t) => t !== a.tabId);
        s.pinned = s.pinned.filter((t) => t !== a.tabId);
        const target = a.to === "space" ? state.spaces.find((x) => x.id === a.spaceId) : s;
        const list = a.to === "pinned" ? target.pinned : target.tabs;
        const i = a.before ? list.indexOf(a.before) : -1;
        if (i >= 0) list.splice(i, 0, a.tabId);
        else list.push(a.tabId);
        if (target !== s && s.currentTabId === a.tabId) s.currentTabId = s.tabs[0] || null;
        return true;
      }
      case "tabs.rename":
        state.tabs[a.tabId].customTitle = a.title || null;
        return null;
      case "tabs.setEmoji":
        state.tabs[a.tabId].emoji = a.emoji || null;
        return null;
      case "tabs.duplicate": {
        const src = state.tabs[a.tabId];
        const tab = makeTab(src.panes[0].url, src.panes[0].title);
        sp.tabs.splice(sp.tabs.indexOf(a.tabId) + 1, 0, tab.id);
        sp.currentTabId = tab.id;
        return tab.id;
      }
      case "tabs.reopenClosed": {
        const url = state.closed.pop();
        if (!url) return null;
        const tab = makeTab(url);
        sp.tabs.push(tab.id);
        sp.currentTabId = tab.id;
        return tab.id;
      }
      case "tabs.closeAll":
        sp.tabs.slice().forEach(closeTab);
        return null;
      case "tabs.visibleOrder":
        return sp.pinned.concat(sp.tabs);
      case "tabs.recent":
        return sp.tabs.slice(0, a.max);
      case "tabs.contextMenu":
        return [
          { id: "copyLink", title: "Copy Link" },
          { id: "rename", title: "Rename" },
          { separator: true },
          { id: "close", title: "Close Tab" },
        ];
      case "panes.load": {
        const p = paneById(a.paneId);
        const text = a.text.trim();
        const url = /^https?:\/\//.test(text)
          ? text
          : /^[\w-]+(\.[\w-]+)+/.test(text)
          ? "https://" + text
          : "https://duckduckgo.com/?q=" + encodeURIComponent(text);
        navigate(p, url);
        state.window.commandBarOpen = false;
        return null;
      }
      case "panes.back": {
        const p = paneById(a.paneId);
        if (p.historyIndex > 0) p.url = p.history[--p.historyIndex];
        return null;
      }
      case "panes.forward": {
        const p = paneById(a.paneId);
        if (p.historyIndex < p.history.length - 1) p.url = p.history[++p.historyIndex];
        return null;
      }
      case "panes.reload":
      case "panes.stop":
      case "panes.focus":
      case "panes.zoom":
      case "panes.copyURL":
      case "panes.toggleBookmark":
        return null;
      case "panes.find":
        paneById(a.paneId).findOpen = a.open;
        return null;
      case "panes.close": {
        const t = tabOfPane(a.paneId);
        if (t.panes.length > 1) t.panes = t.panes.filter((p) => p.id !== a.paneId);
        else closeTab(t.id);
        return null;
      }
      case "spaces.activate":
        state.window.spaceId = a.spaceId;
        return null;
      case "spaces.create": {
        const s = { id: newId("s"), title: a.title || null, emoji: null, hue: 26, tabs: [], pinned: [], currentTabId: null };
        state.spaces.push(s);
        state.window.spaceId = s.id;
        return s.id;
      }
      case "spaces.rename":
        state.spaces.find((s) => s.id === a.spaceId).title = a.title;
        return null;
      case "spaces.setEmoji":
        state.spaces.find((s) => s.id === a.spaceId).emoji = a.emoji;
        return null;
      case "spaces.setTheme":
        state.spaces.find((s) => s.id === a.spaceId).hue = a.theme.hue;
        return null;
      case "window.setSidebar":
        state.window.sidebarVisible = a.visible == null ? !state.window.sidebarVisible : a.visible;
        return null;
      case "window.configure":
      case "window.toggleFullscreen":
      case "window.minimize":
      case "window.zoom":
      case "window.close":
      case "window.new":
        return null;
      case "commandBar.set":
        state.window.commandBarOpen = !!a.open;
        state.window.commandBarPrefillsURL = !!a.prefillURL;
        return null;
      case "search.suggest":
        return suggest(a.query, a.limit || 6);
      case "search.topSites":
        return suggest("", a.limit || 8);
      case "search.open": {
        const id = a.id;
        const kind = id.slice(0, 1);
        const rest = id.slice(2);
        state.window.commandBarOpen = false;
        if (kind === "t") return call("tabs.activate", { tabId: rest });
        const tab = sp.currentTabId ? state.tabs[sp.currentTabId] : null;
        const url = kind === "s" ? "https://duckduckgo.com/?q=" + encodeURIComponent(rest) : rest;
        if (a.newTab || !tab) return call("tabs.create", { url });
        navigate(tab.panes[tab.focusedPane], url);
        return null;
      }
      case "search.go": {
        const tab = sp.currentTabId ? state.tabs[sp.currentTabId] : null;
        if (!tab || a.newTab) {
          const id = call("tabs.create", { url: "about:blank" });
          return call("panes.load", { paneId: state.tabs[id].panes[0].id, text: a.text });
        }
        return call("panes.load", { paneId: tab.panes[tab.focusedPane].id, text: a.text });
      }
      case "toasts.show": {
        const t = {
          id: newId("toast"),
          title: a.title || null,
          message: a.message,
          icon: a.icon || "info.circle",
          actions: a.actions || [],
          sticky: !!a.sticky,
        };
        state.toasts.push(t);
        return t.id;
      }
      case "toasts.dismiss":
        state.toasts = a.id ? state.toasts.filter((t) => t.id !== a.id) : state.toasts.slice(1);
        return null;
      case "settings.get":
        return state.settings[a.key] === undefined ? null : state.settings[a.key];
      case "settings.set":
        state.settings[a.key] = a.value;
        return null;
      case "storage.get":
        return state.storage[a.key] === undefined ? null : state.storage[a.key];
      case "storage.set":
        if (a.value == null) delete state.storage[a.key];
        else state.storage[a.key] = a.value;
        return null;
      case "clipboard.write":
        state.clipboard = a.text;
        return null;
      case "clipboard.read":
        return state.clipboard || "";
      case "commands.register":
        commandsRegistered.set(a.id, a);
        return null;
      case "commands.unregister":
        commandsRegistered.delete(a.id);
        return null;
      case "commands.list":
        return Array.from(commandsRegistered.values());
      case "commands.run":
        return null;
      case "events.listen":
        if (a.on) listening.add(a.name);
        else listening.delete(a.name);
        return null;
      case "haptics.tap":
      case "shell.reload":
      case "shell.openSettings":
        return null;
      default:
        throw new Error("fakeBrowser: unknown call " + name);
    }
  }

  function callAsync(name, a) {
    switch (name) {
      case "search.suggestMore":
        return Promise.resolve(suggest(a.query, a.limit || 6));
      case "menus.show":
        return Promise.resolve(null);
      case "panes.eval":
        return Promise.resolve(null);
      case "bjs":
        return Promise.resolve({ fn: a.fn, args: a.args });
      default:
        return Promise.reject(new Error("fakeBrowser: unknown async call " + name));
    }
  }

  return { state, slice, call, callAsync, calls, commandsRegistered, listening, tabOfPane, paneById };
}

module.exports = { createFakeBrowser };
