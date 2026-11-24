// The command bar's brain, separate from its looks.
//
// `useCommandBar()` owns the query, the suggestion list and the keyboard
// handling; <AddressField> and <SuggestionList> (or anything you write) just
// render what it returns. Suggestions for a keystroke are computed
// synchronously, so the list is never a frame behind the text.
import {
  useState, useEffect, useRef, useWindow, useCurrentPane, useSuggestions,
  commandBar, commands, search, tabs, panes, type KeyEvent, type Suggestion, type Modifiers, type PaneInfo,
} from "wowser";

/** Commands registered by this branch (`useCommand`, `commands.register`)
 *  whose title matches what was typed, as suggestions. */
function matchingCommands(query: string): Suggestion[] {
  const q = query.trim().toLowerCase();
  if (q.length < 2) return [];
  return commands
    .list()
    .filter((c) => !c.id.startsWith("builtin:") && c.title && c.title.toLowerCase().includes(q))
    .slice(0, 3)
    .map((c) => ({
      id: "command:" + c.id,
      kind: "command",
      title: c.title,
      subtitle: c.hotkey ? "Command · " + c.hotkey : "Command",
      icon: { kind: "symbol", name: "command" },
    }));
}

export interface CommandBarController {
  open: boolean;
  pane: PaneInfo | null;
  query: string;
  setQuery(text: string): void;
  suggestions: Suggestion[];
  selected: number;
  setSelected(index: number): void;
  /** Handle a key from the text field; true if consumed. */
  onKey(e: KeyEvent): boolean;
  /** Enter: run the selected suggestion, or go to the typed text. */
  submit(text: string, e?: { modifiers: Modifiers }): void;
  choose(s: Suggestion, opts?: { newTab?: boolean }): void;
  close(): void;
}

export function useCommandBar(opts: { limit?: number } = {}): CommandBarController {
  const open = useWindow((w) => w.commandBarOpen);
  const prefill = useWindow((w) => w.commandBarPrefillsURL);
  const pane = useCurrentPane();
  const [query, setQueryRaw] = useState("");
  const [selected, setSelected] = useState(0);
  // Editing the current URL (⌘L): don't suggest anything until the user types.
  const [edited, setEdited] = useState(false);
  const wasOpen = useRef(false);

  useEffect(() => {
    if (open && !wasOpen.current) {
      setQueryRaw(prefill && pane && pane.url ? pane.url : "");
      setEdited(false);
      setSelected(0);
    }
    wasOpen.current = open;
  }, [open]);

  const showing = open && (edited || !prefill || !pane || pane.isEmpty);
  const suggestions = useSuggestions(showing ? query : "", { limit: opts.limit ?? 6, instantOnly: !showing });
  const own = showing ? matchingCommands(query) : [];
  const limit = opts.limit ?? 6;
  const list = showing ? [...suggestions.slice(0, Math.max(1, limit - own.length)), ...own] : [];

  const close = () => {
    // An empty tab has nowhere to return to: closing the bar closes the tab.
    if (pane && pane.isEmpty && query === "") tabs.close(pane.tabId);
    else commandBar.close();
    if (pane && !pane.isEmpty) panes.focus(pane.id);
  };

  const choose = (s: Suggestion, o?: { newTab?: boolean }) => {
    if (s.kind === "command") commands.run(s.id.slice("command:".length));
    else search.open(s, o);
    commandBar.close();
  };

  const submit = (text: string, e?: { modifiers: Modifiers }) => {
    const newTab = !!(e && e.modifiers.cmd);
    const s = list[selected];
    if (s) choose(s, { newTab });
    else if (text.trim()) {
      search.go(text, { newTab });
      commandBar.close();
    }
  };

  const onKey = (e: KeyEvent) => {
    if (e.key === "down" || e.key === "up") {
      if (!list.length) return false;
      const d = e.key === "down" ? 1 : -1;
      setSelected((selected + d + list.length) % list.length);
      return true;
    }
    if (e.key === "escape") {
      close();
      return true;
    }
    return false;
  };

  return {
    open,
    pane,
    query,
    setQuery(text) {
      setQueryRaw(text);
      setEdited(true);
      setSelected(0);
    },
    suggestions: list,
    selected: Math.min(selected, Math.max(0, list.length - 1)),
    setSelected,
    onKey,
    submit,
    choose,
    close,
  };
}
