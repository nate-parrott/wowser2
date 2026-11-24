// Rebuilds ShellKit/runtime/transpiler.js from the pinned sucrase version.
//   bun run build:transpiler
import { join } from "path";
const out = join(import.meta.dir, "../../Wowser/Core/Sources/Core/Shell/ShellKit/runtime");
const result = await Bun.build({
  entrypoints: [join(import.meta.dir, "transpiler_entry.js")],
  target: "browser",
  format: "iife",
  minify: true,
});
if (!result.success) {
  console.error(result.logs.join("\n"));
  process.exit(1);
}
const code = await result.outputs[0].text();
const pkg = await Bun.file(join(import.meta.dir, "node_modules/sucrase/package.json")).json();
const banner =
  `// GENERATED — do not edit. Sucrase ${pkg.version} (MIT, https://github.com/alangpierce/sucrase),\n` +
  `// bundled by scripts/shell/build_transpiler.js. Defines globalThis.__transpile(code, path, dev).\n`;
await Bun.write(join(out, "transpiler.js"), banner + code);
console.log("wrote transpiler.js", (code.length / 1024).toFixed(0) + " KB");
