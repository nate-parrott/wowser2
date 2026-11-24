// Shell reconciler — a small React-shaped renderer that targets the native
// node tree instead of the DOM.
//
// It runs inside JavaScriptCore (the app) and under bun/node (tests + the DOM
// simulator in scripts/shell). It knows nothing about the browser: it turns
// elements into a stream of host ops (`create` / `update` / `children` /
// `remove`) and routes native events back to the handlers in the latest props.
//
// Deliberately small: function components, hooks, keys, fragments, context,
// memo and error boundaries. No concurrent rendering, no suspense, no classes.
"use strict";

const FRAGMENT = Symbol.for("shell.fragment");
const BOUNDARY = Symbol.for("shell.boundary");
const PROVIDER = Symbol.for("shell.provider");
const MEMO = Symbol.for("shell.memo");

let host = null; // { commit(ops), reportError(info) }
let nextNodeId = 1;
let nextCtxId = 1;
let uidCounter = 0;

const instancesByNodeId = new Map();
const roots = new Map(); // rootKey -> root instance

let ops = [];
let dirty = new Set(); // component instances needing re-render
let dirtyHostParents = new Set(); // host/root instances whose child list changed
let pendingEffects = []; // [{inst, cell}]
let flushScheduled = false;
let flushing = false;
let current = null; // instance being rendered
let hookIndex = 0;

function setHost(h) {
  host = h;
}

// ---------------------------------------------------------------- elements

function h(type, props, ...children) {
  const p = {};
  let key = null;
  let src = null;
  if (props) {
    for (const k in props) {
      if (k === "key") key = props[k] == null ? null : String(props[k]);
      else if (k === "__source") src = props[k];
      else if (k === "__self") continue;
      else p[k] = props[k];
    }
  }
  if (children.length === 1) p.children = children[0];
  else if (children.length > 1) p.children = children;
  return { $$shell: true, type, props: p, key, src };
}

// Automatic JSX runtime entry points (`jsx`, `jsxs`, `jsxDEV`).
function jsx(type, props, key, _isStatic, source) {
  const p = {};
  if (props) for (const k in props) if (k !== "key") p[k] = props[k];
  let k = key;
  if (k === undefined && props && props.key !== undefined) k = props.key;
  return { $$shell: true, type, props: p, key: k == null ? null : String(k), src: source || null };
}

function isElement(x) {
  return x != null && typeof x === "object" && x.$$shell === true;
}

/** Flatten a children value into an array of elements. Strings and numbers
 *  become `text` host elements; null / undefined / booleans vanish. */
function normalize(children, out) {
  out = out || [];
  if (children == null || typeof children === "boolean") return out;
  if (Array.isArray(children)) {
    for (let i = 0; i < children.length; i++) normalize(children[i], out);
    return out;
  }
  if (typeof children === "string" || typeof children === "number") {
    out.push({ $$shell: true, type: "text", props: { text: String(children) }, key: null, src: null });
    return out;
  }
  if (isElement(children)) {
    out.push(children);
    return out;
  }
  throw new Error(
    "Objects are not valid as a child (got " +
      (typeof children === "function" ? "a function" : describeValue(children)) +
      "). Render an element, a string, or an array."
  );
}

function describeValue(v) {
  try {
    const s = JSON.stringify(v);
    return s && s.length > 80 ? s.slice(0, 80) + "…" : s;
  } catch (_) {
    return String(v);
  }
}

function typeName(type) {
  if (typeof type === "string") return type;
  if (type === FRAGMENT) return "Fragment";
  if (type === BOUNDARY) return "ErrorBoundary";
  if (type && type.$$kind === PROVIDER) return "Context.Provider";
  if (type && type.$$kind === MEMO) return typeName(type.inner);
  if (typeof type === "function") return type.displayName || type.name || "Anonymous";
  return String(type);
}

// ---------------------------------------------------------------- equality

function deepEqual(a, b) {
  if (Object.is(a, b)) return true;
  if (typeof a !== "object" || typeof b !== "object" || a === null || b === null) return false;
  const aa = Array.isArray(a);
  if (aa !== Array.isArray(b)) return false;
  if (aa) {
    if (a.length !== b.length) return false;
    for (let i = 0; i < a.length; i++) if (!deepEqual(a[i], b[i])) return false;
    return true;
  }
  if (isElement(a) || isElement(b)) return false;
  const ka = Object.keys(a);
  if (ka.length !== Object.keys(b).length) return false;
  for (let i = 0; i < ka.length; i++) {
    const k = ka[i];
    if (!Object.prototype.hasOwnProperty.call(b, k) || !deepEqual(a[k], b[k])) return false;
  }
  return true;
}

function shallowEqual(a, b) {
  if (a === b) return true;
  const ka = Object.keys(a);
  if (ka.length !== Object.keys(b).length) return false;
  for (let i = 0; i < ka.length; i++) {
    const k = ka[i];
    if (!Object.prototype.hasOwnProperty.call(b, k) || !Object.is(a[k], b[k])) return false;
  }
  return true;
}

/** Default `memo` comparison: shallow, except plain data (objects / arrays of
 *  JSON-ish values, e.g. a tab snapshot or a style object) compares
 *  structurally. Store slices hand out fresh objects on every change, so
 *  identity comparison would defeat memo for every row of a list. */
function propsEqual(a, b) {
  if (a === b) return true;
  const ka = Object.keys(a);
  if (ka.length !== Object.keys(b).length) return false;
  for (let i = 0; i < ka.length; i++) {
    const k = ka[i];
    if (!Object.prototype.hasOwnProperty.call(b, k)) return false;
    const x = a[k];
    const y = b[k];
    if (Object.is(x, y)) continue;
    if (typeof x === "function" || typeof y === "function") return false;
    if (k === "children") return false;
    if (!deepEqual(x, y)) return false;
  }
  return true;
}

// ---------------------------------------------------------------- host props

/** Props as the native side sees them: no children, no refs, and functions
 *  replaced by `true` (the handler itself stays in JS; native only needs to
 *  know that one is attached). */
function sanitizeProps(props) {
  const out = {};
  for (const k in props) {
    if (k === "children" || k === "ref") continue;
    const v = props[k];
    if (v === undefined) continue;
    out[k] = typeof v === "function" ? true : v;
  }
  return out;
}

function diffHostProps(prev, next) {
  let changed = null;
  for (const k in next) {
    if (!deepEqual(prev[k], next[k])) {
      (changed = changed || {})[k] = next[k];
    }
  }
  for (const k in prev) {
    if (!(k in next)) (changed = changed || {})[k] = null;
  }
  return changed;
}

// ---------------------------------------------------------------- instances

function kindOf(type) {
  if (typeof type === "string") return "host";
  if (type === FRAGMENT) return "frag";
  if (type === BOUNDARY) return "boundary";
  if (type && type.$$kind === PROVIDER) return "provider";
  if (type && type.$$kind === MEMO) return "comp";
  if (typeof type === "function") return "comp";
  throw new Error(
    "Invalid element type: " +
      (type === undefined ? "undefined (did you forget to export or import a component?)" : describeValue(type))
  );
}

function createInstance(el, parent) {
  return {
    kind: kindOf(el.type),
    type: el.type,
    key: el.key,
    el,
    parent,
    depth: parent ? parent.depth + 1 : 0,
    children: [],
    mounted: true,
    // host
    nodeId: 0,
    hostProps: null,
    // comp
    hooks: null,
    dirty: false,
    // provider
    subscribers: null,
    // boundary
    error: null,
  };
}

function mount(el, parent) {
  const inst = createInstance(el, parent);
  try {
    switch (inst.kind) {
      case "host": {
        inst.nodeId = nextNodeId++;
        inst.hostProps = sanitizeProps(el.props);
        instancesByNodeId.set(inst.nodeId, inst);
        ops.push(["create", inst.nodeId, el.type, inst.hostProps]);
        attachRef(inst, el.props.ref);
        mountChildren(inst, normalize(el.props.children));
        const ids = hostChildIds(inst);
        if (ids.length) ops.push(["children", inst.nodeId, ids]);
        break;
      }
      case "comp":
        inst.hooks = [];
        mountChildren(inst, normalize(renderComponent(inst)));
        break;
      case "provider":
        inst.subscribers = new Set();
        mountChildren(inst, normalize(el.props.children));
        break;
      case "boundary":
        mountBoundary(inst);
        break;
      default:
        mountChildren(inst, normalize(el.props.children));
    }
  } catch (e) {
    // Never leave a half-mounted subtree behind: effects registered so far
    // and native nodes created so far must go.
    unmount(inst, true);
    throw e;
  }
  return inst;
}

function mountChildren(inst, els) {
  for (let i = 0; i < els.length; i++) inst.children.push(mount(els[i], inst));
}

function mountBoundary(inst) {
  try {
    mountChildren(inst, normalize(inst.el.props.children));
  } catch (e) {
    catchInBoundary(inst, e);
  }
}

function catchInBoundary(inst, error) {
  inst.error = error;
  reportError(error, inst, false);
  const old = inst.children;
  inst.children = [];
  for (let i = 0; i < old.length; i++) unmount(old[i], true);
  const fallback = inst.el.props.fallback;
  let els = [];
  try {
    const reset = () => {
      inst.error = null;
      markDirty(inst);
    };
    els = normalize(typeof fallback === "function" ? fallback(error, reset) : fallback);
    mountChildren(inst, els);
  } catch (e2) {
    // A broken fallback must not take the boundary's parent down with it.
    reportError(e2, inst, false);
    const partial = inst.children;
    inst.children = [];
    for (let i = 0; i < partial.length; i++) unmount(partial[i], true);
  }
  markHostChildrenDirty(inst);
}

function unmount(inst, removeHost) {
  if (!inst.mounted) return;
  inst.mounted = false;
  dirty.delete(inst);
  if (inst.kind === "host") {
    attachRef(inst, null, inst.el.props.ref);
    instancesByNodeId.delete(inst.nodeId);
    // Only the topmost host node of a removed subtree needs an explicit
    // remove; native drops its descendants with it.
    if (removeHost) ops.push(["remove", inst.nodeId]);
    removeHost = false;
  } else if (inst.kind === "comp" && inst.hooks) {
    for (let i = inst.hooks.length - 1; i >= 0; i--) {
      const cell = inst.hooks[i];
      if (cell && cell.tag === "effect") {
        cell.dead = true;
        runCleanup(cell, inst);
      } else if (cell && cell.tag === "context" && cell.provider) {
        cell.provider.subscribers.delete(inst);
      }
    }
  }
  for (let i = 0; i < inst.children.length; i++) unmount(inst.children[i], removeHost);
}

function update(inst, el) {
  const prevEl = inst.el;
  inst.el = el;
  switch (inst.kind) {
    case "host": {
      const next = sanitizeProps(el.props);
      const changed = diffHostProps(inst.hostProps, next);
      if (changed) {
        inst.hostProps = next;
        ops.push(["update", inst.nodeId, changed]);
      }
      if (prevEl.props.ref !== el.props.ref) attachRef(inst, el.props.ref, prevEl.props.ref);
      reconcileChildren(inst, normalize(el.props.children));
      break;
    }
    case "comp": {
      const t = inst.type;
      if (!inst.dirty && t.$$kind === MEMO && (t.compare || propsEqual)(prevEl.props, el.props)) return;
      reconcileChildren(inst, normalize(renderComponent(inst)));
      break;
    }
    case "provider": {
      if (!Object.is(prevEl.props.value, el.props.value)) {
        inst.subscribers.forEach((s) => markDirty(s));
      }
      reconcileChildren(inst, normalize(el.props.children));
      break;
    }
    case "boundary":
      updateBoundary(inst);
      break;
    default:
      reconcileChildren(inst, normalize(el.props.children));
  }
}

function updateBoundary(inst) {
  inst.dirty = false;
  dirty.delete(inst);
  if (inst.error) {
    // Still showing the fallback; it only goes away through reset().
    return;
  }
  try {
    reconcileChildren(inst, normalize(inst.el.props.children));
  } catch (e) {
    catchInBoundary(inst, e);
  }
}

function sameType(inst, el) {
  return inst.type === el.type;
}

/** Keyed child reconciliation. Children with an explicit key match by key;
 *  the rest match by position among unkeyed siblings of the same type. */
function reconcileChildren(parent, els) {
  const old = parent.children;
  let keyed = null;
  for (let i = 0; i < old.length; i++) {
    if (old[i].key != null) (keyed = keyed || new Map()).set(old[i].key, old[i]);
  }
  const next = [];
  const used = new Set();
  let structureChanged = old.length !== els.length;
  try {
    for (let i = 0; i < els.length; i++) {
      const el = els[i];
      let match = null;
      if (el.key != null) {
        const c = keyed && keyed.get(el.key);
        if (c && !used.has(c) && sameType(c, el)) match = c;
      } else {
        const c = old[i];
        if (c && c.key == null && !used.has(c) && sameType(c, el)) match = c;
      }
      if (match) {
        used.add(match);
        next.push(match);
        if (old[i] !== match) structureChanged = true;
        if (match.el !== el || match.dirty) update(match, el);
      } else {
        structureChanged = true;
        next.push(mount(el, parent));
      }
    }
  } catch (e) {
    // Keep every still-mounted instance reachable so a boundary further up
    // can tear the subtree down cleanly.
    for (let i = 0; i < old.length; i++) if (!used.has(old[i])) next.push(old[i]);
    parent.children = next;
    throw e;
  }
  for (let i = 0; i < old.length; i++) {
    if (!used.has(old[i])) {
      structureChanged = true;
      unmount(old[i], true);
    }
  }
  parent.children = next;
  if (structureChanged) markHostChildrenDirty(parent);
}

function hostChildIds(inst, out) {
  out = out || [];
  for (let i = 0; i < inst.children.length; i++) {
    const c = inst.children[i];
    if (c.kind === "host") out.push(c.nodeId);
    else hostChildIds(c, out);
  }
  return out;
}

function markHostChildrenDirty(inst) {
  let p = inst;
  while (p && p.kind !== "host") p = p.parent;
  if (p) dirtyHostParents.add(p);
}

// ---------------------------------------------------------------- components

function renderComponent(inst) {
  const type = inst.type.$$kind === MEMO ? inst.type.inner : inst.type;
  const prev = current;
  const prevIdx = hookIndex;
  current = inst;
  hookIndex = 0;
  inst.dirty = false;
  dirty.delete(inst);
  try {
    const out = type(inst.el.props);
    if (inst.hookCount !== undefined && inst.hookCount !== hookIndex) {
      throw new Error(
        typeName(inst.type) +
          " called a different number of hooks than on its previous render (" +
          inst.hookCount +
          " → " +
          hookIndex +
          "). Hooks must not be called conditionally."
      );
    }
    inst.hookCount = hookIndex;
    return out;
  } catch (e) {
    if (e && typeof e === "object" && !e.shellStack) {
      try {
        e.shellStack = componentStack(inst);
      } catch (_) {}
    }
    throw e;
  } finally {
    current = prev;
    hookIndex = prevIdx;
  }
}

function componentStack(inst) {
  const lines = [];
  for (let p = inst; p; p = p.parent) {
    if (p.kind === "comp" || p.kind === "host") {
      const src = p.el && p.el.src;
      lines.push(typeName(p.type) + (src && src.fileName ? " (" + src.fileName + ":" + src.lineNumber + ")" : ""));
    }
  }
  return lines;
}

function markDirty(inst) {
  if (!inst.mounted) return;
  inst.dirty = true;
  dirty.add(inst);
  scheduleFlush();
}

function scheduleFlush() {
  if (flushScheduled || flushing) return;
  flushScheduled = true;
  Promise.resolve().then(flush);
}

function nearestBoundary(inst) {
  for (let p = inst.parent; p; p = p.parent) if (p.kind === "boundary" && !p.error) return p;
  return null;
}

function rootOf(inst) {
  let p = inst;
  while (p.parent) p = p.parent;
  return p;
}

function rerender(inst) {
  if (inst.kind === "boundary") {
    updateBoundary(inst);
    // reset(): the boundary has no error any more but still shows fallback.
    return;
  }
  try {
    reconcileChildren(inst, normalize(renderComponent(inst)));
  } catch (e) {
    const b = nearestBoundary(inst);
    if (b) catchInBoundary(b, e);
    else failRoot(rootOf(inst), e);
  }
}

function failRoot(root, error) {
  reportError(error, root, true);
  const old = root.children;
  root.children = [];
  for (let i = 0; i < old.length; i++) unmount(old[i], true);
  dirtyHostParents.add(root);
}

/** Render everything that is dirty, send the ops, run effects — repeating
 *  until the tree settles. Safe to call at any time; native calls it at the
 *  end of every entry into JS so a state change made by an event handler is on
 *  screen before control returns to the event loop. */
function flush() {
  flushScheduled = false;
  if (flushing) return;
  flushing = true;
  try {
    let guard = 0;
    while (dirty.size || ops.length || dirtyHostParents.size || pendingEffects.length) {
      if (++guard > 100) {
        dirty.clear();
        pendingEffects = [];
        reportError(
          new Error("Too many re-renders. A component is setting state on every render or in an effect with no dependency list."),
          null,
          false
        );
        break;
      }
      if (dirty.size) {
        const list = Array.from(dirty).sort((a, b) => a.depth - b.depth);
        for (let i = 0; i < list.length; i++) {
          const inst = list[i];
          if (inst.mounted && inst.dirty) rerender(inst);
        }
      }
      commit();
      const effects = pendingEffects;
      pendingEffects = [];
      for (let i = 0; i < effects.length; i++) runEffect(effects[i].cell, effects[i].inst);
    }
  } finally {
    flushing = false;
  }
}

function commit() {
  if (dirtyHostParents.size) {
    dirtyHostParents.forEach((p) => {
      if (p.mounted) ops.push(["children", p.nodeId, hostChildIds(p)]);
    });
    dirtyHostParents.clear();
  }
  if (ops.length) {
    const batch = ops;
    ops = [];
    host.commit(batch);
  }
}

function reportError(error, inst, fatal) {
  const info = {
    message: error && error.message ? String(error.message) : String(error),
    stack: error && error.stack ? String(error.stack) : "",
    componentStack: (error && error.shellStack) || (inst ? componentStack(inst) : []),
    fatal: !!fatal,
    rootKey: inst ? rootOf(inst).rootKey : null,
  };
  try {
    if (host && host.reportError) host.reportError(info);
  } catch (_) {}
}

// ---------------------------------------------------------------- hooks

function hookCell(tag, init) {
  if (!current) throw new Error("Hooks can only be called while a component is rendering.");
  const hooks = current.hooks;
  const i = hookIndex++;
  if (i < hooks.length) {
    if (hooks[i].tag !== tag) {
      throw new Error(typeName(current.type) + " changed the order of its hooks between renders.");
    }
    return hooks[i];
  }
  const cell = init();
  cell.tag = tag;
  hooks.push(cell);
  return cell;
}

function useReducer(reducer, initialArg, init) {
  const inst = current;
  const cell = hookCell("state", () => {
    const c = { value: init ? init(initialArg) : initialArg, reducer };
    c.dispatch = (action) => {
      const next = c.reducer(c.value, action);
      if (Object.is(next, c.value)) return;
      c.value = next;
      markDirty(inst);
    };
    return c;
  });
  cell.reducer = reducer;
  return [cell.value, cell.dispatch];
}

function stateReducer(prev, action) {
  return typeof action === "function" ? action(prev) : action;
}

function useState(initial) {
  return useReducer(stateReducer, initial, typeof initial === "function" ? (f) => f() : undefined);
}

function depsChanged(a, b) {
  if (!a || !b) return true;
  if (a.length !== b.length) return true;
  for (let i = 0; i < a.length; i++) if (!Object.is(a[i], b[i])) return true;
  return false;
}

function useEffect(fn, deps) {
  const inst = current;
  const cell = hookCell("effect", () => ({ deps: undefined, cleanup: null, fn: null, first: true }));
  if (cell.first || depsChanged(cell.deps, deps)) {
    cell.first = false;
    cell.deps = deps;
    cell.fn = fn;
    pendingEffects.push({ inst, cell });
  }
}

function runCleanup(cell, inst) {
  const c = cell.cleanup;
  cell.cleanup = null;
  if (typeof c === "function") {
    try {
      c();
    } catch (e) {
      reportError(e, inst, false);
    }
  }
}

function runEffect(cell, inst) {
  if (cell.dead || !inst.mounted) return;
  runCleanup(cell, inst);
  try {
    cell.cleanup = cell.fn();
  } catch (e) {
    reportError(e, inst, false);
  }
}

function useMemo(fn, deps) {
  const cell = hookCell("memo", () => ({ deps: undefined, value: undefined, first: true }));
  if (cell.first || depsChanged(cell.deps, deps)) {
    cell.first = false;
    cell.deps = deps;
    cell.value = fn();
  }
  return cell.value;
}

function useCallback(fn, deps) {
  return useMemo(() => fn, deps);
}

function useRef(initial) {
  return hookCell("ref", () => ({ ref: { current: initial } })).ref;
}

function useId() {
  return hookCell("id", () => ({ id: "u" + ++uidCounter })).id;
}

function createContext(defaultValue) {
  const ctx = { $$ctx: nextCtxId++, defaultValue };
  ctx.Provider = { $$kind: PROVIDER, ctx };
  return ctx;
}

function useContext(ctx) {
  const inst = current;
  const cell = hookCell("context", () => {
    let p = inst.parent;
    while (p && !(p.kind === "provider" && p.type.ctx === ctx)) p = p.parent;
    if (p) p.subscribers.add(inst);
    return { provider: p || null };
  });
  return cell.provider ? cell.provider.el.props.value : ctx.defaultValue;
}

/** Subscribe to an external store. `subscribe(cb)` returns an unsubscribe
 *  function; `getSnapshot()` must return a stable value while nothing changed. */
function useSyncExternalStore(subscribe, getSnapshot) {
  const value = getSnapshot();
  const [, force] = useReducer((n) => n + 1, 0);
  const seen = useRef(value);
  seen.current = value;
  useEffect(() => {
    const check = () => {
      if (!Object.is(seen.current, getSnapshot())) force();
    };
    const unsub = subscribe(check);
    check(); // the store may have changed between render and subscribe
    return unsub;
  }, [subscribe, getSnapshot]);
  return value;
}

function memo(inner, compare) {
  const m = { $$kind: MEMO, inner, compare: compare || null };
  m.displayName = inner.displayName || inner.name;
  return m;
}

// ---------------------------------------------------------------- refs

function nodeHandle(inst) {
  return {
    id: inst.nodeId,
    /** Run a native command on this node ("focus", "blur", "scrollTo", …). */
    command(name, args) {
      return host.command ? host.command(inst.nodeId, name, args === undefined ? null : args) : undefined;
    },
    focus() {
      return this.command("focus");
    },
    blur() {
      return this.command("blur");
    },
    /** Frame in window coordinates, or null before first layout. */
    measure() {
      return this.command("measure");
    },
  };
}

function attachRef(inst, ref, prev) {
  if (prev && prev !== ref) {
    if (typeof prev === "function") prev(null);
    else prev.current = null;
  }
  if (!ref) return;
  const handle = nodeHandle(inst);
  if (typeof ref === "function") ref(handle);
  else ref.current = handle;
}

// ---------------------------------------------------------------- roots

/** Mount `element` as a root. Emits a `root` host node and tells the host
 *  which node id backs `rootKey`. */
function createRoot(rootKey, element) {
  if (roots.has(rootKey)) destroyRoot(rootKey);
  const el = { $$shell: true, type: "root", props: {}, key: null, src: null };
  const root = createInstance(el, null);
  root.rootKey = rootKey;
  root.nodeId = nextNodeId++;
  root.hostProps = {};
  instancesByNodeId.set(root.nodeId, root);
  roots.set(rootKey, root);
  ops.push(["create", root.nodeId, "root", { rootKey }]);
  renderRoot(rootKey, element);
  return root.nodeId;
}

function renderRoot(rootKey, element) {
  const root = roots.get(rootKey);
  if (!root) throw new Error("No root " + rootKey);
  try {
    reconcileChildren(root, normalize(element));
  } catch (e) {
    failRoot(root, e);
  }
  flush();
}

function destroyRoot(rootKey) {
  const root = roots.get(rootKey);
  if (!root) return;
  roots.delete(rootKey);
  unmount(root, true);
  flush();
}

// ---------------------------------------------------------------- events

/** Native → JS: an event fired on a node. Returns the handler's return value
 *  (used by intercepting events such as drop validation). */
function dispatch(nodeId, name, payload) {
  const inst = instancesByNodeId.get(nodeId);
  let result;
  if (inst && inst.mounted) {
    const fn = inst.el.props[name];
    if (typeof fn === "function") {
      try {
        // Events with more than one argument arrive as { __args: [...] }.
        if (payload && typeof payload === "object" && Array.isArray(payload.__args)) result = fn.apply(null, payload.__args);
        else result = fn(payload);
      } catch (e) {
        reportError(e, inst, false);
      }
    }
  }
  flush();
  return result === undefined ? null : result;
}

/** Run `fn` as one native → JS entry: errors are reported, and everything it
 *  made dirty is rendered before returning. */
function batch(fn) {
  let result;
  try {
    result = fn();
  } catch (e) {
    reportError(e, null, false);
  }
  flush();
  return result;
}

// ---------------------------------------------------------------- inspection

/** Describe a native node for the inspector / feedback tool: its host type,
 *  where it was written, and the chain of components that produced it. */
function describeNode(nodeId) {
  const inst = instancesByNodeId.get(nodeId);
  if (!inst) return null;
  const src = inst.el.src;
  const owners = [];
  for (let p = inst.parent; p; p = p.parent) {
    if (p.kind !== "comp") continue;
    const s = p.el.src;
    owners.push({
      component: typeName(p.type),
      file: s && s.fileName ? s.fileName : null,
      line: s && s.lineNumber ? s.lineNumber : null,
    });
  }
  return {
    id: nodeId,
    type: inst.type,
    file: src && src.fileName ? src.fileName : null,
    line: src && src.lineNumber ? src.lineNumber : null,
    props: inst.hostProps,
    owners,
  };
}

/** The whole host tree as plain data (tests, `shell_inspect`). */
function dumpTree(rootKey) {
  const root = roots.get(rootKey);
  if (!root) return null;
  const walk = (inst) => {
    const kids = [];
    const collect = (i) => {
      for (const c of i.children) {
        if (c.kind === "host") kids.push(walk(c));
        else collect(c);
      }
    };
    collect(inst);
    const out = { id: inst.nodeId, type: inst.type, props: inst.hostProps };
    if (kids.length) out.children = kids;
    return out;
  };
  return walk(root);
}

function _resetForTests() {
  roots.forEach((_, k) => destroyRoot(k));
  instancesByNodeId.clear();
  ops = [];
  dirty.clear();
  dirtyHostParents.clear();
  pendingEffects = [];
  nextNodeId = 1;
  flushScheduled = false;
}

module.exports = {
  setHost,
  h,
  jsx,
  jsxs: jsx,
  jsxDEV: jsx,
  Fragment: FRAGMENT,
  ErrorBoundary: BOUNDARY,
  isElement,
  normalize,
  deepEqual,
  shallowEqual,
  useState,
  useReducer,
  useEffect,
  useLayoutEffect: useEffect,
  useMemo,
  useCallback,
  useRef,
  useId,
  useContext,
  createContext,
  useSyncExternalStore,
  memo,
  createRoot,
  renderRoot,
  destroyRoot,
  dispatch,
  batch,
  flush,
  describeNode,
  dumpTree,
  typeName,
  _resetForTests,
};
