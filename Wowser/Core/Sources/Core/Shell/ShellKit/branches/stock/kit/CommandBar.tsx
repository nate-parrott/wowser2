import { Column, Row, Stack, Icon, TextInput } from "wowser";
import { SuggestionList } from "./SuggestionList";
import type { CommandBarController } from "./commandBar";

/**
 * A floating command bar card (the look of an empty tab, or a Spotlight-style
 * palette): input row on top, suggestions underneath. Centre it in a Stack.
 */
export function CommandBar({ bar, width = 560 }: { bar: CommandBarController; width?: number }) {
  if (!bar.open) return null;
  return (
    <Column
      testID="command-bar"
      style={{
        width,
        maxWidth: "fill",
        align: "stretch",
        cornerRadius: 10,
        background: { material: "glass" },
        shadow: { color: "#000/0.1", radius: 12 },
        transition: { type: "scale", scale: 0.97 },
      }}
    >
      <Row style={{ height: 42, align: "center", gap: 4, padding: { left: 12, right: 12 }, background: "background", cornerRadius: 10 }}>
        <Icon name="magnifyingglass" size={14} weight="medium" style={{ opacity: 0.5 }} />
        <TextInput
          testID="command-input"
          autoFocus
          selectAllOnFocus
          value={bar.query}
          placeholder="Search or enter address"
          onChangeText={bar.setQuery}
          onKey={bar.onKey}
          onSubmit={bar.submit}
          style={{ flex: 1, fontSize: 14 }}
        />
      </Row>
      <SuggestionList bar={bar} />
    </Column>
  );
}

/** Dims the content behind an open command bar and closes it on click. */
export function CommandBarScrim({ bar }: { bar: CommandBarController }) {
  if (!bar.open) return null;
  return <Stack testID="scrim" style={{ flex: 1, background: "#000/0.001" }} onPress={() => bar.close()} />;
}
