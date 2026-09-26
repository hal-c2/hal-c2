// @effect-diagnostics nodeBuiltinImport:off - builds real old homes on disk.
import * as NodeFS from "node:fs";
import * as NodeOS from "node:os";
import * as NodePath from "node:path";
import { DatabaseSync } from "node:sqlite";

import { afterEach, describe, expect, it } from "@effect/vitest";

import { migrateLegacyHome, type LegacyHomeMigrationOptions } from "./legacyHomeMigration.ts";
import { resolveHalC2Dirs, type HalC2Profile } from "./xdgDirs.ts";

const roots: string[] = [];
const openDatabases: DatabaseSync[] = [];

afterEach(() => {
  for (const database of openDatabases.splice(0)) {
    database.close();
  }
  for (const root of roots.splice(0)) {
    NodeFS.rmSync(root, { recursive: true, force: true });
  }
});

const makeHome = () => {
  const homeDir = NodeFS.mkdtempSync(NodePath.join(NodeOS.tmpdir(), "hal-c2-migrate-"));
  roots.push(homeDir);
  return homeDir;
};

const write = (file: string, contents = "x") => {
  NodeFS.mkdirSync(NodePath.dirname(file), { recursive: true });
  NodeFS.writeFileSync(file, contents);
};

/** A WAL database with a committed row, left open like a running T3 Code would. */
const writeOpenDatabase = (file: string, value: string) => {
  NodeFS.mkdirSync(NodePath.dirname(file), { recursive: true });
  const database = new DatabaseSync(file);
  database.exec("PRAGMA journal_mode = WAL");
  database.exec("CREATE TABLE threads (title TEXT)");
  database.prepare("INSERT INTO threads (title) VALUES (?)").run(value);
  openDatabases.push(database);
};

const readTitle = (file: string) => {
  const database = new DatabaseSync(file, { readOnly: true });
  try {
    return (database.prepare("SELECT title FROM threads").get() as { title: string }).title;
  } finally {
    database.close();
  }
};

/**
 * Every path and its bytes, to prove the old home is left as it was. A WAL
 * database's `-shm` index is shared memory that every reader updates, so only
 * its presence is compared.
 */
const snapshot = (dir: string): Record<string, string> => {
  const result: Record<string, string> = {};
  for (const entry of NodeFS.readdirSync(dir, { recursive: true, withFileTypes: true })) {
    const full = NodePath.join(entry.parentPath, entry.name);
    const relative = NodePath.relative(dir, full);
    result[relative] =
      entry.isFile() && !entry.name.endsWith("-shm")
        ? NodeFS.readFileSync(full).toString("base64")
        : entry.isFile()
          ? "shm"
          : "dir";
  }
  return result;
};

const optionsFor = (
  homeDir: string,
  overrides: Partial<LegacyHomeMigrationOptions> & { profile?: HalC2Profile } = {},
) => {
  const lines: string[] = [];
  const env = overrides.env ?? {};
  const profile = overrides.profile ?? "hal-c2";
  const options: LegacyHomeMigrationOptions = {
    dirs: resolveHalC2Dirs({ env, homeDir, platform: "linux", profile }),
    env,
    homeDir,
    platform: "linux",
    profile,
    log: (line) => lines.push(line),
    ...overrides,
  };
  return { options, lines, dirs: options.dirs };
};

const makeT3Home = (homeDir: string) => {
  const t3 = NodePath.join(homeDir, ".t3");
  write(NodePath.join(t3, "userdata", "settings.json"), '{"theme":"dark"}');
  write(NodePath.join(t3, "userdata", "keybindings.json"), "[]");
  write(NodePath.join(t3, "userdata", "themes", "mine.json"), "{}");
  write(NodePath.join(t3, "userdata", "desktop-settings.json"), "{}");
  write(NodePath.join(t3, "userdata", "environment-id"), "env-1");
  write(NodePath.join(t3, "userdata", "saved-environments.json"), "[]");
  write(NodePath.join(t3, "userdata", "secrets", "token.bin"), "secret");
  write(NodePath.join(t3, "userdata", "attachments", "a.png"), "png");
  write(NodePath.join(t3, "userdata", "logs", "server.log"), "log");
  write(NodePath.join(t3, "userdata", "model-manifest.json"), "{}");
  write(NodePath.join(t3, "userdata", "shell-web", "Cookies"), "c");
  write(NodePath.join(t3, "shell", "shell.qml"), "Item {}");
  write(NodePath.join(t3, "shell", "tui", "shell.qml"), "Item {}");
  write(NodePath.join(t3, "caches", "acp-auth-claude.json"), "{}");
  write(NodePath.join(t3, "caches", "provider-status", "codex.json"), "{}");
  write(NodePath.join(t3, "caches", "pull-requests", "1.json"), "{}");
  write(NodePath.join(t3, "tools", "cloudflared", "bin"), "bin");
  write(NodePath.join(t3, "runtime", "versions", "1.0.0", "bin"), "bin");
  write(NodePath.join(t3, "runtime", "db-backup", "1", "statev2.sqlite"), "backup");
  write(NodePath.join(t3, "worktrees", "api", "feature", "README.md"), "wt");
  write(NodePath.join(t3, "dev", "settings.json"), '{"dev":true}');
  writeOpenDatabase(NodePath.join(t3, "userdata", "statev2.sqlite"), "from userdata");
  return t3;
};

describe("migrateLegacyHome", () => {
  it("copies what the user cannot get back into the kind it belongs to", async () => {
    const homeDir = makeHome();
    const t3 = makeT3Home(homeDir);
    const before = snapshot(t3);
    const { options, lines, dirs } = optionsFor(homeDir);

    const result = await migrateLegacyHome(options);

    expect(result.outcome).toBe("migrated");
    expect(result.source).toBe(t3);
    const at = (dir: string, ...parts: string[]) => NodePath.join(dir, ...parts);
    expect(NodeFS.readFileSync(at(dirs.config, "settings.json"), "utf8")).toBe('{"theme":"dark"}');
    expect(NodeFS.existsSync(at(dirs.config, "themes", "mine.json"))).toBe(true);
    expect(NodeFS.existsSync(at(dirs.config, "desktop-settings.json"))).toBe(true);
    expect(NodeFS.existsSync(at(dirs.config, "shell", "tui", "shell.qml"))).toBe(true);
    expect(readTitle(at(dirs.data, "statev2.sqlite"))).toBe("from userdata");
    expect(NodeFS.readFileSync(at(dirs.data, "environment-id"), "utf8")).toBe("env-1");
    expect(NodeFS.existsSync(at(dirs.data, "attachments", "a.png"))).toBe(true);
    expect(NodeFS.existsSync(at(dirs.data, "saved-environments.json"))).toBe(true);
    expect(NodeFS.existsSync(at(dirs.data, "acp-auth", "acp-auth-claude.json"))).toBe(true);
    expect(NodeFS.existsSync(at(dirs.data, "runtime", "db-backup", "1", "statev2.sqlite"))).toBe(
      true,
    );
    expect(NodeFS.existsSync(at(dirs.state, "logs", "server.log"))).toBe(true);
    expect(NodeFS.statSync(at(dirs.data, "secrets")).mode & 0o777).toBe(0o700);

    // What can be fetched or rebuilt again stays behind, and so do worktrees.
    expect(NodeFS.existsSync(at(dirs.data, "runtime", "versions"))).toBe(false);
    expect(NodeFS.existsSync(at(dirs.data, "model-manifest.json"))).toBe(false);
    expect(NodeFS.existsSync(at(dirs.data, "shell-web"))).toBe(false);
    expect(NodeFS.existsSync(at(dirs.data, "worktrees"))).toBe(false);
    expect(NodeFS.existsSync(dirs.cache)).toBe(false);
    expect(result.copied).not.toContain("tools");
    expect(result.copied).not.toContain("worktrees");

    const record = JSON.parse(NodeFS.readFileSync(at(dirs.state, "migrated-from.json"), "utf8"));
    expect(record.source).toBe(t3);
    expect(record.copied).toEqual(result.copied);
    expect(typeof record.at).toBe("string");
    expect(lines).toHaveLength(1);
    expect(lines[0]).toContain(t3);

    expect(snapshot(t3)).toEqual(before);
    expect(
      NodeFS.readdirSync(NodePath.dirname(dirs.data)).filter((e) => e.includes("migrating")),
    ).toEqual([]);
  });

  it("does nothing on a second call", async () => {
    const homeDir = makeHome();
    makeT3Home(homeDir);
    const { options } = optionsFor(homeDir);
    expect((await migrateLegacyHome(options)).outcome).toBe("migrated");
    expect(await migrateLegacyHome(options)).toEqual({
      source: undefined,
      copied: [],
      outcome: "already-done",
    });
  });

  it("copies a development profile from the old dev directory", async () => {
    const homeDir = makeHome();
    makeT3Home(homeDir);
    const { options, dirs } = optionsFor(homeDir, { profile: "hal-c2-dev" });
    expect((await migrateLegacyHome(options)).outcome).toBe("migrated");
    expect(dirs.config).toContain("hal-c2-dev");
    expect(NodeFS.readFileSync(NodePath.join(dirs.config, "settings.json"), "utf8")).toBe(
      '{"dev":true}',
    );
    expect(NodeFS.existsSync(NodePath.join(dirs.data, "statev2.sqlite"))).toBe(false);
  });

  it("picks T3CODE_HOME first, then ~/.hal-c2, then ~/.t3, skipping a missing one", async () => {
    const homeDir = makeHome();
    makeT3Home(homeDir);
    write(NodePath.join(homeDir, ".hal-c2", "userdata", "environment-id"), "hal");
    const relocated = NodePath.join(homeDir, "srv-t3");
    write(NodePath.join(relocated, "userdata", "environment-id"), "relocated");

    const withRelocated = optionsFor(homeDir, { env: { T3CODE_HOME: relocated } });
    expect((await migrateLegacyHome(withRelocated.options)).source).toBe(relocated);

    const other = makeHome();
    makeT3Home(other);
    write(NodePath.join(other, ".hal-c2", "userdata", "environment-id"), "hal");
    const missing = optionsFor(other, { env: { T3CODE_HOME: NodePath.join(other, "gone") } });
    const result = await migrateLegacyHome(missing.options);
    expect(result.source).toBe(NodePath.join(other, ".hal-c2"));
    expect(NodeFS.readFileSync(NodePath.join(missing.dirs.data, "environment-id"), "utf8")).toBe(
      "hal",
    );
  });

  it("reports no source and records nothing on a fresh machine", async () => {
    const homeDir = makeHome();
    const { options, dirs } = optionsFor(homeDir);
    expect((await migrateLegacyHome(options)).outcome).toBe("no-source");
    expect(NodeFS.existsSync(dirs.state)).toBe(false);
    expect(NodeFS.existsSync(dirs.data)).toBe(false);
  });

  it("does not read the old home when HAL-C2 already has data", async () => {
    const homeDir = makeHome();
    makeT3Home(homeDir);
    const { options, dirs } = optionsFor(homeDir);
    write(NodePath.join(dirs.data, "statev2.sqlite"), "");
    expect((await migrateLegacyHome(options)).outcome).toBe("already-done");
    expect(NodeFS.existsSync(NodePath.join(dirs.config, "settings.json"))).toBe(false);
  });

  it("merges into a config dir that already exists but holds no data", async () => {
    const homeDir = makeHome();
    makeT3Home(homeDir);
    write(NodePath.join(homeDir, ".t3", "userdata", "client-settings.json"), '{"c":1}');
    write(NodePath.join(homeDir, ".t3", "userdata", "clerk-tokens.json"), "{}");
    write(NodePath.join(homeDir, ".t3", "userdata", "connection-catalog.json"), "{}");
    write(NodePath.join(homeDir, ".t3", "userdata", "snap-shots", "s.png"), "png");
    write(NodePath.join(homeDir, ".t3", "userdata", "browser-artifacts", "b.json"), "{}");
    const { options, dirs } = optionsFor(homeDir);
    // A desktop app that started first may have made an empty shell dir.
    NodeFS.mkdirSync(NodePath.join(dirs.config, "shell"), { recursive: true });

    expect((await migrateLegacyHome(options)).outcome).toBe("migrated");
    expect(NodeFS.existsSync(NodePath.join(dirs.config, "shell", "tui", "shell.qml"))).toBe(true);
    expect(NodeFS.existsSync(NodePath.join(dirs.config, "shell", "shell.qml"))).toBe(true);
    expect(NodeFS.readFileSync(NodePath.join(dirs.config, "client-settings.json"), "utf8")).toBe(
      '{"c":1}',
    );
    for (const entry of [
      "clerk-tokens.json",
      "connection-catalog.json",
      "snap-shots/s.png",
      "browser-artifacts/b.json",
    ]) {
      expect(NodeFS.existsSync(NodePath.join(dirs.data, entry))).toBe(true);
    }
  });

  it("does not run again after the data directory is removed, until the record is", async () => {
    const homeDir = makeHome();
    makeT3Home(homeDir);
    const { options, dirs } = optionsFor(homeDir);
    await migrateLegacyHome(options);
    NodeFS.rmSync(dirs.data, { recursive: true });
    expect((await migrateLegacyHome(options)).outcome).toBe("already-done");
    NodeFS.rmSync(NodePath.join(dirs.state, "migrated-from.json"));
    expect((await migrateLegacyHome(options)).outcome).toBe("migrated");
  });

  it("records an opt-out so a later start does not migrate", async () => {
    const homeDir = makeHome();
    makeT3Home(homeDir);
    const optedOut = optionsFor(homeDir, { env: { HAL_C2_NO_MIGRATE: "1" } });
    expect((await migrateLegacyHome(optedOut.options)).outcome).toBe("opted-out");
    const record = JSON.parse(
      NodeFS.readFileSync(NodePath.join(optedOut.dirs.state, "migrated-from.json"), "utf8"),
    );
    expect(record).toMatchObject({ source: null, skipped: true });
    expect(NodeFS.existsSync(optedOut.dirs.data)).toBe(false);

    expect((await migrateLegacyHome(optionsFor(homeDir).options)).outcome).toBe("already-done");
  });

  it("starts fresh and leaves no half-copied data when a copy fails", async () => {
    const homeDir = makeHome();
    const t3 = makeT3Home(homeDir);
    write(NodePath.join(t3, "userdata", "state.sqlite"), "this is not a database");
    const before = snapshot(t3);
    const { options, dirs, lines } = optionsFor(homeDir);

    const result = await migrateLegacyHome(options);

    expect(result.outcome).toBe("failed");
    expect(result.error).toBeDefined();
    expect(NodeFS.existsSync(dirs.data)).toBe(false);
    expect(NodeFS.existsSync(NodePath.join(dirs.state, "migrated-from.json"))).toBe(false);
    for (const dir of [dirs.config, dirs.data, dirs.state]) {
      const siblings = NodeFS.existsSync(NodePath.dirname(dir))
        ? NodeFS.readdirSync(NodePath.dirname(dir))
        : [];
      expect(siblings.filter((entry) => entry.includes(".migrating-"))).toEqual([]);
    }
    expect(lines.join("\n")).toContain(t3);
    expect(snapshot(t3)).toEqual(before);
  });

  it("starts again from the beginning after a crash mid-copy", async () => {
    const homeDir = makeHome();
    makeT3Home(homeDir);
    const { options, dirs } = optionsFor(homeDir);
    // No live process has this pid; its staging dir is what a crash leaves.
    const abandoned = `${dirs.data}.migrating-2147483646`;
    write(NodePath.join(abandoned, "environment-id"), "half");

    expect((await migrateLegacyHome(options)).outcome).toBe("migrated");
    expect(NodeFS.existsSync(abandoned)).toBe(false);
    expect(NodeFS.readFileSync(NodePath.join(dirs.data, "environment-id"), "utf8")).toBe("env-1");
  });
});
