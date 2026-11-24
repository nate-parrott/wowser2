import { Row, Text, Spacer, Stack, useCurrentPane, useTabs, panes } from "wowser";
import { IconButton } from "../kit/IconButton";

/**
 * A status bar for the bottom of the window: the page's address, load
 * progress, zoom buttons and a tab count. Reads the focused pane, so it
 * re-renders as the page loads — which is why it's its own component.
 */
export function StatusBar() {
  const pane = useCurrentPane();
  const strip = useTabs();
  const loading = !!pane && pane.isLoading;
  return (
    <Stack testID="status-bar" style={{ height: 24, background: "background" }}>
      <Stack style={{ alignSelf: "top", width: "fill", height: 1, background: "primary/0.1" }} />
      <Row style={{ flex: 1, gap: 8, align: "center", padding: { horizontal: 10 }, fontSize: 11, color: "secondary" }}>
        <Text style={{ lineLimit: 1, truncate: "middle", maxWidth: 480 }}>
          {loading ? `Loading ${pane!.displayURL}… ${Math.round(pane!.progress * 100)}%` : pane?.url ?? ""}
        </Text>
        <Spacer />
        <Text style={{ monospacedDigits: true }}>{strip.tabs.length + strip.pinned.length} tabs</Text>
        <Row>
          <IconButton icon="minus.magnifyingglass" size={10} tooltip="Zoom Out" style={{ width: 22, height: 20 }} disabled={!pane} onPress={() => pane && panes.zoomOut(pane.id)} />
          <IconButton icon="plus.magnifyingglass" size={10} tooltip="Zoom In" style={{ width: 22, height: 20 }} disabled={!pane} onPress={() => pane && panes.zoomIn(pane.id)} />
        </Row>
      </Row>
    </Stack>
  );
}
