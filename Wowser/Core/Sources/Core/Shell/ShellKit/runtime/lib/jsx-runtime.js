// Target of the automatic JSX transform (`jsxImportSource: "wowser"`).
"use strict";
const R = require("./reconciler");
module.exports = { jsx: R.jsx, jsxs: R.jsx, jsxDEV: R.jsx, Fragment: R.Fragment };
