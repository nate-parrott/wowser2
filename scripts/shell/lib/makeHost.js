// Builds the `__host` object the shell runtime expects, backed by the fake
// browser and in-memory file maps. Environment-neutral: the bun test loader
// and the in-page DOM simulator both use it.
"use strict";

const EXTENSIONS = ["", ".tsx", ".ts", ".jsx", ".js", ".json", "/index.tsx", "/index.ts", "/index.jsx", "/index.js"];

/**
 * @param o.builtins   { [name]: code } — ShellKit/runtime/lib/*.js
 * @param o.files      { [path]: source } — the branch
 * @param o.transpile  (code, path, dev) => code
 * @param o.fake       createFakeBrowser()
 * @param o.getShell   () => globalThis.__shell of the context being hosted
 * @param o.onCommit   (ops) => void
 * @param o.timers     { set(fn, ms, repeat) => handle, clear(handle) }
 */
function makeHost(o) {
  const subscribed = new Map(); // key -> last json
  const timers = new Map();
  const logs = [];
  const errors = [];
  const commands = [];

  const sliceJSON = (key) => {
    const v = o.fake.slice(key);
    return v == null ? "" : JSON.stringify(v);
  };

  /** Push every subscribed slice whose JSON changed (call after mutations). */
  function publish() {
    const pairs = [];
    subscribed.forEach((prev, key) => {
      const next = sliceJSON(key);
      if (next !== prev) {
        subscribed.set(key, next);
        pairs.push(key, next);
      }
    });
    if (pairs.length) o.getShell().slices(pairs);
  }

  const host = {
    platform: o.platform || "sim",
    windowId: o.fake.state.window.id,
    branch: o.branch || "test",
    log(level, message) {
      logs.push({ level, message });
      if (o.echo) console.log("[shell:" + level + "]", message);
    },
    reportError(json) {
      errors.push(JSON.parse(json));
      if (o.echo) console.error("[shell:error]", json);
    },
    readBuiltin(name) {
      return o.builtins[name] == null ? null : o.builtins[name];
    },
    resolveModule(base) {
      for (const ext of EXTENSIONS) if (o.files[base + ext] != null) return base + ext;
      return null;
    },
    loadModule(path) {
      const src = o.files[path];
      if (src == null) throw new Error("No such file: " + path);
      if (path.endsWith(".json")) return src;
      try {
        return o.transpile(src, path, true);
      } catch (e) {
        throw new SyntaxError(path + ": " + e.message);
      }
    },
    commit(json) {
      o.onCommit(JSON.parse(json));
    },
    command(nodeId, name, argsJSON) {
      commands.push({ nodeId, name, args: argsJSON ? JSON.parse(argsJSON) : null });
      return o.onCommand ? JSON.stringify(o.onCommand(nodeId, name, argsJSON ? JSON.parse(argsJSON) : null) ?? null) : "";
    },
    subscribe(key) {
      const json = sliceJSON(key);
      subscribed.set(key, json);
      return json;
    },
    unsubscribe(key) {
      subscribed.delete(key);
    },
    call(name, argsJSON) {
      try {
        const args = argsJSON ? JSON.parse(argsJSON) : undefined;
        if (name === "shell.readFile") return JSON.stringify(o.files[args.path] ?? null);
        const out = o.fake.call(name, args);
        // Mirror the app: state changes reach subscribers after the call
        // returns, coalesced.
        o.timers.set(publish, 0, false);
        return out == null ? "" : JSON.stringify(out);
      } catch (e) {
        return "\u0001" + e.message;
      }
    },
    callAsync(id, name, argsJSON) {
      o.fake.callAsync(name, argsJSON ? JSON.parse(argsJSON) : undefined).then(
        (v) => {
          o.getShell().resolve(id, v == null ? "" : JSON.stringify(v));
          publish();
        },
        (e) => o.getShell().reject(id, e.message)
      );
    },
    setTimer(id, ms, repeat) {
      timers.set(id, o.timers.set(() => o.getShell().fireTimer(id), ms, repeat));
    },
    clearTimer(id) {
      const h = timers.get(id);
      if (h !== undefined) {
        o.timers.clear(h);
        timers.delete(id);
      }
    },
  };
  return { host, publish, logs, errors, commands, subscribed };
}

module.exports = { makeHost, EXTENSIONS };
