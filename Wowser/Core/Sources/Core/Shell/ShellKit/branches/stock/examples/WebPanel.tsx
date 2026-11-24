import { Column, Row, Pressable, Icon, Text, WebIsland, useStorage } from "wowser";

const PANELS = [
  { id: "notes", icon: "note.text", title: "Notes", url: "https://keep.google.com/" },
  { id: "translate", icon: "character.bubble", title: "Translate", url: "https://translate.google.com/" },
  { id: "music", icon: "music.note", title: "Music", url: "https://music.youtube.com/" },
];

/**
 * Web panels, Vivaldi-style: a strip of icons; clicking one opens that site
 * in a narrow column beside the page, as a phone-sized view. The site is a
 * plain web view — it gets no access to the browser.
 */
export function WebPanels({ width = 360 }: { width?: number }) {
  const [openId, setOpenId] = useStorage<string | null>("webPanel", null);
  const open = PANELS.find((p) => p.id === openId) ?? null;
  return (
    <Row testID="web-panels" style={{ height: "fill", align: "stretch" }}>
      {open ? (
        <Column style={{ width, align: "stretch", background: "background" }}>
          <Row style={{ height: 30, gap: 6, align: "center", padding: { horizontal: 10 } }}>
            <Text style={{ flex: 1, fontSize: 11, fontWeight: "semibold", color: "secondary" }}>{open.title}</Text>
          </Row>
          <WebIsland key={open.id} src={open.url} mobile style={{ flex: 1 }} />
        </Column>
      ) : null}
      <Column style={{ width: 38, gap: 4, padding: { vertical: 8 }, align: "center", background: "primary/0.03" }}>
        {PANELS.map((p) => (
          <Pressable
            key={p.id}
            testID={"panel-" + p.id}
            tooltip={p.title}
            style={{ width: 28, height: 28, align: "center", justify: "center", cornerRadius: 7, background: openId === p.id ? "accent/0.2" : "clear", hover: { background: "primary/0.08" } }}
            onPress={() => setOpenId(openId === p.id ? null : p.id)}
          >
            <Icon name={p.icon} size={13} weight="medium" />
          </Pressable>
        ))}
      </Column>
    </Row>
  );
}
