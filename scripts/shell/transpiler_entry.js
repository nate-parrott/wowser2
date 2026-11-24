// Entry point for the vendored transpiler bundle (ShellKit/runtime/transpiler.js).
// Sucrase turns TypeScript / JSX / ES modules into plain CommonJS and keeps
// every statement on its original line, so stack traces need no source maps.
import { transform } from "sucrase";

globalThis.__transpile = function (code, filePath, dev) {
  const isTS = /\.tsx?$/.test(filePath);
  const transforms = ["jsx", "imports"];
  if (isTS) transforms.unshift("typescript");
  return transform(code, {
    transforms,
    jsxRuntime: "automatic",
    jsxImportSource: "wowser",
    production: !dev,
    filePath,
    preserveDynamicImport: false,
    disableESTransforms: true,
  }).code;
};
