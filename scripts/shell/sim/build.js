// Builds a self-contained simulator page for a branch.
//
//   bun run sim/build.js <branch> [--entry layouts/Chrome] [--platform ios]
//                        [--scheme dark] [--out out/sim.html]
//
// <branch> is a folder under ShellKit/branches (seed overlays are applied) or
// a path to any branch folder. Open the result in a browser, or use shot.js.
"use strict";
const fs = require("fs");
const path = require("path");
const { readBranch, readBuiltins, RUNTIME, BRANCHES } = require("../lib/loadShell");

function loadBranchFiles(name) {
  const dir = fs.existsSync(name) && fs.statSync(name).isDirectory() ? path.resolve(name) : path.join(BRANCHES, name);
  let files = readBranch(dir);
  const manifest = files["manifest.json"] ? JSON.parse(files["manifest.json"]) : {};
  if (manifest.seedBase) files = Object.assign(readBranch(path.join(BRANCHES, manifest.seedBase)), files);
  return files;
}

function buildPage(branch, options) {
  const tools = {};
  for (const [name, file] of [["fakeBrowser", "lib/fakeBrowser.js"], ["makeHost", "lib/makeHost.js"], ["tree", "lib/tree.js"], ["render", "sim/render.js"]]) {
    tools[name] = fs.readFileSync(path.join(__dirname, "..", file), "utf8");
  }
  const bundle = {
    options: Object.assign({ branch: path.basename(branch) }, options),
    tools,
    builtins: readBuiltins(),
    files: options.files || loadBranchFiles(branch),
    transpiler: fs.readFileSync(path.join(RUNTIME, "transpiler.js"), "utf8"),
    bootstrap: fs.readFileSync(path.join(RUNTIME, "bootstrap.js"), "utf8"),
  };
  const ios = options.platform === "ios";
  const json = JSON.stringify(bundle).replace(/</g, "\\u003c");
  return `<!doctype html>
<html><head><meta charset="utf-8"><title>Shell simulator — ${bundle.options.branch}</title>
<style>
  html, body { margin: 0; height: 100%; background: ${ios ? "#111" : "#5b6b8c"}; }
  body { display: grid; place-items: center; font-family: -apple-system, "SF Pro Text", Inter, "Helvetica Neue", Arial, sans-serif; font-size: 13px; -webkit-font-smoothing: antialiased; }
  #window { ${ios ? "width: 390px; height: 844px; border-radius: 44px;" : "width: calc(100% - 48px); height: calc(100% - 48px); border-radius: 12px;"} overflow: hidden; box-shadow: 0 20px 60px rgba(0,0,0,0.35), 0 0 0 0.5px rgba(0,0,0,0.3); background: #ececec; }
  ::-webkit-scrollbar { display: none; }
  input::placeholder { color: inherit; opacity: 0.45; }
</style></head>
<body><div id="window"></div>
<script>window.__SIM_BUNDLE__ = ${json};</script>
<script>${fs.readFileSync(path.join(__dirname, "page.js"), "utf8").replace(/<\/script>/g, "<\\/script>")}</script>
</body></html>`;
}

module.exports = { buildPage, loadBranchFiles };

if (require.main === module) {
  const args = process.argv.slice(2);
  const opt = (name) => {
    const i = args.indexOf("--" + name);
    return i >= 0 ? args[i + 1] : undefined;
  };
  const branch = args[0] && !args[0].startsWith("--") ? args[0] : "stock";
  const out = opt("out") || path.join(__dirname, "../out/sim.html");
  fs.mkdirSync(path.dirname(out), { recursive: true });
  fs.writeFileSync(out, buildPage(branch, { entry: opt("entry"), platform: opt("platform"), scheme: opt("scheme") }));
  console.log("wrote " + out);
}
