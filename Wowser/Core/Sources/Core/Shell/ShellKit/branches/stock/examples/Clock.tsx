import { Column, Text, useNow } from "wowser";

/** A small clock for the sidebar. Re-renders once a second — just this
 *  component, nothing around it. */
export function Clock() {
  const now = new Date(useNow(1000));
  const time = now.toLocaleTimeString([], { hour: "numeric", minute: "2-digit" });
  const date = now.toLocaleDateString([], { weekday: "long", month: "short", day: "numeric" });
  return (
    <Column testID="clock" style={{ padding: [8, 12], align: "start", gap: 1 }}>
      <Text style={{ fontSize: 22, fontWeight: "semibold", fontDesign: "rounded", monospacedDigits: true }}>{time}</Text>
      <Text style={{ fontSize: 11, color: "secondary" }}>{date}</Text>
    </Column>
  );
}
