import { useState, useEffect, useGlobalHotkey, mouse } from "wowser";

export default function CursorHalo({ hotkey = "ctrl+alt+h", size = 72 }: { hotkey?: string; size?: number }) {
  const [on, setOn] = useState(false);
  const [at, setAt] = useState({ x: 0, y: 0 });
  useGlobalHotkey(hotkey, () => setOn((v) => !v));
  useEffect(() => {
    if (!on) return undefined;
    // Start where the pointer is, then follow it anywhere on screen.
    const now = mouse.location();
    setAt({ x: now.screenX, y: now.screenY });
    return mouse.onGlobalMove(setAt);
  }, [on]);
  return { on, size, x: at.x, y: at.y };
}
