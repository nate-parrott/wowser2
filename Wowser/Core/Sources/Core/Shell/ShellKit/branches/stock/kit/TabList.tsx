import { Column, Text, Divider, useTabs, tabs, type TabInfo, type SpaceId } from "wowser";
import { TabRow } from "./TabRow";
import { quick } from "./theme";

/** Split a tab list into runs that share an AI group name. Groups only show
 *  once there are enough tabs for them to help. */
export function groupTabs(list: TabInfo[], minCount = 5): { name: string | null; tabs: TabInfo[] }[] {
  if (list.length < minCount) return [{ name: null, tabs: list }];
  const out: { name: string | null; tabs: TabInfo[] }[] = [];
  for (const t of list) {
    const last = out[out.length - 1];
    if (last && last.name === t.group) last.tabs.push(t);
    else out.push({ name: t.group, tabs: [t] });
  }
  return out;
}

/** The vertical tab list of a space. Put it inside a ScrollView. */
export function TabList({ spaceId, row: RowComponent = TabRow }: { spaceId?: SpaceId; row?: typeof TabRow }) {
  const strip = useTabs(spaceId);
  const groups = groupTabs(strip.tabs);
  return (
    <Column
      style={{ animate: quick, align: "stretch" }}
      dropTypes={["tab"]}
      onDrop={(e) => (e.id ? tabs.move(e.id, { to: "tabs" }) : false)}
    >
      {groups.map((g, i) => (
        <Column key={(g.name ?? "") + ":" + g.tabs[0].id} style={{ align: "stretch" }}>
          {g.name ? (
            <Text style={{ fontSize: 11, fontWeight: "medium", color: "secondary", padding: { top: 12, bottom: 4, left: 12 } }}>
              {g.name}
            </Text>
          ) : i > 0 ? (
            <Divider style={{ margin: [6, 14] }} />
          ) : null}
          {g.tabs.map((t) => (
            <RowComponent key={t.id} tab={t} />
          ))}
        </Column>
      ))}
    </Column>
  );
}
