// Everything in examples/ at once, on top of the kit layout. Not a serious
// UI — a place to see the pieces working together.
//
//   // mac/index.tsx
//   export { default, setup } from "../layouts/Playground";
import { Row, Column, Stack, Divider, useWindow } from "wowser";
import { Content, WindowBackground } from "wowser/native";
import { Sidebar } from "../kit/Sidebar";
import { TabStrip } from "../kit/TabStrip";
import { Toolbar } from "../kit/Toolbar";
import { SuggestionList } from "../kit/SuggestionList";
import { CommandBar, CommandBarScrim } from "../kit/CommandBar";
import { Toasts } from "../kit/Toasts";
import { useCommandBar } from "../kit/commandBar";
import { Clock } from "../examples/Clock";
import { ReadingList } from "../examples/ReadingList";
import { TabSearch } from "../examples/TabSearch";
import { StatusBar } from "../examples/StatusBar";
import { SpeedDial } from "../examples/SpeedDial";
import { WebPanels } from "../examples/WebPanel";
import { Orb } from "../examples/Orb";
import { ZenMode } from "../examples/ZenMode";
import { installBehaviours } from "../examples/behaviours";

export function setup() {
  return installBehaviours();
}

export default function Playground() {
  const bar = useCommandBar();
  const sidebar = useWindow((w) => w.sidebarVisible);
  const empty = !bar.pane || bar.pane.isEmpty;
  return (
    <Stack style={{ flex: 1 }}>
      <WindowBackground style={{ flex: 1 }} />
      <Row style={{ flex: 1 }}>
        {sidebar ? (
          <Sidebar>
            <ReadingList />
            <Row style={{ align: "center", padding: { right: 10 } }}>
              <Clock />
              <Stack style={{ flex: 1 }} />
              <Orb />
            </Row>
          </Sidebar>
        ) : null}
        {sidebar ? <Divider /> : null}
        <Column style={{ flex: 1, align: "stretch" }}>
          <ZenMode
            chrome={
              <Column style={{ align: "stretch" }}>
                {sidebar ? null : <TabStrip />}
                {empty ? null : <Toolbar bar={bar} />}
              </Column>
            }
          >
            <Content toolbar="hidden" style={{ flex: 1 }} />
            {empty ? (
              <Column style={{ flex: 1, align: "center", justify: "center", gap: 10 }}>
                <CommandBar bar={bar} />
                <SpeedDial />
              </Column>
            ) : bar.open ? (
              <>
                <CommandBarScrim bar={bar} />
                <SuggestionList bar={bar} style={{ alignSelf: "top", width: "fill", background: "background", shadow: { color: "#000/0.12", radius: 8, y: 3 } }} />
              </>
            ) : null}
            <Toasts style={{ alignSelf: "topTrailing" }} />
          </ZenMode>
          <StatusBar />
        </Column>
        <Divider />
        <WebPanels />
      </Row>
      <TabSearch />
    </Stack>
  );
}
