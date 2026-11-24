import { memo, Pressable, Row, Column, Text, Icon, TabIcon, tabs, useContextMenu, type DropEvent, type TabInfo } from "wowser";
import { TAB_HEIGHT } from "./theme";
import { tabMenu } from "./tabMenu";

const accessory = {
  padding: 6,
  cornerRadius: 99,
  color: "secondary",
  hover: { background: "primary/0.1" },
} as const;

/** One row of the vertical tab list, written with primitives so it can be
 *  restyled: 34pt pill, glass when selected, close button on hover. */
export const TabRow = memo(function TabRow({ tab }: { tab: TabInfo }) {
  const menu = useContextMenu(tabMenu(tab));
  const dim = tab.isGhost || tab.isUnloaded;

  const onDrop = (e: DropEvent) => {
    if (e.type === "tab" && e.id) return tabs.move(e.id, { to: "tabs", before: tab.id });
    if (e.type === "url" && e.url) {
      tabs.create({ url: e.url, activate: false });
      return true;
    }
    return false;
  };

  return (
    <Pressable
      testID={"tab-" + tab.id}
      anchorId={tab.id}
      group
      role="tab"
      label={tab.title}
      tooltip={tab.title}
      style={{
        height: TAB_HEIGHT,
        margin: [2, 6],
        padding: { left: 8, right: 4 },
        gap: 8,
        align: "center",
        cornerRadius: 8,
        background: tab.isCurrent ? { material: "glass", tint: "accent/0.5" } : "clear",
        dropTarget: { border: { color: "accent", width: 2 } },
      }}
      onPress={(e) => tabs.select(tab.id, { modifiers: e.modifiers })}
      draggable={{ type: "tab", id: tab.id }}
      dropTypes={["tab", "url"]}
      onDrop={onDrop}
      {...menu}
    >
      <TabIcon tabId={tab.id} size={16} style={{ opacity: dim ? 0.55 : 1 }} />
      <Column style={{ flex: 1, align: "start", gap: 1 }}>
        <Text style={{ fontSize: 13, lineLimit: 1, italic: tab.hasCustomTitle, opacity: dim ? 0.65 : 1 }}>
          {tab.title}
        </Text>
        {tab.subtitle ? (
          <Text style={{ fontSize: 10, color: "secondary", lineLimit: 1 }}>{tab.subtitle}</Text>
        ) : null}
      </Column>
      <Row style={{ gap: 2, opacity: 0, groupHover: { opacity: 1 } }}>
        {tab.isSplit ? (
          <Pressable style={accessory} tooltip="Separate Split Tabs" onPress={() => tabs.separateSplit(tab.id)}>
            <Icon name="arrow.trianglehead.branch" size={9} weight="heavy" />
          </Pressable>
        ) : null}
        <Pressable style={accessory} tooltip="Close Tab" testID={"close-" + tab.id} onPress={() => tabs.close(tab.id)}>
          <Icon name="xmark" size={9} weight="heavy" />
        </Pressable>
      </Row>
    </Pressable>
  );
});
