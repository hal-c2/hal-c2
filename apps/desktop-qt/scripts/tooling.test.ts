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

describe.skipIf(platform === "win32")("dev-qt", () => {
  it("refuses a standalone MC release without a home of its own", () => {
    const result = NodeChildProcess.spawnSync(
      process.execPath,
      [NodeURL.fileURLToPath(new URL("./dev-qt.mjs", import.meta.url)), "--standalone"],
      {
        encoding: "utf8",
        env: { ...process.env, HAL_C2_MC_RELEASE: "/opt/hal-c2-mc", HAL_C2_MC_HOME: "" },
      },
    );
    expect(result.status).toBe(1);
    expect(result.stderr).toContain("--home-dir");
  });
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
