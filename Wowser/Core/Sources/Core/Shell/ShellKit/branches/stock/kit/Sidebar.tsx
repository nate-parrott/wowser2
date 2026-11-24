import {
  Column, Row, Stack, Spacer, ScrollView, Pressable, Text, Icon, WindowControls,
  useSetting, useSpace, useTabs, useRef, window, tabs, type Children,
} from "wowser";
import { Favorites } from "./Favorites";
import { TabList } from "./TabList";
import { SpaceDots } from "./SpaceDots";
import { ghostButton, clamp, SIDEBAR_DEFAULT, SIDEBAR_MIN, SIDEBAR_MAX } from "./theme";

export function useSidebarWidth(): [number, (w: number) => void] {
  const [stored, set] = useSetting<number>("sidebarWidth");
  return [clamp(stored ?? SIDEBAR_DEFAULT, SIDEBAR_MIN, SIDEBAR_MAX), (w) => set(clamp(w, SIDEBAR_MIN, SIDEBAR_MAX))];
}

/** Drag strip on the sidebar's trailing edge. */
function ResizeHandle() {
  const [width, setWidth] = useSidebarWidth();
  const start = useRef(width);
  return (
    <Stack
      style={{ alignSelf: "trailing", width: 6, height: "fill", cursor: "resizeLeftRight", pressed: { background: "primary/0.15" } }}
      onPan={(e) => {
        if (e.phase === "began") start.current = width;
        else setWidth(start.current + e.dx);
      }}
    />
  );
}

function Header() {
  const space = useSpace();
  return (
    <Row style={{ padding: 6, gap: 4, align: "center" }} windowDrag>
      <WindowControls />
      {space ? (
        <Row style={{ flex: 1, gap: 5, align: "center" }}>
          <Text style={{ fontSize: 12 }}>{space.emoji ?? ""}</Text>
          <Text style={{ fontSize: 11, fontWeight: "semibold", color: "secondary", lineLimit: 1 }}>{space.name}</Text>
        </Row>
      ) : (
        <Spacer />
      )}
      <Pressable
        testID="toggle-sidebar"
        tooltip="Toggle Sidebar"
        style={{ ...ghostButton, width: 26, height: 26 }}
        onPress={() => window.toggleSidebar()}
      >
        <Icon name="sidebar.left" size={12} weight="medium" />
      </Pressable>
    </Row>
  );
}

function NewTabRow() {
  return (
    <Pressable
      testID="new-tab"
      style={{
        height: 34,
        margin: [2, 6],
        padding: { left: 8 },
        gap: 8,
        align: "center",
        cornerRadius: 8,
        color: "secondary",
        hover: { background: "primary/0.07" },
      }}
      onPress={() => tabs.create()}
    >
      <Icon name="plus" size={12} weight="medium" />
      <Text style={{ fontSize: 13 }}>New Tab</Text>
    </Pressable>
  );
}

/**
 * A vertical sidebar built from primitives: header, favorites, tabs, space
 * dots. `children` are inserted between the tab list and the dots — the spot
 * for your own widgets.
 */
export function Sidebar({ children, header = true }: { children?: Children; header?: boolean }) {
  const [width] = useSidebarWidth();
  const { currentTabId } = useTabs();
  return (
    <Stack style={{ width, height: "fill" }}>
      <Column style={{ flex: 1, align: "stretch" }}>
        {header ? <Header /> : null}
        <Favorites />
        <ScrollView style={{ flex: 1 }} scrollTo={currentTabId} contentStyle={{ align: "stretch" }}>
          <TabList />
          <NewTabRow />
        </ScrollView>
        {children}
        <SpaceDots />
      </Column>
      <ResizeHandle />
    </Stack>
  );
}
