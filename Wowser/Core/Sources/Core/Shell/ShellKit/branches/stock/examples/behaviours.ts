// Customisations with no UI: they run from the entry module's `setup()`,
// once per window.
//
//   // mac/index.tsx
//   import { installBehaviours } from "../examples/behaviours";
//   export function setup() { return installBehaviours(); }
//   export { default } from "../layouts/Classic";
import { on, commands, tabs, panes, toasts, readSlice, type TabInfo } from "wowser";

/** Send some sites somewhere else before they load. */
const REDIRECTS: [RegExp, (m: RegExpExecArray) => string][] = [
  [/^https?:\/\/(?:www\.)?twitter\.com\/(.*)$/, (m) => `https://x.com/${m[1]}`],
  [/^https?:\/\/(?:www\.)?reddit\.com\/(.*)$/, (m) => `https://old.reddit.com/${m[1]}`],
  [/^https?:\/\/(?:[a-z]+\.)?m\.wikipedia\.org\/(.*)$/, (m) => `https://en.wikipedia.org/${m[1]}`],
];

/** Never open these. */
const BLOCKED = [/^https?:\/\/([a-z0-9-]+\.)?doubleclick\.net\//];

function allTabs(): TabInfo[] {
  const strip = readSlice("tabs");
  return strip ? [...strip.pinned, ...strip.tabs] : [];
}

export function installBehaviours(): () => void {
  const off: (() => void)[] = [];

  // 1. Redirect and block navigations. The listener answers synchronously,
  //    before the request leaves the browser.
  off.push(
    on("navigate", (e) => {
      if (BLOCKED.some((re) => re.test(e.url))) return { cancel: true };
      for (const [re, to] of REDIRECTS) {
        const m = re.exec(e.url);
        if (m) return { redirect: to(m) };
      }
      return null;
    })
  );

  // 2. Per-site CSS, applied on every visit from now on.
  panes.setInjection("news.ycombinator.com", { css: "body { max-width: 900px; margin: 0 auto; } .comment { font-size: 14px; line-height: 1.5; }" });

  // 3. Commands: they get hotkeys and show up in kit command bars.
  off.push(
    commands.register({
      id: "close-duplicates",
      title: "Close Duplicate Tabs",
      icon: "square.on.square.dashed",
      hotkey: "cmd+shift+d",
      run() {
        const seen = new Set<string>();
        let closed = 0;
        for (const tab of allTabs()) {
          if (!tab.url || tab.isPinned) continue;
          if (seen.has(tab.url)) {
            tabs.close(tab.id);
            closed++;
          } else seen.add(tab.url);
        }
        toasts.show({ message: closed ? `Closed ${closed} duplicate tab${closed === 1 ? "" : "s"}` : "No duplicate tabs", icon: "square.on.square.dashed" });
      },
    })
  );
  off.push(
    commands.register({
      id: "sort-tabs-by-site",
      title: "Sort Tabs by Site",
      icon: "arrow.up.arrow.down",
      run() {
        const host = (t: TabInfo) => (t.url ? t.url.replace(/^[a-z]+:\/\/(www\.)?/, "") : "~");
        const sorted = allTabs().filter((t) => !t.isPinned).sort((a, b) => host(a).localeCompare(host(b)));
        // Appending each in order leaves the list sorted.
        sorted.forEach((t) => tabs.move(t.id, { to: "tabs" }));
      },
    })
  );

  // 4. React to browser events.
  off.push(
    on("tabClosed", (e) => {
      if (e.url && /\/checkout|\/cart/.test(e.url)) toasts.show({ message: "Closed a checkout page — ⌘⇧T reopens it", icon: "cart" });
    })
  );

  return () => off.forEach((f) => f());
}
