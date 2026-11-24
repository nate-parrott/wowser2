import { Column, Row, Stack, Text, TextInput, Icon, TabIcon, Pressable, useState, useTabs, useHotkey, tabs, type TabInfo } from "wowser";

/**
 * A quick switcher: ⌘⇧A opens a palette listing every tab; type to filter,
 * arrows to move, Enter to switch. Place it as the last child of the
 * window's root Stack so it floats above everything.
 */
export function TabSearch({ hotkey = "cmd+shift+a" }: { hotkey?: string }) {
  const [open, setOpen] = useState(false);
  const [query, setQuery] = useState("");
  const [index, setIndex] = useState(0);
  const strip = useTabs();
  useHotkey(hotkey, () => {
    setQuery("");
    setIndex(0);
    setOpen((o) => !o);
  });
  if (!open) return null;

  const q = query.trim().toLowerCase();
  const all: TabInfo[] = [...strip.pinned, ...strip.tabs];
  const matches = q ? all.filter((t) => (t.title + " " + (t.url ?? "")).toLowerCase().includes(q)) : all;
  const selected = Math.min(index, Math.max(0, matches.length - 1));
  const pick = (t: TabInfo | undefined) => {
    if (t) tabs.activate(t.id);
    setOpen(false);
  };

  return (
    <Stack testID="tab-search" style={{ flex: 1, align: "top", padding: { top: 90 }, transition: "opacity" }}>
      <Stack testID="tab-search-scrim" style={{ flex: 1, background: "#000/0.2" }} onPress={() => setOpen(false)} />
      <Column
        style={{ width: 520, align: "stretch", cornerRadius: 14, background: { material: "regular" }, shadow: { color: "#000/0.25", radius: 24, y: 8 }, clip: true }}
      >
        <Row style={{ height: 44, gap: 8, align: "center", padding: { horizontal: 14 } }}>
          <Icon name="magnifyingglass" size={14} style={{ opacity: 0.5 }} />
          <TextInput
            testID="tab-search-input"
            autoFocus
            value={query}
            placeholder={`Search ${all.length} tabs`}
            onChangeText={(t) => {
              setQuery(t);
              setIndex(0);
            }}
            onKey={(e) => {
              if (e.key === "down") setIndex(Math.min(selected + 1, matches.length - 1));
              else if (e.key === "up") setIndex(Math.max(selected - 1, 0));
              else if (e.key === "escape") setOpen(false);
              else return false;
              return true;
            }}
            onSubmit={() => pick(matches[selected])}
            onBlur={() => setOpen(false)}
            style={{ flex: 1, fontSize: 15 }}
          />
        </Row>
        <Column style={{ align: "stretch", padding: 6, maxHeight: 360 }}>
          {matches.slice(0, 9).map((t, i) => (
            <Pressable
              key={t.id}
              testID={"tab-search-row-" + i}
              style={{
                height: 32,
                gap: 10,
                align: "center",
                padding: { horizontal: 8 },
                cornerRadius: 8,
                background: i === selected ? "accent" : "clear",
                color: i === selected ? "onAccent" : "primary",
              }}
              onPress={() => pick(t)}
            >
              <TabIcon tabId={t.id} size={16} />
              <Text style={{ flex: 1, fontSize: 13, lineLimit: 1 }}>{t.title}</Text>
              {t.isCurrent ? <Text style={{ fontSize: 11, opacity: 0.6 }}>current</Text> : null}
            </Pressable>
          ))}
          {matches.length === 0 ? <Text style={{ padding: 12, fontSize: 12, color: "secondary" }}>No tabs match “{query}”</Text> : null}
        </Column>
      </Column>
    </Stack>
  );
}
