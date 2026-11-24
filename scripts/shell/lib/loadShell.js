// bun/node loader: boots the real runtime in an isolated context against a
// branch on disk (or an in-memory file map) and the fake browser.
"use strict";
const fs = require("fs");
const path = require("path");
const vm = require("vm");
const { makeHost } = require("./makeHost");
const { createTree } = require("./tree");
const { createFakeBrowser } = require("./fakeBrowser");

const RUNTIME = path.join(__dirname, "../../../Wowser/Core/Sources/Core/Shell/ShellKit/runtime");
const BRANCHES = path.join(__dirname, "../../../Wowser/Core/Sources/Core/Shell/ShellKit/branches");

function readBuiltins() {
  const out = {};
  for (const f of fs.readdirSync(path.join(RUNTIME, "lib"))) {
    if (f.endsWith(".js")) out[f.slice(0, -3)] = fs.readFileSync(path.join(RUNTIME, "lib", f), "utf8");
  }
  return out;
}

function readBranch(dir) {
  const out = {};
  const walk = (d, prefix) => {
    for (const e of fs.readdirSync(d, { withFileTypes: true })) {
      if (e.name.startsWith(".")) continue;
      const rel = prefix ? prefix + "/" + e.name : e.name;
      if (e.isDirectory()) walk(path.join(d, e.name), rel);
      else if (/\.(xml|tsx?|jsx?|json|html|css|md|svg)$/.test(e.name)) out[rel] = fs.readFileSync(path.join(d, e.name), "utf8");
    }
  };
  walk(dir, "");
  return out;
}

let transpilerCode = null;
function makeTranspile() {
  if (transpilerCode == null) transpilerCode = fs.readFileSync(path.join(RUNTIME, "transpiler.js"), "utf8");
  const ctx = vm.createContext({});
  vm.runInContext(transpilerCode, ctx);
  return vm.runInContext("__transpile", ctx);
}

/**
 * Boot a shell. `opts.files` (in-memory branch) or `opts.branch` (a folder
 * name under ShellKit/branches, or an absolute path).
 */
function loadShell(opts) {
  opts = opts || {};
  const files =
    opts.files || readBranch(path.isAbsolute(opts.branch) ? opts.branch : path.join(BRANCHES, opts.branch));
  const fake = opts.fake || createFakeBrowser(opts.seed);
  const tree = createTree();
  const sandbox = { Promise, JSON, Math, Date, Object, Array, Map, Set, Symbol, Error, TypeError, SyntaxError, Proxy, Reflect, URL };
  const ctx = vm.createContext({});
  const pendingTimers = new Set();
  const made = makeHost({
    builtins: readBuiltins(),
    files,
    transpile: makeTranspile(),
    fake,
    platform: opts.platform || "mac",
    branch: opts.branchName || (typeof opts.branch === "string" ? path.basename(opts.branch) : "test"),
    echo: !!opts.echo,
    getShell: () => ctx.__shell,
    onCommit: (ops) => tree.apply(ops),
    onCommand: opts.onCommand,
    timers: {
      set(fn, ms, repeat) {
        const h = (repeat ? setInterval : setTimeout)(() => {
          if (!repeat) pendingTimers.delete(h);
          fn();
        }, ms);
        pendingTimers.add(h);
        return h;
      },
      clear(h) {
        clearTimeout(h);
        clearInterval(h);
        pendingTimers.delete(h);
      },
    },
  });
  ctx.__host = made.host;
  vm.runInContext(fs.readFileSync(path.join(RUNTIME, "bootstrap.js"), "utf8"), ctx, { filename: "bootstrap.js" });
  void sandbox;

  const shell = ctx.__shell;
  const api = {
    ctx,
    shell,
    tree,
    fake,
    files,
    host: made.host,
    logs: made.logs,
    errors: made.errors,
    commands: made.commands,
    subscribed: made.subscribed,
    publish: made.publish,
    mount(entry, props) {
      const manifest = files["manifest.json"] ? JSON.parse(files["manifest.json"]) : {};
      const e = entry || (manifest.entry && manifest.entry[made.host.platform]) || "index";
      return shell.mount("main", e, JSON.stringify(Object.assign({ windowId: made.host.windowId }, props)));
    },
    /** Fire a node event the way native would. */
    fire(node, name, payload) {
      if (!node) throw new Error("fire(" + name + "): no node");
      const out = shell.dispatch(node.id, name, payload === undefined ? "" : JSON.stringify(payload));
      return out ? JSON.parse(out) : null;
    },
    press(node, modifiers) {
      return api.fire(node, "onPress", { modifiers: modifiers || {}, x: 0, y: 0 });
    },
    /** Deliver a native event (`on("navigate")`, commands…) and return the listener's answer. */
    emit(name, payload) {
      const out = shell.emit(name, JSON.stringify(payload === undefined ? null : payload));
      made.publish();
      return out ? JSON.parse(out) : null;
    },
    /** Press a registered hotkey ("cmd+shift+a"). */
    hotkey(combo) {
      const cmd = Array.from(fake.commandsRegistered.values()).find((c) => c.hotkey === combo);
      if (!cmd) throw new Error("no command bound to " + combo);
      return api.emit("command", { id: cmd.id });
    },
    /** Run a registered command by id. */
    command(id) {
      return api.emit("command", { id });
    },
    /** Mutate the fake browser directly, then push changed slices. */
    mutate(fn) {
      fn(fake.state, fake);
      made.publish();
    },
    /** Let timers / promises settle. */
    async settle(ms) {
      await new Promise((r) => setTimeout(r, ms == null ? 5 : ms));
      await Promise.resolve();
    },
    dispose() {
      try {
        shell.dispose();
      } catch (_) {}
      pendingTimers.forEach((h) => {
        clearTimeout(h);
        clearInterval(h);
      });
    },
  };
  return api;
}

module.exports = { loadShell, readBranch, readBuiltins, RUNTIME, BRANCHES };
