// Slices: read-only, always-current views of browser state.
//
// A slice is addressed by a name and a small argument object
// (`("tab", {id})`). The host computes it natively from `BrowserState` as an
// Equatable snapshot, encodes it once per change, and pushes the JSON here.
// Components read slices with `useSlice`; many readers share one native
// subscription.
"use strict";
const R = require("./reconciler");

const host = globalThis.__host;
const entries = new Map(); // key -> { value, json, refs, listeners }
let sweepTimer = 0;

function keyFor(name, arg) {
  if (arg == null) return name;
  // Sort keys so {a,b} and {b,a} share a subscription.
  const keys = Object.keys(arg).sort();
  const o = {};
  for (let i = 0; i < keys.length; i++) if (arg[keys[i]] != null) o[keys[i]] = arg[keys[i]];
  return name + "|" + JSON.stringify(o);
}

function entryFor(key) {
  let e = entries.get(key);
  if (!e) {
    const json = host.subscribe(key);
    e = { json, value: json ? JSON.parse(json) : null, refs: 0, listeners: new Set() };
    entries.set(key, e);
    scheduleSweep();
  }
  return e;
}

/** Current value of a slice (subscribes natively on first read). */
function read(name, arg) {
  return entryFor(keyFor(name, arg)).value;
}

function listen(key, cb) {
  const e = entryFor(key);
  e.refs++;
  e.listeners.add(cb);
  return () => {
    e.refs--;
    e.listeners.delete(cb);
    if (e.refs <= 0) scheduleSweep();
  };
}

// Unsubscribe lazily so a slice that is dropped and re-read within the same
// update (a list re-keying, a tab switch) doesn't thrash the native side.
function scheduleSweep() {
  if (sweepTimer) return;
  sweepTimer = setTimeout(() => {
    sweepTimer = 0;
    entries.forEach((e, key) => {
      if (e.refs <= 0) {
        entries.delete(key);
        host.unsubscribe(key);
      }
    });
  }, 2000);
}

function _push(key, json) {
  const e = entries.get(key);
  if (!e || e.json === json) return;
  e.json = json;
  e.value = json ? JSON.parse(json) : null;
  e.listeners.forEach((cb) => cb());
}

/** Read a slice and re-render when it changes. With `selector`, re-render
 *  only when the selected part changes (compared structurally). */
function useSlice(name, arg, selector) {
  const key = keyFor(name, arg);
  const [, force] = R.useReducer((n) => n + 1, 0);
  const value = entryFor(key).value;
  const selected = selector ? selector(value) : value;
  const sel = R.useRef(selector);
  sel.current = selector;
  const last = R.useRef(selected);
  last.current = selected;
  R.useEffect(() => {
    const check = () => {
      const v = entryFor(key).value;
      const s = sel.current ? sel.current(v) : v;
      if (!R.deepEqual(s, last.current)) force();
    };
    const off = listen(key, check);
    check();
    return off;
  }, [key]);
  return selected;
}

/** Current value by full key (see `keyFor`). */
function readKey(key) {
  return entryFor(key).value;
}

module.exports = { read, readKey, listen, useSlice, keyFor, _push, _entries: entries };
