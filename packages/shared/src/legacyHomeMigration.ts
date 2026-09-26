// @effect-diagnostics nodeBuiltinImport:off - plain async Node so Electron and the server can both run it before any Effect runtime.
// @effect-diagnostics globalDate:off -- the migration record is written before any Effect runtime exists.
/**
 * The one-shot copy from an old home (`~/.t3`, `~/.hal-c2`, or one named by
 * `T3CODE_HOME`/`T3_HOME`) into HAL-C2's XDG directories
 * (`features/node/platform/storage-migration.feature`).
 *
 * It copies, never moves or links, and only what the user cannot get back:
 * settings, the database, secrets, attachments, sign-ins, logs. Caches, tools,
 * old CLI versions and `<old home>/worktrees` stay behind; git worktrees are
 * registered by absolute path and keep working where they are.
 *
 * Everything is staged beside its final directory as `<dir>.migrating-<pid>`
 * and renamed into place, so a failed or interrupted copy never leaves a
 * half-migrated data directory. `state/migrated-from.json` records the result
 * and stops it from running twice. The Electron app may call this before it
 * starts the server, and the server calls it again; the second call sees the
 * data directory and does nothing.
 */

import * as NodeFS from "node:fs";
import * as NodePath from "node:path";
import { DatabaseSync } from "node:sqlite";

import {
  HAL_C2_DEV_APP_DIR,
  legacyHomeCandidates,
  type HalC2Dirs,
  type HalC2DirsEnvironment,
  type HalC2Profile,
} from "./xdgDirs.ts";

export interface LegacyHomeMigrationResult {
  /** The old home copied from. */
  readonly source: string | undefined;
  /** Paths copied, relative to the old home. */
  readonly copied: readonly string[];
  readonly outcome: "migrated" | "no-source" | "already-done" | "opted-out" | "failed";
  readonly error?: string;
}

export interface LegacyHomeMigrationOptions {
  readonly dirs: HalC2Dirs;
  readonly env: HalC2DirsEnvironment & { readonly HAL_C2_NO_MIGRATE?: string | undefined };
  readonly homeDir: string;
  readonly platform: NodeJS.Platform;
  /** `hal-c2` copies `<old home>/userdata`; `hal-c2-dev` copies `<old home>/dev`. */
  readonly profile: HalC2Profile;
  readonly log: (line: string) => void;
}

export const MIGRATION_RECORD_FILE = "migrated-from.json";

/** Files whose presence means the data directory already belongs to HAL-C2. */
const DATA_MARKERS = ["environment-id", "statev2.sqlite"] as const;

const PROFILE_CONFIG_ENTRIES = [
  "settings.json",
  "keybindings.json",
  "themes",
  "desktop-settings.json",
  "client-settings.json",
] as const;

const PROFILE_DATABASES = ["statev2.sqlite", "state.sqlite"] as const;

const PROFILE_DATA_ENTRIES = [
  "attachments",
  "secrets",
  "environment-id",
  "clerk-tokens.json",
  "saved-environments.json",
  "connection-catalog.json",
  "browser-artifacts",
  "snap-shots",
  "providers",
  "device",
] as const;

const PROFILE_STATE_ENTRIES = ["logs"] as const;

type Kind = "config" | "data" | "state";

const KINDS: readonly Kind[] = ["config", "data", "state"];

const isDirectory = (candidate: string): boolean => {
  try {
    return NodeFS.statSync(candidate).isDirectory();
  } catch {
    return false;
  }
};

const exists = (candidate: string): boolean => NodeFS.existsSync(candidate);

const optedOut = (value: string | undefined): boolean => {
  const trimmed = value?.trim().toLowerCase();
  return trimmed !== undefined && trimmed !== "" && trimmed !== "0" && trimmed !== "false";
};

const errorMessage = (cause: unknown): string =>
  cause instanceof Error ? cause.message : String(cause);

const recordPath = (dirs: HalC2Dirs) => NodePath.join(dirs.state, MIGRATION_RECORD_FILE);

const writeRecord = async (dirs: HalC2Dirs, record: object): Promise<void> => {
  await NodeFS.promises.mkdir(dirs.state, { recursive: true, mode: 0o700 });
  const target = recordPath(dirs);
  const temporary = `${target}.${process.pid}.tmp`;
  await NodeFS.promises.writeFile(temporary, `${JSON.stringify(record, null, 2)}\n`, {
    mode: 0o600,
  });
  await NodeFS.promises.rename(temporary, target);
};

const pidIsAlive = (pid: number): boolean => {
  if (pid === process.pid) {
    return true;
  }
  try {
    process.kill(pid, 0);
    return true;
  } catch (cause) {
    return (cause as NodeJS.ErrnoException).code === "EPERM";
  }
};

/** Removes staging directories that a crashed earlier run left beside `dir`. */
const removeAbandonedStaging = async (dir: string): Promise<void> => {
  const parent = NodePath.dirname(dir);
  const prefix = `${NodePath.basename(dir)}.migrating-`;
  let entries: string[];
  try {
    entries = await NodeFS.promises.readdir(parent);
  } catch {
    return;
  }
  for (const entry of entries) {
    if (!entry.startsWith(prefix)) {
      continue;
    }
    const pid = Number(entry.slice(prefix.length));
    if (Number.isInteger(pid) && pidIsAlive(pid)) {
      continue;
    }
    await NodeFS.promises.rm(NodePath.join(parent, entry), { recursive: true, force: true });
  }
};

/** A consistent snapshot of a database that another process may have open. */
const snapshotDatabase = (source: string, target: string): void => {
  const temporary = `${target}.tmp`;
  NodeFS.rmSync(temporary, { force: true });
  const database = new DatabaseSync(source, { readOnly: true });
  try {
    database.exec(`VACUUM INTO '${temporary.replaceAll("'", "''")}'`);
  } finally {
    database.close();
  }
  NodeFS.renameSync(temporary, target);
};

const copyEntry = async (
  source: string,
  target: string,
  filter?: (source: string) => boolean,
): Promise<void> => {
  await NodeFS.promises.mkdir(NodePath.dirname(target), { recursive: true, mode: 0o700 });
  await NodeFS.promises.cp(source, target, {
    recursive: true,
    errorOnExist: true,
    force: false,
    preserveTimestamps: true,
    verbatimSymlinks: true,
    ...(filter ? { filter } : {}),
  });
};

/**
 * Moves each staged entry into `finalDir`, or renames the whole staging
 * directory when `finalDir` does not exist yet. An entry already at its final
 * path is kept: the user's own file wins over the old home's copy.
 */
const promote = async (staging: string, finalDir: string): Promise<void> => {
  if (!exists(finalDir)) {
    await NodeFS.promises.mkdir(NodePath.dirname(finalDir), { recursive: true });
    await NodeFS.promises.rename(staging, finalDir);
    return;
  }
  const promoteInto = async (from: string, to: string): Promise<void> => {
    for (const entry of await NodeFS.promises.readdir(from, { withFileTypes: true })) {
      const source = NodePath.join(from, entry.name);
      const target = NodePath.join(to, entry.name);
      if (!exists(target)) {
        await NodeFS.promises.rename(source, target);
      } else if (entry.isDirectory() && isDirectory(target)) {
        await promoteInto(source, target);
      }
    }
  };
  await promoteInto(staging, finalDir);
  await NodeFS.promises.rm(staging, { recursive: true, force: true });
};

const hasDataOfItsOwn = (dirs: HalC2Dirs): boolean =>
  DATA_MARKERS.some((marker) => exists(NodePath.join(dirs.data, marker)));

/**
 * Copies from the first old home that exists into `dirs`, once. Never throws
 * and never writes to the old home.
 */
export const migrateLegacyHome = async (
  options: LegacyHomeMigrationOptions,
): Promise<LegacyHomeMigrationResult> => {
  const { dirs, env, log } = options;
  const staging = new Map<Kind, string>(
    KINDS.map((kind) => [kind, `${dirs[kind]}.migrating-${process.pid}`]),
  );
  let source: string | undefined;

  try {
    if (hasDataOfItsOwn(dirs) || exists(recordPath(dirs))) {
      return { source: undefined, copied: [], outcome: "already-done" };
    }

    if (optedOut(env.HAL_C2_NO_MIGRATE)) {
      await writeRecord(dirs, { source: null, skipped: true, at: new Date().toISOString() });
      log("HAL_C2_NO_MIGRATE is set: starting fresh without copying from an old home.");
      return { source: undefined, copied: [], outcome: "opted-out" };
    }

    source = legacyHomeCandidates(options).find(isDirectory);
    if (source === undefined) {
      return { source: undefined, copied: [], outcome: "no-source" };
    }

    for (const kind of KINDS) {
      await removeAbandonedStaging(dirs[kind]);
      await NodeFS.promises.rm(staging.get(kind)!, { recursive: true, force: true });
      await NodeFS.promises.mkdir(staging.get(kind)!, { recursive: true, mode: 0o700 });
    }

    const copied: string[] = [];
    const home = source;
    const profileDir = options.profile === HAL_C2_DEV_APP_DIR ? "dev" : "userdata";
    const copy = async (
      relative: string,
      kind: Kind,
      targetRelative: string,
      filter?: (source: string) => boolean,
    ) => {
      const from = NodePath.join(home, relative);
      if (!exists(from)) {
        return;
      }
      await copyEntry(from, NodePath.join(staging.get(kind)!, targetRelative), filter);
      copied.push(relative);
    };

    for (const entry of PROFILE_CONFIG_ENTRIES) {
      await copy(NodePath.join(profileDir, entry), "config", entry);
    }
    await copy("shell", "config", "shell");

    for (const database of PROFILE_DATABASES) {
      const relative = NodePath.join(profileDir, database);
      const from = NodePath.join(home, relative);
      if (exists(from)) {
        snapshotDatabase(from, NodePath.join(staging.get("data")!, database));
        copied.push(relative);
      }
    }
    for (const entry of PROFILE_DATA_ENTRIES) {
      await copy(NodePath.join(profileDir, entry), "data", entry);
    }
    const stagedSecrets = NodePath.join(staging.get("data")!, "secrets");
    if (exists(stagedSecrets)) {
      await NodeFS.promises.chmod(stagedSecrets, 0o700);
    }

    // ACP sign-ins lived among the caches, but they are auth state.
    const caches = NodePath.join(home, "caches");
    if (isDirectory(caches)) {
      for (const entry of (await NodeFS.promises.readdir(caches)).toSorted()) {
        if (entry.startsWith("acp-auth-") && entry.endsWith(".json")) {
          await copy(NodePath.join("caches", entry), "data", NodePath.join("acp-auth", entry));
        }
      }
    }

    // Old CLI versions are downloaded again; database backups are not.
    const runtimeVersions = NodePath.join(home, "runtime", "versions");
    await copy(
      "runtime",
      "data",
      "runtime",
      (candidate) =>
        candidate !== runtimeVersions && !candidate.startsWith(runtimeVersions + NodePath.sep),
    );

    for (const entry of PROFILE_STATE_ENTRIES) {
      await copy(NodePath.join(profileDir, entry), "state", entry);
    }

    // Another process may have finished first; its data wins.
    if (hasDataOfItsOwn(dirs) || exists(recordPath(dirs))) {
      for (const kind of KINDS) {
        await NodeFS.promises.rm(staging.get(kind)!, { recursive: true, force: true });
      }
      return { source: undefined, copied: [], outcome: "already-done" };
    }

    // The data directory goes last: its existence is what marks the migration done.
    await promote(staging.get("config")!, dirs.config);
    await promote(staging.get("state")!, dirs.state);
    await promote(staging.get("data")!, dirs.data);
    await writeRecord(dirs, { source, at: new Date().toISOString(), copied });
    log(`Migrated from ${source} into the XDG directories (${copied.length} items copied).`);
    return { source, copied, outcome: "migrated" };
  } catch (cause) {
    const error = errorMessage(cause);
    for (const dir of staging.values()) {
      try {
        NodeFS.rmSync(dir, { recursive: true, force: true });
      } catch {
        // Best effort: an abandoned staging dir is removed on the next start.
      }
    }
    log(`Warning: migrating from ${source ?? "the old home"} failed, starting fresh: ${error}`);
    return { source, copied: [], outcome: "failed", error };
  }
};
