// The real client entry for mc/platform/storage-layout.feature: which directory
// the terminal client reads the user's shell from.
//
// The scenario's paths ("~/…", "/xdg/config", "/srv/hal-c2") are mapped into a temp
// sandbox, so nothing outside it is read or written. Every place the Givens could
// point at gets a broken keymap.json; the client stops on the one it actually reads
// and names that file, before it connects or takes over the terminal.
import * as NodeFS from "node:fs";
import * as NodeOS from "node:os";
import * as NodePath from "node:path";

import type { World } from "./world.ts";

const TUI_DIR = NodePath.resolve(import.meta.dir, "../..");
const ENTRY_TIMEOUT_MS = 10_000;

export interface StorageWorld extends World {
  /** The Givens: the storage variables the user's terminal sets, as the scenario spells them. */
  storage?: { root: string; env: Record<string, string> };
  storageRun?: { code: number; stderr: string };
}

export function storageSetup(ctx: StorageWorld): { root: string; env: Record<string, string> } {
  if (!ctx.storage) {
    const root = NodeFS.mkdtempSync(NodePath.join(NodeOS.tmpdir(), "hal-c2-tui-storage-"));
    ctx.cleanups.push(() => NodeFS.rmSync(root, { recursive: true, force: true }));
    ctx.storage = { root, env: {} };
  }
  return ctx.storage;
}

/** A scenario path inside the sandbox: "~" is the sandbox home, "/x" is "<sandbox>/fs/x". */
export function sandboxPath(ctx: StorageWorld, path: string): string {
  const { root } = storageSetup(ctx);
  if (path === "~" || path.startsWith("~/")) return NodePath.join(root, "home", path.slice(1));
  if (NodePath.isAbsolute(path)) return NodePath.join(root, "fs", path);
  return path;
}

/** Runs the client entry with only the scenario's storage variables set. */
export async function runStorageLaunch(ctx: StorageWorld): Promise<void> {
  const setup = storageSetup(ctx);
  const env: Record<string, string> = {};
  for (const [key, value] of Object.entries(process.env)) {
    if (value === undefined || key.startsWith("HAL_C2_") || key.startsWith("XDG_")) continue;
    env[key] = value;
  }
  const home = sandboxPath(ctx, "~");
  const mapped = Object.fromEntries(
    Object.entries(setup.env).map(([key, value]) => [key, sandboxPath(ctx, value)]),
  );
  const candidates = [
    NodePath.join(home, ".config/hal-c2/shell/tui"),
    mapped.XDG_CONFIG_HOME && NodePath.join(mapped.XDG_CONFIG_HOME, "hal-c2/shell/tui"),
    mapped.HAL_C2_HOME && NodePath.join(mapped.HAL_C2_HOME, "config/shell/tui"),
    mapped.HAL_C2_TUI_SHELL_DIR,
  ];
  for (const dir of candidates) {
    if (!dir) continue;
    NodeFS.mkdirSync(dir, { recursive: true });
    NodeFS.writeFileSync(NodePath.join(dir, "keymap.json"), "{ not json");
  }
  const log = NodePath.join(setup.root, "tui.log");
  // `--base-dir` only places the MC's runtime record, never the shell.
  const mcRoot = NodePath.join(setup.root, "mc");
  const child = Bun.spawn(["bun", "src/index.ts", "--base-dir", mcRoot], {
    cwd: TUI_DIR,
    env: {
      ...env,
      ...mapped,
      HOME: home,
      HAL_C2_TUI_LOG: log,
    },
    stdin: "ignore",
    stdout: "pipe",
    stderr: "pipe",
  });
  const timer = setTimeout(() => child.kill(), ENTRY_TIMEOUT_MS);
  const [code, stderr] = await Promise.all([child.exited, new Response(child.stderr).text()]);
  clearTimeout(timer);
  ctx.storageRun = { code, stderr };
}
