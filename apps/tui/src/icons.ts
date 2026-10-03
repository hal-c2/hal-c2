// Centralized glyph registry — the TUI's stand-ins for the web UI's lucide icons.
//
// A terminal can only spend whole columns, and most emoji are East-Asian-wide
// (two columns) which would shear every aligned row. So each glyph here MUST be a
// single display column; `icons.test.ts` enforces that with `Bun.stringWidth`.
// The decision was "hybrid — emoji only where reliably single-width": that gate is
// the width test, and today it resolves to single-column unicode symbols that read
// as icons. `webIcon` records the lucide name each glyph mirrors so the parity is
// documented and checkable, and so a future single-width emoji can drop in behind
// the same guard.

export interface IconGlyph {
  /** What the TUI renders — guaranteed one display column. */
  readonly glyph: string;
  /** The web (lucide-react) icon name this stands in for. */
  readonly webIcon: string;
}

/** Per-tool / per-activity icons (mirrors web MessagesTimeline tool-type icons). */
export const TOOL_ICONS = {
  terminal: { glyph: "$", webIcon: "terminal" },
  fileRead: { glyph: "◎", webIcon: "eye" },
  fileSearch: { glyph: "▤", webIcon: "search" },
  fileChange: { glyph: "✎", webIcon: "square-pen" },
  imageView: { glyph: "▣", webIcon: "image" },
  webSearch: { glyph: "⌕", webIcon: "globe" },
  mcp: { glyph: "⚙", webIcon: "wrench" },
  dynamic: { glyph: "⚒", webIcon: "hammer" },
  userInput: { glyph: "✦", webIcon: "message-circle" },
  subagent: { glyph: "◈", webIcon: "bot" },
  thinking: { glyph: "✱", webIcon: "sparkles" },
  error: { glyph: "✗", webIcon: "x" },
  default: { glyph: "•", webIcon: "dot" },
} as const satisfies Record<string, IconGlyph>;

/** Tool-call lifecycle status icons (mirrors web Check / X / loader / Minus). */
export const STATUS_ICONS = {
  success: { glyph: "✓", webIcon: "check" },
  failure: { glyph: "✗", webIcon: "x" },
  progress: { glyph: "⟳", webIcon: "loader" },
  neutral: { glyph: "−", webIcon: "minus" },
} as const satisfies Record<string, IconGlyph>;

// Nerd Fonts glyphs (private-use code points, one column each) for a terminal
// whose font has them. Opt-in: without the font they draw as empty boxes.
const NERD_TOOL_GLYPHS: Record<keyof typeof TOOL_ICONS, string> = {
  terminal: "",
  fileRead: "",
  fileChange: "",
  imageView: "",
  webSearch: "",
  mcp: "",
  dynamic: "",
  fileSearch: "\uf002",
  subagent: "\uf0c0",
  userInput: "",
  thinking: "",
  error: "",
  default: "",
};
const NERD_FILE_GLYPHS: Record<string, string> = {
  ts: "",
  tsx: "",
  js: "",
  jsx: "",
  json: "",
  md: "",
  py: "",
  rs: "",
  go: "",
  css: "",
  html: "",
  sh: "",
  yml: "",
  yaml: "",
  toml: "",
  lock: "",
};
const NERD_FILE_DEFAULT = "";
/** The file glyph every font has. */
export const PLAIN_FILE_GLYPH = "◦";

const PLAIN_TOOL_GLYPHS = Object.fromEntries(
  Object.entries(TOOL_ICONS).map(([name, icon]) => [name, icon.glyph]),
) as Record<keyof typeof TOOL_ICONS, string>;

/** `HAL_C2_TUI_NERD_FONT=1`: the user says their terminal font has the Nerd Fonts glyphs. */
export const nerdFontRequested = (env: Readonly<Record<string, string | undefined>>): boolean =>
  env.HAL_C2_TUI_NERD_FONT === "1" || env.HAL_C2_TUI_NERD_FONT === "true";

let nerdFont = false;

export const usesNerdFont = (): boolean => nerdFont;

/**
 * Switch the tool icons between the single-column fallbacks and the Nerd
 * Fonts glyphs. The registry is rewritten in place, so readers of
 * `TOOL_ICONS.x.glyph` follow; the host repaints what it already drew.
 */
export function setNerdFont(on: boolean): void {
  nerdFont = on;
  const glyphs = on ? NERD_TOOL_GLYPHS : PLAIN_TOOL_GLYPHS;
  for (const name of Object.keys(TOOL_ICONS) as Array<keyof typeof TOOL_ICONS>) {
    (TOOL_ICONS[name] as { glyph: string }).glyph = glyphs[name];
  }
}

/** The glyph in front of a file's name: its type's with a nerd font, else the plain one. */
export function fileGlyph(path: string): string {
  if (!nerdFont) return PLAIN_FILE_GLYPH;
  const base = path.split("/").pop() ?? path;
  const dot = base.lastIndexOf(".");
  const extension = dot > 0 ? base.slice(dot + 1).toLowerCase() : "";
  return NERD_FILE_GLYPHS[extension] ?? NERD_FILE_DEFAULT;
}

if (nerdFontRequested(process.env)) setNerdFont(true);

/** Every glyph the registry ships, for the single-column width guard in tests. */
export function allIconGlyphs(): ReadonlyArray<IconGlyph> {
  return [...Object.values(TOOL_ICONS), ...Object.values(STATUS_ICONS)];
}

// File-type → named ANSI colour for the changed-files tree's file glyph, echoing
// the web's PierreEntryIcon colouring at terminal-palette fidelity (a coarse map;
// unknown extensions fall back to the muted default).
const FILE_TYPE_COLORS: Record<string, string> = {
  ts: "blue",
  tsx: "blue",
  js: "yellow",
  jsx: "yellow",
  mjs: "yellow",
  cjs: "yellow",
  json: "yellow",
  css: "magenta",
  scss: "magenta",
  html: "red",
  md: "cyan",
  mdx: "cyan",
  py: "blue",
  rs: "red",
  go: "cyan",
  zig: "yellow",
  sh: "green",
  bash: "green",
  yml: "magenta",
  yaml: "magenta",
  toml: "magenta",
  lock: "gray",
  sql: "cyan",
};

/** Named ANSI colour for a path's file type, or null when unknown (caller dims it). */
export function fileTypeColor(path: string): string | null {
  const base = path.split("/").pop() ?? path;
  const dot = base.lastIndexOf(".");
  if (dot <= 0) return null;
  return FILE_TYPE_COLORS[base.slice(dot + 1).toLowerCase()] ?? null;
}
