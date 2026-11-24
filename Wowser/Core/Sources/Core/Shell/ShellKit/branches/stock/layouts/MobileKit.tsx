// A phone layout from primitives: page on top, a bottom bar with the address
// and a tabs button, and a sheet of tabs. Same hooks and actions as desktop;
// only the arrangement differs.
import { Column, Row, Stack, Pressable, Text, Icon, ScrollView, TabIcon, useState, useTabs, useWindow, tabs, type TabInfo } from "wowser";
import { Content, WindowBackground } from "wowser/native";
import { AddressField } from "../kit/AddressField";
import { SuggestionList } from "../kit/SuggestionList";
import { NavButtons } from "../kit/Toolbar";
import { useCommandBar } from "../kit/commandBar";

function TabCard({ tab, onPick }: { tab: TabInfo; onPick: () => void }) {
  return (
    <Pressable
      testID={"tab-" + tab.id}
      style={{
        height: 52,
        gap: 12,
        align: "center",
        padding: { horizontal: 14 },
        cornerRadius: 14,
        background: tab.isCurrent ? "accent/0.18" : "primary/0.05",
        pressed: { scale: 0.98 },
        animate: "snappy",
      }}
      onPress={() => {
        tabs.select(tab.id);
        onPick();
      }}
    >
      <TabIcon tabId={tab.id} size={20} />
      <Text style={{ flex: 1, fontSize: 16, lineLimit: 1 }}>{tab.title}</Text>
      <Pressable testID={"close-" + tab.id} style={{ width: 32, height: 32, align: "center", justify: "center" }} onPress={() => tabs.close(tab.id)}>
        <Icon name="xmark" size={12} weight="bold" style={{ opacity: 0.5 }} />
      </Pressable>
    </Pressable>
  );
}

function TabSheet({ onClose }: { onClose: () => void }) {
  const strip = useTabs();
  return (
    <Column
      testID="tab-sheet"
      style={{
        alignSelf: "bottom",
        width: "fill",
        maxHeight: 520,
        align: "stretch",
        cornerRadius: { topLeft: 24, topRight: 24 },
        background: { material: "regular" },
        transition: { type: "move", edge: "bottom" },
      }}
    >
      <Row style={{ padding: [14, 18], align: "center" }}>
        <Text style={{ flex: 1, fontSize: 20, fontWeight: "bold" }}>{strip.tabs.length + strip.pinned.length} Tabs</Text>
        <Pressable testID="sheet-new" style={{ padding: 8 }} onPress={() => { tabs.create(); onClose(); }}>
          <Icon name="plus" size={18} weight="semibold" />
        </Pressable>
      </Row>
      <ScrollView contentStyle={{ gap: 8, padding: { horizontal: 12, bottom: 24 }, align: "stretch" }}>
        {[...strip.pinned, ...strip.tabs].map((t) => (
          <TabCard key={t.id} tab={t} onPick={onClose} />
        ))}
      </ScrollView>
    </Column>
  );
}

export default function MobileKit() {
  const bar = useCommandBar({ limit: 4 });
  const [sheet, setSheet] = useState(false);
  const count = useTabs().tabs.length;
  const paneId = useWindow((w) => w.focusedPaneId);
  return (
    <Stack style={{ flex: 1, animate: { type: "spring", duration: 0.35, bounce: 0.15 } }}>
      <WindowBackground style={{ flex: 1 }} />
      <Column style={{ flex: 1, align: "stretch" }}>
        <Stack style={{ flex: 1, margin: { horizontal: 6, top: 6 }, cornerRadius: 22, clip: true }}>
          <Content toolbar="hidden" style={{ flex: 1 }} />
        </Stack>
        {bar.open ? <SuggestionList bar={bar} style={{ padding: { horizontal: 10, vertical: 4 } }} /> : null}
        <Row style={{ height: 56, gap: 6, align: "center", padding: { horizontal: 10 } }}>
          {bar.open ? null : <NavButtons paneId={paneId} />}
          <AddressField bar={bar} fontSize={16} style={{ height: 40, cornerRadius: 20, background: { material: "glass" } }} />
          {bar.open ? null : (
            <Pressable
              testID="tabs-button"
              style={{ width: 40, height: 40, align: "center", justify: "center", cornerRadius: 20, background: { material: "glass", interactive: true } }}
              onPress={() => setSheet(true)}
            >
              <Text style={{ fontSize: 13, fontWeight: "bold", monospacedDigits: true }}>{count}</Text>
            </Pressable>
          )}
        </Row>
      </Column>
      {sheet ? <Stack testID="sheet-scrim" style={{ flex: 1, background: "#000/0.25", transition: "opacity" }} onPress={() => setSheet(false)} /> : null}
      {sheet ? <TabSheet onClose={() => setSheet(false)} /> : null}
    </Stack>
  );
}
