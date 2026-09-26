import type { RGBA } from "@opentui/core";
import type { ShellThemeState } from "@t3tools/contracts/shell";

import { ansi, THEME, type Palette } from "../theme.ts";

/**
 * The TUI paints with the terminal's own palette (indexed colours), so the
 * published theme only names itself; bricks read colours from the `Theme`
 * singleton instead.
 */
export const TUI_THEME_STATE: ShellThemeState = {
  id: "terminal",
  appearance: "dark",
  colors: {},
  radius: 0,
  fontUi: null,
  fontMono: null,
};

export interface TuiTheme {
  readonly colors: Palette;
  /** An ANSI colour by name ("red", "cyan", "gray"), as thread status dots name them. */
  readonly ansi: (name: string) => RGBA;
  /** desktop-qt's `Theme.palette.color(role, fallback)`, so shared bricks resolve. */
  readonly palette: { readonly color: (role: string, fallback?: unknown) => unknown };
}

export function createTuiTheme(palette: Palette = THEME): TuiTheme {
  return {
    colors: palette,
    ansi,
    palette: {
      color: (role, fallback) => (palette as unknown as Record<string, RGBA>)[role] ?? fallback,
    },
  };
}
