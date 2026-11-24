import { useState, useTabs, useHotkey, tabs, type KeyEvent, type TabInfo } from "wowser";

export default function TabSearch({ hotkey = "cmd+shift+a" }: { hotkey?: string }) {
  const [open, setOpen] = useState(false);
  const [query, setQueryRaw] = useState("");
  const [index, setIndex] = useState(0);
  const strip = useTabs();
  useHotkey(hotkey, () => {
    setQueryRaw("");
    setIndex(0);
    setOpen((o) => !o);
  });

  const all: TabInfo[] = [...strip.pinned, ...strip.tabs];
  const q = query.trim().toLowerCase();
  const matches = q ? all.filter((t) => (t.title + " " + (t.url ?? "")).toLowerCase().includes(q)) : all;
  const selected = Math.min(index, Math.max(0, matches.length - 1));

  return {
    open,
    query,
    total: all.length,
    matches,
    selected,
    close: () => setOpen(false),
    setQuery(text: string) {
      setQueryRaw(text);
      setIndex(0);
    },
    pick(tab?: TabInfo) {
      if (tab) tabs.activate(tab.id);
      setOpen(false);
    },
    onKey(e: KeyEvent) {
      if (e.key === "down") setIndex(Math.min(selected + 1, matches.length - 1));
      else if (e.key === "up") setIndex(Math.max(selected - 1, 0));
      else if (e.key === "escape") setOpen(false);
      else return false;
      return true;
    },
  };
}
