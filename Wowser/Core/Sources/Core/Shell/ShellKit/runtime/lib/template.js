// View templates: a view is `Name.xml` (what it looks like) plus, optionally,
// `Name.ts` / `Name.js` (how it behaves).
//
//   <!-- kit/TabRow.xml -->
//   <view>
//     <Pressable group height="34" cornerRadius="8" hover:background="primary/0.07"
//                onPress="tabs.select(tab.id)">
//       <TabIcon tabId="{tab.id}" size="16"/>
//       <Text flex="1" lineLimit="1">{tab.title}</Text>
//       <Icon if="{tab.isPinned}" name="pin.fill" size="9"/>
//     </Pressable>
//   </view>
//
// The template renders on its own: `{…}` bindings see the view's props,
// browser state (`$window`, `$tabs`, `$pane`, …) and the action namespaces
// (`tabs`, `panes`, …), and can keep simple state of their own
// (`onPress="open = !open"`). The logic file, when there is one, default-
// exports a function `(props) => ({ …names the template can use })`; it may
// use hooks. A view therefore shows up before its logic is written, and a
// logic file that fails to load leaves an inert view rather than an error.
//
// Everything here compiles onto the reconciler: a template element becomes
// an ordinary element, with its position in the template as its identity —
// so `if` / `for` never shuffle the state or animations of their siblings.
"use strict";
const R = require("./reconciler");
const store = require("./store");
const api = require("./api");
const index = require("./index");
const natives = require("./native");
const { parse } = require("./xml");

const host = globalThis.__host;

// ---------------------------------------------------------------- vocabulary

const HOST_TAGS = {
  Row: "row",
  Column: "column",
  View: "column",
  Stack: "stack",
  Spacer: "spacer",
  Divider: "divider",
  Icon: "icon",
  Image: "image",
  Favicon: "favicon",
  TabIcon: "tabicon",
  ScrollView: "scroll",
  TextInput: "textinput",
  WebPane: "webpane",
  WebIsland: "webisland",
  WindowControls: "windowcontrols",
  Window: "window",
};

/** Built-in components (functions, not host tags). */
const COMPONENT_TAGS = {
  Text: index.Text,
  Pressable: index.Pressable,
  Menu: index.Menu,
  Popover: index.Popover,
  Native: index.Native,
  Fragment: R.Fragment,
  ErrorBoundary: R.ErrorBoundary,
};

const STYLE_KEYS = new Set(
  (
    "width height minWidth maxWidth minHeight maxHeight flex layoutPriority aspectRatio padding margin " +
    "alignSelf offset zIndex background color opacity cornerRadius cornerStyle border shadow clip blur scale " +
    "scaleX scaleY rotate anchor hidden cursor pointerEvents animate transition fontSize fontWeight fontDesign italic " +
    "gap align justify lineLimit truncate textAlign letterSpacing lineSpacing underline strikethrough " +
    "monospacedDigits selectable placeholderColor"
  ).split(" ")
);
const VARIANTS = new Set(["hover", "pressed", "disabled", "focused", "dropTarget", "groupHover", "groupPressed", "dark"]);

/** Attributes whose literal value is always text, never a number / boolean. */
const STRING_ATTRS = new Set(
  (
    "text title placeholder tooltip label testID name src url value anchorId id tabId paneId spaceId query " +
    "hotkey message subtitle summary icon cropTo"
  ).split(" ")
);

// ---------------------------------------------------------------- expressions

const exprCache = new Map();
const handlerCache = new Map();
const reported = new Set();

function compileExpr(code) {
  let fn = exprCache.get(code);
  if (!fn) {
    // Not strict: `with` is what lets a bare name resolve through the scope.
    fn = new Function("$s", "with ($s) { return (" + code + "\n) }");
    exprCache.set(code, fn);
  }
  return fn;
}

function compileHandler(code) {
  let fn = handlerCache.get(code);
  if (!fn) {
    try {
      fn = new Function("$s", "with ($s) { return (" + code + "\n) }");
    } catch (_) {
      // Not a single expression ("a = 1; b()"): run it as statements.
      fn = new Function("$s", "with ($s) { " + code + "\n}");
    }
    handlerCache.set(code, fn);
  }
  return fn;
}

function warnOnce(key, message) {
  if (reported.has(key)) return;
  reported.add(key);
  console.warn(message);
}

/** Split "a {b} c" into literal and `{expr}` parts (brace- and string-aware). */
function splitBraces(raw) {
  const parts = [];
  let i = 0;
  let lit = "";
  const n = raw.length;
  while (i < n) {
    if (raw[i] !== "{") {
      lit += raw[i++];
      continue;
    }
    let depth = 0;
    let k = i;
    for (; k < n; k++) {
      const c = raw[k];
      if (c === "{") depth++;
      else if (c === "}") {
        if (--depth === 0) break;
      } else if (c === '"' || c === "'" || c === "`") {
        k++;
        while (k < n && raw[k] !== c) {
          if (raw[k] === "\\") k++;
          k++;
        }
      }
    }
    if (lit) parts.push({ text: lit });
    lit = "";
    parts.push({ expr: raw.slice(i + 1, k) });
    i = k + 1;
  }
  if (lit) parts.push({ text: lit });
  return parts;
}

function literal(raw, attr) {
  if (STRING_ATTRS.has(attr)) return raw;
  const t = raw.trim();
  if (t === "true") return true;
  if (t === "false") return false;
  if (t !== "" && /^-?(\d+\.?\d*|\.\d+)$/.test(t)) return Number(t);
  // "2 6" → [2, 6]: the short form of padding / margin.
  if (/^-?[\d.]+(\s+-?[\d.]+)+$/.test(t)) return t.split(/\s+/).map(Number);
  return raw;
}

/** A compiled attribute / text value: `get(scope)`. */
function compileValue(raw, attr, where) {
  if (raw === true) return { get: () => true };
  const parts = splitBraces(String(raw));
  if (parts.length === 0) return { get: () => (STRING_ATTRS.has(attr) ? "" : literal("", attr)) };
  if (parts.length === 1 && parts[0].text != null) {
    const v = literal(parts[0].text, attr);
    return { get: () => v };
  }
  const evalPart = (code) => {
    let fn = null;
    let broken = null;
    try {
      fn = compileExpr(code);
    } catch (e) {
      broken = e;
    }
    return (scope) => {
      if (broken) {
        warnOnce(where + code, `${where}: {${code}} is not a valid expression: ${broken.message}`);
        return undefined;
      }
      try {
        return fn(scope);
      } catch (e) {
        // A binding that can't be evaluated yet (its data hasn't arrived, its
        // logic isn't written) renders as nothing rather than failing the view.
        warnOnce(where + code + e.message, `${where}: {${code}} → ${e.message}`);
        return undefined;
      }
    };
  };
  if (parts.length === 1) return { get: evalPart(parts[0].expr) };
  const fns = parts.map((p) => (p.text != null ? () => p.text : evalPart(p.expr)));
  return {
    get(scope) {
      let s = "";
      for (let i = 0; i < fns.length; i++) {
        const v = fns[i](scope);
        if (v != null && v !== false) s += v;
      }
      return s;
    },
  };
}

/** `{expr}` or bare `expr`, for attributes that are always code (if, for…). */
function codeOf(raw) {
  const s = String(raw).trim();
  const parts = splitBraces(s);
  return parts.length === 1 && parts[0].expr != null ? parts[0].expr : s;
}

// ---------------------------------------------------------------- scope

const STATE = {
  $window: (t) => t.read("window"),
  $spaces: (t) => t.read("spaces") || [],
  $space: (t) => {
    const w = t.read("window");
    return (t.read("spaces") || []).find((s) => w && s.id === w.spaceId) || null;
  },
  $tabs: (t) => t.read("tabs") || { pinned: [], tabs: [], currentTabId: null },
  $tab: (t) => {
    const w = t.read("window");
    return w && w.currentTabId ? t.read("tab", { id: w.currentTabId }) : null;
  },
  $pane: (t) => {
    const w = t.read("window");
    return w && w.focusedPaneId ? t.read("pane", { id: w.focusedPaneId }) : null;
  },
  $theme: (t) => t.read("theme") || { scheme: "light", accent: "#0a84ff", onAccent: "#ffffff" },
  $toasts: (t) => t.read("toasts") || [],
  $mouse: (t) => t.read("mouse") || { x: 0, y: 0, inside: false },
  $screen: (t) => t.read("screen") || { width: 0, height: 0 },
  $tabById: (t) => (id) => (id ? t.read("tab", { id }) : null),
  $paneById: (t) => (id) => (id ? t.read("pane", { id }) : null),
  $tabsOf: (t) => (space) => t.read("tabs", { space }) || { pinned: [], tabs: [], currentTabId: null },
  $setting: (t) => (key) => t.read("setting", { key }),
  $storage: (t) => (key, fallback) => {
    const v = t.read("storage", { key });
    return v == null ? fallback : v;
  },
};

const ACTIONS = ["tabs", "panes", "spaces", "folders", "window", "commandBar", "search", "toasts", "settings", "storage", "clipboard", "commands", "menus", "shell", "haptics", "mouse", "call", "browser"];

/** What a view instance shares across the scopes of one render. */
function createScope(base, locals) {
  return new Proxy(Object.create(null), {
    has(_, key) {
      return typeof key === "string";
    },
    get(_, key) {
      if (typeof key !== "string") return undefined;
      if (locals && key in locals) return locals[key];
      if (key === "event") return base.event;
      if (base.logic && key in base.logic) return base.logic[key];
      if (key in base.state) return base.state[key];
      if (key === "props") return base.props;
      if (key in base.props) return base.props[key];
      if (base.imports && base.imports.has(key)) return base.imports.get(key)();
      if (key.charCodeAt(0) === 36 /* $ */ && Object.prototype.hasOwnProperty.call(STATE, key)) return STATE[key](base.tracker);
      if (ACTIONS.indexOf(key) >= 0) return api[key];
      return globalThis[key];
    },
    set(_, key, value) {
      if (typeof key !== "string") return true;
      if (locals && key in locals) {
        locals[key] = value;
        return true;
      }
      if (base.logic && key in base.logic) {
        // Logic owns this name; assign through its setter if it offers one.
        const setter = base.logic["set" + key[0].toUpperCase() + key.slice(1)];
        if (typeof setter === "function") setter(value);
        else warnOnce(base.file + key, `${base.file}: "${key}" comes from the logic file and has no set${key[0].toUpperCase() + key.slice(1)}(); assignment ignored.`);
        return true;
      }
      // Template state. Visible immediately to the rest of this handler,
      // rendered on the next pass.
      base.state[key] = value;
      base.patch({ [key]: value });
      return true;
    },
  });
}

/** Tracks which slices a render read, and re-renders when one changes. */
function useTracker() {
  const [, force] = R.useReducer((n) => n + 1, 0);
  const ref = R.useRef(null);
  if (!ref.current) {
    const t = { used: new Set(), subs: new Map() };
    t.read = (name, arg) => {
      const key = store.keyFor(name, arg);
      t.used.add(key);
      return store.readKey(key);
    };
    ref.current = t;
  }
  const t = ref.current;
  t.used = new Set();
  R.useEffect(() => {
    t.used.forEach((key) => {
      if (!t.subs.has(key)) t.subs.set(key, store.listen(key, force));
    });
    t.subs.forEach((off, key) => {
      if (!t.used.has(key)) {
        off();
        t.subs.delete(key);
      }
    });
  });
  R.useEffect(
    () => () => {
      t.subs.forEach((off) => off());
      t.subs.clear();
    },
    []
  );
  return t;
}

// ---------------------------------------------------------------- compiling

const FOR = /^\s*(?:\(\s*([\w$]+)\s*(?:,\s*([\w$]+))?\s*\)|([\w$]+))\s+(?:in|of)\s+([\s\S]+)$/;

function setPath(target, path, value) {
  let o = target;
  for (let i = 0; i < path.length - 1; i++) {
    const k = path[i];
    // "padding.left" after "padding='4'" would be a conflict; last one wins.
    if (o[k] == null || typeof o[k] !== "object" || Array.isArray(o[k])) o[k] = {};
    o = o[k];
  }
  o[path[path.length - 1]] = value;
}

function compileNode(node, view) {
  if (node.$c) return node.$c;
  const where = `${view.file}:${node.line}`;
  const c = {
    setters: [],
    events: [],
    key: null,
    cond: null,
    elseIf: null,
    isElse: false,
    loop: null,
    slot: null,
    ref: null,
    bind: null,
    kind: null, // "host" | "component" | "view" | special
    type: null,
    styled: true,
  };
  const tag = node.tag;
  if (Object.prototype.hasOwnProperty.call(HOST_TAGS, tag)) {
    c.kind = "host";
    c.type = HOST_TAGS[tag];
    // A window's width / height / x / y / anchor describe the native window,
    // not a box in the layout: they stay plain props.
    if (tag === "Window") c.styled = false;
  } else if (Object.prototype.hasOwnProperty.call(COMPONENT_TAGS, tag)) {
    c.kind = "component";
    c.type = COMPONENT_TAGS[tag];
  } else if (tag.startsWith("native:")) {
    c.kind = "component";
    c.type = natives.native(tag.slice("native:".length));
  } else if (tag === "children" || tag === "slot") {
    c.kind = "slot";
  } else if (tag === "import" || tag === "contextMenu" || tag === "items") {
    c.kind = tag;
  } else {
    c.kind = "view";
    c.styled = false; // a view's attributes are its props, verbatim
  }

  for (const a of node.attrs) {
    const name = a.name;
    const raw = a.value;
    if (name === "if") c.cond = compileValue("{" + codeOf(raw) + "}", name, where);
    else if (name === "else-if" || name === "elseif") c.elseIf = compileValue("{" + codeOf(raw) + "}", name, where);
    else if (name === "else") c.isElse = true;
    else if (name === "for") {
      const m = FOR.exec(codeOf(raw));
      if (!m) warnOnce(where + "for", `${where}: for="${raw}" should look like "item in list" or "(item, index) in list"`);
      else c.loop = { item: m[1] || m[3], index: m[2] || null, list: compileValue("{" + m[4] + "}", name, where) };
    } else if (name === "key") c.key = compileValue(raw, "key", where);
    else if (name === "slot" && c.kind !== "slot") c.slot = String(raw);
    else if (name === "ref") c.ref = compileValue("{" + codeOf(raw) + "}", name, where);
    else if (name === "bind") c.bind = compileValue("{" + codeOf(raw) + "}", name, where);
    else if (/^on[A-Z]/.test(name)) {
      const code = codeOf(raw);
      try {
        c.events.push([name, compileHandler(code), code]);
      } catch (e) {
        warnOnce(where + name, `${where}: ${name}="${code}" is not valid JavaScript: ${e.message}`);
      }
    } else {
      const path = name.split(".");
      let variant = null;
      const colon = path[0].indexOf(":");
      if (colon > 0 && VARIANTS.has(path[0].slice(0, colon))) {
        variant = path[0].slice(0, colon);
        path[0] = path[0].slice(colon + 1);
      }
      const leaf = path[path.length - 1];
      let full = path;
      if (variant) full = ["style", variant].concat(path);
      else if (c.styled && STYLE_KEYS.has(path[0])) full = ["style"].concat(path);
      c.setters.push({ path: full, value: compileValue(raw, leaf, where), spread: name === "style" });
    }
  }
  node.$c = c;
  return c;
}

/** JSX-style whitespace: line breaks and the indentation around them vanish. */
function cleanText(raw) {
  if (raw.indexOf("\n") < 0) return raw;
  const lines = raw.split("\n");
  const out = [];
  for (let i = 0; i < lines.length; i++) {
    let l = lines[i];
    if (i > 0) l = l.replace(/^\s+/, "");
    if (i < lines.length - 1) l = l.replace(/\s+$/, "");
    if (l) out.push(l);
  }
  return out.join(" ");
}

function runHandler(fn, base, locals, args) {
  const previous = base.event;
  base.event = args[0];
  try {
    let out = fn(createScope(base, locals));
    // `onPress="{close}"` and `onPress="close"` name a function: call it
    // with whatever the event carries.
    if (typeof out === "function") out = out.apply(null, args);
    return out;
  } finally {
    base.event = previous;
  }
}

function buildProps(node, c, scope, base, locals, view) {
  const props = {};
  if (c.bind) {
    const spread = c.bind.get(scope);
    if (spread && typeof spread === "object") Object.assign(props, spread);
  }
  for (let i = 0; i < c.setters.length; i++) {
    const s = c.setters[i];
    const value = s.value.get(scope);
    if (s.spread) {
      if (value && typeof value === "object") props.style = Object.assign({}, props.style, value);
    } else if (value !== undefined) {
      setPath(props, s.path, value);
    }
  }
  for (let i = 0; i < c.events.length; i++) {
    const [name, fn] = c.events[i];
    props[name] = (...args) => runHandler(fn, base, locals, args);
  }
  if (c.ref) props.ref = c.ref.get(scope);
  return props;
}

/** Menu entries from <item> / <separator/> / <menu> children. */
function menuEntries(nodes, scope, base, locals, view) {
  const out = [];
  walk(nodes, scope, base, locals, view, (node, c, s, l) => {
    if (node.tag === "separator") {
      out.push("-");
      return;
    }
    const props = buildProps(node, c, s, base, l, view);
    const entry = { title: props.title == null ? "" : String(props.title) };
    for (const k of ["icon", "checked", "disabled", "destructive", "id"]) if (props[k] != null && props[k] !== false) entry[k] = props[k];
    if (props.onSelect) entry.onSelect = () => props.onSelect();
    if (node.tag === "menu") entry.children = menuEntries(node.children, s, base, l, view);
    out.push(entry);
  });
  return out;
}

/** Run `visit` for each element that survives `if` / `for`, in order. */
function walk(nodes, scope, base, locals, view, visit, onText) {
  let chain; // undefined: no if-chain · false: none taken yet · true: one taken
  for (let i = 0; i < nodes.length; i++) {
    const node = nodes[i];
    if (node.type === "text") {
      if (onText) onText(node, scope, i);
      continue;
    }
    const c = compileNode(node, view);
    const each = (s, l, keyPrefix) => {
      if (c.cond) {
        chain = !!c.cond.get(s);
        if (!chain) return;
      } else if (c.elseIf) {
        if (chain !== false) return;
        chain = !!c.elseIf.get(s);
        if (!chain) return;
      } else if (c.isElse) {
        if (chain !== false) return;
        chain = true;
      } else {
        chain = undefined;
      }
      visit(node, c, s, l, i, keyPrefix);
    };
    if (c.loop) {
      const list = c.loop.list.get(scope);
      const items = list == null ? [] : Array.isArray(list) ? list : typeof list === "number" ? Array.from({ length: list }, (_, k) => k) : Array.from(list);
      for (let k = 0; k < items.length; k++) {
        const l = Object.assign({}, locals);
        l[c.loop.item] = items[k];
        if (c.loop.index) l[c.loop.index] = k;
        each(createScope(base, l), l, k);
      }
    } else {
      each(scope, locals, null);
    }
  }
}

function renderChildren(nodes, scope, base, locals, view) {
  const out = [];
  // Loops gather under one keyed fragment so the rows' keys can't collide
  // with their siblings' positions.
  const loops = new Map();
  walk(
    nodes,
    scope,
    base,
    locals,
    view,
    (node, c, s, l, position, loopIndex) => {
      if (c.kind === "import" || c.kind === "contextMenu" || c.kind === "items") return;
      const el = renderElement(node, c, s, base, l, view, position, loopIndex);
      if (el == null) return;
      if (loopIndex == null) {
        out.push(el);
        return;
      }
      let group = loops.get(position);
      if (!group) {
        group = [];
        loops.set(position, group);
        out.push({ $$shell: true, type: R.Fragment, props: { children: group }, key: "#" + position, src: null });
      }
      group.push(el);
    },
    (node, s) => {
      if (node.raw) {
        out.push(node.value);
        return;
      }
      if (!node.$v) node.$v = compileValue(cleanText(node.value), "text", `${view.file}:${node.line}`);
      const text = node.$v.get(s);
      if (text !== "" && text != null && text !== false) out.push(String(text));
    }
  );
  return out;
}

function renderElement(node, c, scope, base, locals, view, position, loopIndex) {
  if (c.kind === "slot") {
    const nameAttr = node.attrs.find((a) => a.name === "name");
    const content = nameAttr ? base.props[nameAttr.value] : base.props.children;
    // Fallback content between the tags shows when nothing was passed.
    if (content == null || (Array.isArray(content) && content.length === 0)) {
      return node.children.length ? { $$shell: true, type: R.Fragment, props: { children: renderChildren(node.children, scope, base, locals, view) }, key: "#" + position, src: null } : null;
    }
    return { $$shell: true, type: R.Fragment, props: { children: content }, key: "#" + position, src: null };
  }

  const props = buildProps(node, c, scope, base, locals, view);
  let type = c.type;
  if (c.kind === "view") {
    type = view.resolve(node.tag);
    if (!type) return missingView(node, view, position);
  }

  // Children: structural ones (<contextMenu>, <items>) become props; with a
  // `slot` attribute they become a named prop; the rest are children.
  let kids = node.children;
  let hasSpecial = false;
  for (let i = 0; i < kids.length; i++) {
    const k = kids[i];
    if (k.type === "el" && (k.tag === "contextMenu" || k.tag === "items" || k.attrs.some((a) => a.name === "slot"))) {
      hasSpecial = true;
      break;
    }
  }
  if (hasSpecial) {
    const rest = [];
    const slots = {};
    for (const k of kids) {
      if (k.type === "el" && k.tag === "contextMenu") {
        // Entries written out as <item> children, or computed: items="{…}".
        const given = k.attrs.find((a) => a.name === "items");
        const entries = given ? compileValue(given.value, "items", `${view.file}:${k.line}`).get(scope) : menuEntries(k.children, scope, base, locals, view);
        const [data, run] = api.menus.compile(entries || []);
        props.contextMenu = data;
        props.onContextMenuSelect = run;
      } else if (k.type === "el" && k.tag === "items") {
        props.items = menuEntries(k.children, scope, base, locals, view);
      } else if (k.type === "el" && c.kind !== "host" && k.attrs.some((a) => a.name === "slot")) {
        const name = k.attrs.find((a) => a.name === "slot").value;
        (slots[name] = slots[name] || []).push(k);
      } else rest.push(k);
    }
    for (const name in slots) props[name] = renderChildren(slots[name], scope, base, locals, view);
    kids = rest;
  }
  if (kids.length) {
    const rendered = renderChildren(kids, scope, base, locals, view);
    if (rendered.length === 1) props.children = rendered[0];
    else if (rendered.length > 1) props.children = rendered;
  }

  let key;
  if (c.key) key = String(c.key.get(scope));
  else key = loopIndex != null ? String(loopIndex) : "#" + position;
  return { $$shell: true, type, props, key, src: { fileName: view.file, lineNumber: node.line } };
}

/** A tag that doesn't resolve to anything yet: show where it will go. */
function missingView(node, view, position) {
  warnOnce(view.file + "<" + node.tag, `${view.file}:${node.line}: no view or component named <${node.tag}> (yet).`);
  return {
    $$shell: true,
    type: "row",
    key: "#" + position,
    src: { fileName: view.file, lineNumber: node.line },
    props: {
      style: { padding: [4, 8], cornerRadius: 6, border: { color: "primary/0.25", width: 1 }, align: "center", justify: "center" },
      tooltip: `<${node.tag}> isn't defined yet`,
      children: { $$shell: true, type: "text", key: null, src: null, props: { text: node.tag, style: { fontSize: 10, color: "secondary" } } },
    },
  };
}

// ---------------------------------------------------------------- views

let branchFiles = null;
function filesByName() {
  if (branchFiles) return branchFiles;
  branchFiles = new Map();
  let list = [];
  try {
    list = api.call("shell.files") || [];
  } catch (_) {}
  for (const path of list) {
    const m = /(^|\/)([A-Z][\w$]*)\.(xml|tsx|ts|jsx|js)$/.exec(path);
    if (!m) continue;
    const name = m[2];
    const noExt = path.replace(/\.(xml|tsx|ts|jsx|js)$/, "");
    const have = branchFiles.get(name) || [];
    if (have.indexOf(noExt) < 0) have.push(noExt);
    branchFiles.set(name, have);
  }
  return branchFiles;
}

function dirname(p) {
  const i = p.lastIndexOf("/");
  return i < 0 ? "" : p.slice(0, i);
}

function componentFrom(mod, name) {
  if (!mod) return null;
  const c = mod[name] || mod.default;
  return typeof c === "function" || (c && c.$$kind) ? c : null;
}

/**
 * Turn `Name.xml` (+ optional sibling logic module) into a component module.
 * `req(spec)` requires relative to the template file.
 */
function loadView(file, source, req) {
  const name = file.replace(/^.*\//, "").replace(/\.xml$/, "");
  const parsed = parse(source);
  for (const p of parsed.problems) console.warn(`${file}:${p.line}: ${p.message}`);

  const rootEl = parsed.children.find((n) => n.type === "el" && n.tag === "view");
  const content = rootEl ? rootEl.children : parsed.children;
  const stateAttr = rootEl && rootEl.attrs.find((a) => a.name === "state");
  // state="{ open: false }" — the braces here are the object literal itself
  // (state="{{ open: false }}" works too).
  let initialState = null;
  if (stateAttr) {
    const raw = String(stateAttr.value).trim();
    initialState = compileValue("{" + (raw.startsWith("{{") ? codeOf(raw) : raw) + "}", "state", file);
  }

  // The logic file is optional, and a broken one must not take the view down.
  let logicModule = null;
  const base = file.slice(0, -4);
  for (const ext of [".ts", ".js", ".tsx", ".jsx"]) {
    if (!host.resolveModule(base + ext)) continue;
    try {
      logicModule = req("./" + name + ext);
    } catch (e) {
      console.error(`${base + ext} failed to load, so ${name} is showing without its logic: ${e && e.message ? e.message : e}`);
      host.reportError(
        JSON.stringify({ message: String(e && e.message ? e.message : e), stack: (e && e.stack) || "", componentStack: [name + " (" + base + ext + ")"], fatal: false, rootKey: null })
      );
    }
    break;
  }
  const logic = logicModule && typeof logicModule.default === "function" ? logicModule.default : null;

  const imports = new Map();
  for (const n of content) {
    if (n.type !== "el" || n.tag !== "import") continue;
    const as = n.attrs.find((a) => a.name === "name");
    const from = n.attrs.find((a) => a.name === "from");
    if (as && from) imports.set(String(as.value), String(from.value));
  }

  // An import is a view to use as a tag, or any module to use as a value:
  //   <import name="theme" from="./theme"/>  →  {theme.HEADER_HEIGHT}
  const importValues = new Map();
  imports.forEach((from, as) => {
    let loaded;
    importValues.set(as, () => {
      if (loaded === undefined) {
        try {
          const mod = req(from);
          loaded = mod && mod.__esModule && Object.keys(mod).length === 1 && "default" in mod ? mod.default : mod;
        } catch (e) {
          console.error(`${file}: import "${from}" failed: ${e && e.message ? e.message : e}`);
          loaded = null;
        }
      }
      return loaded;
    });
  });

  const resolved = new Map();
  const view = {
    file,
    resolve(tag) {
      if (resolved.has(tag)) return resolved.get(tag);
      let component = null;
      const tryRequire = (spec) => {
        try {
          return componentFrom(req(spec), tag);
        } catch (e) {
          console.error(`${file}: <${tag}> failed to load from "${spec}": ${e && e.message ? e.message : e}`);
          return null;
        }
      };
      const dir = dirname(file);
      if (imports.has(tag)) component = tryRequire(imports.get(tag));
      else if (host.resolveModule((dir ? dir + "/" : "") + tag)) component = tryRequire("./" + tag);
      else {
        // Anywhere in the branch, by file name; kit/ wins a tie.
        const candidates = (filesByName().get(tag) || []).slice().sort((a, b) => (b.startsWith("kit/") ? 1 : 0) - (a.startsWith("kit/") ? 1 : 0) || a.localeCompare(b));
        if (candidates.length > 1) warnOnce(file + tag + "ambiguous", `${file}: <${tag}> matches ${candidates.join(", ")}; using ${candidates[0]}. Add <import name="${tag}" from="…"/> to choose.`);
        if (candidates.length) component = tryRequire("/" + candidates[0]);
      }
      // Don't cache a miss: the file may appear on the next reload.
      if (component) resolved.set(tag, component);
      return component;
    },
  };

  function View(props) {
    const tracker = useTracker();
    const [state, patch] = R.useReducer(
      (s, p) => Object.assign({}, s, p),
      null,
      () => {
        if (!initialState) return {};
        const seed = { tracker, logic: null, state: {}, props, patch() {}, file, event: undefined, imports: importValues };
        const v = initialState.get(createScope(seed, null));
        return v && typeof v === "object" ? Object.assign({}, v) : {};
      }
    );
    const scopeOfLogic = logic ? logic(props) || null : null;
    // `state` is copied so a handler's assignments read back within the handler.
    const baseScope = { tracker, logic: scopeOfLogic, state: Object.assign({}, state), props, patch, file, event: undefined, imports: importValues };
    return renderChildren(content, createScope(baseScope, null), baseScope, null, view);
  }
  View.displayName = name;
  const component = R.memo(View);

  const exports = { __esModule: true, default: component };
  if (logicModule) for (const k in logicModule) if (k !== "default") exports[k] = logicModule[k];
  exports[name] = component;
  return exports;
}

/** Compile a template from a string (tests, `shell eval`, streaming previews). */
function viewFromString(source, name) {
  return loadView((name || "Inline") + ".xml", source, () => {
    throw new Error("inline templates can't import files");
  }).default;
}

module.exports = { loadView, viewFromString, parse, splitBraces, HOST_TAGS, STYLE_KEYS };
