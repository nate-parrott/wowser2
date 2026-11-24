import { useTabs, useStorage, type TabInfo } from "wowser";

function domainOf(tab: TabInfo): string {
  if (!tab.url) return "Other";
  const m = /^[a-z]+:\/\/(?:www\.)?([^/:]+)/i.exec(tab.url);
  if (!m) return "Other";
  const parts = m[1].split(".");
  return parts.length > 2 ? parts.slice(-2).join(".") : m[1];
}

export default function DomainGroups() {
  const strip = useTabs();
  const [collapsed, setCollapsed] = useStorage<string[]>("collapsedDomains", []);
  const byDomain = new Map<string, TabInfo[]>();
  for (const tab of strip.tabs) {
    const d = domainOf(tab);
    byDomain.set(d, [...(byDomain.get(d) ?? []), tab]);
  }
  return {
    groups: [...byDomain.entries()].map(([domain, tabs]) => ({ domain, tabs, closed: collapsed.includes(domain) })),
    toggle: (d: string) => setCollapsed(collapsed.includes(d) ? collapsed.filter((x) => x !== d) : [...collapsed, d]),
  };
}
