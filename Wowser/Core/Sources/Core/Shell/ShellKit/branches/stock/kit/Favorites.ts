import { useTabs, type TabInfo, type SpaceId } from "wowser";

/** Lay pinned tabs out in rows, with placeholders up to three cells. */
export default function Favorites({ spaceId, columns = 4 }: { spaceId?: SpaceId; columns?: number }) {
  const { pinned } = useTabs(spaceId);
  const cells: (TabInfo | null)[] = [...pinned];
  while (cells.length < 3) cells.push(null);
  const rows: (TabInfo | null)[][] = [];
  for (let i = 0; i < cells.length; i += columns) rows.push(cells.slice(i, i + columns));
  // Avoid a lonely last cell: borrow one from the row above.
  const last = rows[rows.length - 1];
  const prev = rows[rows.length - 2];
  if (prev && last.length === 1 && prev.length > 2) last.unshift(prev.pop()!);
  return { rows };
}
