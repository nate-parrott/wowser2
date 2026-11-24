// Metrics and looks shared by the kit. These mirror the built-in UI
// (UIConstants.swift, ButtonStyles.swift) so kit components sit next to
// native ones without a seam.
import type { BoxStyle, Animation } from "wowser";

export const HEADER_HEIGHT = 42;
export const TAB_HEIGHT = 34;
export const SIDEBAR_MIN = 160;
export const SIDEBAR_MAX = 420;
export const SIDEBAR_DEFAULT = 200;

/** The app's standard ease: cubic-bezier(0.25, 0.1, 0.25, 1). */
export const ease = (duration = 0.3): Animation => ({ type: "ease", duration });
export const quick: Animation = { type: "ease", duration: 0.12 };

/** 30×30 toolbar button: rounded hover plate, dims when disabled. */
export const toolbarButton: BoxStyle = {
  width: 30,
  height: 30,
  align: "center",
  justify: "center",
  cornerRadius: 6,
  cornerStyle: "circular",
  fontSize: 13,
  fontWeight: "medium",
  hover: { background: "primary/0.07" },
  pressed: { background: "primary/0.1" },
  disabled: { opacity: 0.33 },
};

/** Small borderless button: faint plate on hover, shrinks when pressed. */
export const ghostButton: BoxStyle = {
  align: "center",
  justify: "center",
  cornerRadius: 4,
  color: "secondary",
  animate: "snappy",
  hover: { background: "primary/0.07" },
  pressed: { scale: 0.9 },
  disabled: { opacity: 0.33 },
};

export function clamp(v: number, lo: number, hi: number) {
  return Math.min(hi, Math.max(lo, v));
}
