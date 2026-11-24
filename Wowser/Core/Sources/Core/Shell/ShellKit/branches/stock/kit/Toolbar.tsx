import { Row, Stack, usePane, panes, tabs, type BoxStyle, type Children, type PaneId } from "wowser";
import { IconButton } from "./IconButton";
import { AddressField } from "./AddressField";
import type { CommandBarController } from "./commandBar";
import { HEADER_HEIGHT } from "./theme";

/** Back / forward / reload for one pane. */
export function NavButtons({ paneId }: { paneId: PaneId | null }) {
  const pane = usePane(paneId);
  return (
    <Row>
      <IconButton testID="back" icon="chevron.backward" tooltip="Back" disabled={!pane?.canGoBack} onPress={() => pane && panes.back(pane.id)} />
      <IconButton testID="forward" icon="chevron.forward" tooltip="Forward" disabled={!pane?.canGoForward} onPress={() => pane && panes.forward(pane.id)} />
      <IconButton
        testID="reload"
        icon={pane?.isLoading ? "xmark" : "arrow.clockwise"}
        tooltip={pane?.isLoading ? "Stop" : "Reload"}
        disabled={!pane || pane.isEmpty}
        onPress={() => pane && (pane.isLoading ? panes.stop(pane.id) : panes.reload(pane.id))}
      />
    </Row>
  );
}

/** A thin progress line for the bottom edge of a toolbar. */
export function ProgressLine({ paneId }: { paneId: PaneId | null }) {
  const pane = usePane(paneId);
  const loading = !!pane && pane.isLoading;
  return (
    <Stack
      style={{
        alignSelf: "bottom",
        height: 2,
        width: "fill",
        background: "accent",
        scaleX: loading && pane ? Math.max(0.05, pane.progress) : 1,
        anchor: "leading",
        opacity: loading ? 1 : 0,
        animate: { type: "ease", duration: 0.2 },
      }}
    />
  );
}

/**
 * A toolbar from primitives: nav buttons, the address field, then whatever
 * you pass as `children` (your own buttons). `leading` goes before the nav
 * buttons — e.g. <WindowControls/> or a sidebar toggle.
 */
export function Toolbar({ bar, leading, children, style }: { bar: CommandBarController; leading?: Children; children?: Children; style?: BoxStyle }) {
  const pane = bar.pane;
  return (
    <Stack style={{ height: HEADER_HEIGHT, background: "background", ...style }}>
      <Row style={{ flex: 1, gap: 4, align: "center", padding: { horizontal: 8 } }}>
        {leading}
        <NavButtons paneId={pane ? pane.id : null} />
        <AddressField
          bar={bar}
          style={{ height: 28, cornerRadius: 8, background: "primary/0.06", hover: { background: "primary/0.09" }, focused: { background: "primary/0.04", border: { color: "accent/0.6", width: 1.5 } } }}
        />
        {children}
        <IconButton testID="new-split" icon="rectangle.split.2x1" tooltip="New Split Pane" onPress={() => tabs.create({ inSplit: true })} />
      </Row>
      <Stack style={{ alignSelf: "bottom", height: 1, width: "fill", background: "primary/0.1" }} />
      <ProgressLine paneId={pane ? pane.id : null} />
    </Stack>
  );
}
