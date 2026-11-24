# Examples

Small, self-contained customisations. Each one is here to be copied from —
and to prove the primitives are enough for it. A view is a template
(`Name.xml`) plus, when it needs one, a logic file (`Name.ts`). Use one by
writing its tag in a layout, e.g. in `layouts/ClassicKit.xml`:

    <Sidebar>
      <Clock/>
    </Sidebar>

| File | What it shows |
| --- | --- |
| Clock | A live widget: `useNow`, text styling |
| TabSearch | A hotkey-opened overlay: `useHotkey`, `TextInput`, filtering tabs |
| ZenMode | Hide all chrome until the pointer nears an edge: hover zones, `animate` |
| DomainGroups | Tabs grouped by site with collapsible headers: derived data, `useStorage` |
| StatusBar (template only) | A bottom bar with progress, zoom and counts: `usePane`, actions |
| SpeedDial | A top-sites grid for empty tabs: `search.topSites()` |
| ReadingList | A drop target that saves links: drag & drop, `useStorage` |
| WebPanels (template only) | A sidebar web panel (Vivaldi-style): `<WebIsland src="https://…">` |
| Orb (template only) + widgets/orb.html | A canvas animation in the chrome: `<WebIsland>` with props and messages |
| behaviours.ts | No UI at all: redirects, per-site CSS, commands — from `setup()` |
