// The stock Mac layout: the built-in window, taken apart one level.
//
// Every piece here is the real native view, so this looks and behaves like
// the browser you already have. What JS owns is the *arrangement*: where the
// sidebar sits, what happens when it's hidden, what surrounds the content.
// To go further, swap a native piece for its `kit/` twin (same job, written
// with primitives) — see layouts/ClassicKit.tsx for all of them swapped.
import { Row, Stack, Divider, useWindow, useState } from "wowser";
import { Sidebar, Content, Toasts, WindowBackground } from "wowser/native";
import { useSidebarWidth } from "../kit/Sidebar";

/** With the sidebar hidden, it slides in from the left edge on hover. */
function FloatingSidebar() {
  const [width] = useSidebarWidth();
  const [shown, setShown] = useState(false);
  return (
    <Stack
      style={{ alignSelf: "leading", align: "leading", height: "fill", width: shown ? width + 18 : 4 }}
      onHover={setShown}
    >
      <Stack
        style={{
          width,
          height: "fill",
          offset: { x: shown ? 0 : -width - 20 },
          animate: { type: "spring", duration: 0.16, bounce: 0.2 },
        }}
      >
        <Sidebar floating />
      </Stack>
    </Stack>
  );
}

export default function Classic() {
  const sidebar = useWindow((w) => w.sidebarVisible);
  return (
    <Stack style={{ flex: 1 }}>
      <WindowBackground style={{ flex: 1 }} />
      <Row style={{ flex: 1 }}>
        {sidebar ? <Sidebar /> : null}
        {sidebar ? <Divider /> : null}
        {/* Sidebar hidden → the page becomes an inset rounded card. */}
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
          <Content style={{ flex: 1 }} />
          <Toasts style={{ alignSelf: "topTrailing" }} />
        </Stack>
      </Row>
      {sidebar ? null : <FloatingSidebar />}
    </Stack>
  );
}
