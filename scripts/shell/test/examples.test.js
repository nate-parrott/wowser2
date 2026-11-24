import { test, expect, afterEach, describe } from "bun:test";
const { loadShell, readBranch, BRANCHES } = require("../lib/loadShell");
const path = require("path");

let s;
afterEach(() => s && s.dispose());

// Mount one example inside a tiny host layout, on top of the stock branch.
function bootWith(source, opts) {
  const files = Object.assign(readBranch(path.join(BRANCHES, "stock")), { "t/index.tsx": source });
  s = loadShell(Object.assign({ files }, opts));
  s.mount("t/index");
  if (s.errors.length) throw new Error(JSON.stringify(s.errors, null, 1));
  return s;
}
const ids = (prefix) => s.tree.findAll((n) => (n.props.testID || "").startsWith(prefix)).map((n) => n.props.testID);

describe("examples: each idea works with the primitives as they are", () => {
  test("Clock ticks without re-rendering its surroundings", async () => {
    bootWith(`
      import { Column, Text } from "wowser";
      import { Clock } from "../examples/Clock";
      globalThis.outerRenders = 0;
      export default function T() { outerRenders++; return <Column><Text>static</Text><Clock /></Column>; }`);
    const clock = s.tree.byTestId("clock");
    expect(s.tree.text(clock)).toMatch(/\d{1,2}:\d{2}/);
    await s.settle(1100);
    expect(JSON.parse(s.shell.evaluate("outerRenders")).value).toBe(1);
  });

  test("TabSearch: hotkey opens, typing filters, Enter switches tab", async () => {
    bootWith(`
      import { Stack } from "wowser";
      import { TabSearch } from "../examples/TabSearch";
      export default function T() { return <Stack style={{ flex: 1 }}><TabSearch /></Stack>; }`);
    expect(s.tree.byTestId("tab-search")).toBeNull();
    s.hotkey("cmd+shift+a");
    expect(s.tree.byTestId("tab-search")).not.toBeNull();
    expect(ids("tab-search-row-").length).toBe(8);
    const input = s.tree.byTestId("tab-search-input");
    expect(input.props.autoFocus).toBe(true);
    s.fire(input, "onChangeText", "figma");
    expect(ids("tab-search-row-")).toEqual(["tab-search-row-0"]);
    s.fire(input, "onSubmit", { __args: ["figma", { modifiers: {} }] });
    await s.settle();
    const st = s.fake.state;
    expect(st.tabs[st.spaces[0].currentTabId].panes[0].title).toBe("Figma");
    expect(s.tree.byTestId("tab-search")).toBeNull();
  });

  test("ZenMode: chrome leaves the layout, peeks on hover, state persists", async () => {
    bootWith(`
      import { Text } from "wowser";
      import { ZenMode } from "../examples/ZenMode";
      export default function T() { return <ZenMode chrome={<Text testID="chrome">chrome</Text>}><Text>page</Text></ZenMode>; }`);
    expect(s.tree.byTestId("chrome")).not.toBeNull();
    s.hotkey("cmd+shift+.");
    await s.settle();
    expect(s.fake.state.storage.zen).toBe(true);
    expect(s.tree.byTestId("chrome")).toBeNull();
    s.fire(s.tree.byTestId("zen-peek"), "onHover", true);
    expect(s.tree.byTestId("chrome")).not.toBeNull();
    s.fire(s.tree.byTestId("zen-peek"), "onHover", false);
    expect(s.tree.byTestId("chrome")).toBeNull();
  });

  test("DomainGroups: groups by site, collapses, closes a group", async () => {
    bootWith(
      `import { DomainGroups } from "../examples/DomainGroups";
       export default function T() { return <DomainGroups />; }`,
      {
        seed: {
          tabs: [
            ["https://github.com/a/b", "Repo B"],
            ["https://news.ycombinator.com/", "HN"],
            ["https://github.com/c/d/pulls", "Pulls"],
            ["https://gist.github.com/x", "Gist"],
          ],
        },
      }
    );
    expect(ids("group-")).toEqual(["group-github.com"]);
    expect(ids("tab-").length).toBe(4);
    s.press(s.tree.byTestId("group-github.com"));
    await s.settle();
    expect(s.fake.state.storage.collapsedDomains).toEqual(["github.com"]);
    expect(ids("tab-").length).toBe(1);
    s.press(s.tree.byTestId("close-group-github.com"));
    await s.settle();
    expect(s.fake.state.spaces[0].tabs.length).toBe(1);
    expect(ids("group-")).toEqual([]);
  });

  test("StatusBar follows the focused pane's load", async () => {
    bootWith(`import { StatusBar } from "../examples/StatusBar"; export default function T() { return <StatusBar />; }`);
    expect(s.tree.text(s.tree.byTestId("status-bar"))).toContain("https://github.com/nate-parrott/wowser2");
    expect(s.tree.text(s.tree.byTestId("status-bar"))).toContain("8 tabs");
    s.mutate((st) => {
      const pane = st.tabs[st.spaces[0].currentTabId].panes[0];
      pane.isLoading = true;
      pane.progress = 0.4;
    });
    expect(s.tree.text(s.tree.byTestId("status-bar"))).toContain("Loading github.com… 40%");
  });

  test("SpeedDial opens a top site; ⌘-click opens it in a new tab", async () => {
    bootWith(`import { SpeedDial } from "../examples/SpeedDial"; export default function T() { return <SpeedDial count={4} />; }`);
    const dials = ids("dial-");
    expect(dials.length).toBe(4);
    const before = s.fake.state.spaces[0].tabs.length;
    s.press(s.tree.byTestId(dials[1]), { cmd: true });
    await s.settle();
    expect(s.fake.state.spaces[0].tabs.length).toBe(before + 1);
  });

  test("ReadingList: drop a link, drop a tab, open, remove", async () => {
    bootWith(`import { ReadingList } from "../examples/ReadingList"; export default function T() { return <ReadingList />; }`);
    const list = () => s.tree.byTestId("reading-list");
    expect(list().props.dropTypes).toEqual(["tab", "url"]);
    expect(list().props.style.dropTarget).toBeDefined();
    s.fire(list(), "onDrop", { type: "url", url: "https://example.com/a", x: 0, y: 0, width: 1, height: 1 });
    await s.settle();
    const tabId = s.fake.state.spaces[0].tabs[0];
    s.fire(list(), "onDrop", { type: "tab", id: tabId, x: 0, y: 0, width: 1, height: 1 });
    await s.settle();
    expect(s.fake.state.storage.readingList).toEqual([
      { url: "https://news.ycombinator.com/", title: "Hacker News" },
      { url: "https://example.com/a", title: "https://example.com/a" },
    ]);
    expect(s.fake.state.tabs[tabId]).toBeUndefined(); // the dropped tab was closed
    s.press(s.tree.byTestId("unsave-https://example.com/a"));
    await s.settle();
    expect(s.fake.state.storage.readingList.length).toBe(1);
  });

  test("WebPanels: a remote island beside the page, phone-sized", async () => {
    bootWith(`import { WebPanels } from "../examples/WebPanel"; export default function T() { return <WebPanels />; }`);
    expect(s.tree.find((n) => n.type === "webisland")).toBeNull();
    s.press(s.tree.byTestId("panel-translate"));
    await s.settle();
    const island = s.tree.find((n) => n.type === "webisland");
    expect(island.props).toMatchObject({ src: "https://translate.google.com/", mobile: true });
  });

  test("Orb: props flow into the island, messages flow back", async () => {
    bootWith(`import { Orb } from "../examples/Orb"; export default function T() { return <Orb />; }`);
    const island = () => s.tree.find((n) => n.type === "webisland");
    expect(island().props.src).toBe("examples/widgets/orb.html");
    expect(island().props.props).toEqual({ color: s.fake.slice("theme").accent, busy: false });
    expect(s.files["examples/widgets/orb.html"]).toContain("wowser.onProps");
    s.mutate((st) => (st.tabs[st.spaces[0].currentTabId].panes[0].isLoading = true));
    expect(island().props.props.busy).toBe(true);
    s.fire(island(), "onMessage", { type: "tap" });
    expect(s.tree.text(s.tree.byTestId("orb"))).toBe("1");
  });

  test("behaviours: redirect and block navigations, inject CSS, commands", async () => {
    bootWith(`
      import { installBehaviours } from "../examples/behaviours";
      export function setup() { return installBehaviours(); }
      export default function T() { return null; }`);
    await s.settle();
    expect(s.fake.listening.has("navigate")).toBe(true);
    expect(s.emit("navigate", { paneId: "p1", tabId: "t1", url: "https://twitter.com/jack/status/20", isUserInitiated: true })).toEqual({
      redirect: "https://x.com/jack/status/20",
    });
    expect(s.emit("navigate", { paneId: "p1", tabId: "t1", url: "https://ad.doubleclick.net/x", isUserInitiated: false })).toEqual({ cancel: true });
    expect(s.emit("navigate", { paneId: "p1", tabId: "t1", url: "https://example.com/", isUserInitiated: true })).toBeNull();
    expect(s.fake.state.injections["news.ycombinator.com"].css).toContain("max-width");

    // "Close Duplicate Tabs"
    s.mutate((st, fake) => {
      fake.call("tabs.create", { url: "https://www.figma.com/files", activate: false });
      fake.call("tabs.create", { url: "https://www.figma.com/files", activate: false });
    });
    const before = s.fake.state.spaces[0].tabs.length;
    s.hotkey("cmd+shift+d");
    await s.settle();
    expect(s.fake.state.spaces[0].tabs.length).toBe(before - 2);
    expect(s.fake.state.toasts.at(-1).message).toBe("Closed 2 duplicate tabs");

    // "Sort Tabs by Site"
    s.command("sort-tabs-by-site");
    await s.settle();
    const hosts = s.fake.state.spaces[0].tabs.map((id) => new URL(s.fake.state.tabs[id].panes[0].url).host.replace(/^www\./, ""));
    expect(hosts).toEqual([...hosts].sort());
  });

  test("registered commands show up in the kit command bar", async () => {
    s = loadShell({ branch: "stock" });
    s.mount("layouts/Playground");
    await s.settle();
    expect(s.errors).toEqual([]);
    s.press(s.tree.byTestId("address"));
    await s.settle();
    s.fire(s.tree.byTestId("address-input"), "onChangeText", "duplic");
    const rows = s.tree.findAll((n) => (n.props.testID || "").startsWith("suggestion-")).map((n) => s.tree.text(n));
    expect(rows.some((t) => t.includes("Close Duplicate Tabs"))).toBe(true);
  });

  test("Playground: everything together mounts cleanly", async () => {
    s = loadShell({ branch: "stock" });
    s.mount("layouts/Playground");
    await s.settle(30);
    expect(s.errors).toEqual([]);
    for (const id of ["clock", "reading-list", "status-bar", "web-panels", "orb", "zen"]) {
      expect(s.tree.byTestId(id)).not.toBeNull();
    }
    expect(s.tree.nodes.size).toBeLessThan(400);
  });
});
