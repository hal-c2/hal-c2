import { describe, expect, it } from "@effect/vitest";

import { halC2HomeRoot, isLegacyHome, legacyHomeCandidates, resolveHalC2Dirs } from "./xdgDirs.ts";

const linux = { homeDir: "/home/me", platform: "linux" as const };
const mac = { homeDir: "/Users/me", platform: "darwin" as const };
const windows = {
  homeDir: "C:\\Users\\me",
  platform: "win32" as const,
  env: {
    APPDATA: "C:\\Users\\me\\AppData\\Roaming",
    LOCALAPPDATA: "C:\\Users\\me\\AppData\\Local",
  },
};

describe("resolveHalC2Dirs", () => {
  it("uses the XDG defaults on Linux and macOS", () => {
    expect(resolveHalC2Dirs({ ...linux, env: {} })).toEqual({
      config: "/home/me/.config/hal-c2",
      data: "/home/me/.local/share/hal-c2",
      state: "/home/me/.local/state/hal-c2",
      cache: "/home/me/.cache/hal-c2",
      runtime: "/home/me/.local/state/hal-c2",
    });
    expect(resolveHalC2Dirs({ ...mac, env: {} }).data).toBe("/Users/me/.local/share/hal-c2");
  });

  it("uses AppData on Windows with the kind under the app dir", () => {
    expect(resolveHalC2Dirs(windows)).toEqual({
      config: "C:\\Users\\me\\AppData\\Roaming\\hal-c2\\config",
      data: "C:\\Users\\me\\AppData\\Local\\hal-c2\\data",
      state: "C:\\Users\\me\\AppData\\Local\\hal-c2\\state",
      cache: "C:\\Users\\me\\AppData\\Local\\hal-c2\\cache",
      runtime: "C:\\Users\\me\\AppData\\Local\\hal-c2\\state",
    });
    expect(resolveHalC2Dirs({ ...windows, env: {} }).config).toBe(
      "C:\\Users\\me\\AppData\\Roaming\\hal-c2\\config",
    );
  });

  it("honours absolute XDG variables on every platform", () => {
    const dirs = resolveHalC2Dirs({
      ...linux,
      env: {
        XDG_CONFIG_HOME: "/xdg/config",
        XDG_DATA_HOME: "/xdg/data",
        XDG_STATE_HOME: "/xdg/state",
        XDG_CACHE_HOME: "/xdg/cache",
        XDG_RUNTIME_DIR: "/run/user/1000",
      },
    });
    expect(dirs).toEqual({
      config: "/xdg/config/hal-c2",
      data: "/xdg/data/hal-c2",
      state: "/xdg/state/hal-c2",
      cache: "/xdg/cache/hal-c2",
      runtime: "/run/user/1000/hal-c2",
    });
    expect(resolveHalC2Dirs({ ...mac, env: { XDG_RUNTIME_DIR: "/tmp/xdg-runtime" } }).runtime).toBe(
      "/tmp/xdg-runtime/hal-c2",
    );
    expect(
      resolveHalC2Dirs({ ...windows, env: { ...windows.env, XDG_CACHE_HOME: "D:\\xdg\\cache" } })
        .cache,
    ).toBe("D:\\xdg\\cache\\hal-c2\\cache");
  });

  it("ignores empty and relative XDG variables", () => {
    const dirs = resolveHalC2Dirs({
      ...linux,
      env: { XDG_DATA_HOME: "share", XDG_CONFIG_HOME: "./config", XDG_RUNTIME_DIR: "" },
    });
    expect(dirs.data).toBe("/home/me/.local/share/hal-c2");
    expect(dirs.config).toBe("/home/me/.config/hal-c2");
    expect(dirs.runtime).toBe("/home/me/.local/state/hal-c2");
  });

  it("names the development profile's directory hal-c2-dev", () => {
    const dirs = resolveHalC2Dirs({
      ...linux,
      env: { XDG_RUNTIME_DIR: "/run/user/1000" },
      profile: "hal-c2-dev",
    });
    expect(dirs.config).toBe("/home/me/.config/hal-c2-dev");
    expect(dirs.runtime).toBe("/run/user/1000/hal-c2-dev");
    expect(resolveHalC2Dirs({ ...windows, profile: "hal-c2-dev" }).data).toBe(
      "C:\\Users\\me\\AppData\\Local\\hal-c2-dev\\data",
    );
  });

  it("puts every kind under HAL_C2_HOME, outranking the XDG variables", () => {
    const dirs = resolveHalC2Dirs({
      ...linux,
      env: {
        HAL_C2_HOME: "/srv/hal-c2",
        XDG_DATA_HOME: "/xdg/data",
        XDG_RUNTIME_DIR: "/run/user/1000",
      },
      profile: "hal-c2-dev",
    });
    expect(dirs).toEqual({
      config: "/srv/hal-c2/config",
      data: "/srv/hal-c2/data",
      state: "/srv/hal-c2/state",
      cache: "/srv/hal-c2/cache",
      runtime: "/srv/hal-c2/state",
    });
  });

  it("lets an explicit root outrank HAL_C2_HOME", () => {
    const dirs = resolveHalC2Dirs({
      ...linux,
      env: { HAL_C2_HOME: "/srv/hal-c2" },
      root: "/repo/.hal-c2",
    });
    expect(dirs.data).toBe("/repo/.hal-c2/data");
  });

  it("never uses an old home as the root", () => {
    for (const home of ["/home/me/.t3", "/home/me/.hal-c2/", "/home/me/.t3/../.t3"]) {
      expect(halC2HomeRoot({ ...linux, env: { HAL_C2_HOME: home } })).toBeUndefined();
      expect(resolveHalC2Dirs({ ...linux, env: { HAL_C2_HOME: home } }).data).toBe(
        "/home/me/.local/share/hal-c2",
      );
    }
    expect(isLegacyHome("C:\\Users\\ME\\.T3", windows)).toBe(true);
    expect(halC2HomeRoot({ ...linux, env: { HAL_C2_HOME: "relative" } })).toBeUndefined();
    expect(halC2HomeRoot({ ...linux, env: { HAL_C2_HOME: "/srv/hal-c2 " } })).toBe("/srv/hal-c2");
  });
});

describe("legacyHomeCandidates", () => {
  it("orders a named T3 install before the dot directories", () => {
    expect(legacyHomeCandidates({ ...linux, env: { T3CODE_HOME: "/srv/t3" } })).toEqual([
      "/srv/t3",
      "/home/me/.hal-c2",
      "/home/me/.t3",
    ]);
    expect(legacyHomeCandidates({ ...linux, env: { T3_HOME: "/srv/t3" } })[0]).toBe("/srv/t3");
    expect(legacyHomeCandidates({ ...linux, env: {} })).toEqual([
      "/home/me/.hal-c2",
      "/home/me/.t3",
    ]);
  });

  it("treats a HAL_C2_HOME that names an old home as a source, not a root", () => {
    expect(legacyHomeCandidates({ ...linux, env: { HAL_C2_HOME: "/home/me/.t3" } })).toEqual([
      "/home/me/.t3",
      "/home/me/.hal-c2",
    ]);
    expect(legacyHomeCandidates({ ...linux, env: { HAL_C2_HOME: "/srv/hal-c2" } })).toEqual([
      "/home/me/.hal-c2",
      "/home/me/.t3",
    ]);
  });

  it("drops relative values", () => {
    expect(legacyHomeCandidates({ ...linux, env: { T3CODE_HOME: "t3" } })).toEqual([
      "/home/me/.hal-c2",
      "/home/me/.t3",
    ]);
  });
});
