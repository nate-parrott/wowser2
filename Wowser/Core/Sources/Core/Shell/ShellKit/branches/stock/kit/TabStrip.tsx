import { memo, Row, Pressable, Spacer, Text, Icon, TabIcon, WindowControls, useTabs, useSpaces, tabs, useContextMenu, type TabInfo } from "wowser";
import { IconButton } from "./IconButton";
import { tabMenu } from "./tabMenu";

/** One horizontal tab. Shares free width with its siblings, up to `maxWidth`. */
export const StripTab = memo(function StripTab({ tab, compact, spaces }: { tab: TabInfo; compact?: boolean; spaces: any[] }) {
  const menu = useContextMenu(tabMenu(tab, spaces));
  const on = tab.isCurrent;
  return (
    <Pressable
      testID={"tab-" + tab.id}
      group
      role="tab"
      label={tab.title}
      tooltip={tab.title}
      style={{
        flex: compact ? undefined : 1,
        minWidth: compact ? undefined : 44,
        maxWidth: compact ? undefined : 220,
        width: compact ? 36 : undefined,
        height: 30,
        gap: 7,
        align: "center",
        justify: compact ? "center" : "start",
        padding: { left: compact ? 0 : 9, right: compact ? 0 : 5 },
        cornerRadius: { topLeft: 9, topRight: 9 },
        background: on ? "background" : "clear",
        animate: { type: "ease", duration: 0.12 },
        hover: on ? {} : { background: "primary/0.07" },
        dropTarget: { border: { color: "accent", width: 2 } },
      }}
      onPress={(e) => tabs.select(tab.id, { modifiers: e.modifiers })}
      draggable={{ type: "tab", id: tab.id }}
      dropTypes={["tab", "url"]}
      onDrop={(e) => {
        if (e.type === "tab" && e.id) {
          // Drop on the trailing half → after this tab.
          const list = tabs.visibleOrder();
          const after = e.x > e.width / 2 ? list[list.indexOf(tab.id) + 1] : tab.id;
          return tabs.move(e.id, { to: tab.isPinned ? "pinned" : "tabs", before: after });
        }
        if (e.type === "url" && e.url) {
          tabs.create({ url: e.url });
          return true;
        }
        return false;
      }}
      {...menu}
    >
      <TabIcon tabId={tab.id} size={16} style={{ opacity: tab.isUnloaded ? 0.55 : 1 }} />
      {compact ? null : (
        <Text style={{ flex: 1, fontSize: 12, lineLimit: 1, opacity: on ? 1 : 0.8 }}>{tab.title}</Text>
      )}
      {compact ? null : (
        <Pressable
          testID={"close-" + tab.id}
          tooltip="Close Tab"
          style={{
            width: 18,
            height: 18,
            align: "center",
            justify: "center",
            cornerRadius: 9,
            opacity: on ? 0.7 : 0,
            groupHover: { opacity: 0.7 },
            hover: { background: "primary/0.12", opacity: 1 },
          }}
          onPress={() => tabs.close(tab.id)}
        >
          <Icon name="xmark" size={8} weight="heavy" />
        </Pressable>
      )}
    </Pressable>
  );
});

/**
 * A horizontal tab strip that doubles as the window's title bar: pinned tabs
 * as compact icons, then tabs, then "+". Empty space drags the window.
 */
export function TabStrip({ windowControls = true }: { windowControls?: boolean }) {
  const strip = useTabs();
  const spaces = useSpaces();
  return (
    <Row
      testID="tab-strip"
      windowDrag
      style={{ height: 38, align: "end", padding: { left: 6, right: 8 }, gap: 1 }}
      dropTypes={["tab", "url"]}
      onDrop={(e) => {
        if (e.type === "tab" && e.id) return tabs.move(e.id, { to: "tabs" });
        if (e.type === "url" && e.url) {
          tabs.create({ url: e.url });
          return true;
        }
        return false;
      }}
    >
      {windowControls ? <WindowControls style={{ margin: { bottom: 2, right: 6 } }} /> : null}
      {strip.pinned.map((t) => (
        <StripTab key={t.id} tab={t} compact spaces={spaces} />
      ))}
      {strip.tabs.map((t) => (
        <StripTab key={t.id} tab={t} spaces={spaces} />
      ))}
      <IconButton testID="new-tab" icon="plus" size={11} tooltip="New Tab" style={{ width: 26, height: 26, margin: { bottom: 2, left: 3 } }} onPress={() => tabs.create()} />
      <Spacer style={{ minWidth: 40 }} />
    </Row>
  );
}
