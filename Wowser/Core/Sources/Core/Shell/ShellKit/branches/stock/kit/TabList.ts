import { useTabs, type TabInfo, type SpaceId } from "wowser";

/** Split a tab list into runs that share an AI group name. Groups only show
 *  once there are enough tabs for them to help. */
export function groupTabs(list: TabInfo[], minCount = 5): { name: string | null; tabs: TabInfo[] }[] {
  if (list.length === 0) return [];
  if (list.length < minCount) return [{ name: null, tabs: list }];
  const out: { name: string | null; tabs: TabInfo[] }[] = [];
  for (const t of list) {
    const last = out[out.length - 1];
    if (last && last.name === t.group) last.tabs.push(t);
    else out.push({ name: t.group, tabs: [t] });
  }
  return out;
}

export default function TabList({ spaceId }: { spaceId?: SpaceId }) {
  return { groups: groupTabs(useTabs(spaceId).tabs) };
}
