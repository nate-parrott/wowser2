import { useGlobalHotkey, window as browserWindow, type TabInfo } from "wowser";
import { useTabPalette } from "./TabSearch";

export default function GlobalSwitcher({ hotkey = "ctrl+alt+space" }: { hotkey?: string }) {
  const palette = useTabPalette();
  // Works while another app is in front.
  useGlobalHotkey(hotkey, palette.toggle);
  return {
    ...palette,
    pick(tab?: TabInfo) {
      palette.pick(tab);
      if (tab) browserWindow.activate();
    },
  };
}
