// A conventional top-tabs browser: tab strip in the title bar, toolbar
// underneath, bookmarks bar, full-bleed page. Same browser model, different
// arrangement — nothing here is special-cased natively.
import { Column, Row, Stack, Pressable, Text, TabIcon, Menu, Icon, useTabs, useSpaces, useSpace, tabs, spaces } from "wowser";
import { Content, WindowBackground } from "wowser/native";
import { TabStrip } from "../kit/TabStrip";
import { Toolbar } from "../kit/Toolbar";
import { IconButton } from "../kit/IconButton";
import { SuggestionList } from "../kit/SuggestionList";
import { CommandBarScrim } from "../kit/CommandBar";
import { Toasts } from "../kit/Toasts";
import { useCommandBar } from "../kit/commandBar";

/** Pinned tabs, drawn as a bookmarks bar. */
function BookmarksBar() {
  const { pinned } = useTabs();
  if (!pinned.length) return null;
  return (
    <Row style={{ height: 28, gap: 2, align: "center", padding: { horizontal: 8 }, background: "background" }}>
      {pinned.map((t) => (
        <Pressable
          key={t.id}
          testID={"bookmark-" + t.id}
          tooltip={t.url ?? t.title}
          style={{
            height: 22,
            gap: 5,
            align: "center",
            padding: { horizontal: 6 },
            cornerRadius: 6,
            maxWidth: 140,
            background: t.isCurrent ? "primary/0.08" : "clear",
            hover: { background: "primary/0.07" },
          }}
          onPress={() => tabs.select(t.id)}
        >
          <TabIcon tabId={t.id} size={14} />
          <Text style={{ fontSize: 11, lineLimit: 1 }}>{t.title}</Text>
        </Pressable>
      ))}
    </Row>
  );
}

/** Spaces as a profile-style menu at the end of the toolbar. */
function SpaceMenu() {
  const all = useSpaces();
  const current = useSpace();
  return (
    <Menu
      tooltip="Spaces"
      items={[
        ...all.map((s) => ({
          title: (s.emoji ? s.emoji + " " : "") + s.name,
          checked: s.isCurrent,
          onSelect: () => spaces.activate(s.id),
        })),
        "-",
        { title: "New Space", icon: "plus", onSelect: () => spaces.create() },
      ]}
      style={{ height: 26, padding: { horizontal: 8 }, gap: 4, align: "center", cornerRadius: 13, background: "accent/0.15", hover: { background: "accent/0.25" } }}
    >
      <Text style={{ fontSize: 11, fontWeight: "medium" }}>{(current?.emoji ? current.emoji + " " : "") + (current?.name ?? "")}</Text>
      <Icon name="chevron.down" size={8} weight="bold" style={{ opacity: 0.6 }} />
    </Menu>
  );
}

export default function Chrome() {
  const bar = useCommandBar();
  const empty = !bar.pane || bar.pane.isEmpty;
  return (
    <Stack style={{ flex: 1 }}>
      {/* The backdrop shows through the tab strip; everything below it is opaque. */}
      <WindowBackground style={{ flex: 1 }} />
      <Column style={{ flex: 1, align: "stretch" }}>
        <TabStrip />
        <Toolbar bar={bar}>
          <SpaceMenu />
          <IconButton icon="star" tooltip="Bookmark This Tab" testID="pin-current" onPress={() => bar.pane && tabs.pin(bar.pane.tabId)} />
        </Toolbar>
        <BookmarksBar />
        <Stack style={{ flex: 1, background: "background" }}>
          <Content toolbar="hidden" style={{ flex: 1 }} />
          {bar.open && !empty ? <CommandBarScrim bar={bar} /> : null}
          {bar.open ? (
            <SuggestionList
              bar={bar}
              style={{
                alignSelf: "top",
                width: 640,
                maxWidth: "fill",
                background: "background",
                cornerRadius: { bottomLeft: 12, bottomRight: 12 },
                shadow: { color: "#000/0.15", radius: 12, y: 4 },
              }}
            />
          ) : null}
          <Toasts style={{ alignSelf: "bottomTrailing" }} />
        </Stack>
      </Column>
    </Stack>
  );
}
