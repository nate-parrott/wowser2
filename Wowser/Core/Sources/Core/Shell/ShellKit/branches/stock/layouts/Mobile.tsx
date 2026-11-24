// The stock iOS layout: the built-in page card, puck, tray and command bar.
import { MobileBrowser } from "wowser/native";

export default function Mobile() {
  return <MobileBrowser style={{ flex: 1 }} />;
}
