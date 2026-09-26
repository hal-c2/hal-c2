import { describe, expect, it } from "bun:test";

import { LaunchError, parseLaunchArgs, resolveNodeDirs } from "./nodeDiscovery.ts";

describe("parseLaunchArgs", () => {
  it("reads both flags in either spelling", () => {
    expect(
      parseLaunchArgs(["--url", "https://node.example/?token=t", "--base-dir=/tmp/x"]),
    ).toEqual({
      url: "https://node.example/?token=t",
      baseDir: "/tmp/x",
    });
  });

  it("rejects an unknown flag and a flag without a value", () => {
    expect(() => parseLaunchArgs(["--port", "1"])).toThrow(LaunchError);
    expect(() => parseLaunchArgs(["--url"])).toThrow("--url needs a value.");
  });
});

describe("resolveNodeDirs", () => {
  const base = { homeDir: "/home/u", platform: "linux" as const };

  it("puts the node under an elixir level of a root", () => {
    expect(resolveNodeDirs({ ...base, baseDir: "/w/.hal-c2", env: {} })).toEqual({
      state: "/w/.hal-c2/state/elixir",
      data: "/w/.hal-c2/data/elixir",
    });
  });

  it("uses HAL_C2_NODE_HOME directly, unless a base dir is given", () => {
    const env = { HAL_C2_NODE_HOME: "/n" };
    expect(resolveNodeDirs({ ...base, env })).toEqual({ state: "/n/state", data: "/n/data" });
    expect(resolveNodeDirs({ ...base, baseDir: "/r", env }).state).toBe("/r/state/elixir");
  });
});
