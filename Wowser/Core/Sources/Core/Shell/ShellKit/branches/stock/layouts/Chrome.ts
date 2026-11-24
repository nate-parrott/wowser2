import { useCommandBar } from "../kit/commandBar";

export default function Chrome() {
  const bar = useCommandBar();
  return { bar, empty: !bar.pane || bar.pane.isEmpty };
}
