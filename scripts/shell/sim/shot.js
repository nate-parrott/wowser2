// Screenshot a branch in the simulator (needs Playwright + Chromium).
//
//   node sim/shot.js <branch> --out out/chrome.png [--entry layouts/Chrome]
//        [--platform ios] [--scheme dark] [--size 1200x760] [--scale 2]
//        [--do "click:new-tab" --do "type:command-input:wiki" --do "hover:tab-t2" --do "eval:sim.mutate(s => …)"]
//
// --do steps run in order before the capture; targets are testIDs.
"use strict";
const fs = require("fs");
const path = require("path");
const { buildPage } = require("./build");

async function shoot(branch, o) {
  const { chromium } = require("playwright");
  const ios = o.platform === "ios";
  const [w, h] = (o.size || (ios ? "438x892" : "1200x760")).split("x").map(Number);
  const html = path.join(__dirname, "../out", "shot-" + process.pid + "-" + Date.now() + ".html");
  fs.mkdirSync(path.dirname(html), { recursive: true });
  fs.writeFileSync(html, buildPage(branch, o));
  const browser = await chromium.launch();
  try {
    const page = await browser.newPage({ viewport: { width: w, height: h }, deviceScaleFactor: o.scale || 1 });
    const consoleErrors = [];
    page.on("pageerror", (e) => consoleErrors.push(String(e)));
    await page.goto("file://" + html);
    await page.waitForTimeout(150);
    for (const step of o.steps || []) {
      const [verb, ...rest] = step.split(":");
      const arg = rest.join(":");
      if (verb === "click") await page.click(`[data-testid="${arg}"]`);
      else if (verb === "hover") await page.hover(`[data-testid="${arg}"]`);
      else if (verb === "type") {
        const i = arg.indexOf(":");
        await page.fill(`[data-testid="${arg.slice(0, i)}"]`, arg.slice(i + 1));
      } else if (verb === "key") await page.keyboard.press(arg);
      else if (verb === "eval") await page.evaluate(arg);
      else if (verb === "wait") await page.waitForTimeout(Number(arg));
      else throw new Error("unknown step " + step);
      await page.waitForTimeout(60);
    }
    await page.waitForTimeout(o.settle || 350);
    const info = await page.evaluate(() => ({ errors: window.sim.errors, logs: window.sim.logs.slice(-20) }));
    if (o.out) await page.screenshot({ path: o.out });
    return Object.assign(info, { pageErrors: consoleErrors });
  } finally {
    await browser.close();
    fs.rmSync(html, { force: true });
  }
}

module.exports = { shoot };

if (require.main === module) {
  const args = process.argv.slice(2);
  const opt = (name) => {
    const i = args.indexOf("--" + name);
    return i >= 0 ? args[i + 1] : undefined;
  };
  const steps = [];
  args.forEach((a, i) => a === "--do" && steps.push(args[i + 1]));
  const branch = args[0] && !args[0].startsWith("--") ? args[0] : "stock";
  shoot(branch, { entry: opt("entry"), platform: opt("platform"), scheme: opt("scheme"), size: opt("size"), scale: opt("scale") ? Number(opt("scale")) : 1, out: opt("out") || path.join(__dirname, "../out/shot.png"), steps })
    .then((info) => {
      if (info.errors.length || info.pageErrors.length) {
        console.error(JSON.stringify(info, null, 1));
        process.exitCode = 1;
      } else console.log("ok");
    })
    .catch((e) => {
      console.error(e);
      process.exit(1);
    });
}
