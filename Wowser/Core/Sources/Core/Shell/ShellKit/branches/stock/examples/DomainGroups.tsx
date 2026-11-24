import { Column, Row, Pressable, Text, Icon, Favicon, useTabs, useStorage, tabs, type TabInfo } from "wowser";
import { TabRow } from "../kit/TabRow";

function domainOf(tab: TabInfo): string {
  if (!tab.url) return "Other";
  const m = /^[a-z]+:\/\/(?:www\.)?([^/:]+)/i.exec(tab.url);
  if (!m) return "Other";
  const parts = m[1].split(".");
  return parts.length > 2 ? parts.slice(-2).join(".") : m[1];
}

/**
 * A tab list grouped by site, with collapsible groups and a per-group
 * "close all". A drop-in replacement for kit/TabList: same rows, different
 * grouping. Which groups are collapsed is remembered per branch.
 */
export function DomainGroups() {
  const strip = useTabs();
  const [collapsed, setCollapsed] = useStorage<string[]>("collapsedDomains", []);
  const groups = new Map<string, TabInfo[]>();
  for (const tab of strip.tabs) {
    const d = domainOf(tab);
    groups.set(d, [...(groups.get(d) ?? []), tab]);
  }
  const toggle = (d: string) => setCollapsed(collapsed.includes(d) ? collapsed.filter((x) => x !== d) : [...collapsed, d]);

  return (
    <Column testID="domain-groups" style={{ align: "stretch", animate: { type: "ease", duration: 0.15 } }}>
      {[...groups.entries()].map(([domain, list]) => {
        const closed = collapsed.includes(domain);
        if (list.length === 1) return <TabRow key={list[0].id} tab={list[0]} />;
        return (
          <Column key={domain} style={{ align: "stretch" }}>
            <Pressable
              group
              testID={"group-" + domain}
              style={{ height: 26, gap: 6, align: "center", margin: { top: 6, horizontal: 6 }, padding: { horizontal: 8 }, cornerRadius: 6, hover: { background: "primary/0.05" } }}
              onPress={() => toggle(domain)}
            >
              <Icon name="chevron.forward" size={8} weight="bold" style={{ rotate: closed ? 0 : 90, opacity: 0.5, animate: "snappy" }} />
              <Favicon url={list[0].url} size={12} />
              <Text style={{ flex: 1, fontSize: 11, fontWeight: "semibold", color: "secondary", lineLimit: 1 }}>{domain}</Text>
              <Text style={{ fontSize: 10, color: "secondary", monospacedDigits: true, groupHover: { opacity: 0 } }}>{list.length}</Text>
              <Pressable
                testID={"close-group-" + domain}
                tooltip={`Close ${list.length} tabs`}
                style={{ padding: 4, cornerRadius: 99, opacity: 0, groupHover: { opacity: 1 }, hover: { background: "primary/0.1" } }}
                onPress={() => list.forEach((t) => tabs.close(t.id))}
              >
                <Icon name="xmark" size={8} weight="heavy" />
              </Pressable>
            </Pressable>
            {closed ? null : list.map((t) => <TabRow key={t.id} tab={t} />)}
          </Column>
        );
      })}
    </Column>
  );
}
