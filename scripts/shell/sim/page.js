// Runs inside the simulator page: boots the real runtime against the fake
// browser and draws the node tree with the DOM renderer.
"use strict";
(function () {
  const B = window.__SIM_BUNDLE__;
  // bootstrap.js replaces these globals with bridge-backed versions.
  const real = {
    console: window.console,
    setTimeout: window.setTimeout.bind(window),
    setInterval: window.setInterval.bind(window),
    clearTimeout: window.clearTimeout.bind(window),
    clearInterval: window.clearInterval.bind(window),
  };
  const mods = {};
  function req(name) {
    if (mods[name]) return mods[name].exports;
    const m = (mods[name] = { exports: {} });
    new Function("module", "exports", "require", B.tools[name])(m, m.exports, (n) => req(n.replace(/^\.\.?\/(lib\/|sim\/)?/, "").replace(/\.js$/, "")));
    return m.exports;
  }
  const { createFakeBrowser } = req("fakeBrowser");
  const { makeHost } = req("makeHost");
  const { createTree } = req("tree");
  const { createRenderer } = req("render");

  // The transpiler defines globalThis.__transpile.
  (0, eval)(B.transpiler);

  const params = new URLSearchParams(location.search);
  const fake = createFakeBrowser();
  if (params.get("scheme") === "dark" || B.options.scheme === "dark") fake.state.scheme = "dark";
  const tree = createTree();
  const platform = params.get("platform") || B.options.platform || "mac";
  const made = makeHost({
    builtins: B.builtins,
    files: B.files,
    transpile: window.__transpile,
    fake,
    platform,
    branch: B.options.branch,
    echo: true,
    console: real.console,
    getShell: () => window.__shell,
    onCommit: (ops) => {
      tree.apply(ops);
      schedule();
    },
    timers: {
      set: (fn, ms, repeat) => (repeat ? real.setInterval(fn, ms) : real.setTimeout(fn, ms)),
      clear: (h) => {
        real.clearTimeout(h);
        real.clearInterval(h);
      },
    },
  });
  window.__host = made.host;
  (0, eval)(B.bootstrap);

  const renderer = createRenderer({
    container: document.getElementById("window"),
    tree,
    fake,
    files: B.files,
    dispatch: (id, name, payload) => {
      const out = window.__shell.dispatch(id, name, payload === undefined ? "" : JSON.stringify(payload));
      made.publish();
      schedule();
      return out ? JSON.parse(out) : null;
    },
  });
  let scheduled = false;
  function schedule() {
    if (scheduled) return;
    scheduled = true;
    Promise.resolve().then(() => {
      scheduled = false;
      renderer.sync();
    });
  }
  // Feed the `mouse` slice ($mouse / useMouse) from the real pointer.
  const frame = document.getElementById("window");
  window.addEventListener("mousemove", (e) => {
    const r = frame.getBoundingClientRect();
    const x = Math.round(e.clientX - r.left);
    const y = Math.round(e.clientY - r.top);
    fake.state.mouse = { x, y, inside: x >= 0 && y >= 0 && x <= r.width && y <= r.height };
    made.publish();
    schedule();
  });
  window.addEventListener("message", (e) => {
    if (e.data && e.data.__island) window.__shell.dispatch(e.data.__island, "onMessage", JSON.stringify(e.data.message));
  });

  const manifest = B.files["manifest.json"] ? JSON.parse(B.files["manifest.json"]) : {};
  const entry = params.get("entry") || B.options.entry || (manifest.entry && manifest.entry[platform]) || "index";
  window.__shell.mount("main", entry, JSON.stringify({ windowId: made.host.windowId }));
  renderer.sync();

  // Handles for scripted interaction (shot.js) and poking around in devtools.
  window.sim = {
    fake,
    tree,
    errors: made.errors,
    logs: made.logs,
    mutate(fn) {
      fn(fake.state, fake);
      made.publish();
      renderer.sync();
    },
    sync: () => renderer.sync(),
  };
})();
