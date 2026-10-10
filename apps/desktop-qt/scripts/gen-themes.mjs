// Regenerates src/native/themes.json: the built-in palettes the shell resolves
// its theme from (ThemeController), taken from packages/shared's
// themePalettes.ts. Run
// `node apps/desktop-qt/scripts/gen-themes.mjs` from the repo root after
// changing a palette. Colours stay as written there (oklch or hex); the shell
// converts them when it loads the file.
import * as NodeFS from "node:fs";
import * as NodePath from "node:path";
import * as NodeURL from "node:url";

const here = NodePath.dirname(NodeURL.fileURLToPath(import.meta.url));
const repoRoot = NodePath.join(here, "..", "..", "..");
const palettes = await import(
  NodeURL.pathToFileURL(NodePath.join(repoRoot, "packages/shared/src/themePalettes.ts")).href
);
const output = NodePath.join(here, "..", "src/native/themes.json");

// Roles outside the theme files that the bricks read: success is emerald-500
// and info blue-500, in both appearances.
const fixed = { success: "oklch(0.696 0.17 162.48)", info: "oklch(0.623 0.214 259.815)" };

const themes = {
  roles: palettes.THEME_COLOR_ROLES,
  // The stock look (no theme chosen), and the palette roles a theme file
  // leaves out are filled from.
  standard: { light: palettes.HAL_C2_LIGHT_THEME_COLORS, dark: palettes.HAL_C2_DARK_THEME_COLORS },
  defaults: {
    light: palettes.T3_CHAT_THEME.colors,
    dark: palettes.T3_CHAT_THEME.variants.dark,
  },
  fixed: { light: fixed, dark: fixed },
  // The corner radius (0.625rem) and the UI and monospace font stacks.
  radius: 10,
  fonts: {
    ui: '-apple-system, BlinkMacSystemFont, "Segoe UI", system-ui, sans-serif',
    mono: 'ui-monospace, "SF Mono", "SFMono-Regular", Menlo, Consolas, "Liberation Mono", monospace',
  },
  reserved: [...palettes.RESERVED_THEME_IDS],
  builtIn: palettes.BUILT_IN_THEMES.map(({ id, label, appearance, colors, variants }) => ({
    id,
    label,
    appearance,
    colors,
    ...(variants ? { variants } : {}),
  })),
};

NodeFS.writeFileSync(output, `${JSON.stringify(themes, null, 2)}\n`);
console.log(`wrote ${NodePath.relative(repoRoot, output)}`);
