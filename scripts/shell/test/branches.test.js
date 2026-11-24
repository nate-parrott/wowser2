import { test, expect, afterEach, describe } from "bun:test";
const { loadShell, readBranch, BRANCHES } = require("../lib/loadShell");
const path = require("path");

let s;
afterEach(() => s && s.dispose());

function boot(entry, opts) {
  s = loadShell(Object.assign({ branch: "stock" }, opts));
  s.mount(entry);
  if (s.errors.length) throw new Error(JSON.stringify(s.errors, null, 1));
  return s;
}
const natives = () => s.tree.findAll((n) => n.type === "native").map((n) => n.props.name);

describe("stock layouts", () => {
  test("Classic composes native parts and reacts to the sidebar toggle", async () => {
    boot();
    expect(natives()).toEqual(["WindowBackground", "Sidebar", "Content", "Toasts"]);
    s.mutate((st) => (st.window.sidebarVisible = false));
    // Hidden: content is inset, sidebar floats (offset off-screen until hover).
    expect(natives()).toEqual(["WindowBackground", "Content", "Toasts", "Sidebar"]);
    const floating = s.tree.find((n) => n.type === "native" && n.props.name === "Sidebar");
    expect(floating.props.floating).toBe(true);
    const zone = s.tree.find((n) => n.props.onHover);
    expect(zone.props.style.width).toBe(4);
    s.fire(zone, "onHover", true);
    expect(zone.props.style.width).toBe(218);
  });

  test("every file in the stock branch transpiles and loads", () => {
    s = loadShell({ branch: "stock" });
    const files = Object.keys(s.files).filter((f) => /\.(tsx?|jsx?)$/.test(f));
    expect(files.length).toBeGreaterThan(15);
    for (const f of files) {
      const out = JSON.parse(s.shell.evaluate(`__shell.require(${JSON.stringify(f)}); 1`));
      if (!out.ok) throw new Error(f + ": " + out.error);
    }
  });

  test("ClassicKit: tabs render, select, close and reorder through the kit", async () => {
    boot("layouts/ClassicKit");
    const st = s.fake.state;
    const ids = st.spaces[0].tabs.slice();
    expect(s.tree.byTestId("tab-" + ids[0])).not.toBeNull();
    expect(s.tree.text(s.tree.byTestId("tab-" + ids[0]))).toBe("Hacker News");
    // select
    s.fire(s.tree.byTestId("tab-" + ids[0]), "onPress", { modifiers: {}, x: 0, y: 0 });
    await s.settle();
    expect(st.spaces[0].currentTabId).toBe(ids[0]);
    expect(s.tree.byTestId("tab-" + ids[0]).props.style.background).toEqual({ material: "glass", tint: "accent/0.5" });
    // close
    s.press(s.tree.byTestId("close-" + ids[2]));
    await s.settle();
    expect(s.tree.byTestId("tab-" + ids[2])).toBeNull();
    // drag a tab onto another → inserted before it
    const ok = s.fire(s.tree.byTestId("tab-" + ids[0]), "onDrop", { type: "tab", id: ids[4], x: 1, y: 1, width: 10, height: 10 });
    expect(ok).toBe(true);
    await s.settle();
    expect(st.spaces[0].tabs).toEqual([ids[4], ids[0], ids[1], ids[3]]);
  });

  test("ClassicKit: command bar — type, arrow, enter", async () => {
    boot("layouts/ClassicKit");
    s.press(s.tree.byTestId("address"));
    await s.settle();
    const input = () => s.tree.byTestId("address-input");
    expect(input()).not.toBeNull();
    // ⌘L-style open prefills the URL and shows no suggestions yet.
    expect(input().props.value).toBe("https://github.com/nate-parrott/wowser2");
    expect(s.tree.byTestId("suggestion-0")).toBeNull();
    s.fire(input(), "onChangeText", "wiki");
    // Suggestions are there synchronously — no settle().
    expect(s.tree.text(s.tree.byTestId("suggestion-0"))).toContain("Tangerine - Wikipedia");
    expect(s.tree.byTestId("suggestion-0").props.style.background).toBe("accent");
    expect(s.fire(input(), "onKey", { key: "down", modifiers: {} })).toBe(true);
    expect(s.tree.byTestId("suggestion-1").props.style.background).toBe("accent");
    s.fire(input(), "onSubmit", "wiki");
    await s.settle();
    expect(s.tree.byTestId("address-input")).toBeNull();
    const cur = s.fake.state.tabs[s.fake.state.spaces[0].currentTabId];
    expect(cur.panes[0].url).toBe("https://en.wikipedia.org/wiki/WebKit");
  });

  test("ClassicKit: an empty tab shows the centred command bar; escape closes the tab", async () => {
    boot("layouts/ClassicKit");
    s.press(s.tree.byTestId("new-tab"));
    await s.settle();
    expect(s.tree.byTestId("command-bar")).not.toBeNull();
    expect(s.tree.byTestId("back")).toBeNull(); // no toolbar on an empty tab
    const before = s.fake.state.spaces[0].tabs.length;
    s.fire(s.tree.byTestId("command-input"), "onKey", { key: "escape", modifiers: {} });
    await s.settle();
    expect(s.fake.state.spaces[0].tabs.length).toBe(before - 1);
  });

  test("Chrome: horizontal strip with window controls, bookmarks bar", async () => {
    boot("layouts/Chrome");
    const strip = s.tree.byTestId("tab-strip");
    expect(strip.type).toBe("row");
    expect(strip.props.windowDrag).toBe(true);
    expect(strip.children[0].type).toBe("windowcontrols");
    expect(s.tree.findAll((n) => (n.props.testID || "").startsWith("bookmark-")).length).toBe(3);
    // Dropping on the trailing half of a tab inserts after it.
    const ids = s.fake.state.spaces[0].tabs.slice();
    s.fire(s.tree.byTestId("tab-" + ids[0]), "onDrop", { type: "tab", id: ids[3], x: 90, y: 5, width: 100, height: 30 });
    await s.settle();
    expect(s.fake.state.spaces[0].tabs).toEqual([ids[0], ids[3], ids[1], ids[2], ids[4]]);
    // New tab button
    s.press(s.tree.byTestId("new-tab"));
    await s.settle();
    expect(s.fake.state.spaces[0].tabs.length).toBe(6);
  });

  test("MobileKit on iOS: tab sheet opens, picks a tab, closes", async () => {
    boot("layouts/MobileKit", { platform: "ios" });
    expect(s.tree.byTestId("tab-sheet")).toBeNull();
    s.press(s.tree.byTestId("tabs-button"));
    expect(s.tree.byTestId("tab-sheet")).not.toBeNull();
    const first = s.fake.state.spaces[0].tabs[0];
    s.press(s.tree.byTestId("tab-" + first));
    await s.settle();
    expect(s.tree.byTestId("tab-sheet")).toBeNull();
    expect(s.fake.state.spaces[0].currentTabId).toBe(first);
  });

  test("per-row updates: a title change touches one text node", async () => {
    boot("layouts/ClassicKit");
    const ops = [];
    const orig = s.host.commit;
    s.host.commit = (json) => { ops.push(...JSON.parse(json)); orig(json); };
    const id = s.fake.state.spaces[0].tabs[3];
    s.mutate((st) => (st.tabs[id].panes[0].title = "Renamed"));
    const updates = ops.filter((o) => o[0] === "update");
    expect(ops.filter((o) => o[0] !== "update")).toEqual([]);
    // the title text + the row's label/tooltip
    expect(updates.length).toBeLessThanOrEqual(2);
  });
});

test("the chrome seed is stock plus an overlay", () => {
  const chrome = readBranch(path.join(BRANCHES, "chrome"));
  expect(Object.keys(chrome).sort()).toEqual(["mac/index.tsx", "manifest.json"]);
  const files = Object.assign(readBranch(path.join(BRANCHES, "stock")), chrome);
  s = loadShell({ files });
  s.mount();
  expect(s.errors).toEqual([]);
  expect(s.tree.byTestId("tab-strip")).not.toBeNull();
});
