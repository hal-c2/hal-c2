import {
  HAL_C2_PROJECT_FILE_NAMES,
  MAX_SCRIPT_ID_LENGTH,
  type HalC2ProjectFile,
  type HalC2ProjectFileScript,
  type ProjectScript,
  type ProjectScriptIcon,
} from "@hal-c2/contracts";
import { parseHalC2ProjectFile } from "@hal-c2/shared/halC2ProjectFile";

// A project's actions (named commands) as the terminal edits them, and what
// its checked-in hal-c2.json offers.

export const PROJECT_ACTION_ICONS: ReadonlyArray<ProjectScriptIcon> = [
  "play",
  "test",
  "lint",
  "configure",
  "build",
  "debug",
];

export interface ProjectActionInput {
  readonly name: string;
  readonly command: string;
  readonly icon: ProjectScriptIcon;
}

/** Why an action cannot be saved, in the words the user is told; null when it can. */
export function validateProjectAction(input: Pick<ProjectActionInput, "name" | "command">) {
  if (input.name.trim() === "") return "Name is required.";
  if (input.command.trim() === "") return "Command is required.";
  return null;
}

/** An id from the action's name, unique among `existingIds` (`dev`, `dev-2`, …). */
export function nextProjectActionId(name: string, existingIds: Iterable<string>): string {
  const taken = new Set(existingIds);
  const cleaned = name
    .trim()
    .toLowerCase()
    .replace(/[^a-z0-9]+/g, "-")
    .replace(/^-+|-+$/g, "");
  const base =
    (cleaned.length <= MAX_SCRIPT_ID_LENGTH
      ? cleaned
      : cleaned.slice(0, MAX_SCRIPT_ID_LENGTH).replace(/-+$/g, "")) || "script";
  if (!taken.has(base)) return base;
  for (let suffix = 2; ; suffix += 1) {
    const tail = `-${suffix}`;
    const candidate = `${base.slice(0, MAX_SCRIPT_ID_LENGTH - tail.length)}${tail}`;
    if (!taken.has(candidate)) return candidate;
  }
}

/** The file's actions the project does not have yet: same command or same name (any case) is had. */
export function importableProjectActions(
  fileScripts: ReadonlyArray<HalC2ProjectFileScript>,
  scripts: ReadonlyArray<ProjectScript>,
): ReadonlyArray<HalC2ProjectFileScript> {
  return fileScripts.filter(
    (fileScript) =>
      !scripts.some(
        (script) =>
          script.command === fileScript.command ||
          script.name.toLowerCase() === fileScript.name.toLowerCase(),
      ),
  );
}

/** The project action a hal-c2.json entry becomes on import. */
export function projectActionFromFile(id: string, fileScript: HalC2ProjectFileScript) {
  const runOnWorktreeCreate = fileScript.runOnWorktreeCreate ?? false;
  return {
    id,
    name: fileScript.name,
    command: fileScript.command,
    icon: fileScript.icon ?? "play",
    runOnWorktreeCreate,
    ...(runOnWorktreeCreate && fileScript.async === false ? { async: false } : {}),
    ...(fileScript.previewUrl
      ? { previewUrl: fileScript.previewUrl, autoOpenPreview: fileScript.autoOpenPreview ?? false }
      : {}),
  } as ProjectScript;
}

/**
 * Read a checkout's project file (`hal-c2.json`, else the legacy `t3.json`).
 * Null when there is none or it does not match the format.
 */
export async function readProjectFile(
  readFile: (cwd: string, relativePath: string) => Promise<string | null>,
  workspaceRoot: string,
): Promise<HalC2ProjectFile | null> {
  for (const name of HAL_C2_PROJECT_FILE_NAMES) {
    const contents = await readFile(workspaceRoot, name).catch(() => null);
    if (contents !== null) return parseHalC2ProjectFile(contents);
  }
  return null;
}

/** A shortcut as the server resolves it (`ServerConfig.keybindings`). */
interface ResolvedShortcutRule {
  readonly command: string;
  readonly shortcut: {
    readonly key: string;
    readonly ctrlKey: boolean;
    readonly shiftKey: boolean;
    readonly altKey: boolean;
    readonly modKey: boolean;
  };
}

/** The host action a chord runs for the action `id` of the open thread's project. */
export const PROJECT_ACTION_RUN_PREFIX = "project.action.run.";

/**
 * The chords that run project actions (`script.<id>.run` rules), as a keymap
 * layer. `mod` is Ctrl in a terminal, which never sees the Command key.
 */
export function projectActionKeymap(
  rules: ReadonlyArray<ResolvedShortcutRule>,
): Record<string, string> {
  const layer: Record<string, string> = {};
  for (const rule of rules) {
    const id = /^script\.(.+)\.run$/.exec(rule.command)?.[1];
    if (!id) continue;
    const { shortcut } = rule;
    const chord = [
      shortcut.ctrlKey || shortcut.modKey ? "ctrl" : null,
      shortcut.altKey ? "alt" : null,
      shortcut.shiftKey ? "shift" : null,
      shortcut.key.toLowerCase(),
    ]
      .filter((part) => part !== null)
      .join("+");
    layer[chord] = `${PROJECT_ACTION_RUN_PREFIX}${id}`;
  }
  return layer;
}
