import type { RGBA } from "@opentui/core";
import type { ShellThemeState } from "@hal-c2/contracts/shell";
import { createPropertyMap, type PropertyMap } from "opentui-qml";

import { ansi, currentColourTheme, THEME, type Palette } from "../theme.ts";

/**
 * Published under `theme`. By default the TUI paints with the terminal's own
 * palette (indexed colours), so the state only names the theme; bricks read
 * colours from the `Theme` singleton instead.
 */
export const tuiThemeState = (): ShellThemeState => ({
  id: currentColourTheme(),
  appearance: "dark",
  colors: {},
  radius: 0,
  fontUi: null,
  fontMono: null,
});

export interface TuiTheme {
  /** The palette's roles, each a reactive key: bricks bound to one follow a theme change. */
  readonly colors: PropertyMap;
  /** An ANSI colour by name ("red", "cyan", "gray"), as thread status dots name them. */
  readonly ansi: (name: string) => RGBA;
  /** desktop-qt's `Theme.palette.color(role, fallback)`, so shared bricks resolve. */
  readonly palette: { readonly color: (role: string, fallback?: unknown) => unknown };
  /** Publish the palette again after `setColourTheme` rewrote it. */
  readonly refresh: () => void;
}

export function createTuiTheme(palette: Palette = THEME): TuiTheme {
  const roles = () => ({ ...palette }) as unknown as Record<string, RGBA>;
  const colors = createPropertyMap(roles());
  return {
    colors,
    ansi,
    palette: { color: (role, fallback) => roles()[role] ?? fallback },
    refresh: () => {
      for (const [role, colour] of Object.entries(roles())) colors.set(role, colour);
    },
  };
}
