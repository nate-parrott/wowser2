import { useStorage, tabs, readSlice, type DropEvent } from "wowser";

interface Saved {
  url: string;
  title: string;
}

export default function ReadingList() {
  const [items, setItems] = useStorage<Saved[]>("readingList", []);
  const add = (url: string, title: string) => {
    if (!items.some((i) => i.url === url)) setItems([{ url, title }, ...items]);
  };
  return {
    items,
    remove: (url: string) => setItems(items.filter((i) => i.url !== url)),
    drop(e: DropEvent) {
      if (e.type === "url" && e.url) add(e.url, e.url);
      if (e.type === "tab" && e.id) {
        // A dropped tab is an id; look the tab up to get its page.
        const tab = readSlice("tab", { id: e.id });
        if (tab && tab.url) {
          add(tab.url, tab.title);
          tabs.close(e.id);
        }
      }
    },
  };
}
