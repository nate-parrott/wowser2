import { tabs, panes, clipboard, spaces as spacesApi, type MenuEntry, type TabInfo, type SpaceInfo } from "wowser";

/** The context menu for a tab, as data. Edit freely — it's just a list. */
export function tabMenu(tab: TabInfo, spaces: SpaceInfo[] = []): MenuEntry[] {
  const others = spaces.filter((s) => !s.isCurrent);
  return [
    tab.url && { title: "Copy Link", icon: "link", onSelect: () => clipboard.writeText(tab.url!) },
    tab.isSplit && { title: "Separate Split Tabs", onSelect: () => tabs.separateSplit(tab.id) },
    { title: "Duplicate", icon: "plus.square.on.square", onSelect: () => tabs.duplicate(tab.id) },
    tab.hasCustomTitle && { title: "Clear Custom Title", onSelect: () => tabs.rename(tab.id, null) },
    tab.isPinned
      ? { title: "Unpin", icon: "pin.slash", onSelect: () => tabs.unpin(tab.id) }
      : { title: "Pin", icon: "pin", onSelect: () => tabs.pin(tab.id) },
    {
      title: tab.isPip ? "Turn Off Picture in Picture" : "Open as Picture in Picture",
      icon: "pip",
      onSelect: () => tabs.setPip(tab.id, !tab.isPip),
    },
    others.length > 0 && {
      title: "Move to Space",
      children: others.map((s) => ({
        title: (s.emoji ? s.emoji + " " : "") + s.name,
        onSelect: () => tabs.move(tab.id, { to: "space", spaceId: s.id }),
      })),
    },
    "-",
    tab.focusedPaneId && { title: "Reload", icon: "arrow.clockwise", onSelect: () => panes.reload(tab.focusedPaneId!) },
    { title: "Close Tab", icon: "xmark", destructive: true, onSelect: () => tabs.close(tab.id) },
  ];
}
void spacesApi;
