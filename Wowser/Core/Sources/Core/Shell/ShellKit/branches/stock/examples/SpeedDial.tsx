import { Column, Row, Pressable, Text, Favicon, useMemo, useWindow, search, type Suggestion } from "wowser";

/**
 * A grid of the space's top sites, for empty tabs. Show it where your
 * layout draws an empty tab (next to, or instead of, the command bar).
 */
export function SpeedDial({ columns = 4, count = 8 }: { columns?: number; count?: number }) {
  // Top sites differ per space; recompute when the space changes.
  const spaceId = useWindow((w) => w.spaceId);
  const sites = useMemo(() => search.topSites(count), [spaceId, count]);
  const rows: Suggestion[][] = [];
  for (let i = 0; i < sites.length; i += columns) rows.push(sites.slice(i, i + columns));
  return (
    <Column testID="speed-dial" style={{ gap: 14, padding: 20 }}>
      {rows.map((row, i) => (
        <Row key={i} style={{ gap: 14 }}>
          {row.map((site) => (
            <Pressable
              key={site.id}
              layout="column"
              testID={"dial-" + site.id}
              tooltip={site.url ?? site.title}
              style={{ width: 96, gap: 8, padding: [14, 6], align: "center", cornerRadius: 16, animate: "snappy", hover: { background: "primary/0.06" }, pressed: { scale: 0.96 } }}
              onPress={(e) => search.open(site, { newTab: e.modifiers.cmd })}
            >
              <Column style={{ width: 48, height: 48, align: "center", justify: "center", cornerRadius: 12, background: { material: "glass" } }}>
                <Favicon url={site.url ?? null} src={site.icon.kind === "favicon" ? site.icon.src : null} size={24} />
              </Column>
              <Text style={{ fontSize: 11, lineLimit: 1, color: "secondary" }}>{site.title}</Text>
            </Pressable>
          ))}
        </Row>
      ))}
    </Column>
  );
}
