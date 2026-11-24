# Examples

Small, self-contained customisations. Each one is here to be copied from —
and to prove the primitives are enough for it. Try one by importing it into
a layout, e.g. in `layouts/ClassicKit.tsx`:

    import { Clock } from "../examples/Clock";
    …
    <Sidebar><Clock /></Sidebar>

| File | What it shows |
| --- | --- |
| Clock.tsx | A live widget: `useNow`, text styling |
| TabSearch.tsx | A hotkey-opened overlay: `useHotkey`, `TextInput`, filtering tabs |
| ZenMode.tsx | Hide all chrome until the pointer nears an edge: hover zones, `animate` |
| DomainGroups.tsx | Tabs grouped by site with collapsible headers: derived data, `useStorage` |
| StatusBar.tsx | A bottom bar with progress, zoom and counts: `usePane`, actions |
| SpeedDial.tsx | A top-sites grid for empty tabs: `search.topSites()` |
| ReadingList.tsx | A drop target that saves links: drag & drop, `useStorage` |
| WebPanel.tsx | A sidebar web panel (Vivaldi-style): `<WebIsland src="https://…">` |
| Orb.tsx + widgets/orb.html | A canvas animation in the chrome: `<WebIsland>` with props and messages |
| behaviours.ts | No UI at all: redirects, per-site CSS, commands — from `setup()` |
