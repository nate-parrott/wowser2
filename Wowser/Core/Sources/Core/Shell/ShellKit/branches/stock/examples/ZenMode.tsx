import { Column, Stack, useState, useStorage, useHotkey, type Children } from "wowser";

/**
 * Wrap a layout's chrome and its content: in zen mode the chrome slides away
 * and the page takes the whole window; moving the pointer to the top edge
 * brings the chrome back while it's there. ⌘⇧. toggles.
 *
 *   <ZenMode chrome={<><TabStrip/><Toolbar bar={bar}/></>}>
 *     <Content toolbar="hidden" />
 *   </ZenMode>
 */
export function ZenMode({ chrome, children, hotkey = "cmd+shift+." }: { chrome: Children; children: Children; hotkey?: string }) {
  const [zen, setZen] = useStorage("zen", false);
  const [peek, setPeek] = useState(false);
  useHotkey(hotkey, () => setZen(!zen));
  const shown = !zen || peek;
  return (
    <Stack testID="zen" style={{ flex: 1 }}>
      <Column style={{ flex: 1, align: "stretch" }}>
        {/* Out of zen the chrome takes its space; in zen it floats over the page. */}
        {zen ? null : chrome}
        <Stack style={{ flex: 1 }}>{children}</Stack>
      </Column>
      {zen ? (
        <Column
          testID="zen-peek"
          style={{ alignSelf: "top", width: "fill", align: "stretch", minHeight: 6 }}
          onHover={setPeek}
        >
          <Column
            style={{
              align: "stretch",
              background: { material: "bar" },
              shadow: { color: "#000/0.15", radius: 10, y: 3 },
              opacity: shown ? 1 : 0,
              offset: { y: shown ? 0 : -12 },
              animate: { type: "spring", duration: 0.25, bounce: 0.1 },
            }}
          >
            {peek ? chrome : null}
          </Column>
        </Column>
      ) : null}
    </Stack>
  );
}
