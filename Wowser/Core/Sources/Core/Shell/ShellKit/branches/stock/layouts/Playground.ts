import { useCommandBar } from "../kit/commandBar";
import { installBehaviours } from "../examples/behaviours";

/** Runs once per window: navigation rules, per-site CSS, commands. */
export function setup() {
  return installBehaviours();
}

export default function Playground() {
  const bar = useCommandBar();
  return { bar, empty: !bar.pane || bar.pane.isEmpty };
}
