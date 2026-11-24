import { Row, Pressable, Text, Icon, TextInput, commandBar, type BoxStyle } from "wowser";
import type { CommandBarController } from "./commandBar";

/**
 * The URL display in a toolbar. Idle: the site name; click to edit. While
 * the command bar is open it becomes the text field. Pair it with
 * <SuggestionList bar={bar}/> placed wherever the results should appear.
 */
export function AddressField({ bar, style, fontSize = 12 }: { bar: CommandBarController; style?: BoxStyle; fontSize?: number }) {
  const pane = bar.pane;
  if (bar.open) {
    return (
      <Row style={{ flex: 1, gap: 6, align: "center", padding: { horizontal: 8 }, ...style }}>
        <Icon name="magnifyingglass" size={fontSize} weight="medium" style={{ opacity: 0.5 }} />
        <TextInput
          testID="address-input"
          autoFocus
          selectAllOnFocus
          value={bar.query}
          placeholder="Search or enter address"
          onChangeText={bar.setQuery}
          onKey={bar.onKey}
          onSubmit={bar.submit}
          onBlur={() => commandBar.close()}
          style={{ flex: 1, fontSize }}
        />
      </Row>
    );
  }
  return (
    <Pressable
      testID="address"
      style={{ flex: 1, gap: 6, align: "center", padding: { horizontal: 8 }, cursor: "text", ...style }}
      onPress={() => commandBar.open({ prefillURL: true })}
      tooltip={pane?.url ?? undefined}
    >
      {pane && pane.url ? (
        <Icon name={pane.isSecure ? "lock.fill" : "lock.open.fill"} size={fontSize - 2} style={{ opacity: 0.33 }} />
      ) : null}
      <Text style={{ fontSize, lineLimit: 1, truncate: "middle" }}>{pane?.displayURL ?? ""}</Text>
    </Pressable>
  );
}
