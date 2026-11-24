import { memo, Row, Column, Pressable, TabIcon, useTabs, tabs, useContextMenu, type TabInfo, type SpaceId } from "wowser";
import { tabMenu } from "./tabMenu";

const Cell = memo(function Cell({ tab }: { tab: TabInfo }) {
  const menu = useContextMenu(tabMenu(tab));
  return (
    <Pressable
      testID={"fav-" + tab.id}
      tooltip={tab.title}
      label={tab.title}
      style={{
        flex: 1,
        height: 40,
        align: "center",
        justify: "center",
        cornerRadius: 20,
        background: { material: "glass", tint: tab.isCurrent ? "accent/0.5" : undefined, interactive: true },
        dropTarget: { border: { color: "accent", width: 2 } },
      }}
      onPress={(e) => (tab.isCurrent ? tabs.resetToPinnedURL(tab.id) : tabs.select(tab.id, { modifiers: e.modifiers }))}
      draggable={{ type: "tab", id: tab.id }}
      dropTypes={["tab"]}
      onDrop={(e) => (e.id ? tabs.pin(e.id, tab.id) : false)}
      {...menu}
    >
      <TabIcon tabId={tab.id} size={16} />
    </Pressable>
  );
});

function Placeholder() {
  return (
    <Row
      tooltip="Drag your favorite tabs here"
      style={{
        flex: 1,
        height: 40,
        cornerRadius: 20,
        background: { material: "glass" },
        dropTarget: { border: { color: "accent", width: 2 } },
      }}
      dropTypes={["tab"]}
      onDrop={(e) => (e.id ? tabs.pin(e.id) : false)}
    />
  );
}

/** The grid of pinned tabs: up to `columns` capsules per row. */
export function Favorites({ spaceId, columns = 4 }: { spaceId?: SpaceId; columns?: number }) {
  const { pinned } = useTabs(spaceId);
  const cells: (TabInfo | null)[] = [...pinned];
  while (cells.length < 3) cells.push(null);
  const rows: (TabInfo | null)[][] = [];
  for (let i = 0; i < cells.length; i += columns) rows.push(cells.slice(i, i + columns));
  // Avoid a lonely last cell: borrow one from the row above.
  const last = rows[rows.length - 1];
  const prev = rows[rows.length - 2];
  if (prev && last.length === 1 && prev.length > 2) last.unshift(prev.pop()!);
  return (
    <Column style={{ gap: 8, padding: { horizontal: 8, top: 5, bottom: 10 }, align: "stretch" }}>
      {rows.map((row, i) => (
        <Row key={i} style={{ gap: 8 }}>
          {row.map((tab, j) => (tab ? <Cell key={tab.id} tab={tab} /> : <Placeholder key={"p" + j} />))}
        </Row>
      ))}
    </Column>
  );
}
