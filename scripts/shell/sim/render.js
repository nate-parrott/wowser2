// DOM renderer for the simulator: draws the shell's native node tree with
// HTML + CSS that approximates what ShellRenderer.swift does with SwiftUI.
//
// It is an approximation — SwiftUI's layout and materials are not CSS — but it
// follows the same contract (wowser.d.ts), so it catches structural mistakes
// and gives a readable picture of a layout without a Mac.
"use strict";

const SEMANTIC = {
  light: {
    primary: [0, 0, 0, 0.85], secondary: [0, 0, 0, 0.5], tertiary: [0, 0, 0, 0.26],
    background: [255, 255, 255, 1], separator: [0, 0, 0, 0.1],
  },
  dark: {
    primary: [255, 255, 255, 0.85], secondary: [255, 255, 255, 0.55], tertiary: [255, 255, 255, 0.25],
    background: [30, 34, 40, 1], separator: [255, 255, 255, 0.1],
  },
  fixed: {
    clear: [0, 0, 0, 0], white: [255, 255, 255, 1], black: [0, 0, 0, 1], red: [255, 59, 48, 1],
    orange: [255, 149, 0, 1], yellow: [255, 204, 0, 1], green: [52, 199, 89, 1], blue: [0, 122, 255, 1],
    purple: [175, 82, 222, 1], pink: [255, 45, 85, 1], gray: [142, 142, 147, 1],
  },
};

function parseHex(hex) {
  let h = hex.slice(1);
  if (h.length === 3 || h.length === 4) h = h.split("").map((c) => c + c).join("");
  const n = (i) => parseInt(h.slice(i, i + 2), 16);
  return [n(0), n(2), n(4), h.length >= 8 ? n(6) / 255 : 1];
}

function createRenderer(opts) {
  const { container, tree, dispatch, fake, files } = opts;
  const els = new Map(); // node id -> { el, node, state }
  let theme = { scheme: "light", accent: "#0a84ff", onAccent: "#ffffff" };

  function color(c) {
    if (c == null) return null;
    let alphaMul = 1;
    let name = c;
    const slash = c.lastIndexOf("/");
    if (slash > 0) {
      alphaMul = parseFloat(c.slice(slash + 1));
      name = c.slice(0, slash);
    }
    let rgba;
    if (name.startsWith("#")) rgba = parseHex(name);
    else if (name === "accent") rgba = parseHex(theme.accent);
    else if (name === "onAccent") rgba = parseHex(theme.onAccent);
    else rgba = SEMANTIC[theme.scheme][name] || SEMANTIC.fixed[name] || [255, 0, 255, 1];
    return `rgba(${rgba[0]},${rgba[1]},${rgba[2]},${+(rgba[3] * alphaMul).toFixed(3)})`;
  }

  const px = (v) => (typeof v === "number" ? v + "px" : v);
  function edges(v) {
    if (v == null) return null;
    if (typeof v === "number") return [v, v, v, v];
    if (Array.isArray(v)) return [v[0], v[1], v[0], v[1]];
    return [
      v.top ?? v.vertical ?? 0, v.right ?? v.horizontal ?? 0,
      v.bottom ?? v.vertical ?? 0, v.left ?? v.horizontal ?? 0,
    ];
  }
  const PLACE = {
    center: ["center", "center"], top: ["start", "center"], bottom: ["end", "center"],
    leading: ["center", "start"], trailing: ["center", "end"], topLeading: ["start", "start"],
    topTrailing: ["start", "end"], bottomLeading: ["end", "start"], bottomTrailing: ["end", "end"],
  };
  const FLEX_ALIGN = { start: "flex-start", center: "center", end: "flex-end", stretch: "stretch", baseline: "baseline" };
  const JUSTIFY = { start: "flex-start", center: "center", end: "flex-end", between: "space-between", around: "space-around", evenly: "space-evenly" };
  const WEIGHT = { ultraLight: 100, thin: 200, light: 300, regular: 400, medium: 500, semibold: 600, bold: 700, heavy: 800, black: 900 };
  const DESIGN = {
    default: '-apple-system, "SF Pro Text", "Inter", "Helvetica Neue", Arial, sans-serif',
    rounded: '"SF Pro Rounded", "Nunito", sans-serif',
    monospaced: '"SF Mono", ui-monospace, Menlo, monospace',
    serif: '"New York", Georgia, serif',
  };

  function animationCSS(a) {
    if (!a) return "none";
    if (a === true || a === "default") return "all 0.2s cubic-bezier(0.25,0.1,0.25,1)";
    if (a === "snappy") return "all 0.18s cubic-bezier(0.2,0.9,0.3,1)";
    if (a === "smooth") return "all 0.35s cubic-bezier(0.3,0.7,0.2,1)";
    if (a === "bouncy") return "all 0.35s cubic-bezier(0.3,1.6,0.5,1)";
    const d = a.duration ?? (a.type === "spring" ? 0.35 : 0.2);
    if (a.type === "spring") return `all ${d}s cubic-bezier(0.3,${1 + (a.bounce || 0) * 1.6},0.5,1)`;
    const fn = { ease: "cubic-bezier(0.25,0.1,0.25,1)", easeIn: "ease-in", easeOut: "ease-out", linear: "linear" }[a.type];
    return `all ${d}s ${fn}`;
  }

  function effectiveStyle(node, st) {
    const base = node.props.style || {};
    let s = base;
    const add = (v) => {
      if (v) s = Object.assign({}, s, v);
    };
    if (theme.scheme === "dark") add(base.dark);
    if (st.groupHover) add(base.groupHover);
    if (st.groupPressed) add(base.groupPressed);
    if (st.hover && !node.props.disabled) add(base.hover);
    if (st.focused) add(base.focused);
    if (st.pressed && !node.props.disabled) add(base.pressed);
    if (st.dropTarget) add(base.dropTarget);
    if (node.props.disabled) add(base.disabled);
    return s;
  }

  // SwiftUI sizes a container from its children: a box hugs its content
  // unless something inside wants to grow, in which case it grows too. CSS
  // has no such rule, so work out "wants to grow" per axis up front.
  const GREEDY_NATIVE = { Content: "hv", WindowBackground: "hv", ClassicBrowser: "hv", MobileBrowser: "hv", ErrorScreen: "hv", SpacePager: "hv", TabList: "hv", Sidebar: "v", Toolbar: "h", FavoritesGrid: "h", NewTabButton: "h", SpaceDots: "h", LoadingBar: "h", TabThumbnail: "hv" };
  const flexCache = new Map();
  function flexOf(node, parent) {
    const key = node.id;
    if (flexCache.has(key)) return flexCache.get(key);
    const s = node.props.style || {};
    const axis = parentAxis(parent);
    let h = false;
    let v = false;
    switch (node.type) {
      case "spacer":
        h = axis === "row";
        v = axis === "column";
        break;
      case "divider":
        h = axis !== "row";
        v = axis === "row";
        break;
      case "scroll":
      case "webpane":
      case "webisland":
      case "root":
        h = v = true;
        break;
      case "native": {
        const g = GREEDY_NATIVE[node.props.name] || "";
        h = g.includes("h");
        v = g.includes("v");
        break;
      }
      case "textinput":
        h = true;
        break;
      case "row":
      case "column":
      case "stack":
      case "menu":
      case "popover":
        for (const c of node.children) {
          const f = flexOf(c, node);
          h = h || f.h;
          v = v || f.v;
        }
        // align: "stretch" hands every child the full cross size, which in
        // SwiftUI makes the container itself take all it is offered.
        if (s.align === "stretch") {
          if (node.type === "column") h = true;
          if (node.type === "row") v = true;
        }
        break;
    }
    if (s.flex != null) {
      if (axis === "row") h = true;
      else if (axis === "column") v = true;
      else h = v = true;
    }
    if (s.width === "fill") h = true;
    if (s.height === "fill") v = true;
    if (typeof s.width === "number") h = false;
    if (typeof s.height === "number") v = false;
    const out = { h, v };
    flexCache.set(key, out);
    return out;
  }

  function parentAxis(parent) {
    if (!parent) return "stack";
    if (parent.type === "row") return "row";
    if (parent.type === "stack" || parent.type === "root" || parent.type === "popover") return "stack";
    if (parent.type === "scroll") return parent.props.axis === "horizontal" ? "row" : "column";
    return "column";
  }

  function applyStyle(rec) {
    const { el, node, state } = rec;
    const s = effectiveStyle(node, state);
    const css = el.style;
    const type = node.type;
    const axis = parentAxis(rec.parent ? rec.parent.node : null);
    css.cssText = "";
    css.boxSizing = "border-box";
    css.position = "relative";
    css.minWidth = "0";
    css.minHeight = "0";
    css.flex = "0 0 auto";

    // ---- own layout
    if (type === "row" || type === "column" || type === "menu") {
      css.display = "flex";
      css.flexDirection = type === "column" ? "column" : "row";
      css.alignItems = FLEX_ALIGN[s.align] || "center";
      css.justifyContent = JUSTIFY[s.justify] || "flex-start";
      if (s.gap != null) css.gap = s.gap + "px";
    } else if (type === "stack" || type === "root" || type === "popover") {
      css.display = "grid";
      css.gridTemplateColumns = "minmax(0, 1fr)";
      css.gridTemplateRows = "minmax(0, 1fr)";
      const p = PLACE[s.align] || PLACE.center;
      css.alignItems = p[0];
      css.justifyItems = p[1];
    } else if (type === "scroll") {
      const horizontal = node.props.axis === "horizontal";
      const cs = node.props.contentStyle || {};
      css.display = "flex";
      css.flexDirection = horizontal ? "row" : "column";
      css.alignItems = FLEX_ALIGN[cs.align] || "center";
      if (cs.gap != null) css.gap = cs.gap + "px";
      css[horizontal ? "overflowX" : "overflowY"] = "auto";
      css.scrollbarWidth = "none";
      const cp = edges(cs.padding);
      if (cp) css.padding = cp.map(px).join(" ");
    }

    // ---- placement in parent
    const fx = rec.flex || { h: false, v: false };
    if (axis === "stack") {
      css.gridArea = "1 / 1";
      const p = s.alignSelf ? PLACE[s.alignSelf] : null;
      if (p) {
        css.alignSelf = p[0];
        css.justifySelf = p[1];
      }
      // Greedy children fill the stack — unless capped, in which case they
      // take the cap and sit where `alignSelf` puts them.
      if (fx.h) {
        if (typeof s.maxWidth === "number") css.width = "100%";
        else css.justifySelf = "stretch";
      }
      if (fx.v) {
        if (typeof s.maxHeight === "number") css.height = "100%";
        else css.alignSelf = "stretch";
      }
    } else {
      const main = axis === "row" ? fx.h : fx.v;
      const cross = axis === "row" ? fx.v : fx.h;
      if (s.flex != null) css.flex = `${s.flex} 1 0px`;
      else if (main) css.flex = "1 1 auto";
      if (cross) css.alignSelf = "stretch";
    }
    if (typeof s.width === "number") css.width = s.width + "px";
    if (typeof s.height === "number") css.height = s.height + "px";
    if (s.minWidth != null) css.minWidth = s.minWidth + "px";
    if (s.minHeight != null) css.minHeight = s.minHeight + "px";
    if (typeof s.maxWidth === "number") css.maxWidth = s.maxWidth + "px";
    if (typeof s.maxHeight === "number") css.maxHeight = s.maxHeight + "px";
    if (s.maxWidth === "fill" && typeof s.width === "number") {
      css.maxWidth = "100%";
    }
    if (s.aspectRatio) css.aspectRatio = String(s.aspectRatio);
    if (type === "root") {
      css.width = "100%";
      css.height = "100%";
    }
    if (type === "divider") {
      css.background = color("separator");
      css.alignSelf = "stretch";
      if (axis === "row") css.width = "1px";
      else css.height = "1px";
    }

    const pad = edges(s.padding);
    if (pad && type !== "scroll") css.padding = pad.map(px).join(" ");
    const mar = edges(s.margin);
    if (mar) css.margin = mar.map(px).join(" ");

    // ---- appearance
    const bg = s.background;
    if (typeof bg === "string") css.background = color(bg);
    else if (bg && bg.gradient) {
      css.background = `linear-gradient(135deg, ${bg.gradient.map(color).join(", ")})`;
    } else if (bg && bg.material) {
      const dark = theme.scheme === "dark";
      if (bg.material === "glass") {
        css.background = dark ? "rgba(255,255,255,0.10)" : "rgba(255,255,255,0.45)";
        css.backdropFilter = "blur(14px) saturate(1.8)";
        css.boxShadow = `inset 0 0 0 0.5px ${dark ? "rgba(255,255,255,0.25)" : "rgba(255,255,255,0.9)"}, 0 1px 4px rgba(0,0,0,0.08)`;
      } else {
        const a = { ultraThin: 0.35, thin: 0.5, regular: 0.65, thick: 0.78, ultraThick: 0.88, bar: 0.7, sidebar: 0.5 }[bg.material] ?? 0.6;
        css.background = dark ? `rgba(40,40,44,${a})` : `rgba(246,246,248,${a})`;
        css.backdropFilter = "blur(30px) saturate(1.6)";
      }
      if (bg.tint) css.backgroundImage = `linear-gradient(${color(bg.tint)}, ${color(bg.tint)})`;
    }
    if (s.color) css.color = color(s.color);
    if (s.opacity != null) css.opacity = String(s.opacity);
    if (s.cornerRadius != null) {
      const r = s.cornerRadius;
      css.borderRadius = typeof r === "number"
        ? Math.min(r, 9999) + "px"
        : [r.topLeft, r.topRight, r.bottomRight, r.bottomLeft].map((v) => (v || 0) + "px").join(" ");
    }
    if (s.border) css.outline = `${s.border.width ?? 1}px solid ${color(s.border.color)}`, (css.outlineOffset = `-${s.border.width ?? 1}px`);
    if (s.shadow) {
      const sh = `${s.shadow.x || 0}px ${s.shadow.y || 0}px ${s.shadow.radius * 2}px ${color(s.shadow.color || "#000/0.33")}`;
      css.boxShadow = css.boxShadow ? css.boxShadow + ", " + sh : sh;
    }
    if (s.clip) css.overflow = "hidden";
    if (s.blur) css.filter = `blur(${s.blur}px)`;
    const tf = [];
    if (s.offset) tf.push(`translate(${s.offset.x || 0}px, ${s.offset.y || 0}px)`);
    if (s.scale != null) tf.push(`scale(${s.scale})`);
    if (s.scaleX != null || s.scaleY != null) tf.push(`scale(${s.scaleX ?? 1}, ${s.scaleY ?? 1})`);
    if (s.rotate) tf.push(`rotate(${s.rotate}deg)`);
    if (tf.length) css.transform = tf.join(" ");
    if (s.anchor) {
      const p = PLACE[s.anchor];
      const m = { start: "0%", center: "50%", end: "100%" };
      css.transformOrigin = `${m[p[1]]} ${m[p[0]]}`;
    }
    if (s.zIndex != null) css.zIndex = String(s.zIndex);
    if (s.hidden) css.visibility = "hidden";
    if (s.cursor) css.cursor = { pointer: "pointer", text: "text", resizeLeftRight: "col-resize", resizeUpDown: "row-resize", grab: "grab", arrow: "default" }[s.cursor];
    css.transition = animationCSS(s.animate);

    // ---- text
    if (s.fontSize != null) css.fontSize = s.fontSize + "px";
    if (s.fontWeight) css.fontWeight = String(WEIGHT[s.fontWeight] || 400);
    if (s.fontDesign) css.fontFamily = DESIGN[s.fontDesign];
    if (s.italic) css.fontStyle = "italic";
    if (type === "text") {
      css.display = "block";
      css.lineHeight = "1.25";
      if (s.lineLimit === 1) {
        css.whiteSpace = "nowrap";
        css.overflow = "hidden";
        css.textOverflow = "ellipsis";
        css.maxWidth = css.maxWidth || "100%";
      } else if (s.lineLimit) {
        css.display = "-webkit-box";
        css.webkitLineClamp = String(s.lineLimit);
        css.webkitBoxOrient = "vertical";
        css.overflow = "hidden";
      }
      if (s.textAlign) css.textAlign = { leading: "left", center: "center", trailing: "right" }[s.textAlign];
      if (s.letterSpacing) css.letterSpacing = s.letterSpacing + "px";
      if (s.underline) css.textDecoration = "underline";
      if (s.strikethrough) css.textDecoration = "line-through";
      if (s.monospacedDigits) css.fontVariantNumeric = "tabular-nums";
      css.userSelect = s.selectable ? "text" : "none";
    }
    if (type === "textinput") {
      css.background = "transparent";
      css.border = "none";
      css.outline = "none";
      css.color = s.color ? color(s.color) : "inherit";
      css.fontFamily = "inherit";
      css.padding = pad ? pad.map(px).join(" ") : "0";
      css.minWidth = "20px";
    }
    if (node.props.onPress || node.props.onDoublePress) css.cursor = css.cursor || "default";
    if (node.props.windowDrag) css.webkitAppRegion = "drag";
  }

  // ------------------------------------------------------------ leaf content

  const ICONS = {
    "xmark": "M5 5l14 14M19 5L5 19",
    "plus": "M12 4v16M4 12h16",
    "chevron.backward": "M15 4l-8 8 8 8",
    "chevron.forward": "M9 4l8 8-8 8",
    "chevron.down": "M4 9l8 8 8-8",
    "chevron.up": "M4 15l8-8 8 8",
    "arrow.clockwise": "M19 12a7 7 0 1 1-2.1-5M19 4v4h-4",
    "magnifyingglass": "M10.5 4a6.5 6.5 0 1 1 0 13 6.5 6.5 0 0 1 0-13zM15.5 15.5L20 20",
    "sidebar.left": "M3 5h18v14H3zM9 5v14",
    "sidebar.right": "M3 5h18v14H3zM15 5v14",
    "rectangle.split.2x1": "M3 5h18v14H3zM12 5v14",
    "globe": "M12 3a9 9 0 1 1 0 18 9 9 0 0 1 0-18zM3 12h18M12 3c3 3 3 15 0 18M12 3c-3 3-3 15 0 18",
    "lock.fill": "F:M7 11V8a5 5 0 0 1 10 0v3h1v9H6v-9zM9 11h6V8a3 3 0 0 0-6 0z",
    "lock.open.fill": "F:M7 11V7a5 5 0 0 1 9.5-2l-1.8.9A3 3 0 0 0 9 7v4h9v9H6v-9z",
    "pin": "M9 3h6l-1 6 3 3H7l3-3zM12 12v9",
    "pin.slash": "M9 3h6l-1 6 3 3H7l3-3zM12 12v9M4 4l16 16",
    "link": "M10 14a4 4 0 0 0 5.7 0l3-3a4 4 0 0 0-5.7-5.7l-1 1M14 10a4 4 0 0 0-5.7 0l-3 3a4 4 0 0 0 5.7 5.7l1-1",
    "info.circle": "M12 3a9 9 0 1 1 0 18 9 9 0 0 1 0-18zM12 11v6M12 7.5v.5",
    "clock": "M12 3a9 9 0 1 1 0 18 9 9 0 0 1 0-18zM12 7v5l3 2",
    "star": "M12 3l2.7 5.8 6.3.8-4.6 4.4 1.2 6.3L12 17.2 6.4 20.3l1.2-6.3L3 9.6l6.3-.8z",
    "star.fill": "F:M12 3l2.7 5.8 6.3.8-4.6 4.4 1.2 6.3L12 17.2 6.4 20.3l1.2-6.3L3 9.6l6.3-.8z",
    "pip": "M3 5h18v14H3zM12 12h7v5h-7z",
    "moon.fill": "F:M20 14.5A8.5 8.5 0 0 1 9.5 4 8.5 8.5 0 1 0 20 14.5z",
    "eye.slash": "M3 12s3.5-6 9-6 9 6 9 6-3.5 6-9 6-9-6-9-6zM4 4l16 16",
    "square.grid.2x2": "M4 4h7v7H4zM13 4h7v7h-7zM4 13h7v7H4zM13 13h7v7h-7z",
    "list.bullet": "M8 6h12M8 12h12M8 18h12M4 6h.5M4 12h.5M4 18h.5",
    "arrow.trianglehead.branch": "M6 4v16M6 8c0 6 12 2 12 8v4",
    "plus.square.on.square": "M8 8h12v12H8zM4 16V4h12M14 11v6M11 14h6",
    "trash": "M5 7h14M9 7V4h6v3M7 7l1 13h8l1-13",
    "speaker.wave.2.fill": "F:M4 9h4l5-4v14l-5-4H4z",
    "doc.on.doc": "M8 8h11v12H8zM5 16V4h10",
    "bolt.fill": "F:M13 2L5 13h6l-1 9 8-11h-6z",
    "note.text": "M5 4h14v16H5zM8 9h8M8 13h8M8 17h4",
    "timer": "M12 6a8 8 0 1 1 0 16 8 8 0 0 1 0-16zM12 10v4M10 2h4",
  };
  function iconSVG(name, size, weight) {
    const d = ICONS[name];
    const sw = { ultraLight: 1, thin: 1.2, light: 1.5, regular: 1.9, medium: 2.3, semibold: 2.7, bold: 3.1, heavy: 3.6, black: 4 }[weight] || 2;
    if (!d) {
      return `<svg width="${size}" height="${size}" viewBox="0 0 24 24"><rect x="4" y="4" width="16" height="16" rx="4" fill="none" stroke="currentColor" stroke-width="${sw}" stroke-dasharray="3 2"/><title>${name}</title></svg>`;
    }
    const fill = d.startsWith("F:");
    return `<svg width="${size}" height="${size}" viewBox="0 0 24 24" fill="${fill ? "currentColor" : "none"}" stroke="${fill ? "none" : "currentColor"}" stroke-width="${sw}" stroke-linecap="round" stroke-linejoin="round"><path d="${fill ? d.slice(2) : d}"/></svg>`;
  }

  function hostOf(url) {
    try {
      return new URL(url).host.replace(/^www\./, "");
    } catch (_) {
      return "";
    }
  }
  function faviconHTML(url, size) {
    const host = url ? hostOf(url) : "";
    if (!host) return `<div style="width:${size}px;height:${size}px;border-radius:50%;background:${color("primary/0.1")}"></div>`;
    let hsh = 0;
    for (const c of host) hsh = (hsh * 31 + c.charCodeAt(0)) % 360;
    return `<div style="width:${size}px;height:${size}px;border-radius:${size * 0.22}px;background:hsl(${hsh} 62% 52%);color:#fff;font:700 ${Math.round(size * 0.62)}px/${size}px -apple-system,Inter,Arial,sans-serif;text-align:center">${host[0].toUpperCase()}</div>`;
  }

  function fakePage(paneId) {
    const pane = paneId ? fake.paneById(paneId) : null;
    if (!pane || !pane.url) return `<div style="width:100%;height:100%"></div>`;
    const host = hostOf(pane.url);
    const lines = Array.from({ length: 9 }, (_, i) => `<div style="height:10px;border-radius:5px;background:#e9e9ee;margin:10px 0;width:${[92, 80, 96, 60, 88, 94, 72, 85, 40][i]}%"></div>`).join("");
    return `<div style="width:100%;height:100%;background:#fff;color:#1d1d1f;overflow:hidden;font-family:-apple-system,Inter,Arial,sans-serif">
      <div style="height:54px;display:flex;align-items:center;gap:12px;padding:0 32px;border-bottom:1px solid #eee">${faviconHTML(pane.url, 22)}<b style="font-size:15px">${host}</b></div>
      <div style="padding:36px 32px;max-width:680px"><div style="font-size:28px;font-weight:700;margin-bottom:18px">${pane.title || host}</div>${lines}
      <div style="height:150px;border-radius:12px;background:linear-gradient(135deg,#eef,#fee);margin:22px 0"></div>${lines}</div></div>`;
  }

  const NATIVE_SIM = {
    WindowBackground: () => {
      const g = theme.gradient || ["#ffffff00", "#0a84ff22"];
      const base = theme.scheme === "dark" ? "#26282c" : "#eceef2";
      return `<div style="width:100%;height:100%;background:linear-gradient(135deg, ${g.map(color).join(",")}), ${base}"></div>`;
    },
    Content: (node) => {
      const w = fake.slice("window");
      const tab = w.currentTabId ? fake.state.tabs[w.currentTabId] : null;
      if (!tab) return `<div style="width:100%;height:100%"></div>`;
      const label = node.props.toolbar === "hidden" ? "" : `<div style="height:42px;display:flex;align-items:center;justify-content:center;font:12px -apple-system,Inter,Arial;color:#888;background:${color("background")};border-bottom:1px solid ${color("separator")}">native toolbar</div>`;
      return `<div style="width:100%;height:100%;display:flex;flex-direction:column">${label}<div style="flex:1;display:flex;min-height:0">${tab.panes.map((p) => `<div style="flex:${p.weight};min-width:0">${fakePage(p.id)}</div>`).join(`<div style="width:1px;background:${color("separator")}"></div>`)}</div></div>`;
    },
    Toasts: () => "",
    ErrorScreen: (node) =>
      `<div style="width:100%;height:100%;background:#2a1215;color:#ffb4b4;padding:32px;font:13px ui-monospace,Menlo,monospace;white-space:pre-wrap;overflow:auto"><b style="font-size:16px">UI error</b>\n\n${escapeHTML(node.props.message || "")}\n\n${escapeHTML((node.props.componentStack || []).join("\n  in "))}\n\n${escapeHTML(node.props.stack || "")}</div>`,
  };
  function escapeHTML(s) {
    return String(s).replace(/[&<>]/g, (c) => ({ "&": "&amp;", "<": "&lt;", ">": "&gt;" }[c]));
  }
  function nativePlaceholder(node) {
    const sized = { Sidebar: "width:200px;height:100%", NewTabButton: "height:28px;width:100%", SpaceDots: "height:38px;width:100%", FavoritesGrid: "height:55px;width:100%", TabList: "min-height:120px;width:100%", Toolbar: "height:42px;width:100%" }[node.props.name] || "width:100%;height:100%;min-height:24px";
    return `<div style="${sized};box-sizing:border-box;display:flex;align-items:center;justify-content:center;border:1px dashed ${color("primary/0.25")};border-radius:8px;color:${color("secondary")};font:11px -apple-system,Inter,Arial,sans-serif">native ${escapeHTML(node.props.name)}</div>`;
  }

  function renderLeaf(rec) {
    const { el, node } = rec;
    const p = node.props;
    const s = p.style || {};
    switch (node.type) {
      case "text":
        if (p.runs) {
          el.innerHTML = "";
          for (const r of p.runs) {
            const span = document.createElement("span");
            span.textContent = r.text;
            if (r.style) {
              if (r.style.fontWeight) span.style.fontWeight = String(WEIGHT[r.style.fontWeight]);
              if (r.style.color) span.style.color = color(r.style.color);
              if (r.style.italic) span.style.fontStyle = "italic";
              if (r.style.fontSize) span.style.fontSize = r.style.fontSize + "px";
              if (r.style.opacity != null) span.style.opacity = String(r.style.opacity);
            }
            el.appendChild(span);
          }
        } else el.textContent = p.text == null ? "" : p.text;
        break;
      case "icon":
        el.innerHTML = iconSVG(p.name, p.size || 13, p.weight);
        el.style.display = "flex";
        break;
      case "favicon":
        el.innerHTML = faviconHTML(p.url, p.size || 16);
        el.style.display = "flex";
        el.style.alignItems = "center";
        el.style.justifyContent = "center";
        break;
      case "tabicon": {
        const tab = fake.state.tabs[p.tabId];
        const size = p.size || 16;
        if (tab && tab.emoji) el.innerHTML = `<div style="font-size:${size - 3}px;width:${size}px;text-align:center">${tab.emoji}</div>`;
        else el.innerHTML = faviconHTML(tab && tab.panes[0] ? tab.panes[0].url : null, size);
        break;
      }
      case "image": {
        let img = el.firstChild;
        if (!img || img.tagName !== "IMG") {
          el.innerHTML = "";
          img = document.createElement("img");
          img.style.cssText = "width:100%;height:100%;display:block";
          el.appendChild(img);
        }
        img.style.objectFit = p.contentMode === "fill" ? "cover" : "contain";
        if (img.getAttribute("src") !== p.src) img.setAttribute("src", p.src);
        break;
      }
      case "windowcontrols":
        el.innerHTML = `<div style="width:68px;height:28px;display:flex;align-items:center;gap:8px;padding-left:8px;box-sizing:border-box">${["#ff5f57", "#febc2e", "#28c840"].map((c) => `<div style="width:12px;height:12px;border-radius:50%;background:${c};box-shadow:inset 0 0 0 0.5px rgba(0,0,0,0.15)"></div>`).join("")}</div>`;
        break;
      case "webpane":
        el.innerHTML = fakePage(p.paneId);
        break;
      case "webisland": {
        let frame = el.firstChild;
        if (!frame || frame.dataset.src !== p.src) {
          el.innerHTML = "";
          frame = document.createElement("iframe");
          frame.dataset.src = p.src;
          frame.style.cssText = "border:0;width:100%;height:100%;background:transparent;display:block";
          frame.setAttribute("allowtransparency", "true");
          if (/^https?:/.test(p.src)) frame.srcdoc = `<body style="margin:0;font:12px -apple-system,Arial;color:#888;display:grid;place-items:center;height:100vh">web panel: ${escapeHTML(p.src)}</body>`;
          else {
            const shim = `<script>(function(){var cbs=[];window.wowser={props:${JSON.stringify(p.props ?? null)},onProps:function(cb){cbs.push(cb);cb(window.wowser.props)},post:function(m){parent.postMessage({__island:${node.id},message:m},"*")},call:function(){return Promise.resolve(null)}};window.addEventListener("message",function(e){if(e.data&&e.data.__props!==undefined){window.wowser.props=e.data.__props;cbs.forEach(function(cb){cb(e.data.__props)})}})})();<\/script>`;
            frame.srcdoc = shim + (files[p.src] || `<body>missing ${escapeHTML(p.src)}</body>`);
          }
          el.appendChild(frame);
          rec.lastProps = JSON.stringify(p.props ?? null);
        } else if (rec.lastProps !== JSON.stringify(p.props ?? null)) {
          rec.lastProps = JSON.stringify(p.props ?? null);
          if (frame.contentWindow) frame.contentWindow.postMessage({ __props: p.props ?? null }, "*");
        }
        break;
      }
      case "native": {
        const sim = NATIVE_SIM[p.name];
        el.innerHTML = sim ? sim(node) : nativePlaceholder(node);
        el.style.display = "flex";
        break;
      }
      case "textinput":
        if (el.value !== p.value) el.value = p.value || "";
        el.placeholder = p.placeholder || "";
        if (s.fontSize) el.style.fontSize = s.fontSize + "px";
        break;
    }
  }

  // ------------------------------------------------------------ events

  const mods = (e) => ({ cmd: !!(e.metaKey || e.ctrlKey), shift: !!e.shiftKey, alt: !!e.altKey, ctrl: !!e.ctrlKey });
  const has = (node, name) => node.props[name] === true;

  function groupRoot(rec) {
    for (let r = rec.parent; r; r = r.parent) {
      const x = els.get(r.id);
      if (x && x.node.props.group) return x;
    }
    return null;
  }
  function restyleSubtree(rec) {
    applyStyle(rec);
    for (const c of rec.node.children) {
      const cr = els.get(c.id);
      if (cr) restyleSubtree(cr);
    }
  }

  function wire(rec) {
    const { el } = rec;
    const node = () => rec.node;
    const setState = (key, v) => {
      if (rec.state[key] === v) return;
      rec.state[key] = v;
      if (node().props.group && (key === "hover" || key === "pressed")) {
        const walk = (n) => {
          for (const c of n.children) {
            const cr = els.get(c.id);
            if (!cr) continue;
            if (!c.props.group) {
              cr.state[key === "hover" ? "groupHover" : "groupPressed"] = v;
              applyStyle(cr);
              walk(c);
            }
          }
        };
        walk(node());
      }
      applyStyle(rec);
    };
    el.addEventListener("mouseenter", () => {
      setState("hover", true);
      if (has(node(), "onHover")) dispatch(node().id, "onHover", true);
    });
    el.addEventListener("mouseleave", () => {
      setState("hover", false);
      setState("pressed", false);
      if (has(node(), "onHover")) dispatch(node().id, "onHover", false);
    });
    el.addEventListener("mousedown", (e) => {
      const n = node();
      if (has(n, "onPress") || has(n, "onDoublePress") || has(n, "onPan")) {
        setState("pressed", true);
        // Like AppKit: clicking chrome doesn't steal focus from a text field.
        if (n.type !== "textinput") e.preventDefault();
      }
      if (has(n, "onPan")) {
        e.stopPropagation();
        const x0 = e.clientX;
        const y0 = e.clientY;
        dispatch(n.id, "onPan", { phase: "began", dx: 0, dy: 0, vx: 0, vy: 0 });
        const move = (ev) => dispatch(n.id, "onPan", { phase: "changed", dx: ev.clientX - x0, dy: ev.clientY - y0, vx: 0, vy: 0 });
        const up = (ev) => {
          window.removeEventListener("mousemove", move);
          window.removeEventListener("mouseup", up);
          dispatch(n.id, "onPan", { phase: "ended", dx: ev.clientX - x0, dy: ev.clientY - y0, vx: 0, vy: 0 });
        };
        window.addEventListener("mousemove", move);
        window.addEventListener("mouseup", up);
      }
    });
    el.addEventListener("mouseup", () => setState("pressed", false));
    el.addEventListener("click", (e) => {
      const n = node();
      if (n.props.disabled) return;
      if (has(n, "onPress")) {
        e.stopPropagation();
        const r = el.getBoundingClientRect();
        dispatch(n.id, "onPress", { modifiers: mods(e), x: e.clientX - r.left, y: e.clientY - r.top });
      }
    });
    el.addEventListener("dblclick", (e) => {
      const n = node();
      if (has(n, "onDoublePress")) {
        e.stopPropagation();
        dispatch(n.id, "onDoublePress", { modifiers: mods(e), x: 0, y: 0 });
      }
    });
    el.addEventListener("focusin", () => setState("focused", true));
    el.addEventListener("focusout", () => setState("focused", false));
    el.addEventListener("dragstart", (e) => {
      const d = node().props.draggable;
      if (!d) return;
      e.stopPropagation();
      e.dataTransfer.setData("application/x-shell", JSON.stringify(d));
    });
    el.addEventListener("dragover", (e) => {
      if (!node().props.dropTypes) return;
      e.preventDefault();
      e.stopPropagation();
      setState("dropTarget", true);
    });
    el.addEventListener("dragleave", () => setState("dropTarget", false));
    el.addEventListener("drop", (e) => {
      const n = node();
      if (!n.props.dropTypes) return;
      e.preventDefault();
      e.stopPropagation();
      setState("dropTarget", false);
      let d = null;
      try {
        d = JSON.parse(e.dataTransfer.getData("application/x-shell"));
      } catch (_) {}
      if (!d || !n.props.dropTypes.includes(d.type)) return;
      const r = el.getBoundingClientRect();
      dispatch(n.id, "onDrop", Object.assign({}, d, { x: e.clientX - r.left, y: e.clientY - r.top, width: r.width, height: r.height }));
    });
    if (rec.node.type === "textinput") {
      el.addEventListener("input", () => dispatch(node().id, "onChangeText", el.value));
      el.addEventListener("keydown", (e) => {
        const map = { ArrowUp: "up", ArrowDown: "down", ArrowLeft: "left", ArrowRight: "right", Enter: "enter", Escape: "escape", Tab: "tab", Backspace: "backspace" };
        const key = map[e.key];
        if (key === "enter") {
          if (has(node(), "onSubmit")) dispatch(node().id, "onSubmit", { __args: [el.value, { modifiers: mods(e) }] });
          e.preventDefault();
          return;
        }
        if (key && has(node(), "onKey")) {
          if (dispatch(node().id, "onKey", { key, modifiers: mods(e) }) === true) e.preventDefault();
        }
      });
      el.addEventListener("focus", () => {
        if (node().props.selectAllOnFocus) el.select();
        if (has(node(), "onFocus")) dispatch(node().id, "onFocus");
      });
      el.addEventListener("blur", () => {
        if (has(node(), "onBlur") && els.has(node().id)) dispatch(node().id, "onBlur");
      });
    }
  }

  // ------------------------------------------------------------ sync

  const LEAVES = new Set(["text", "icon", "favicon", "tabicon", "image", "windowcontrols", "webpane", "webisland", "native", "textinput", "spacer", "divider"]);

  function sync() {
    const t = fake.slice("theme");
    const themeChanged = JSON.stringify(t) !== JSON.stringify(theme);
    theme = t;
    const seen = new Set();
    const autoFocus = [];
    flexCache.clear();
    const walk = (node, parent) => {
      seen.add(node.id);
      let rec = els.get(node.id);
      if (!rec) {
        const el = document.createElement(node.type === "textinput" ? "input" : "div");
        el.dataset.node = node.id;
        el.dataset.type = node.type;
        rec = { id: node.id, el, node, parent: null, state: {}, sig: null };
        els.set(node.id, rec);
        wire(rec);
        if (node.type === "textinput" && node.props.autoFocus) autoFocus.push(el);
        const g = parent ? (parent.props.group ? els.get(parent.id) : groupRoot({ parent: els.get(parent.id) })) : null;
        if (g) rec.state.groupHover = !!g.state.hover;
      }
      rec.node = node;
      rec.parent = parent ? els.get(parent.id) : null;
      rec.flex = flexOf(node, parent);
      const sig = JSON.stringify(node.props) + "|" + (parent ? parent.type + (parent.props.axis || "") : "") + (rec.flex.h ? "h" : "") + (rec.flex.v ? "v" : "");
      if (sig !== rec.sig || themeChanged) {
        rec.sig = sig;
        rec.el.draggable = !!node.props.draggable;
        if (node.props.testID) rec.el.dataset.testid = node.props.testID;
        if (node.props.tooltip) rec.el.title = node.props.tooltip;
        applyStyle(rec);
        if (LEAVES.has(node.type)) renderLeaf(rec);
      } else if (node.type === "tabicon" || node.type === "webpane" || node.type === "native") {
        renderLeaf(rec); // depends on browser state, not just props
      }
      if (!LEAVES.has(node.type)) {
        let kids = node.children;
        if (node.type === "popover" && !node.props.open) kids = kids.slice(0, 1);
        const want = kids.map((c) => walk(c, node));
        let i = 0;
        for (; i < want.length; i++) {
          if (rec.el.childNodes[i] !== want[i]) rec.el.insertBefore(want[i], rec.el.childNodes[i] || null);
        }
        while (rec.el.childNodes.length > want.length) rec.el.removeChild(rec.el.lastChild);
        if (node.type === "popover" && want[1]) {
          want[1].style.position = "absolute";
          want[1].style.top = "100%";
          want[1].style.zIndex = "50";
        }
      }
      return rec.el;
    };
    const root = tree.root("main");
    if (root) {
      const el = walk(root, null);
      if (el.parentNode !== container) {
        container.innerHTML = "";
        container.appendChild(el);
      }
    }
    els.forEach((rec, id) => {
      if (!seen.has(id)) els.delete(id);
    });
    container.style.color = color("primary");
    container.style.colorScheme = theme.scheme;
    autoFocus.forEach((el) => el.focus());
  }

  return { sync, els };
}

module.exports = { createRenderer };
