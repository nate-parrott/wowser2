import { useSetting } from "wowser";
import { clamp, SIDEBAR_DEFAULT, SIDEBAR_MIN, SIDEBAR_MAX } from "./theme";

/** The user's sidebar width (shared with the built-in sidebar), clamped. */
export function useSidebarWidth(): [number, (w: number) => void] {
  const [stored, set] = useSetting<number>("sidebarWidth");
  return [clamp(stored ?? SIDEBAR_DEFAULT, SIDEBAR_MIN, SIDEBAR_MAX), (w) => set(clamp(w, SIDEBAR_MIN, SIDEBAR_MAX))];
}

export default function Sidebar() {
  const [width, setWidth] = useSidebarWidth();
  return { width, setWidth };
}
