# shell dev tools

Tests and a simulator for the scripted browser UI (`Core/Shell`, see
`shell.md`). Everything here runs the **real** JS runtime and the **real**
branches from `Wowser/Core/Sources/Core/Shell/ShellKit`, against a fake
browser — no Mac needed. `bun` is JavaScriptCore, the same engine the app uses.

    bun install
    bun test                                   # runtime, layouts, examples

    # Render a branch to a PNG (Playwright + Chromium)
    node sim/shot.js stock  --entry layouts/ClassicKit --out out/kit.png
    node sim/shot.js chrome --scheme dark --do "click:address" --do "type:address-input:wiki"
    node sim/shot.js stock  --entry layouts/MobileKit --platform ios --do "click:tabs-button"

    # Or build a page and open it in a browser to click around
    bun run sim/build.js stock --entry layouts/Playground     # → out/sim.html

    bun run build:transpiler                   # re-vendor Sucrase after a version bump

| | |
| --- | --- |
| `lib/fakeBrowser.js` | In-memory browser answering the same slices and calls as `ShellSlices.swift` / `ShellActions.swift`. Keep the JSON shapes identical. |
| `lib/makeHost.js` | The `__host` object, for both tests and the simulator page. |
| `lib/loadShell.js` | Boots the runtime in a `vm` context; `s.mount()`, `s.press()`, `s.mutate()`, `s.emit()`, `s.hotkey()`. |
| `lib/tree.js` | Mirror of the native node tree (the JS twin of `ShellTree`). |
| `sim/render.js` | Draws the node tree with DOM + CSS. An approximation of the SwiftUI renderer: it follows the same sizing rules (boxes hug unless something inside grows) but materials, fonts and SF Symbols are stand-ins. Native components are placeholders. |

The simulator is for structure and logic. What a branch really looks like is
decided by `ShellRenderer.swift`; check there (and on a Mac) before trusting
a pixel.
