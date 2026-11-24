import { test, expect, afterEach, describe } from "bun:test";
const { loadShell } = require("../lib/loadShell");

let s;
afterEach(() => s && s.dispose());
const boot = (files, entry = "index") => {
  s = loadShell({ files });
  s.mount(entry);
  return s;
};
const value = (code) => JSON.parse(s.shell.evaluate(code)).value;

describe("XML templates", () => {
  test("a template alone renders: props, attributes, style, text", () => {
    boot({
      "index.xml": `
        <view>
          <Column gap="4" padding="2 6" background="accent/0.5" align="stretch" testID="root">
            <Row height="34" cornerRadius.topLeft="9" hover:background="primary/0.07" pressed:scale="0.97" group testID="row">
              <Icon name="2.circle.fill" size="12"/>
              <Text fontSize="13" lineLimit="1" flex="1">Hello {"wor" + "ld"}!</Text>
            </Row>
          </Column>
        </view>`,
    });
    expect(s.errors).toEqual([]);
    const root = s.tree.byTestId("root");
    expect(root.type).toBe("column");
    expect(root.props.style).toEqual({ gap: 4, padding: [2, 6], background: "accent/0.5", align: "stretch" });
    const row = s.tree.byTestId("row");
    expect(row.props.group).toBe(true);
    expect(row.props.style).toEqual({ height: 34, cornerRadius: { topLeft: 9 }, hover: { background: "primary/0.07" }, pressed: { scale: 0.97 } });
    const icon = s.tree.find((n) => n.type === "icon");
    expect(icon.props).toEqual({ name: "2.circle.fill", size: 12 }); // names stay strings
    expect(s.tree.text()).toBe("Hello world!");
  });

  test("browser state and actions are in scope with no logic file", async () => {
    boot({
      "index.xml": `
        <view>
          <Column>
            <Text testID="count">{$tabs.tabs.length} tabs in {$space.name}</Text>
            <Row for="tab in $tabs.tabs" key="{tab.id}" testID="tab-{tab.id}" onPress="tabs.activate(tab.id)"
                 background="{tab.isCurrent ? 'accent' : 'clear'}">
              <Text>{tab.title}</Text>
              <Pressable testID="close-{tab.id}" onPress="tabs.close(tab.id)"><Icon name="xmark"/></Pressable>
            </Row>
            <Text if="{$window.sidebarVisible}" testID="sb">sidebar on</Text>
            <Text else="" testID="sb">sidebar off</Text>
          </Column>
        </view>`,
    });
    expect(s.errors).toEqual([]);
    expect(s.tree.text(s.tree.byTestId("count"))).toBe("5 tabs in Home");
    const ids = s.fake.state.spaces[0].tabs.slice();
    expect(s.tree.byTestId("tab-" + ids[1]).props.style.background).toBe("accent");
    s.press(s.tree.byTestId("tab-" + ids[3]));
    await s.settle();
    expect(s.tree.byTestId("tab-" + ids[3]).props.style.background).toBe("accent");
    expect(s.tree.byTestId("tab-" + ids[1]).props.style.background).toBe("clear");
    s.press(s.tree.byTestId("close-" + ids[0]));
    await s.settle();
    expect(s.tree.byTestId("tab-" + ids[0])).toBeNull();
    expect(s.tree.text(s.tree.byTestId("count"))).toBe("4 tabs in Home");
    s.mutate((st) => (st.window.sidebarVisible = false));
    expect(s.tree.text(s.tree.byTestId("sb"))).toBe("sidebar off");
  });

  test("template state: assignment in handlers, if / else-if / else, stable identity", () => {
    boot({
      "index.xml": `
        <view state="{ n: 0, open: false }">
          <Column>
            <Text testID="inc" onPress="n = n + 1; open = n > 1">+</Text>
            <Text if="{n === 0}" testID="msg">zero</Text>
            <Text else-if="{n === 1}" testID="msg">one</Text>
            <Text else testID="msg">many ({n})</Text>
            <TextInput testID="field" value="{String(n)}"/>
            <Text if="{open}" testID="open">open</Text>
          </Column>
        </view>`,
    });
    expect(s.errors).toEqual([]);
    const fieldId = s.tree.byTestId("field").id;
    expect(s.tree.text(s.tree.byTestId("msg"))).toBe("zero");
    s.press(s.tree.byTestId("inc"));
    expect(s.tree.text(s.tree.byTestId("msg"))).toBe("one");
    expect(s.tree.byTestId("open")).toBeNull();
    s.press(s.tree.byTestId("inc"));
    expect(s.tree.text(s.tree.byTestId("msg"))).toBe("many (2)");
    expect(s.tree.byTestId("open")).not.toBeNull();
    // Branches coming and going did not remount the sibling after them.
    expect(s.tree.byTestId("field").id).toBe(fieldId);
    expect(s.tree.byTestId("field").props.value).toBe("2");
  });

  test("logic file: props in, names out; hooks work; named exports pass through", async () => {
    boot({
      "index.xml": `<view><Column><Counter start="5" label="Clicks"/></Column></view>`,
      "Counter.xml": `
        <view>
          <Row testID="counter" onPress="{bump}" tooltip="{label}">
            <Text>{label}: {count} (double {double})</Text>
          </Row>
        </view>`,
      "Counter.ts": `
        import { useState, useMemo } from "wowser";
        export const helper = 42;
        export default function Counter({ start }: { start: number }) {
          const [count, setCount] = useState(start);
          const double = useMemo(() => count * 2, [count]);
          return { count, double, bump: () => setCount(count + 1) };
        }`,
      "other.ts": `import Counter, { helper } from "./Counter"; globalThis.probe = [typeof Counter, helper];`,
    });
    expect(s.errors).toEqual([]);
    expect(s.tree.text()).toBe("Clicks: 5 (double 10)");
    s.press(s.tree.byTestId("counter"));
    expect(s.tree.text()).toBe("Clicks: 6 (double 12)");
    s.shell.evaluate(`__shell.require("other")`);
    expect(value("probe")).toEqual(["object", 42]);
  });

  test("renders before the code exists, and survives broken logic", () => {
    boot({
      "index.xml": `
        <view>
          <Column>
            <Text testID="a">{notWrittenYet.deep.value}</Text>
            <Text testID="b" onPress="{handlerThatDoesNotExist}">static part</Text>
            <Brand/>
            <FutureWidget size="3"/>
          </Column>
        </view>`,
      "Brand.xml": `<view><Text testID="brand">{title}</Text><Text testID="plain">still here</Text></view>`,
      "Brand.ts": `export default function Brand() { return { title: "x" } } }}} syntax error`,
    });
    // Nothing fatal: the window is up.
    expect(s.errors.filter((e) => e.fatal)).toEqual([]);
    expect(s.tree.text(s.tree.byTestId("b"))).toBe("static part");
    expect(s.tree.text(s.tree.byTestId("plain"))).toBe("still here");
    // The broken logic file was reported, with its name.
    expect(s.errors.some((e) => e.componentStack.join().includes("Brand.ts"))).toBe(true);
    // A tag with no view yet shows a placeholder naming it.
    expect(s.tree.find((n) => n.props.tooltip === "<FutureWidget> isn't defined yet")).not.toBeNull();
    expect(s.logs.some((l) => l.message.includes("notWrittenYet"))).toBe(true);
    // Pressing a handler that doesn't exist yet is harmless.
    s.press(s.tree.byTestId("b"));
    expect(s.errors.filter((e) => e.fatal)).toEqual([]);
  });

  test("a truncated template shows what has been written so far", () => {
    boot({
      "index.xml": `
        <view>
          <Column testID="col">
            <Text testID="one">first</Text>
            <Row testID="row" gap="4">
              <Text testID="two">second</Text>
              <Text testID="three" fontSi`,
    });
    expect(s.errors.filter((e) => e.fatal)).toEqual([]);
    expect(s.tree.byTestId("one")).not.toBeNull();
    expect(s.tree.byTestId("two")).not.toBeNull();
    expect(s.tree.byTestId("row").props.style.gap).toBe(4);
    expect(s.logs.some((l) => /never closed|not finished/.test(l.message))).toBe(true);
  });

  test("slots, children, context menus and menu items", async () => {
    boot({
      "index.xml": `
        <view>
          <Card title="Hi">
            <Icon slot="leading" name="star"/>
            <Text testID="body">body</Text>
            <Text testID="body2">more</Text>
          </Card>
        </view>`,
      "Card.xml": `
        <view>
          <Row testID="card">
            <slot name="leading"><Text>no icon</Text></slot>
            <Text>{title}</Text>
            <children/>
            <slot name="trailing"><Text testID="fallback">fallback</Text></slot>
            <contextMenu>
              <item title="Close {title}" icon="xmark" onSelect="toasts.show('closed ' + title)"/>
              <separator/>
              <menu title="Move to">
                <item for="sp in $spaces" title="{sp.name}" checked="{sp.isCurrent}" onSelect="spaces.activate(sp.id)"/>
              </menu>
            </contextMenu>
          </Row>
        </view>`,
    });
    expect(s.errors).toEqual([]);
    const card = s.tree.byTestId("card");
    expect(card.children.map((c) => c.type)).toEqual(["icon", "text", "text", "text", "text"]);
    expect(s.tree.byTestId("fallback")).not.toBeNull();
    expect(card.props.contextMenu).toEqual([
      { id: "0", title: "Close Hi", icon: "xmark" },
      { separator: true },
      { id: "2", title: "Move to", children: [{ id: "2.0", title: "Home", checked: true }, { id: "2.1", title: "Work" }] },
    ]);
    s.fire(card, "onContextMenuSelect", "2.1");
    await s.settle();
    expect(s.fake.state.window.spaceId).toBe("s2");
    s.fire(s.tree.byTestId("card"), "onContextMenuSelect", "0");
    expect(s.fake.state.toasts.at(-1).message).toBe("closed Hi");
  });

  test("templates and TSX components mix both ways; native: tags; source mapping", () => {
    boot({
      "index.tsx": `
        import Panel from "./Panel";
        export default function App() { return <Panel count={3} />; }`,
      "Panel.xml": `<view>
  <Column testID="panel">
    <native:Content toolbar="hidden" flex="1"/>
    <Badge n="{count}"/>
  </Column>
</view>`,
      "Badge.tsx": `
        import { Text } from "wowser";
        export function Badge({ n }: { n: number }) { return <Text testID="badge">{n * 2}</Text>; }`,
    });
    expect(s.errors).toEqual([]);
    expect(s.tree.text(s.tree.byTestId("badge"))).toBe("6");
    const native = s.tree.find((n) => n.type === "native");
    expect(native.props).toMatchObject({ name: "Content", toolbar: "hidden", style: { flex: 1 } });
    const d = JSON.parse(s.shell.describeNode(s.tree.byTestId("panel").id));
    expect(d.file).toBe("Panel.xml");
    expect(d.line).toBe(2);
    expect(d.owners.map((o) => o.component)).toEqual(["Panel", "App"]);
  });

  test("only the views that read a slice re-render when it changes", async () => {
    boot({
      "index.xml": `<view><Column><Static/><Live/></Column></view>`,
      "Static.xml": `<view><Text testID="static">{bump()}</Text></view>`,
      "Static.ts": `globalThis.staticRenders = 0; export default () => ({ bump: () => ++staticRenders });`,
      "Live.xml": `<view><Text testID="live">{$pane ? $pane.title : ""}</Text></view>`,
    });
    expect(value("staticRenders")).toBe(1);
    s.mutate((st) => (st.tabs[st.spaces[0].currentTabId].panes[0].title = "Changed"));
    expect(s.tree.text(s.tree.byTestId("live"))).toBe("Changed");
    expect(value("staticRenders")).toBe(1);
  });
});
