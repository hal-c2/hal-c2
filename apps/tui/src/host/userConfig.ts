import * as NodeFS from "node:fs";
import * as NodePath from "node:path";

/** What the user's shell config directory adds to the QML shell at start. */
export interface TuiUserConfig {
  /** Extra plugin files (`HAL_C2_TUI_PLUGINS` entries ending in `.qml`). */
  readonly plugins: ReadonlyArray<string>;
  readonly pluginDirs: ReadonlyArray<string>;
  /** `keymap.json`: overrides merged into the shell's `Keymap`s. */
  readonly keymap: Record<string, unknown> | undefined;
}

export const KEYMAP_FILE = "keymap.json";
export const PLUGINS_DIR = "plugins";

/**
 * Read `<configDir>/keymap.json` and the plugin locations: `<configDir>/plugins`
 * when it exists, plus `pluginPaths` (a path-list of `.qml` files and
 * directories, from `HAL_C2_TUI_PLUGINS`). A named directory that does not exist
 * is skipped with a warning; a keymap file that is not valid JSON throws, so
 * the client stops before it takes over the terminal.
 */
export function readUserConfig(input: {
  readonly configDir: string;
  readonly pluginPaths?: string | undefined;
  readonly warn: (message: string) => void;
}): TuiUserConfig {
  const plugins: string[] = [];
  const pluginDirs: string[] = [];
  const defaultDir = NodePath.join(input.configDir, PLUGINS_DIR);
  if (isDirectory(defaultDir)) pluginDirs.push(defaultDir);
  for (const entry of (input.pluginPaths ?? "").split(NodePath.delimiter)) {
    if (entry.trim() === "") continue;
    const path = NodePath.resolve(entry);
    if (path.endsWith(".qml")) plugins.push(path);
    else if (isDirectory(path)) pluginDirs.push(path);
    else input.warn(`plugin directory "${path}" does not exist; skipped`);
  }
  return {
    plugins,
    pluginDirs,
    keymap: readKeymapFile(NodePath.join(input.configDir, KEYMAP_FILE)),
  };
}

function isDirectory(path: string): boolean {
  try {
    return NodeFS.statSync(path).isDirectory();
  } catch {
    return false;
  }
}

function readKeymapFile(path: string): Record<string, unknown> | undefined {
  let text: string;
  try {
    text = NodeFS.readFileSync(path, "utf8");
  } catch {
    return undefined;
  }
  let parsed: unknown;
  try {
    parsed = JSON.parse(text);
  } catch (error) {
    throw new Error(
      `keymap file ${path} is not valid JSON: ${error instanceof Error ? error.message : String(error)}`,
      { cause: error },
    );
  }
  if (typeof parsed !== "object" || parsed === null || Array.isArray(parsed)) {
    throw new Error(`keymap file ${path} must hold a JSON object of key → action`);
  }
  return parsed as Record<string, unknown>;
}
