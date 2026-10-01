import { describe, expect, it } from "bun:test";

import { LaunchError, parseLaunchArgs, resolveMcDirs } from "./mcDiscovery.ts";

describe("parseLaunchArgs", () => {
  it("reads both flags in either spelling", () => {
    expect(parseLaunchArgs(["--url", "https://mc.example/?token=t", "--base-dir=/tmp/x"])).toEqual({
      url: "https://mc.example/?token=t",
      baseDir: "/tmp/x",
    });
  });

  it("reads --dev as a switch", () => {
    expect(parseLaunchArgs(["--dev", "--url=https://mc.example"])).toEqual({
      dev: true,
      url: "https://mc.example",
    });
  });

  it("rejects an unknown flag and a flag without a value", () => {
    expect(() => parseLaunchArgs(["--port", "1"])).toThrow(LaunchError);
    expect(() => parseLaunchArgs(["--url"])).toThrow("--url needs a value.");
  });
});

describe("resolveMcDirs", () => {
  const base = { homeDir: "/home/u", platform: "linux" as const };

  it("puts the MC under an elixir level of a root", () => {
    expect(resolveMcDirs({ ...base, baseDir: "/w/.hal-c2", env: {} })).toEqual({
      state: "/w/.hal-c2/state/elixir",
      data: "/w/.hal-c2/data/elixir",
    });
  });

  it("finds a dev MC in the hal-c2-dev profile, unless a base dir is given", () => {
    expect(resolveMcDirs({ ...base, dev: true, env: {} })).toEqual({
      state: "/home/u/.local/state/hal-c2-dev/elixir",
      data: "/home/u/.local/share/hal-c2-dev/elixir",
    });
    expect(resolveMcDirs({ ...base, dev: true, baseDir: "/w/.hal-c2", env: {} }).data).toBe(
      "/w/.hal-c2/data/elixir",
    );
  });

  it("uses HAL_C2_MC_HOME directly, unless a base dir is given", () => {
    const env = { HAL_C2_MC_HOME: "/n" };
    expect(resolveMcDirs({ ...base, env })).toEqual({ state: "/n/state", data: "/n/data" });
    expect(resolveMcDirs({ ...base, baseDir: "/r", env }).state).toBe("/r/state/elixir");
  });
});
