import { useCommandBar } from "../kit/commandBar";

export default function MobileKit() {
  return { bar: useCommandBar({ limit: 4 }) };
}
