// `import { … } from "wowser/native"` — whole pieces of the browser,
// implemented natively and driven straight from browser state. They render
// exactly what the built-in UI renders and never re-render through JS.
//
// Start from these; when one doesn't bend far enough, replace it with the
// matching component in the branch's `kit/` folder (same job, written with
// primitives, yours to edit).
"use strict";
const { h } = require("./reconciler");

function native(name) {
  const C = (props) => h("native", Object.assign({ name }, props));
  C.displayName = name;
  return C;
}

module.exports = {
  /** The whole built-in window, exactly as shipped. No parts to rearrange. */
  ClassicBrowser: native("ClassicBrowser"),
  /** A live thumbnail of a tab's page. Props: `tabId`. */
  TabThumbnail: native("TabThumbnail"),
  /** The whole built-in iOS UI. */
  MobileBrowser: native("MobileBrowser"),
  /** The entire built-in sidebar: window controls, space name, favorites,
   *  tabs, new-tab button, space dots. `floating` draws the hover-reveal look. */
  Sidebar: native("Sidebar"),
  /** Swipeable pages of favorites + tabs, one per space, with paging dots. */
  SpacePager: native("SpacePager"),
  /** The favorites grid of a space. Props: `spaceId?`. */
  FavoritesGrid: native("FavoritesGrid"),
  /** The vertical tab list of a space: rows, AI groups, folders, drag & drop.
   *  Props: `spaceId?`. */
  TabList: native("TabList"),
  /** One built-in tab row. Props: `tabId`. */
  TabRow: native("TabRow"),
  /** The three-part new-tab / quick-action button. */
  NewTabButton: native("NewTabButton"),
  /** Paging dots for spaces. */
  SpaceDots: native("SpaceDots"),
  /** The current space's icon menu and editable name. */
  SpaceName: native("SpaceName"),
  /** The whole content area: the current tab's panes, each with its toolbar,
   *  the 3D tab switcher, split drop targets. Props: `toolbar`: "auto"
   *  (default; hides when the sidebar is collapsed) | "always" | "hidden". */
  Content: native("Content"),
  /** The built-in toolbar for one pane (nav buttons, address field,
   *  trailing items). Props: `paneId?` (default: focused pane). */
  Toolbar: native("Toolbar"),
  /** The built-in command bar card, as shown on an empty tab. */
  CommandBar: native("CommandBar"),
  /** Toasts for this window. */
  Toasts: native("Toasts"),
  /** The window backdrop: behind-window blur plus the space's gradient or image. */
  WindowBackground: native("WindowBackground"),
  /** The page-load progress bar for a pane. Props: `paneId?`. */
  LoadingBar: native("LoadingBar"),
  native,
};
