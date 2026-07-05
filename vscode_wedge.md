# VS Code viewer "wedge" investigation — state dump

Status: **FIX IMPLEMENTED, awaiting runtime verification** (needs an app
relaunch with the wedged tab open).

## The bug (confirmed)

The prior session's hypothesis was verified. Two paths:

- **Pre-commit**: `VSCodeLoadingOverlay` (mounted via `LoadingFailureOverlay`
  when the nav to the serve-web URL fails) probes and only navigates on
  `.ready`. This was already fixed last session.
- **Post-commit (the actual wedge)**: serve-web answers its own
  "…Server is downloading, please wait a moment…" placeholder with **HTTP 200**
  plus `setTimeout(()=>location.reload(),1500)` (verified via curl on both
  53683 and 53684). So the nav *succeeds*, the tab commits,
  `NativePageKey` becomes `.vscode`, and `NativePageOverlay`'s `.vscode` case
  rendered bare `Color.clear` — no placeholder detection, no reset UI. The tab
  self-reloads the placeholder forever.

## The fix (this session)

1. `VSCodeOverlay.swift`: extracted the probe into shared
   `VSCodeServeWebProbe` (`.unreachable/.downloading/.ready`, body-sniffing)
   and hoisted the 12s reset-reveal delay to `vscodeResetRevealDelay`.
2. `VSCodeOverlay.swift`: new `VSCodeWedgeWatcher` view — mounted over an
   already-committed `.vscode` tab. Polls `VSCodeConfig.serveWebBaseURL`
   every 1.5s:
   - `.ready`: reload the tab if it had wedged, then stop watching (a server
     that dies later surfaces as a failed nav → `LoadingFailureOverlay` path).
   - `.downloading`: call `ensureStarted()` (reclaims port from orphans +
     sweeps `.staging` when our manager owns no process — auto-heals the
     orphan-wedge without user action; no-op during a legit download), show
     the native overlay, reveal "Reset and try again" after 12s.
   - `.unreachable`: `ensureStarted()` + overlay in `.starting` phase.
3. `NativePageOverlay.swift`: `.vscode` case now mounts `VSCodeWedgeWatcher`
   (macOS) instead of bare `Color.clear`.

Full app (`xcodebuild -scheme Tangerine`) builds clean. (`swift build` of the
Core package alone still fails on pre-existing unrelated errors in
`Searcher.swift` / `DraggableFruit.swift` that need Xcode-generated resources.)

## Expected recovery path on this machine

Orphan `code-tunnel` pids (807 prod / 2777 dev, up since ~Jun 29) are serving
the placeholder because the `4fe60c…` (VS Code 1.108.0) server build never
finished downloading — empty `.staging` dir keeps getting re-touched. On next
app launch with a VS Code tab: watcher probes → `.downloading` →
`ensureStarted()` kills the orphan on our port, sweeps
`~/.vscode/cli/serve-web/*.staging`, cold-starts serve-web → fresh download of
`4fe60c…`. If the download fails again for an environmental reason, the native
overlay + "Reset and try again" button now appears on the committed tab too.

## Remaining unknowns

- WHY the `4fe60c…` download keeps failing/re-poisoning is still not root-caused
  (could be the empty `.staging` dir itself wedging the CLI — the sweep covers
  that — or a network/proxy issue, which it wouldn't).
- Runtime verification pending: relaunch the app, open/keep the wedged VS Code
  tab, confirm the overlay appears and recovery completes.
