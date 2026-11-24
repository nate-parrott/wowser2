// The same layout as Classic.tsx, with every piece of chrome drawn by the
// kit (primitives) instead of native composites. Only the web content and
// the window backdrop are native. This is the version to fork when you want
// to change how tabs, the toolbar or the command bar look or behave.
import { Row, Column, Stack, Divider, ErrorBoundary, Text, useWindow, useState } from "wowser";
import { Content, WindowBackground } from "wowser/native";
import { Sidebar, useSidebarWidth } from "../kit/Sidebar";
import { Toolbar } from "../kit/Toolbar";
import { SuggestionList } from "../kit/SuggestionList";
import { CommandBar, CommandBarScrim } from "../kit/CommandBar";
import { Toasts } from "../kit/Toasts";
import { useCommandBar } from "../kit/commandBar";
import { HEADER_HEIGHT } from "../kit/theme";

function FloatingSidebar() {
  const [width] = useSidebarWidth();
  const [shown, setShown] = useState(false);
  return (
    <Stack style={{ alignSelf: "leading", align: "leading", height: "fill", width: shown ? width + 18 : 4 }} onHover={setShown}>
      <Stack
        style={{
          width,
          height: "fill",
          cornerRadius: 8,
          background: { material: "ultraThick" },
          border: { color: "primary/0.1", width: 0.5 },
          shadow: { color: "#000/0.12", radius: 8 },
          offset: { x: shown ? 0 : -width - 20 },
          animate: { type: "spring", duration: 0.16, bounce: 0.2 },
        }}
      >
        <Sidebar />
      </Stack>
    </Stack>
  );
}

/** Toolbar + page + command bar for the current tab. */
function Main() {
  const bar = useCommandBar();
  const empty = !bar.pane || bar.pane.isEmpty;
  return (
    <Column style={{ flex: 1, align: "stretch" }}>
      {empty ? null : <Toolbar bar={bar} />}
      <Stack style={{ flex: 1 }}>
        <Content toolbar="hidden" style={{ flex: 1 }} />
        {empty ? (
          // An empty tab is just the command bar, centred.
          <Stack style={{ flex: 1, align: "top", padding: { top: 120, horizontal: 50 } }}>
            <CommandBar bar={bar} />
          </Stack>
        ) : bar.open ? (
          <>
            <CommandBarScrim bar={bar} />
            <SuggestionList
              bar={bar}
              style={{
                alignSelf: "top",
                width: "fill",
                background: "background",
                cornerRadius: { bottomLeft: 8, bottomRight: 8 },
                shadow: { color: "#000/0.12", radius: 8, x: 2, y: 3 },
              }}
            />
          </>
        ) : null}
        <Toasts style={{ alignSelf: "topTrailing" }} />
      </Stack>
    </Column>
  );
}

const broken = (what: string) => (e: Error) =>
  <Text style={{ padding: 12, fontSize: 11, color: "red" }}>{what} failed: {e.message}</Text>;

export default function ClassicKit() {
  const sidebar = useWindow((w) => w.sidebarVisible);
  return (
    <Stack style={{ flex: 1 }}>
      <WindowBackground style={{ flex: 1 }} />
      <Row style={{ flex: 1 }}>
        {sidebar ? (
          <ErrorBoundary fallback={broken("Sidebar")}>
            <Sidebar />
          </ErrorBoundary>
        ) : null}
        {sidebar ? <Divider /> : null}
        <Stack
          style={{
            flex: 1,
            margin: sidebar ? 0 : 8,
            cornerRadius: sidebar ? 0 : 10,
            cornerStyle: "circular",
            clip: true,
            shadow: sidebar ? undefined : { color: "#000/0.1", radius: 3, y: 1 },
          }}
        >
          <ErrorBoundary fallback={broken("Content")}>
            <Main />
          </ErrorBoundary>
        </Stack>
      </Row>
      {sidebar ? null : <FloatingSidebar />}
    </Stack>
  );
}
void HEADER_HEIGHT;
