// Windows, cropped web contents, page watches, global hotkeys and the mouse:
// the primitives behind pop-outs, picture-in-picture and global overlays.
import { test, expect, afterEach, describe } from "bun:test";
const { loadShell, readBranch, BRANCHES } = require("../lib/loadShell");
const path = require("path");

let s;
afterEach(() => s && s.dispose());

function bootWith(files, opts) {
  const all = Object.assign(readBranch(path.join(BRANCHES, "stock")), files);
  s = loadShell(Object.assign({ files: all }, opts));
  s.mount("t/index");
  if (s.errors.length) throw new Error(JSON.stringify(s.errors, null, 1));
  return s;
}
const currentPane = () => {
  const st = s.fake.state;
  return st.tabs[st.spaces[0].currentTabId].panes[0];
};
const watchesFor = (paneId) => Object.entries(s.fake.state.watches).filter(([, w]) => w.paneId === paneId);

describe("<Window>", () => {
  test("is a node whose attributes are plain props, with its children inside", () => {
    bootWith({
      "t/index.xml": `<view state="{ open: true, frame: null }">
        <Stack flex="1">
          <Text testID="main">main</Text>
          <Window if="{open}" testID="w" kind="panel" title="Notes" width="300" height="200" anchor="topTrailing" inset="12"
                  resizable onClose="open = false" onFrame="frame = event">
            <Text testID="inside">in the panel</Text>
          </Window>
          <Text if="{frame}" testID="frame">{frame.width}x{frame.height}</Text>
        </Stack>
      </view>`,
    });
    const w = s.tree.byTestId("w");
    expect(w.type).toBe("window");
    expect(w.props).toMatchObject({ kind: "panel", title: "Notes", width: 300, height: 200, anchor: "topTrailing", inset: 12, resizable: true });
    // Geometry describes the native window, not a box in the layout.
    expect(w.props.style).toBeUndefined();
    expect(s.tree.text(s.tree.byTestId("inside"))).toBe("in the panel");
    expect(w.children.map((c) => c.props.testID)).toEqual(["inside"]);

    // The user resizes it, then closes it.
    s.fire(w, "onFrame", { x: 10, y: 10, width: 420, height: 260 });
    expect(s.tree.text(s.tree.byTestId("frame"))).toBe("420x260");
    s.fire(w, "onClose");
    expect(s.tree.byTestId("w")).toBeNull();
    expect(s.tree.byTestId("main")).not.toBeNull();
  });

  test("works from TSX too", () => {
    bootWith({
      "t/index.tsx": `
        import { Window, Text, useState, Stack } from "wowser";
        export default function T() {
          const [n, setN] = useState(0);
          return <Stack><Window testID="w" kind="overlay" clickThrough x={n} y={40} width={80} height={80} onFocus={() => setN(n + 1)}><Text>o</Text></Window></Stack>;
        }`,
    });
    const w = s.tree.byTestId("w");
    expect(w.props).toMatchObject({ kind: "overlay", clickThrough: true, x: 0, y: 40 });
    s.fire(w, "onFocus");
    expect(s.tree.byTestId("w").props.x).toBe(1);
  });
});

describe("web contents", () => {
  test("<WebPane> carries crop / viewport / cropTo to native", () => {
    bootWith({
      "t/index.xml": `<view>
        <Row>
          <WebPane testID="thumb" paneId="{$pane.id}" viewport="{{ width: 1200 }}" interactive="{false}" width="240" height="150"/>
          <WebPane testID="cut" paneId="{$pane.id}" crop="{{ x: 0, y: 80, width: 600, height: 300 }}" cropFit="fill" flex="1"/>
          <WebPane testID="follow" paneId="{$pane.id}" cropTo="video, canvas" flex="1"/>
        </Row>
      </view>`,
    });
    expect(s.tree.byTestId("thumb").props).toMatchObject({ viewport: { width: 1200 }, interactive: false, style: { width: 240, height: 150 } });
    expect(s.tree.byTestId("cut").props).toMatchObject({ crop: { x: 0, y: 80, width: 600, height: 300 }, cropFit: "fill" });
    expect(s.tree.byTestId("follow").props.cropTo).toBe("video, canvas");
  });

  test("useWatch follows a value inside the page and stops when unmounted", async () => {
    bootWith({
      "t/index.tsx": `
        import { Text, Column, useWatch, useCurrentPane, useState } from "wowser";
        function Title({ paneId }) {
          const title = useWatch(paneId, "document.title");
          return <Text testID="title">{title ?? "…"}</Text>;
        }
        export default function T() {
          const pane = useCurrentPane();
          const [on, setOn] = useState(true);
          return <Column testID="root" onPress={() => setOn(false)}>{on ? <Title paneId={pane.id} /> : null}</Column>;
        }`,
    });
    await s.settle();
    const pane = currentPane();
    const mine = watchesFor(pane.id);
    expect(mine.length).toBe(1);
    expect(mine[0][1].js).toBe("document.title");
    expect(s.tree.text(s.tree.byTestId("title"))).toBe("…");

    s.emit("pageWatch", { id: mine[0][0], value: "Hello" });
    expect(s.tree.text(s.tree.byTestId("title"))).toBe("Hello");
    // Another watch's value is not ours.
    s.emit("pageWatch", { id: "nope", value: "Other" });
    expect(s.tree.text(s.tree.byTestId("title"))).toBe("Hello");

    s.press(s.tree.byTestId("root"));
    await s.settle();
    expect(watchesFor(pane.id).length).toBe(0);
  });

  test("useElementRect re-targets when the pane changes, without a stale rect", async () => {
    bootWith({
      "t/index.tsx": `
        import { Text, useElementRect, useCurrentPane } from "wowser";
        export default function T() {
          const pane = useCurrentPane();
          const r = useElementRect(pane.id, "video");
          return <Text testID="rect">{r ? r.width + "x" + r.height : "none"}</Text>;
        }`,
    });
    await s.settle();
    const first = currentPane();
    const [id, watch] = watchesFor(first.id)[0];
    expect(watch.js).toContain('querySelector("video")');
    s.emit("pageWatch", { id, value: { x: 0, y: 0, width: 640, height: 360, viewportWidth: 1000, viewportHeight: 700 } });
    expect(s.tree.text(s.tree.byTestId("rect"))).toBe("640x360");

    s.mutate((st) => {
      st.spaces[0].currentTabId = st.spaces[0].tabs.find((t) => t !== st.spaces[0].currentTabId);
    });
    await s.settle();
    expect(s.tree.text(s.tree.byTestId("rect"))).toBe("none");
    expect(watchesFor(first.id).length).toBe(0);
    expect(watchesFor(currentPane().id).length).toBe(1);
  });
});

describe("mouse and hotkeys", () => {
  test("$mouse / $screen are live in templates", () => {
    bootWith({
      "t/index.xml": `<view><Text testID="m">{$mouse.inside ? $mouse.x + "," + $mouse.y : "outside"} of {$screen.width}</Text></view>`,
    });
    expect(s.tree.text(s.tree.byTestId("m"))).toBe("outside of 1728");
    s.mutate((st) => (st.mouse = { x: 12, y: 34, inside: true }));
    expect(s.tree.text(s.tree.byTestId("m"))).toBe("12,34 of 1728");
    // Nothing subscribes to the pointer unless a view reads it.
    expect(Array.from(s.subscribed.keys())).toContain("mouse");
  });

  test("views that don't read the pointer don't subscribe to it", () => {
    bootWith({ "t/index.xml": `<view><Text>hi</Text></view>` });
    expect(Array.from(s.subscribed.keys())).not.toContain("mouse");
  });

  test("onMouseMove / onScrollWheel / onMagnify reach handlers", () => {
    bootWith({
      "t/index.xml": `<view state="{ at: '-', zoom: 1, scrolled: 0 }">
        <Column testID="pad" onMouseMove="at = event.inside ? event.x + ':' + event.y : 'left'"
                onScrollWheel="scrolled = scrolled + event.dy" onMagnify="zoom = event.scale">
          <Text testID="out">{at} {scrolled} {zoom}</Text>
        </Column>
      </view>`,
    });
    const pad = s.tree.byTestId("pad");
    expect(pad.props.onMouseMove).toBe(true);
    s.fire(pad, "onMouseMove", { x: 5, y: 9, inside: true });
    s.fire(pad, "onScrollWheel", { dx: 0, dy: -12, x: 5, y: 9, precise: true });
    s.fire(pad, "onMagnify", { phase: "changed", scale: 1.5 });
    expect(s.tree.text(s.tree.byTestId("out"))).toBe("5:9 -12 1.5");
    s.fire(pad, "onMouseMove", { x: 0, y: 0, inside: false });
    expect(s.tree.text(s.tree.byTestId("out"))).toBe("left -12 1.5");
  });

  test("useGlobalHotkey registers a system-wide command", () => {
    bootWith({
      "t/index.tsx": `
        import { Text, useGlobalHotkey, useHotkey, useState } from "wowser";
        export default function T() {
          const [n, setN] = useState(0);
          useGlobalHotkey("ctrl+alt+g", () => setN((v) => v + 1));
          useHotkey("cmd+k", () => {});
          return <Text testID="n">{n}</Text>;
        }`,
    });
    const cmds = Array.from(s.fake.commandsRegistered.values());
    expect(cmds.find((c) => c.hotkey === "ctrl+alt+g").global).toBe(true);
    expect(cmds.find((c) => c.hotkey === "cmd+k").global).toBe(false);
    s.hotkey("ctrl+alt+g");
    expect(s.tree.text(s.tree.byTestId("n"))).toBe("1");
  });
});

describe("examples built on them", () => {
  const playing = (paneId, value) => {
    const w = watchesFor(paneId).find(([, x]) => x.js.includes("paused"));
    s.emit("pageWatch", { id: w[0], value });
  };

  test("PopOutVideo: leaving a playing tab pops its video out; returning puts it back", async () => {
    bootWith({ "t/index.xml": `<view><Stack><PopOutVideo/></Stack></view>` });
    await s.settle();
    const st = s.fake.state;
    const videoTab = st.spaces[0].currentTabId;
    const videoPane = currentPane();
    expect(s.tree.byTestId("popout")).toBeNull();

    // Not playing: switching away does nothing.
    const other = st.spaces[0].tabs.find((t) => t !== videoTab);
    s.mutate((x) => (x.spaces[0].currentTabId = other));
    await s.settle();
    expect(s.tree.byTestId("popout")).toBeNull();
    s.mutate((x) => (x.spaces[0].currentTabId = videoTab));
    await s.settle();

    // Playing: switching away pops it out, cropped to the video.
    playing(videoPane.id, true);
    await s.settle();
    s.mutate((x) => (x.spaces[0].currentTabId = other));
    await s.settle();
    const panel = s.tree.byTestId("popout");
    expect(panel).not.toBeNull();
    expect(panel.type).toBe("window");
    expect(panel.props.title).toBe(videoPane.title);
    expect(s.tree.byTestId("popout-page").props).toMatchObject({ paneId: videoPane.id, cropTo: "video" });

    // Expand goes back to the tab, and the panel goes away.
    s.press(s.tree.byTestId("popout-expand"));
    await s.settle();
    expect(s.fake.state.spaces[0].currentTabId).toBe(videoTab);
    expect(s.tree.byTestId("popout")).toBeNull();

    // Pop out again, then close: the video is paused.
    playing(videoPane.id, true);
    await s.settle();
    s.mutate((x) => (x.spaces[0].currentTabId = other));
    await s.settle();
    s.press(s.tree.byTestId("popout-close"));
    await s.settle();
    expect(s.tree.byTestId("popout")).toBeNull();
    expect(s.fake.calls.some(([name, a]) => name === "panes.eval" && a.paneId === videoPane.id && /pause\(\)/.test(a.js))).toBe(true);
  });

  test("GlobalSwitcher: global hotkey shows an overlay; Enter switches and brings the browser forward", async () => {
    bootWith({ "t/index.xml": `<view><Stack><GlobalSwitcher/></Stack></view>` });
    expect(s.tree.byTestId("switcher")).toBeNull();
    expect(Array.from(s.fake.commandsRegistered.values()).find((c) => c.hotkey === "ctrl+alt+space").global).toBe(true);
    s.hotkey("ctrl+alt+space");
    const w = s.tree.byTestId("switcher");
    expect(w.props).toMatchObject({ kind: "overlay", activates: true });
    const input = s.tree.byTestId("switcher-input");
    s.fire(input, "onChangeText", "figma");
    s.fire(input, "onSubmit", { __args: ["figma", { modifiers: {} }] });
    await s.settle();
    const st = s.fake.state;
    expect(st.tabs[st.spaces[0].currentTabId].panes[0].title).toBe("Figma");
    expect(s.fake.calls.some(([name]) => name === "window.activate")).toBe(true);
    expect(s.tree.byTestId("switcher")).toBeNull();

    // Clicking elsewhere dismisses it.
    s.hotkey("ctrl+alt+space");
    s.fire(s.tree.byTestId("switcher"), "onBlur");
    expect(s.tree.byTestId("switcher")).toBeNull();
  });

  test("EdgePeek: the pointer at the left edge slides the tab list out", () => {
    bootWith({ "t/index.xml": `<view><EdgePeek><Text>page</Text></EdgePeek></view>` });
    s.mutate((st) => (st.window.sidebarVisible = false));
    const x = () => s.tree.byTestId("edge-peek").props.style.offset.x;
    expect(x()).toBe(-251);
    s.mutate((st) => (st.mouse = { x: 3, y: 200, inside: true }));
    expect(x()).toBe(0);
    // Stays while the pointer is on it, leaves when the pointer does.
    s.fire(s.tree.byTestId("edge-peek"), "onHover", true);
    s.mutate((st) => (st.mouse = { x: 120, y: 200, inside: true }));
    expect(x()).toBe(0);
    s.fire(s.tree.byTestId("edge-peek"), "onHover", false);
    expect(x()).toBe(-251);
    s.mutate((st) => (st.window.sidebarVisible = true));
    expect(s.tree.byTestId("edge-peek")).toBeNull();
  });

  test("CursorHalo: a click-through overlay follows the pointer across the screen", async () => {
    bootWith({ "t/index.xml": `<view><Stack><CursorHalo size="{60}"/></Stack></view>` });
    expect(s.tree.byTestId("halo")).toBeNull();
    expect(s.fake.listening.has("globalMouse")).toBe(false);
    s.mutate((st) => (st.mouse = { x: 50, y: 70, inside: true }));
    s.hotkey("ctrl+alt+h");
    await s.settle();
    let halo = s.tree.byTestId("halo");
    expect(halo.props).toMatchObject({ kind: "overlay", clickThrough: true, width: 60, height: 60, x: 120, y: 140 });
    expect(s.fake.listening.has("globalMouse")).toBe(true);
    s.emit("globalMouse", { x: 900, y: 500 });
    halo = s.tree.byTestId("halo");
    expect([halo.props.x, halo.props.y]).toEqual([870, 470]);
    s.hotkey("ctrl+alt+h");
    await s.settle();
    expect(s.tree.byTestId("halo")).toBeNull();
    expect(s.fake.listening.has("globalMouse")).toBe(false);
  });
});
