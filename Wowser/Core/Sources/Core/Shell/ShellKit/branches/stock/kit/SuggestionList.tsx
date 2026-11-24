import { Column, Pressable, Text, Icon, Favicon, Stack, type Suggestion, type BoxStyle } from "wowser";
import type { CommandBarController } from "./commandBar";

export function SuggestionIcon({ s, size = 20 }: { s: Suggestion; size?: number }) {
  const icon = s.icon;
  if (icon.kind === "favicon") return <Favicon url={icon.url} size={size - 4} style={{ width: size, height: size }} />;
  if (icon.kind === "emoji") return <Text style={{ fontSize: size - 6, width: size, textAlign: "center" }}>{icon.value}</Text>;
  return (
    <Stack style={{ width: size, height: size, align: "center" }}>
      <Icon name={icon.kind === "symbol" ? icon.name : "globe"} size={size - 7} weight="medium" />
    </Stack>
  );
}

/** Suggestion rows for a command bar: selected row wears the accent. */
export function SuggestionList({ bar, style }: { bar: CommandBarController; style?: BoxStyle }) {
  if (!bar.suggestions.length) return null;
  return (
    <Column style={{ padding: 10, align: "stretch", ...style }}>
      {bar.suggestions.map((s, i) => {
        const on = i === bar.selected;
        return (
          <Pressable
            key={s.id}
            testID={"suggestion-" + i}
            style={{
              gap: 12,
              padding: 8,
              align: "center",
              cornerRadius: 8,
              background: on ? "accent" : "clear",
              color: on ? "onAccent" : "primary",
              hover: on ? {} : { background: "accent/0.1" },
            }}
            onPress={(e) => bar.choose(s, { newTab: e.modifiers.cmd })}
          >
            <SuggestionIcon s={s} />
            <Text style={{ fontSize: 14, lineLimit: 1, layoutPriority: 2 }}>{s.title}</Text>
            {s.subtitle ? <Text style={{ fontSize: 12, lineLimit: 1, opacity: 0.5, flex: 1 }}>{s.subtitle}</Text> : null}
          </Pressable>
        );
      })}
    </Column>
  );
}
