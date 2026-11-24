import { Stack, Text, WebIsland, useState, useTheme, useCurrentPane } from "wowser";

/**
 * A canvas animation living in the chrome. The drawing happens in a
 * transparent web view (widgets/orb.html) at 60fps without touching the UI
 * thread's JS; this component just feeds it props — the accent colour and
 * whether the page is loading — and listens for clicks it posts back.
 */
export function Orb({ size = 44 }: { size?: number }) {
  const theme = useTheme();
  const loading = useCurrentPane()?.isLoading ?? false;
  const [taps, setTaps] = useState(0);
  return (
    <Stack testID="orb" style={{ width: size, height: size }} tooltip="A WebIsland">
      <WebIsland
        src="examples/widgets/orb.html"
        props={{ color: theme.accent, busy: loading }}
        onMessage={(m) => m && m.type === "tap" && setTaps((n) => n + 1)}
        style={{ flex: 1 }}
      />
      {taps > 0 ? (
        <Text style={{ alignSelf: "bottomTrailing", fontSize: 9, fontWeight: "bold", color: "secondary", monospacedDigits: true }}>{taps}</Text>
      ) : null}
    </Stack>
  );
}
