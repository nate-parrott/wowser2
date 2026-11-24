import { Column, Row, Stack, Text, Icon, Pressable, useToasts, toasts, type BaseStyle } from "wowser";

/** Toast cards for this window, newest on top. */
export function Toasts({ style }: { style?: BaseStyle }) {
  const list = useToasts();
  return (
    <Column style={{ padding: 16, gap: 8, align: "end", animate: { type: "spring", duration: 0.2, bounce: 0.4 }, ...style }}>
      {list.slice(0, 3).map((t) => (
        <Row
          key={t.id}
          testID={"toast-" + t.id}
          style={{
            width: 320,
            padding: 10,
            gap: 10,
            align: "center",
            cornerRadius: 16,
            background: { material: "glass" },
            transition: { type: "move", edge: "top" },
          }}
        >
          <Stack style={{ width: 26, height: 26, align: "center", cornerRadius: 8, background: "accent", color: "white" }}>
            <Icon name={t.icon} size={13} weight="semibold" />
          </Stack>
          <Column style={{ flex: 1, align: "start", gap: 2 }}>
            {t.title ? <Text style={{ fontSize: 11, fontWeight: "semibold", color: "secondary" }}>{t.title}</Text> : null}
            <Text style={{ fontSize: 13, lineLimit: 3 }}>{t.message}</Text>
            {t.actions.length ? (
              <Row style={{ gap: 6, padding: { top: 4 } }}>
                {t.actions.map((title, i) => (
                  <Pressable
                    key={i}
                    style={{
                      padding: [4, 10],
                      cornerRadius: 99,
                      fontSize: 12,
                      fontWeight: "semibold",
                      background: i === 0 ? "accent" : "primary/0.12",
                      color: i === 0 ? "white" : "primary",
                      hover: { opacity: 0.9 },
                    }}
                    onPress={() => toasts.performAction(t.id, i)}
                  >
                    <Text>{title}</Text>
                  </Pressable>
                ))}
              </Row>
            ) : null}
          </Column>
          <Pressable
            testID={"dismiss-" + t.id}
            style={{ width: 26, height: 26, align: "center", justify: "center", cornerRadius: 13, background: "primary/0.2", hover: { background: "primary/0.35" } }}
            onPress={() => toasts.dismiss(t.id)}
          >
            <Icon name="xmark" size={10} weight="bold" />
          </Pressable>
        </Row>
      ))}
    </Column>
  );
}
