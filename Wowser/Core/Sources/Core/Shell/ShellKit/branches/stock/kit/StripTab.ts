import { tabs, type DropEvent, type TabInfo } from "wowser";

export default function StripTab({ tab }: { tab: TabInfo }) {
  return {
    /** Dropping on the trailing half of a tab inserts after it. */
    drop(e: DropEvent) {
      if (e.type === "tab" && e.id) {
        const order = tabs.visibleOrder();
        const before = e.x > e.width / 2 ? order[order.indexOf(tab.id) + 1] : tab.id;
        return tabs.move(e.id, { to: tab.isPinned ? "pinned" : "tabs", before });
      }
      if (e.type === "url" && e.url) tabs.create({ url: e.url });
      return true;
    },
  };
}
