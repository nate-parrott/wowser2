# Super-App Branch — Work-in-Progress Handoff

Branch: `np-superapp`. Snapshot taken mid-work on the network-capture stack — HTTP path is working & tested; HTTPS MITM is wired but a NIO pipeline race is still failing the integration test.

## TL;DR — what works

- **Ghost panes** (agent tabs that are live-but-muted, dimmed in sidebar w/ "Agent tab" subtitle, auto-unghost on user click). Tested.
- **Computer-use BrowserJS API**: `browser.page.click / type / key / scroll`. Synthesizes DOM events (deterministic, works in background tabs). Tested against a `file://` HTML fixture in a real WKWebView.
- **Network capture store**: ChaChaPoly-encrypted JSONL log + Keychain-stored key, opt-in-per-origin allowlist, body/MIME caps, 24h eviction. Tested.
- **Local intercepting HTTP proxy** (NIO): plaintext HTTP fully captured end-to-end through the proxy. Tested.
- **Synthetic fetch** (`browser.net.fetch`) via URLSession, records into the capture store; cookies-from-tab via `WKHTTPCookieStore`. Tested.
- **Local CA + leaf-cert signing** (swift-certificates + swift-nio-ssl): generates a P-256 root on first run, persists to Keychain; signs per-host leaf certs with DNS or IP SAN; caches them. Compiles and used in tests.
- **`LocalCATrust` + `LocalCATrustingSessionDelegate`**: shared trust evaluator that accepts system-rooted certs OR our LocalCA-rooted certs. Used by the proxy's upstream forwarder, by `NetworkSyntheticFetch`, and (planned) by `WKNavigationDelegate` in `WebContent`.
- **Shared Xcode test scheme** `CoreTests` so `xcodebuild -scheme CoreTests test` actually runs the SPM test target. Verified.

## What's broken right now

The HTTPS MITM integration test (`HTTPSCaptureTests.testProxyMITMCapturesHTTPSRequest`) crashes inside the proxy after the MITM swap. Crash:

```
NIOCore/NIOAny.swift:208: Fatal error: tried to decode as type
HTTPPart<HTTPRequestHead, ByteBuffer> but found IOData with contents
ioData(IOData { [504f5354 ... 7475] (113 bytes) })
```

Those bytes decode to `POST /secret-path?q=1 HTTP/1.1 ... hello-from-client` — i.e. the proxy decrypted the inner TLS payload correctly. The issue is purely pipeline-shape: after the MITM swap, decrypted bytes reach a handler that expects `HTTPServerRequestPart`, not `IOData`. The HTTP decoder isn't sitting where I think it is.

The `LocalProxy CONNECT 127.0.0.1:NNNN -> captured=true` log fires, then `LocalProxy MITM swap done for 127.0.0.1:NNNN` fires (so my synchronous swap completed without throwing). But the next inbound bytes still hit a handler with the wrong `InboundIn` type.

## Files added (all under `Wowser/Core/Sources/Core/`)

- `Network/NetworkCaptureStore.swift` — actor + at-rest encryption + allowlist
- `Network/NetworkSyntheticFetch.swift` — URLSession-based synth fetch w/ cookie attachment
- `Network/LocalProxy.swift` — NIO HTTP proxy + CONNECT path (HTTPS MITM via NIOSSL or blind tunnel based on allowlist)
- `Network/LocalCA.swift` — root + leaf cert generation (swift-certificates), Keychain-backed
- `Network/LocalCATrust.swift` — `SecTrust` evaluation against system + LocalCA roots; `URLSessionDelegate` helper
- `BrowserJS/BrowserJSInputDispatcher.swift` — DOM-event-based click/type/key/scroll
- `Network/` directory itself was new

## Files added (tests)

- `Wowser/Core/Tests/CoreTests/Fixtures/computer_use.html` — page with click counter + input that mirrors to a readout div
- `Wowser/Core/Tests/CoreTests/GhostPaneTests.swift` — 3 tests, all pass
- `Wowser/Core/Tests/CoreTests/BrowserJSInputDispatcherTests.swift` — 4 tests, all pass (real WKWebView + file://)
- `Wowser/Core/Tests/CoreTests/NetworkCaptureTests.swift` — 7 tests, all pass (incl. proxy intercepting plaintext HTTP via a NIO test server)
- `Wowser/Core/Tests/CoreTests/HTTPSCaptureTests.swift` — 2 tests; `testProxyTunnelsCertPinnedHostsWithoutMITM` is failing (its blind-tunnel path also breaks — same race), `testProxyMITMCapturesHTTPSRequest` is the main failing one. Includes a manual `ProxyClient` that drives CONNECT + TLS over NIO so the test isn't dependent on URLSession's loopback-bypass quirks (which made the URLSession version silently skip the proxy).

## Files modified (existing source)

- `Wowser/Core/Sources/Core/BrowserJS/BrowserJSHost.swift` — protocol gained `tabsOpenGhost`, `pageClick/type/key/scroll`, `netLog/netGrep/netFetch/netReplay/netCaptureOrigin`. Added `NetLogFilter`, `NetEntrySummary`, `NetEntryHalf`, `NetFetchRequest`, `NetFetchResponse`, `BrowserJSTabInfo.isGhost`.
- `Wowser/Core/Sources/Core/BrowserJS/BrowserJSLiveHost.swift` — implemented all the new protocol methods.
- `Wowser/Core/Sources/Core/BrowserJS/BrowserJSRuntime.swift` — dispatch + JS preamble for new methods.
- `Wowser/Core/Sources/Core/BrowserJS/BrowserJS.d.ts` — surface docs updated.
- `Wowser/Core/Sources/Core/Data/BrowserState.swift` — `Pane.isGhost: Bool`. `BrowserState.unghostTab(id:)`. New uiPublisher sink that mirrors `pane.isGhost` onto `WebContent.silenced`. Linter also added `Tab.customTitle` and `WindowState.findInPageActiveInPaneId` — leave those alone.
- `Wowser/Core/Sources/Core/Data/TabAppearance.swift` — `TabAppearance.subtitle`/`isGhost`; ghost rendering.
- `Wowser/Core/Sources/Core/UI/TabRow.swift` — sidebar row layout grew a 2-line variant when subtitle is present; ghost dimming.
- `Wowser/Core/Sources/Core/UI/Favorites.swift` — `didClickTabToSelect` calls `unghostTab` after `activate`.
- `Wowser/Core/Sources/Core/Web/WebContent.swift` — silenced flag is the wire for ghost mute; the existing prop was kept, just driven from state.
- `Wowser/Core/Tests/CoreTests/BrowserJSTests.swift` — `MockHost` extended for new protocol surface.
- `Wowser/Core/Package.swift` — added `swift-nio-ssl` (`NIOSSL`), `swift-certificates` (`X509`); added `Tests/Fixtures` resource copy.
- `Wowser.xcodeproj/xcshareddata/xcschemes/CoreTests.xcscheme` — new shared scheme that builds and runs the SPM `CoreTests` target. This is what makes `xcodebuild -scheme CoreTests test` work.

## How to run tests

```
xcodebuild -project Wowser.xcodeproj -scheme CoreTests test -destination 'platform=macOS'
```

Or a single class:

```
xcodebuild -project Wowser.xcodeproj -scheme CoreTests test \
  -destination 'platform=macOS' \
  -only-testing:CoreTests/HTTPSCaptureTests/testProxyMITMCapturesHTTPSRequest
```

To run everything except the broken HTTPS test:
```
xcodebuild -project Wowser.xcodeproj -scheme CoreTests test \
  -destination 'platform=macOS' \
  -skip-testing:CoreTests/HTTPSCaptureTests
```

The full suite (excluding HTTPS) is **64 tests, 0 failures** as of this snapshot.

## Where I was when I stopped — the HTTPS pipeline bug

I had just confirmed three things:

1. **The CONNECT decision works** — stderr log `LocalProxy CONNECT 127.0.0.1:NNNN -> captured=true` fires.
2. **The synchronous pipeline swap completes** — `LocalProxy MITM swap done for 127.0.0.1:NNNN` fires (no error path taken).
3. **TLS terminates correctly** — the bytes that crash the next handler are *plaintext* HTTP (`504f5354 ...` = `POST ...`), so NIOSSL is doing its job.

The crash happens because after the swap, the pipeline is supposed to be:

```
[NIOSSLServerHandler, ByteToMessageHandler<HTTPRequestDecoder>, HTTPResponseEncoder, LocalProxyHTTPHandler(mitmHost:)]
```

…but the bytes coming out of NIOSSL appear to be passing through to `LocalProxyHTTPHandler` directly as `IOData`, bypassing the HTTP decoder. So either:
- `configureHTTPServerPipeline()` on `syncOperations` returns an `EventLoopFuture<Void>` that I'm ignoring (NIO HTTP1's pipeline-setup helpers are async-only — only `addHandler` etc. are on `syncOperations`). My code has `try sync.configureHTTPServerPipeline()` — if this method returns a future and I'm not awaiting it, the HTTP handlers may never get added before the next inbound bytes arrive. **This is my prime suspect.** I never confirmed that `syncOperations` has a synchronous overload of `configureHTTPServerPipeline`.
- Or NIOSSL emits `IOData` rather than `ByteBuffer`; if so I'd need a `ByteBuffer`-coercing adapter between NIOSSL and the HTTP decoder.

The signature of the public NIOHTTP1 API I found is:
```
public func configureHTTPServerPipeline(...) -> EventLoopFuture<Void>
```
returning a future — strongly suggests async-only.

### Fix to try first

Replace the `configureHTTPServerPipeline()` call in `LocalProxy.swift` `startMITM()` with explicit synchronous adds:

```swift
try sync.addHandler(serverHandler, position: .first)
try sync.addHandler(ByteToMessageHandler(HTTPRequestDecoder(leftOverBytesStrategy: .dropBytes)))
try sync.addHandler(HTTPResponseEncoder())
try sync.addHandler(LocalProxyHTTPHandler(captureStore: captureStore, ca: ca, mitmHost: (host: host, port: port)))
```

That's all `configureHTTPServerPipeline` does for our case (we don't need pipelining/upgrade). Doing it via `syncOperations.addHandler` keeps the swap atomic on the event loop, which was the whole point of the synchronous-swap refactor.

The blind-tunnel path (`testProxyTunnelsCertPinnedHostsWithoutMITM`) regressed for the same reason — and likely also because the test client's `ProxyClient` does TLS handshake even on the tunneled path (it only validates the upstream cert; the proxy isn't supposed to log here, just relay raw bytes). Re-run after fixing the MITM path; if blind tunnel still fails, check whether `try sync.removeHandler(self)` actually drops the current handler when called from inside an event-loop callback. There's prior art in `swift-nio` saying you must use `removeHandler(context:)` instead of `removeHandler(self)` for the in-flight handler — worth trying.

### After the fix

Once the HTTPS test passes, two follow-on items remain:

1. **Wire `LocalProxy` to live webviews** (task `#11` in the prior session): set `WKWebsiteDataStore.proxyConfigurations` on every profile in `BrowserStore.getOrCreateWebContent`, and override `webView(_:didReceive:completionHandler:)` in `WebContent` to call `LocalCATrust.trustIsValid`. Boot `LocalProxy.shared` from `AppDelegate` so it's listening before any webview opens. The plumbing is mechanical once the proxy is reliable.

2. **Page-driven E2E tests** (user explicitly asked for these — *“we should have computer-use tests for example HTML pages — JS, fetch interception, clicking, screenshotting — outside the main bundle or skipped by default, but you should run them yourself during this work.”*). Plan:

   - New file `Tests/CoreTests/PageDrivenE2ETests.swift`, gated on env var `RUN_E2E_TESTS=1` so it doesn't slow normal CI.
   - HTML fixtures under `Tests/CoreTests/Fixtures/`: a page that does `fetch('https://x.test/api')` on click; a page with a colored div for screenshot diffing.
   - Each test: spin up `LocalProxy` + `LocalCA`, spin up a `TestHTTPSServer` signed by that CA, configure a `WKWebView` with `proxyConfigurations` pointing at the proxy + a nav-delegate that calls `LocalCATrust.trustIsValid`, load the file://, drive it via `BrowserJSInputDispatcher`, then assert on `NetworkCaptureStore.entries(...)`.
   - One test for screenshot: load a known fixed-color page, call `host.contentScreenshot(id:)`, compare a center pixel against the expected color.

## Current task list (from the prior session)

```
#7  ✅ Add shared Xcode scheme that includes CoreTests
#8  ✅ Add swift-certificates + swift-nio-ssl deps
#9  ✅ Implement LocalCA: generate root CA, sign leaves
#10 ✅ Make LocalProxy terminate TLS on CONNECT          ← swap mechanics work, but pipeline shape broken
#11 ⬜ Trust our CA in WebContent + wire proxyConfigurations
#12 🟨 Add HTTPS-capture integration test                ← test exists; failing on pipeline bug
+   ⬜ Page-driven E2E tests (JS + fetch + click + screenshot) — gated, opt-in
```

## Pre-existing weirdnesses worth knowing

- The repo doesn't compile under plain `swift test` / `swift build` because of three pre-existing references that depend on Xcode's resource generation: `Image(.fruit)` in `MobileUI/DraggableFruit.swift`, `Color(.background)` in `Data/TabAppearance.swift:165`, `OmniboxClassifier` in `Search/Searcher.swift` (CoreML model). All build fine via `xcodebuild`. Don't try to fix these — it's a Wowser-level concern, not super-app concern.
- `BrowserState.tabs` is `fileprivate(set)`. Use `insertTab(_:location:inWindow:)` not subscript assignment in tests.
- The Wowser scheme has user-only schemes; my new `CoreTests` scheme is the only shared one. If `xcodebuild -list` ever shows it missing, restore from `Wowser.xcodeproj/xcshareddata/xcschemes/CoreTests.xcscheme`.
- `BrowserJSLiveHost.tabsOpenHTML`'s lookup pattern `ID<WebContent>?.some(.init(raw: id))` is unusual but pre-existing; don't refactor casually.
- The CLAUDE.md was updated mid-session to add a "no I/O in derived getters" rule — relevant to anything that touches snapshot-equatable types.

## Spec reference

The driving spec is `superapp-project.md` in the repo root. Section 7 ("Local intercepting proxy (network capture)") is the relevant chapter for the in-flight TLS work — re-read decisions Q23/Q25 (pure-Swift NIO MITM; cert-pinning hosts; the `[A: let's discuss]` stance on bypassing pinning).

## Branch / commit context

Branch `np-superapp` is dirty. Nothing has been committed yet for this entire run — the last commit is `ae39157 superapp_start`. Diff is large but logically grouped:

- `Network/*` — all new
- `BrowserJS/*` — additive
- `Tests/CoreTests/*` — additive
- `Data/BrowserState.swift`, `Data/TabAppearance.swift`, `UI/TabRow.swift`, `UI/Favorites.swift`, `Web/WebContent.swift` — modified for ghost panes
- `Package.swift`, `Wowser.xcodeproj/xcshareddata/xcschemes/CoreTests.xcscheme` — build config
- `superapp-project.md` — the spec, modified by the user with answers; don't touch

Suggested commit shape if/when you want to land it:

1. `network: add NetworkCaptureStore + LocalProxy (HTTP) + synthetic fetch`
2. `network: add LocalCA + LocalCATrust + TLS termination on CONNECT` (incl. the bug fix when you find it)
3. `browserjs: ghost panes`
4. `browserjs: page.click/type/key/scroll computer-use API`
5. `tests: shared CoreTests scheme + 3 new test classes` (do this ahead of (1) so each commit can be verified)
