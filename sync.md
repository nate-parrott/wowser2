# Sync

Wowser syncs spaces, tabs, top history and autofill between devices through
a shared folder (by default in iCloud Drive). It's off by default: Settings →
General → Sync.

Code: `Wowser/Core/Sources/Core/Sync/`. Tests: `Tests/CoreTests/Sync*Tests.swift`,
`BrowserSyncTests`, `HistoryAutofillSyncTests`, `FolderSyncTransportTests`.

## The short version

- Every synced thing is a **record**: `collection / key → { field: JSON value }`
  (e.g. `tab/<tabID> → { customTitle: "…" }`).
- Each device keeps an **append-only log** of field writes, `(collection, key,
  field, value, clock)`, and reads everyone else's.
- Merging is **per-field last-writer-wins** on a hybrid logical clock (HLC),
  with optional per-field merge policies. That's a state-based CRDT: logs can
  arrive late, out of order or twice and every device ends up the same.
- Order (tabs in a list, spaces, panes in a split) is a **fractional index**
  per item, so moving one tab rewrites one tab's order key.
- Local code doesn't know any of this. A **source** maps its model to records
  (`project`) and folds merged records back in (`apply`). The engine diffs
  projections to produce log writes.

```
  BrowserState ─┐                               ┌─ other devices' logs
  HistoryStore ─┼─ project ─▶ diff ─▶ log writes ┼──▶ transport (folder)
  AutofillStore ┘     ▲                          │
                      │                          ▼
                 apply ◀── SyncUpdate ◀── merge into SyncDocument
```

## What syncs

| Data | Syncs | Doesn't |
|---|---|---|
| **Spaces** (`Profile`) | title, emoji, AI title, hidden, order, attached folder path, theme (+ the title it was generated from), bundled background image + mode, login group | custom background images (local files; other devices keep theirs), recent domains, removed-favorite domains, which tab is selected |
| **Login groups** (which spaces share cookies/logins) | the grouping, as an opaque group id | cookies, website data, passwords |
| **Tabs** | which list they're in (favorites, auto-favorites, a space's tab list, a folder) and order, custom title/emoji, folders (name, members) | selected tab, `lastAccessed`, pip state, folder "open" state, attached agent tabs, badges, agent leases, ghost flag |
| **Panes** (split view) | URL, title, favicon, pinned URL/title (favorites), split weight, which tab they're in + order | everything live: loading state, back/forward, colors, find, focus… |
| **History** | per login group, the top 200 pages by visit score: URL, title, last visit, decayed visit count | the rest of history; deletions (grow-only) |
| **Autofill** | names, emails, phones, companies, addresses (+ use counts), "never remember" domains | saved logins and their passwords |
| — | | memory, cookies, settings/defaults, archive, agent sessions |

Every kind of tab syncs, including terminal, agent, VS Code and file-browser
tabs; on another device they open fresh (a new terminal at that path, etc).

### Only the primary window's tabs

Each space has favorites (per space) and ordinary tabs (per window). Only the
**primary window's** ordinary tabs sync. The primary window is pinned in
`BrowserState.sync.primaryWindowID` the first time sync runs, and stays put
while it exists; when it closes the most recently active window takes over
(with "All windows share tabs", that's also where its tabs go). Remote tabs
land in this device's primary window. Moving a tab to another window
removes it from sync (other devices close it).

If there's no window at all, the browser source reports "unknown" rather than
"no tabs", so nothing gets deleted.

### Navigation fights

Two devices with the same tab open would otherwise drag each other's page
around. We never navigate a live page because of sync:

- Remote URL change for a pane **without** a live webview here: applied to
  `pane.info` directly; it loads when opened.
- For a pane **with** a live webview: parked in `Pane.syncPendingNav`. When the
  tab is next **reopened** (becomes a window's current tab, or its webview is
  recreated) the parked URL loads. If the user navigates that pane first, the
  parked one is dropped and the local navigation (newer clock) wins everywhere.
- Same URL with a new title/favicon just updates the title.

Projections report the parked URL while one is pending, so the device doesn't
write its stale URL back. Claude Code's spinner glyph is stripped from
terminal titles so they don't sync many times a second.

### Login groups

A space's group id is its `dataStoreUUID` string. A new space from another
device gets a cookie jar for its group: the one a local space in that group
already uses, else the group id itself (it's a UUID), else a fresh one. When
another device names a different group for a jar we already have (e.g. both
devices' default space `p0`), we don't switch jars (that would log you out);
we alias our jar to their group id in `BrowserState.sync.loginGroupAliases`.
History syncs per group.

## The engine

### Records and the document

`SyncDocument` holds the merged state: collection → key → field →
`(value, HLC)`. `merge(op)` keeps whichever write the collection's
`SyncMergePolicy` picks (default: higher clock). Policies must be
commutative, associative and idempotent (a semilattice join). Custom ones in
use:

- autofill `lastUsed`, `useCount`: larger number wins (`FieldMergePolicy.maxNumber`)
- history `lastVisit`: larger wins; `visits` (a decayed counter `{n, t}`): the
  stronger counter wins, comparing `log2(n) + t / halfLife`, which ranks two
  counters the same at any point in time. Devices' counts aren't summed.

Reserved fields: `_del` (tombstone: `true` deletes, delete wins over concurrent
edits, only an explicit `false` revives), `_parent` and `_order` (ordered
collections).

### Clocks

`HLC` = (wall millis, counter, device id), totally ordered. A device's clock
always ticks past anything it has seen, so a device with a slow clock can still
overwrite a value it just received. Wire format: `"1700000000123.0@<device>"`.

### Diffing (local → log)

On a local change (throttled to ~1s, on the engine's background queue) the
engine asks each source for a fresh projection. Getting the state is cheap:
sources keep the latest value of their (value-type) store from its publisher,
so there's no hop to the main thread. A field is written iff

1. it changed since the previous projection, **and**
2. it differs from the merged document.

(1) means a stale snapshot never reverts a remote value that hasn't been
applied locally yet (or can't be). (2) means applying a remote value doesn't
echo it back. Records missing from a projection are tombstoned, unless the
collection is grow-only. A collection missing from the projection entirely is
"unknown" and skipped.

Ordered collections: sources list items per parent in local order. If a list
is unchanged since last time, its items keep their previous order keys. If it
changed, the engine keeps the merged doc's keys for the longest run of items
already in order (longest increasing subsequence) and mints keys for the rest
between their neighbors (`SyncOrdering.assignKeys`). Ties (two devices minting
the same key) sort by item id. Appending steps the last key digit, so keys stay
short.

### Applying (log → local)

After merging remote batches the engine hands each source a `SyncUpdate`:
the merged doc, which keys/parents changed, and `expected` (the last
projection it diffed). Sources apply inside their own transaction with
compare-and-set helpers:

- `fieldsToApply(col, key, current:)`: merged values for fields whose local
  value still equals `expected` (the user hasn't edited them since the engine
  looked; if they have, that edit is written next round with a newer clock).
- `shouldDelete(...)`
- `desiredOrder(col, parent:, local:)`: the merged order, keeping local-only
  (not yet synced) items in place, or nil if the user reordered locally.

Remote values a source can't absorb (e.g. a parked navigation, deleting your
last space) stay "not applied"; the engine retries them every few seconds and
shows the count in the debug UI. It never writes local values over them.

### Joining

The first time a source syncs on a device, the engine applies everything
already in the doc (remote values win for records both sides have, e.g. the
default space `p0`), then treats the result as "already seen" so only
local-only records get written. Records that exist locally but are tombstoned
remotely and were never seen here are revived instead of deleted.

### Persistence

`<data stores>/Sync/engine.json`: device id, clock, cursor (highest seq seen
per device), the document, last projections, outbox, devices seen, recent
conflicts and errors. Saved at most every 5s and on quit. Losing it is safe:
the device rejoins as a new device and merges back in.

## Transport

`SyncTransport` is a dumb, eventually consistent pipe: `publish(batch)` and
`fetch(after: cursor)`. Duplicates and delays are fine.

`FolderSyncTransport` (the only one so far):

```
<folder>/v1/devices/<deviceID>/log-000001.jsonl
```

- One writer per file (each device writes only its own), so file-sync
  conflicts can't happen. Each line is one JSON `SyncBatch`.
- Readers remember byte offsets and only parse complete lines.
- After 500 batches (or 4 MB) a device starts the next generation with a
  **snapshot** batch (its whole merged document) and deletes the old files.
  Readers only read each device's newest generation.
- Polls other devices' files (size + mtime) every 5s; uses `NSFileCoordinator`
  in iCloud Drive and asks for evicted placeholder files to download.
- Default folder: `iCloud Drive/Wowser Sync` (`Wowser Sync (Dev)` for dev
  builds, so they don't mix). Any folder works (Settings → Sync → Choose…).

`InMemorySyncHub` / `InMemorySyncTransport`: tests, with seeded random latency.

## Settings and debugging

Settings → General → Sync: on/off, folder, last sync time, other devices and
when they last wrote, Sync Now. "Debug" shows device id, transport, last
local change / write / check / remote change, batches and changes sent and
received, outbox size, fields not applied here, record counts, recent
conflicts (two devices wrote different values to one field within 30s: who
won), and errors. "Reset Sync State…" makes this device forget its sync state
and rejoin.

Logs: `[Sync] …` lines in the console.

## Testing

Unit tests run under `swift build` (`cd Wowser/Core && swift test --filter Sync`):

- `SyncPrimitivesTests`: HLC, fractional keys, order assignment, merge laws
  (randomized), diff rules, CAS helpers.
- `SyncEngineTests`: a toy source over in-memory transports: convergence,
  conflicts, deletes vs edits, concurrent moves/inserts, joins, restarts,
  outbox retries, compaction, edits during an apply hop, unabsorbable values,
  and a randomized 3-replica fuzz with latency.
- `FolderSyncTransportTests`: the folder format, partial lines, generations,
  delayed writes, engines syncing through a real folder.
- `BrowserSyncTests`: two `BrowserState`s: tabs, spaces, login groups, favorites,
  folders, splits, primary window, parked navigations, and a fuzz.
- `HistoryAutofillSyncTests`.

Two real instances, syncing through a temp folder with 0–2s random latency:

```
scripts/sync_test/run_two.sh [--latency 2] [--no-build] [--keep]
```

Each gets its own `WOWSER_DATA_DIR` and in-memory website data. Environment
variables (also usable by hand):

| Variable | Effect |
|---|---|
| `WOWSER_DATA_DIR` | Use this instead of Application Support for all persisted data |
| `WOWSER_EPHEMERAL_WEBSITE_DATA=1` | In-memory cookies/caches per space |
| `WOWSER_SYNC_FOLDER` | Force sync on, through this local folder (fast polling) |
| `WOWSER_SYNC_LATENCY` | `max` or `min-max` seconds of delay per write |
| `WOWSER_SYNC_DEVICE_NAME` | Name shown to other devices |
| `WOWSER_MCP_PORT` | MCP server port (the script uses 48301 / 48302) |

The instances share UserDefaults (same bundle id), so UI preferences are
shared; sync's own settings come from the environment.

## Adding something to sync

1. Pick records: a collection name, stable keys, flat fields of JSON values.
   Use `SyncValue(date)` for dates (exact round-trip).
2. Write `project()` (pure: same state → same projection; no I/O in getters)
   and `apply(update)` using `fieldsToApply` / `shouldDelete` /
   `desiredOrder`. Applying then projecting must give back the merged values,
   or the engine will keep retrying.
3. Add a `SyncCollectionSpec` (ordered? grow-only? merge policy?) and either
   extend an existing source or add a `SyncSource` in `WowserSyncSources.swift`
   and register it in `SyncController.start()`.
4. Add a test next to `BrowserSyncTests` and a row to the table above.

## Not yet

- Tombstones are kept forever (small, but they add up).
- Custom space background images, saved logins/passwords (would need
  encryption or iCloud Keychain), non-primary windows.
- Visit counts take the max across devices rather than summing.
- Transports other than a folder (CloudKit, a server).
