import { useMemo, useWindow, search, type Suggestion } from "wowser";

export default function SpeedDial({ columns = 4, count = 8 }: { columns?: number; count?: number }) {
  // Top sites differ per space; recompute when the space changes.
  const spaceId = useWindow((w) => w.spaceId);
  const sites = useMemo(() => search.topSites(count), [spaceId, count]);
  const rows: Suggestion[][] = [];
  for (let i = 0; i < sites.length; i += columns) rows.push(sites.slice(i, i + columns));
  return { rows };
}
