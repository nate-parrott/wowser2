import { useCommandBar } from "../kit/commandBar";
import { useSidebarWidth } from "../kit/Sidebar.ts";

export default function ClassicKit() {
  const bar = useCommandBar();
  const [sidebarWidth] = useSidebarWidth();
  return { bar, empty: !bar.pane || bar.pane.isEmpty, sidebarWidth };
}
