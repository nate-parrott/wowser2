# CEF (Chromium engine) builds

Wowser can optionally embed Chromium via [CefSwift](https://github.com/Rajaniraiyn/CefSwift).
CEF support is **off by default** so everyday WebKit-only builds stay fast.

## Enabling

```sh
touch Wowser/Core/.cef-enabled       # build flag (gitignored)
scripts/cef/setup.sh                 # one-time: downloads CEF (~120MB), builds cef-helper
```

Then build normally (Xcode or `swift build`). The "Embed CEF" build phase
(`embed.sh`) copies the CEF framework + five helper apps into Wowser.app and
codesigns them. In-app, Settings → General → Browser Engine → "Use Chromium
engine for new tabs" becomes toggleable; each pane records its engine, so
WebKit and Chromium tabs coexist in one running app.

## Disabling

```sh
rm Wowser/Core/.cef-enabled
```

Rebuild — the CefSwift dependency drops out of the package graph entirely
(`#if canImport(CefKit)` code compiles out), and the embed phase no-ops.
Optionally `rm -rf Wowser/Core/.cef` to reclaim the CEF distribution cache.

## How it works

- `Core/Package.swift` adds the CefSwift dependency only when `.cef-enabled`
  exists (or `WOWSER_CEF=1` is exported). macOS only; iOS builds never see CEF.
- `WebContent` is the engine-agnostic base class; `WebContentWebKit` and
  `WebContentChromium` are the engines. `Pane.engine` (persisted) picks per tab.
- CEF requires its `NSApplication` subclass from process start:
  `AppDelegate.main()` calls `ChromiumSupport.installApplicationClassIfAvailable()`
  before `NSApplicationMain`. The CEF runtime itself initializes lazily on the
  first Chromium tab.
- Helper app names ("Wowser Helper (GPU).app" etc.) are load-bearing — CEF
  derives them from the main executable name. All five contain the same
  `cef-helper` binary.
- `Info.plist` carries `LSEnvironment: { MallocNanoZone = 0 }` — Chromium's
  allocator is incompatible with the Nano malloc zone. (Present in WebKit-only
  builds too; harmless.)

## Current Chromium-tab limitations

Nav/back/forward/reload/zoom/mute, titles/favicons/progress, popups→new tabs,
and per-profile persistent storage work. Not yet wired: adblock, auto dark
mode, JS/CSS injection, find-in-page, reader mode, element picker, BrowserJS
agent APIs, thumbnails, downloads UI, capture proxy. These degrade gracefully
(they act on `wkWebview`, which is nil for Chromium tabs).
