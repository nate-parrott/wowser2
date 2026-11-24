import { useState, useRef, useEffect, useCurrentPane, usePane, useWatch, tabs, panes, type PaneId, type TabId } from "wowser";

// Evaluated inside the page, again whenever the page changes.
const PLAYING = `(function () {
  var v = document.querySelector("video");
  return !!v && !v.paused && !v.ended && v.readyState > 2;
})()`;

export default function PopOutVideo() {
  const pane = useCurrentPane();
  const paneId = pane ? pane.id : null;
  const playing = useWatch(paneId, PLAYING);
  const [popped, setPopped] = useState<{ paneId: PaneId; tabId: TabId } | null>(null);
  // The pane we were last looking at, and whether its video was playing.
  const seen = useRef<{ paneId: PaneId | null; tabId: TabId | null; playing: boolean }>({ paneId: null, tabId: null, playing: false });

  useEffect(() => {
    const prev = seen.current;
    if (prev.paneId === paneId) {
      prev.playing = !!playing;
      return;
    }
    // Switched to another pane.
    if (popped && popped.paneId === paneId) setPopped(null);
    else if (prev.paneId && prev.tabId && prev.playing) setPopped({ paneId: prev.paneId, tabId: prev.tabId });
    seen.current = { paneId, tabId: pane ? pane.tabId : null, playing: !!playing };
  }, [paneId, playing]);

  // The popped-out tab was closed: nothing left to show.
  const source = usePane(popped ? popped.paneId : null);
  const live = popped && source ? popped : null;

  return {
    popped: live,
    title: source ? source.title : "",
    expand() {
      if (live) tabs.activate(live.tabId);
    },
    close() {
      if (live) panes.eval(live.paneId, `var v = document.querySelector("video"); if (v) v.pause();`).catch(() => {});
      setPopped(null);
    },
  };
}
