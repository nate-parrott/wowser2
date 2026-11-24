import { Row, Pressable, Stack, Text, useSpaces, spaces, tabs } from "wowser";

/** One dot per space; click to switch, drop a tab to move it there. */
export function SpaceDots() {
  const list = useSpaces();
  if (list.length < 2) return null;
  return (
    <Row style={{ justify: "center", padding: { top: 4, bottom: 8 } }}>
      {list.map((s) => (
        <Pressable
          key={s.id}
          testID={"space-" + s.id}
          tooltip={s.name}
          label={s.name}
          style={{
            width: 26,
            height: 26,
            align: "center",
            justify: "center",
            cornerRadius: 13,
            background: s.isCurrent ? { material: "glass" } : "clear",
            animate: "bouncy",
            hover: { scale: 1.3 },
            dropTarget: { scale: 1.3, border: { color: "accent", width: 2 } },
          }}
          onPress={() => spaces.activate(s.id)}
          draggable={{ type: "space", id: s.id }}
          dropTypes={["tab", "space"]}
          onDrop={(e) => {
            if (e.type === "space" && e.id) spaces.move(e.id, s.id);
            else if (e.type === "tab" && e.id) tabs.move(e.id, { to: "space", spaceId: s.id });
            return true;
          }}
        >
          {s.emoji ? (
            <Text style={{ fontSize: 12 }}>{s.emoji}</Text>
          ) : (
            <Stack style={{ width: 6, height: 6, cornerRadius: 3, background: s.isCurrent ? "accent" : "secondary/0.4" }} />
          )}
        </Pressable>
      ))}
    </Row>
  );
}
