// @effect-diagnostics nodeBuiltinImport:off - Runs the standalone tools against disposable on-disk fixtures.
import * as NodeChildProcess from "node:child_process";
import * as NodeFS from "node:fs";
import * as NodeOS from "node:os";
import * as NodePath from "node:path";
import * as NodeURL from "node:url";
import { afterEach, describe, expect, it } from "vite-plus/test";

const directories: string[] = [];
// oxlint-disable-next-line hal-c2/no-global-process-runtime -- Standalone tooling tests run without an Effect runtime.
const platform = NodeOS.platform();
function temporaryDirectory() {
  const path = NodeFS.mkdtempSync(NodePath.join(NodeOS.tmpdir(), "hal-c2-qt-tooling-"));
  directories.push(path);
  return path;
}
afterEach(() => {
  for (const directory of directories.splice(0))
    NodeFS.rmSync(directory, { recursive: true, force: true });
});

describe.skipIf(platform === "win32")("Qt tooling", () => {
  it("finds the test runner in a later CMAKE_PREFIX_PATH entry", () => {
    const directory = temporaryDirectory();
    const prefix = NodePath.join(directory, "qt");
    NodeFS.mkdirSync(NodePath.join(prefix, "bin"), { recursive: true });
    NodeFS.writeFileSync(
      NodePath.join(prefix, "bin/qmltestrunner"),
      '#!/bin/sh\nprintf "%s\\n" "$@"\n',
      { mode: 0o755 },
    );
    const result = NodeChildProcess.spawnSync(
      process.execPath,
      [NodeURL.fileURLToPath(new URL("./test-qml.mjs", import.meta.url))],
      {
        encoding: "utf8",
        env: {
          ...process.env,
          QT_ROOT_DIR: "",
          QT_PREFIX: "",
          CMAKE_PREFIX_PATH: [NodePath.join(directory, "missing"), prefix].join(NodePath.delimiter),
        },
      },
    );
    expect(result.status).toBe(0);
    expect(result.stdout.trim().split("\n")).toEqual([
      "-input",
      "tests",
      "-import",
      "tests/imports",
    ]);
  });

  describe("check-sqlite-driver.sh", () => {
    const check = (drivers: string, name = "libqsqlite.so") =>
      NodeChildProcess.spawnSync(
        "bash",
        [
          NodeURL.fileURLToPath(new URL("./check-sqlite-driver.sh", import.meta.url)),
          drivers,
          name,
        ],
        { encoding: "utf8" },
      );

    it("passes a bundle whose path has glob characters and holds the driver", () => {
      const drivers = NodePath.join(temporaryDirectory(), "br[ack]et", "sqldrivers");
      NodeFS.mkdirSync(drivers, { recursive: true });
      NodeFS.writeFileSync(NodePath.join(drivers, "libqsqlite.dylib"), "driver");
      expect(check(drivers, "libqsqlite.dylib").status).toBe(0);
    });

    it("names a missing sqldrivers directory", () => {
      const result = check(NodePath.join(temporaryDirectory(), "sqldrivers"));
      expect(result.status).toBe(1);
      expect(result.stderr).toContain("is not a directory");
    });

    it("rejects an empty directory", () => {
      const empty = check(temporaryDirectory());
      expect(empty.status).toBe(1);
      expect(empty.stderr).toContain("has no libqsqlite.so as a regular file");
    });

    it("rejects a directory named like the driver", () => {
      const drivers = temporaryDirectory();
      NodeFS.mkdirSync(NodePath.join(drivers, "libqsqlite.so"));
      const result = check(drivers);
      expect(result.status).toBe(1);
      expect(result.stderr).toContain("has no libqsqlite.so as a regular file");
    });

    it("rejects a dangling symlink named like the driver", () => {
      const drivers = temporaryDirectory();
      NodeFS.symlinkSync(
        NodePath.join(drivers, "gone"),
        NodePath.join(drivers, "libqsqlite.dylib"),
      );
      const dangling = check(drivers, "libqsqlite.dylib");
      expect(dangling.status).toBe(1);
      expect(dangling.stderr).toContain("is a symlink");
    });

    it("wants the driver of the bundle's own platform", () => {
      const drivers = temporaryDirectory();
      NodeFS.writeFileSync(NodePath.join(drivers, "libqsqlite.dylib"), "driver");
      const linux = check(drivers, "libqsqlite.so");
      expect(linux.status).toBe(1);
      expect(linux.stderr).toContain("has no libqsqlite.so");
      NodeFS.writeFileSync(NodePath.join(drivers, "libqsqlite.so"), "driver");
      expect(check(drivers, "libqsqlite.so").status).toBe(0);
      NodeFS.rmSync(NodePath.join(drivers, "libqsqlite.dylib"));
      expect(check(drivers, "libqsqlite.dylib").status).toBe(1);
    });

    it("rejects an empty driver file", () => {
      const drivers = temporaryDirectory();
      NodeFS.writeFileSync(NodePath.join(drivers, "libqsqlite.so"), "");
      const result = check(drivers);
      expect(result.status).toBe(1);
      expect(result.stderr).toContain("is empty");
    });

    it("rejects copies that are not named like Qt's driver", () => {
      const drivers = temporaryDirectory();
      NodeFS.writeFileSync(NodePath.join(drivers, "libqsqliteNOTREAL"), "driver");
      NodeFS.writeFileSync(NodePath.join(drivers, "libqsqlite.so.bak"), "driver");
      const result = check(drivers);
      expect(result.status).toBe(1);
      expect(result.stderr).toContain("has no libqsqlite.so as a regular file");
    });

    // The bundle carries the link, not its target, which need not exist where the app runs.
    it("rejects a symlink, whether it points out of the bundle or into it", () => {
      const drivers = temporaryDirectory();
      const outside = NodePath.join(temporaryDirectory(), "libqsqlite.real");
      NodeFS.writeFileSync(outside, "driver");
      NodeFS.symlinkSync(outside, NodePath.join(drivers, "libqsqlite.so"));
      const linked = check(drivers);
      expect(linked.status).toBe(1);
      expect(linked.stderr).toContain("is a symlink");
      const inside = temporaryDirectory();
      NodeFS.writeFileSync(NodePath.join(inside, "libqsqlite.real"), "driver");
      NodeFS.symlinkSync("libqsqlite.real", NodePath.join(inside, "libqsqlite.so"));
      expect(check(inside).status).toBe(1);
    });

    it("rejects a symlinked sqldrivers directory", () => {
      const root = temporaryDirectory();
      const real = NodePath.join(root, "real");
      NodeFS.mkdirSync(real);
      NodeFS.writeFileSync(NodePath.join(real, "libqsqlite.so"), "driver");
      const drivers = NodePath.join(root, "sqldrivers");
      NodeFS.symlinkSync(real, drivers);
      const result = check(drivers);
      expect(result.status).toBe(1);
      expect(result.stderr).toContain("is a symlink");
      // However the caller spells it: a trailing slash must not follow the link.
      const trailing = check(drivers + "/");
      expect(trailing.status).toBe(1);
      expect(trailing.stderr).toContain("is a symlink");
    });

    it("rejects a driver name that is not one of Qt's two", () => {
      // The allowlist is what stops the name escaping the directory at the join.
      expect(check(temporaryDirectory(), "../libqsqlite.so").status).toBe(1);
      expect(check(temporaryDirectory(), "libqsqlite.so.bak").status).toBe(1);
    });

    it("is invoked by both packagers with their platform's driver, where it guards", () => {
      const read = (name: string) =>
        NodeFS.readFileSync(new URL(`./${name}`, import.meta.url), "utf8");
      const linux = read("package-linux.sh");
      expect(linux).toContain(
        'check-sqlite-driver.sh" "${app_dir}/usr/plugins/sqldrivers" libqsqlite.so',
      );
      // After Qt's plugins are deployed, before the AppImage is written.
      expect(linux.indexOf("check-sqlite-driver.sh")).toBeGreaterThan(linux.indexOf("--plugin qt"));
      expect(linux.indexOf("check-sqlite-driver.sh")).toBeLessThan(
        linux.indexOf("--output appimage"),
      );
      const macos = read("package-macos.sh");
      expect(macos).toContain(
        'check-sqlite-driver.sh" "${app}/Contents/PlugIns/sqldrivers" libqsqlite.dylib',
      );
      // After the pruning loop that can remove the driver, before signing.
      expect(macos.indexOf("check-sqlite-driver.sh")).toBeGreaterThan(
        macos.indexOf("-name '*.dylib'"),
      );
      expect(macos.indexOf("check-sqlite-driver.sh")).toBeLessThan(macos.indexOf("codesign"));
    });

    it("runs directly, as the packagers invoke it", () => {
      const drivers = temporaryDirectory();
      NodeFS.writeFileSync(NodePath.join(drivers, "libqsqlite.so"), "driver");
      const script = NodeURL.fileURLToPath(new URL("./check-sqlite-driver.sh", import.meta.url));
      const result = NodeChildProcess.spawnSync(script, [drivers, "libqsqlite.so"], {
        encoding: "utf8",
      });
      expect(result.error).toBeUndefined();
      expect(result.status).toBe(0);
    });
  });

  it.skipIf(platform !== "linux")(
    "rejects tampered cached packaging tools before installing or executing them",
    () => {
      const directory = temporaryDirectory();
      NodeFS.mkdirSync(NodePath.join(directory, "tools"));
      NodeFS.mkdirSync(NodePath.join(directory, "AppDir"));
      NodeFS.writeFileSync(NodePath.join(directory, "AppDir/keep"), "existing staging directory");
      NodeFS.writeFileSync(
        NodePath.join(directory, "tools/linuxdeploy-1-alpha-20251107-1"),
        "tampered tool",
        { mode: 0o755 },
      );
      const result = NodeChildProcess.spawnSync(
        "bash",
        [NodeURL.fileURLToPath(new URL("./package-linux.sh", import.meta.url)), directory],
        { encoding: "utf8" },
      );
      expect(result.status).not.toBe(0);
      expect(NodeFS.readFileSync(NodePath.join(directory, "AppDir/keep"), "utf8")).toBe(
        "existing staging directory",
      );
    },
  );
});

describe.skipIf(platform === "win32")("theme-from-terminal output", () => {
  it("writes into the shell's config dir: HAL_C2_HOME, then XDG, or the dev profile", async () => {
    const {
      resolveOutput,
    }: {
      resolveOutput: (
        argument: string | undefined,
        env: Record<string, string>,
        dev?: boolean,
      ) => string;
    } = await import(new URL("./theme-from-terminal.mjs", import.meta.url).href);
    const home = NodeOS.homedir();
    expect(resolveOutput(undefined, {})).toBe(
      NodePath.join(home, ".config/hal-c2/shell/theme.json"),
    );
    expect(resolveOutput(undefined, { XDG_CONFIG_HOME: "/xdg/config" })).toBe(
      "/xdg/config/hal-c2/shell/theme.json",
    );
    expect(resolveOutput(undefined, { XDG_CONFIG_HOME: "config" })).toBe(
      NodePath.join(home, ".config/hal-c2/shell/theme.json"),
    );
    expect(resolveOutput(undefined, { HAL_C2_HOME: "/srv/hal-c2" })).toBe(
      "/srv/hal-c2/config/shell/theme.json",
    );
    expect(resolveOutput(undefined, { HAL_C2_HOME: NodePath.join(home, ".hal-c2") })).toBe(
      NodePath.join(home, ".config/hal-c2/shell/theme.json"),
    );
    expect(resolveOutput(undefined, { HAL_C2_HOME: "/srv/hal-c2" }, true)).toBe(
      NodePath.join(home, ".config/hal-c2-dev/shell/theme.json"),
    );
    expect(resolveOutput(undefined, { XDG_CONFIG_HOME: "/xdg/config" }, true)).toBe(
      "/xdg/config/hal-c2-dev/shell/theme.json",
    );
    expect(resolveOutput("/elsewhere/rice.json", {})).toBe("/elsewhere/rice.json");
  });
});
