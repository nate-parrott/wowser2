import { useStorage, useHotkey } from "wowser";

export default function ZenMode({ hotkey = "cmd+shift+." }: { hotkey?: string }) {
  const [zen, setZen] = useStorage("zen", false);
  useHotkey(hotkey, () => setZen(!zen));
  return { zen, setZen };
}
