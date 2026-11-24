import { Column, Row, Pressable, Text, Icon, Favicon, useStorage, useTab, tabs, readSlice, type DropEvent } from "wowser";

interface Saved {
  url: string;
  title: string;
}

/**
 * "Read later": drop a tab or a link on it to save the page; click to open,
 * × to remove. Lives in this branch's storage, so it survives restarts.
 */
export function ReadingList() {
  const [items, setItems] = useStorage<Saved[]>("readingList", []);

  const add = (url: string, title: string) => {
    if (!items.some((i) => i.url === url)) setItems([{ url, title }, ...items]);
  };
  const onDrop = (e: DropEvent) => {
    if (e.type === "url" && e.url) add(e.url, e.url);
    if (e.type === "tab" && e.id) {
      // A dropped tab is an id; look the tab up to get its page.
      const tab = readSlice("tab", { id: e.id });
      if (tab && tab.url) {
        add(tab.url, tab.title);
        tabs.close(e.id);
      }
    }
  };

  return (
    <Column
      testID="reading-list"
      style={{ align: "stretch", margin: 6, padding: 6, gap: 2, cornerRadius: 10, background: "primary/0.04", dropTarget: { background: "accent/0.15", border: { color: "accent", width: 2 } }, animate: true }}
      dropTypes={["tab", "url"]}
      onDrop={onDrop}
    >
      <Row style={{ gap: 6, align: "center", padding: [2, 4] }}>
        <Icon name="bookmark" size={10} weight="semibold" style={{ color: "secondary" }} />
        <Text style={{ flex: 1, fontSize: 11, fontWeight: "semibold", color: "secondary" }}>Read Later</Text>
      </Row>
      {items.length === 0 ? <Text style={{ fontSize: 11, color: "tertiary", padding: [4, 4] }}>Drop tabs or links here</Text> : null}
      {items.map((item) => (
        <Pressable
          key={item.url}
          group
          testID={"saved-" + item.url}
          style={{ height: 26, gap: 8, align: "center", padding: { horizontal: 4 }, cornerRadius: 6, hover: { background: "primary/0.06" } }}
          onPress={() => tabs.create({ url: item.url })}
        >
          <Favicon url={item.url} size={14} />
          <Text style={{ flex: 1, fontSize: 12, lineLimit: 1 }}>{item.title}</Text>
          <Pressable
            testID={"unsave-" + item.url}
            style={{ padding: 4, cornerRadius: 99, opacity: 0, groupHover: { opacity: 1 }, hover: { background: "primary/0.1" } }}
            onPress={() => setItems(items.filter((i) => i.url !== item.url))}
          >
            <Icon name="xmark" size={8} weight="heavy" />
          </Pressable>
        </Pressable>
      ))}
    </Column>
  );
}
void useTab;
