import { test, expect, afterEach } from "bun:test";
const { loadShell } = require("../lib/loadShell");

let s;
afterEach(() => s && s.dispose());

const boot = (files) => {
  s = loadShell({ files });
  s.mount("index");
  return s;
};

test("mounts a tree and updates state from an event", () => {
  boot({
    "index.jsx": `
      import { Column, Row, Text, useState } from "wowser";
      export default function App() {
        const [n, setN] = useState(0);
        return <Column style={{ gap: 4 }}>
          <Row testID="btn" onPress={() => setN(n + 1)}><Text>Count {n}</Text></Row>
          {n > 1 ? <Text>big</Text> : null}
        </Column>;
      }`,
  });
  expect(s.errors).toEqual([]);
  expect(s.tree.text()).toBe("Count 0");
  const btn = s.tree.byTestId("btn");
  expect(btn.props.onPress).toBe(true); // functions never cross the bridge
  s.press(btn);
  expect(s.tree.text()).toBe("Count 1");
  s.press(btn);
  expect(s.tree.text()).toBe("Count 2 big");
});

test("only changed props are sent", () => {
  boot({
    "index.jsx": `
      import { Column, Text, useState } from "wowser";
      export default function App() {
        const [n, setN] = useState(0);
        return <Column testID="c" style={{ gap: 4, padding: 8 }} onPress={() => setN(n + 1)}>
          <Text style={{ fontSize: 12 }}>static</Text>
          <Text>{String(n)}</Text>
        </Column>;
      }`,
  });
  const ops = [];
  s.tree.listeners.add(() => {});
  const orig = s.host.commit;
  s.host.commit = (json) => { ops.push(...JSON.parse(json)); orig(json); };
  s.press(s.tree.byTestId("c"));
  // New closures and a fresh (equal) style object must not produce updates.
  expect(ops).toEqual([["update", expect.any(Number), { text: "1" }]]);
});

test("keyed lists reorder without remounting", () => {
  boot({
    "index.jsx": `
      import { Column, Text, useState, useEffect } from "wowser";
      let mounts = 0;
      function Item({ name }) { useEffect(() => { mounts++; }, []); return <Text testID={name}>{name}</Text>; }
      export default function App() {
        const [items, set] = useState(["a", "b", "c"]);
        globalThis.setItems = set; globalThis.mounts = () => mounts;
        return <Column>{items.map((i) => <Item key={i} name={i} />)}</Column>;
      }`,
  });
  const ids = () => s.tree.root().children[0].children.map((n) => n.id);
  const before = ids();
  s.ctx.__shell.evaluate(`setItems(["c", "a", "b"])`);
  expect(s.tree.text()).toBe("c a b");
  expect(ids()).toEqual([before[2], before[0], before[1]]);
  expect(JSON.parse(s.ctx.__shell.evaluate("mounts()")).value).toBe(3);
  s.ctx.__shell.evaluate(`setItems(["a"])`);
  expect(s.tree.text()).toBe("a");
  expect(s.tree.nodes.has(before[1])).toBe(false);
});

test("effects run after commit and clean up", async () => {
  boot({
    "index.jsx": `
      import { Text, useState, useEffect } from "wowser";
      globalThis.log = [];
      function Child({ v }) {
        useEffect(() => { log.push("in " + v); return () => log.push("out " + v); }, [v]);
        return <Text>{v}</Text>;
      }
      export default function App() {
        const [v, setV] = useState("x");
        globalThis.setV = setV;
        return v ? <Child v={v} /> : null;
      }`,
  });
  const log = () => JSON.parse(s.ctx.__shell.evaluate("log")).value;
  expect(log()).toEqual(["in x"]);
  s.ctx.__shell.evaluate(`setV("y")`);
  expect(log()).toEqual(["in x", "out x", "in y"]);
  s.ctx.__shell.evaluate(`setV(null)`);
  expect(log()).toEqual(["in x", "out x", "in y", "out y"]);
  expect(s.tree.root().children.length).toBe(0);
});

test("context and memo", () => {
  boot({
    "index.jsx": `
      import { Column, Text, useState, useContext, createContext, memo } from "wowser";
      const Ctx = createContext("none");
      globalThis.renders = { leaf: 0, memo: 0 };
      const Leaf = memo(function Leaf() { renders.leaf++; return <Text>{useContext(Ctx)}</Text>; });
      const Static = memo(function Static({ tab }) { renders.memo++; return <Text>{tab.title}</Text>; });
      export default function App() {
        const [v, setV] = useState("one");
        const [, bump] = useState(0);
        globalThis.setV = setV; globalThis.bump = () => bump((n) => n + 1);
        return <Ctx.Provider value={v}><Column><Leaf /><Static tab={{ title: "t" }} /></Column></Ctx.Provider>;
      }`,
  });
  const renders = () => JSON.parse(s.ctx.__shell.evaluate("renders")).value;
  expect(s.tree.text()).toBe("one t");
  s.ctx.__shell.evaluate("bump()");
  // memo holds: structurally-equal data props don't re-render.
  expect(renders()).toEqual({ leaf: 1, memo: 1 });
  s.ctx.__shell.evaluate(`setV("two")`);
  expect(s.tree.text()).toBe("two t");
  expect(renders()).toEqual({ leaf: 2, memo: 1 });
});

test("an error boundary contains a broken component", () => {
  boot({
    "index.jsx": `
      import { Column, Text, ErrorBoundary, useState } from "wowser";
      function Bomb({ armed }) { if (armed) throw new Error("boom"); return <Text>fine</Text>; }
      export default function App() {
        const [armed, setArmed] = useState(false);
        globalThis.arm = setArmed;
        return <Column>
          <Text>header</Text>
          <ErrorBoundary fallback={(e, reset) => <Text testID="fb" onPress={() => { arm(false); reset(); }}>failed: {e.message}</Text>}>
            <Bomb armed={armed} />
          </ErrorBoundary>
        </Column>;
      }`,
  });
  expect(s.tree.text()).toBe("header fine");
  s.ctx.__shell.evaluate("arm(true)");
  expect(s.tree.text()).toBe("header failed: boom");
  expect(s.errors.length).toBe(1);
  expect(s.errors[0].fatal).toBe(false);
  expect(s.errors[0].componentStack[0]).toContain("Bomb (index.jsx:");
  s.press(s.tree.byTestId("fb"));
  expect(s.tree.text()).toBe("header fine");
});

test("a render error at the root shows the native error screen", () => {
  boot({ "index.jsx": `export default function App() { return undefinedThing.x; }` });
  const screen = s.tree.find((n) => n.type === "native" && n.props.name === "ErrorScreen");
  expect(screen).not.toBeNull();
  expect(screen.props.message).toContain("undefinedThing");
});

test("syntax and import errors are reported as fatal with the file name", () => {
  boot({ "index.jsx": `import { Nope } from "./missing"; export default () => null;` });
  expect(s.errors[0].fatal).toBe(true);
  expect(s.errors[0].message).toContain('Cannot find module "./missing"');
  s.dispose();
  boot({ "index.jsx": `export default function App() { return <Row>; }` });
  expect(s.errors[0].fatal).toBe(true);
  expect(s.errors[0].message).toContain("index.jsx");
});

test("runtime errors carry branch-relative file and line", () => {
  boot({
    "index.jsx": `import { Text } from "wowser";
import { explode } from "./util/boom";
export default function App() {
  return <Text onPress={() => explode()}>x</Text>;
}`,
    "util/boom.ts": `export function explode(): never {
  const a: any = null;
  return a.b.c;
}`,
  });
  s.press(s.tree.find((n) => n.type === "text"));
  expect(s.errors.length).toBe(1);
  expect(s.errors[0].stack).toContain("util/boom.ts:3");
});

test("nested text runs, refs and commands", () => {
  boot({
    "index.jsx": `
      import { Text, TextInput, Column, useRef } from "wowser";
      export default function App() {
        const input = useRef(null);
        return <Column>
          <Text style={{ fontSize: 13 }}>Hello <Text style={{ fontWeight: "bold" }}>world</Text>!</Text>
          <TextInput ref={input} value="" />
          <Text testID="go" onPress={() => input.current.focus()}>focus</Text>
        </Column>;
      }`,
  });
  const t = s.tree.find((n) => n.type === "text");
  expect(t.props.runs).toEqual([{ text: "Hello " }, { text: "world", style: { fontWeight: "bold" } }, { text: "!" }]);
  s.press(s.tree.byTestId("go"));
  expect(s.commands).toEqual([{ nodeId: s.tree.find((n) => n.type === "textinput").id, name: "focus", args: null }]);
});

test("describeNode maps a native node back to source", () => {
  boot({
    "index.jsx": `import { Row, Text } from "wowser";
function Tab({ title }) {
  return <Row testID="tab"><Text>{title}</Text></Row>;
}
export default function App() {
  return <Tab title="hi" />;
}`,
  });
  const d = JSON.parse(s.ctx.__shell.describeNode(s.tree.byTestId("tab").id));
  expect(d.type).toBe("row");
  expect(d.file).toBe("index.jsx");
  expect(d.line).toBe(3);
  expect(d.owners.map((o) => o.component)).toEqual(["Tab", "App"]);
  expect(d.owners[0].line).toBe(6);
});

test("runaway re-renders are stopped", () => {
  boot({
    "index.jsx": `
      import { Text, useState, useEffect } from "wowser";
      export default function App() {
        const [n, setN] = useState(0);
        useEffect(() => { setN(n + 1); });
        return <Text>{n}</Text>;
      }`,
  });
  expect(s.errors.some((e) => e.message.includes("Too many re-renders"))).toBe(true);
});
