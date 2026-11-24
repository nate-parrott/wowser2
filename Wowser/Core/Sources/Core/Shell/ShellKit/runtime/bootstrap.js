// Shell bootstrap — evaluated once in a fresh JS context, before anything else.
//
// The host (Swift `ShellEngine`, or the test / simulator hosts in
// scripts/shell) installs `globalThis.__host` first. This file then defines:
//
//   - a CommonJS module loader for the built-in `wowser` modules (lib/*.js,
//     plain JS) and for the branch's own files (transpiled by the host from
//     TS / JSX / ESM to CommonJS);
//   - timers, `console`, `queueMicrotask` — JavaScriptCore has none of them;
//   - `globalThis.__shell`, the entry points the host calls.
//
// Everything crossing the bridge is a JSON string or a primitive. That keeps
// the contract trivial to mock and avoids JSValue ↔ NSDictionary conversion.
(function (global) {
  "use strict";
  const host = global.__host;
  if (!host) throw new Error("__host must be installed before bootstrap.js");

  // ------------------------------------------------------------ console

  function fmt(v) {
    if (typeof v === "string") return v;
    if (v instanceof Error) return v.stack ? v.message + "\n" + v.stack : String(v.message);
    if (typeof v === "function") return "[function " + (v.name || "anonymous") + "]";
    try {
      const s = JSON.stringify(v, null, 1);
      return s === undefined ? String(v) : s;
    } catch (_) {
      return String(v);
    }
  }
  function logger(level) {
    return function () {
      const parts = [];
      for (let i = 0; i < arguments.length; i++) parts.push(fmt(arguments[i]));
      host.log(level, parts.join(" "));
    };
  }
  global.console = {
    log: logger("log"),
    info: logger("info"),
    warn: logger("warn"),
    error: logger("error"),
    debug: logger("debug"),
  };

  // ------------------------------------------------------------ timers

  let nextTimer = 1;
  const timers = new Map();
  function addTimer(fn, ms, repeat, args) {
    if (typeof fn !== "function") throw new TypeError("timer callback must be a function");
    const id = nextTimer++;
    timers.set(id, { fn, repeat, args });
    host.setTimer(id, Math.max(0, Number(ms) || 0), repeat);
    return id;
  }
  function clearTimer(id) {
    if (timers.delete(id)) host.clearTimer(id);
  }
  global.setTimeout = (fn, ms, ...args) => addTimer(fn, ms, false, args);
  global.setInterval = (fn, ms, ...args) => addTimer(fn, ms, true, args);
  global.clearTimeout = clearTimer;
  global.clearInterval = clearTimer;
  global.requestAnimationFrame = (fn) => addTimer(() => fn(Date.now()), 16, false, []);
  global.cancelAnimationFrame = clearTimer;
  if (typeof global.queueMicrotask !== "function") {
    global.queueMicrotask = (fn) => Promise.resolve().then(fn);
  }

  // ------------------------------------------------------------ modules

  const BUILTINS = {
    wowser: "index",
    "wowser/native": "native",
    "wowser/jsx-runtime": "jsx-runtime",
    "wowser/jsx-dev-runtime": "jsx-runtime",
  };
  const builtinCache = Object.create(null);
  const userCache = new Map();

  function evalModule(code, url) {
    // Indirect eval with the wrapper on the first line keeps the module's own
    // line numbers intact in stack traces; sourceURL names the file.
    return (0, eval)(
      "(function (exports, require, module, __filename) {" + code + "\n})\n//# sourceURL=" + url
    );
  }

  function requireBuiltin(name) {
    if (name in builtinCache) return builtinCache[name].exports;
    const code = host.readBuiltin(name);
    if (code == null) throw new Error("Unknown built-in module lib/" + name + ".js");
    const module = { exports: {} };
    builtinCache[name] = module;
    const fn = evalModule(code, "wowser-runtime/lib/" + name + ".js");
    fn(module.exports, (spec) => requireFrom("\u0000builtin/" + name, spec), module, name);
    return module.exports;
  }

  function dirname(p) {
    const i = p.lastIndexOf("/");
    return i < 0 ? "" : p.slice(0, i);
  }
  function normalizePath(p) {
    const out = [];
    const parts = p.split("/");
    for (let i = 0; i < parts.length; i++) {
      const s = parts[i];
      if (s === "" || s === ".") continue;
      if (s === "..") {
        if (!out.length) throw new Error("Import escapes the branch folder: " + p);
        out.pop();
      } else out.push(s);
    }
    return out.join("/");
  }

  function requireFrom(from, spec) {
    if (typeof spec !== "string") throw new TypeError("require() needs a string");
    if (spec in BUILTINS) return requireBuiltin(BUILTINS[spec]);
    const fromBuiltin = from.charCodeAt(0) === 0;
    if (fromBuiltin) {
      if (spec.startsWith("./")) return requireBuiltin(spec.slice(2).replace(/\.js$/, ""));
      throw new Error("Built-in module cannot import " + spec);
    }
    if (spec.startsWith("wowser/")) throw new Error('No built-in module "' + spec + '"');
    // "./x" and "../x" resolve against the importer; anything else resolves
    // against the branch root ("kit/TabStrip", "/kit/TabStrip").
    const base = spec.startsWith(".") ? normalizePath(dirname(from) + "/" + spec) : normalizePath(spec);
    const path = host.resolveModule(base);
    if (!path) {
      throw new Error('Cannot find module "' + spec + '" (imported from ' + from + ")");
    }
    return requireUser(path);
  }

  function requireUser(path) {
    const cached = userCache.get(path);
    if (cached) return cached.exports;
    const module = { exports: {} };
    userCache.set(path, module);
    try {
      // The host returns CommonJS: JSON as-is, everything else transpiled.
      const code = host.loadModule(path);
      if (path.endsWith(".json")) {
        module.exports = JSON.parse(code);
      } else {
        const fn = evalModule(code, path);
        fn(module.exports, (spec) => requireFrom(path, spec), module, path);
      }
    } catch (e) {
      userCache.delete(path);
      throw e;
    }
    return module.exports;
  }

  // ------------------------------------------------------------ entry points

  const reconciler = requireBuiltin("reconciler");
  reconciler.setHost({
    commit(ops) {
      host.commit(JSON.stringify(ops));
    },
    reportError(info) {
      host.reportError(JSON.stringify(info));
    },
    command(nodeId, name, args) {
      const out = host.command(nodeId, name, JSON.stringify(args));
      return out == null || out === "" ? null : JSON.parse(out);
    },
  });
  const store = requireBuiltin("store");
  const api = requireBuiltin("api");
  const index = requireBuiltin("index");

  function errorInfo(e, fatal, rootKey) {
    return JSON.stringify({
      message: e && e.message ? String(e.message) : String(e),
      stack: e && e.stack ? String(e.stack) : "",
      componentStack: (e && e.shellStack) || [],
      fatal: !!fatal,
      rootKey: rootKey == null ? null : rootKey,
    });
  }

  let setupDone = false;
  const cleanups = [];

  global.__shell = {
    /** Mount the branch's UI for one window. `entry` is a branch-relative
     *  module path whose default export is the root component. */
    mount(rootKey, entry, propsJSON) {
      const props = propsJSON ? JSON.parse(propsJSON) : {};
      try {
        const mod = requireUser(host.resolveModule(normalizePath(entry)) || entry);
        const Root = mod && (mod.default || mod.Browser || mod);
        if (typeof Root !== "function" && !(Root && Root.$$kind)) {
          throw new Error(entry + " must `export default` a component (function).");
        }
        if (!setupDone) {
          setupDone = true;
          // Optional once-per-context hook for non-visual behaviour:
          // commands, hotkeys, navigation hooks.
          if (typeof mod.setup === "function") {
            const c = mod.setup({ platform: host.platform });
            if (typeof c === "function") cleanups.push(c);
          }
        }
        const tree = reconciler.h(
          index.WindowContext.Provider,
          { value: props.windowId || null },
          reconciler.h(reconciler.ErrorBoundary, { fallback: index.RootErrorFallback }, reconciler.h(Root, props))
        );
        return reconciler.createRoot(rootKey, tree);
      } catch (e) {
        host.reportError(errorInfo(e, true, rootKey));
        return 0;
      }
    },
    unmount(rootKey) {
      reconciler.destroyRoot(rootKey);
    },
    /** A native event on a node. Returns the handler's result as JSON. */
    dispatch(nodeId, name, payloadJSON) {
      const result = reconciler.dispatch(nodeId, name, payloadJSON ? JSON.parse(payloadJSON) : undefined);
      return result == null ? "" : JSON.stringify(result);
    },
    fireTimer(id) {
      const t = timers.get(id);
      if (!t) return;
      if (!t.repeat) timers.delete(id);
      reconciler.batch(() => t.fn.apply(null, t.args));
    },
    /** A subscribed slice of browser state changed. */
    slice(key, json) {
      reconciler.batch(() => store._push(key, json));
    },
    /** Several slices changed in one browser-state transaction. */
    slices(pairs) {
      reconciler.batch(() => {
        for (let i = 0; i < pairs.length; i += 2) store._push(pairs[i], pairs[i + 1]);
      });
    },
    resolve(id, json) {
      reconciler.batch(() => api._settle(id, true, json));
    },
    reject(id, message) {
      reconciler.batch(() => api._settle(id, false, message));
    },
    /** A named native → JS callback (commands, hotkeys, lifecycle hooks).
     *  Returns the listener's result as JSON ("" for none). */
    emit(name, payloadJSON) {
      const result = reconciler.batch(() => api._emit(name, payloadJSON ? JSON.parse(payloadJSON) : undefined));
      return result == null ? "" : JSON.stringify(result);
    },
    describeNode(nodeId) {
      const d = reconciler.describeNode(nodeId);
      return d ? JSON.stringify(d) : "";
    },
    dumpTree(rootKey) {
      const d = reconciler.dumpTree(rootKey);
      return d ? JSON.stringify(d) : "";
    },
    /** Evaluate code in this context (the `shell_eval` tool). */
    evaluate(code) {
      let out;
      try {
        const value = (0, eval)(code);
        out = { ok: true, value: value === undefined ? null : value };
      } catch (e) {
        out = { ok: false, error: e && e.message ? e.message : String(e), stack: e && e.stack };
      }
      reconciler.flush();
      try {
        return JSON.stringify(out);
      } catch (_) {
        return JSON.stringify({ ok: true, value: String(out.value) });
      }
    },
    dispose() {
      reconciler._resetForTests();
      while (cleanups.length) {
        try {
          cleanups.pop()();
        } catch (_) {}
      }
      timers.forEach((_, id) => host.clearTimer(id));
      timers.clear();
    },
    require: (spec) => requireFrom("index", spec),
  };
})(globalThis);
