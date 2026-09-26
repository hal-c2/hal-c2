import { assert, describe, it } from "@effect/vitest";

import {
  resolveEarlyLinuxElectronOptions,
  resolveEarlyLinuxPasswordStorePreference,
} from "./DesktopEarlyElectronStartup.ts";

describe("DesktopEarlyElectronStartup", () => {
  it("reads the persisted linux password-store preference before Electron is ready", () => {
    const preference = resolveEarlyLinuxPasswordStorePreference({
      env: { HAL_C2_HOME: "/home/user/.hal-c2-test" },
      homeDirectory: "/home/user",
      readFileString: (path) => {
        assert.equal(path, "/home/user/.hal-c2-test/config/desktop-settings.json");
        return JSON.stringify({ linuxPasswordStore: "kwallet6" });
      },
    });

    assert.equal(preference, "kwallet6");
  });

  it("accepts JSONC in the early desktop settings file", () => {
    const preference = resolveEarlyLinuxPasswordStorePreference({
      env: { HAL_C2_HOME: "/home/user/.hal-c2-test" },
      homeDirectory: "/home/user",
      readFileString: () => `{
        // manually edited setting
        "linuxPasswordStore": "gnome-libsecret",
      }`,
    });

    assert.equal(preference, "gnome-libsecret");
  });

  it("falls back to auto when the early settings document is missing or invalid", () => {
    const preference = resolveEarlyLinuxPasswordStorePreference({
      env: {},
      homeDirectory: "/home/user",
      readFileString: () => {
        throw new Error("missing");
      },
    });

    assert.equal(preference, "auto");
  });

  it("preserves absolute root paths when resolving early settings", () => {
    const preference = resolveEarlyLinuxPasswordStorePreference({
      env: { HAL_C2_HOME: "/" },
      homeDirectory: "/home/user",
      readFileString: (path) => {
        assert.equal(path, "/config/desktop-settings.json");
        return JSON.stringify({ linuxPasswordStore: "kwallet6" });
      },
    });

    assert.equal(preference, "kwallet6");
  });

  it("reads desktop settings from XDG_CONFIG_HOME when it is absolute", () => {
    const paths: string[] = [];
    const read = (XDG_CONFIG_HOME: string) =>
      resolveEarlyLinuxPasswordStorePreference({
        env: { XDG_CONFIG_HOME },
        homeDirectory: "/home/user",
        readFileString: (path) => {
          paths.push(path);
          return "{}";
        },
      });

    read("/xdg/config");
    read("relative/config");

    assert.deepEqual(paths, [
      "/xdg/config/hal-c2/desktop-settings.json",
      "/home/user/.config/hal-c2/desktop-settings.json",
    ]);
  });

  it("never reads desktop settings from a legacy HAL_C2_HOME", () => {
    const preference = resolveEarlyLinuxPasswordStorePreference({
      env: { HAL_C2_HOME: "/home/user/.hal-c2" },
      homeDirectory: "/home/user",
      readFileString: (path) => {
        assert.equal(path, "/home/user/.config/hal-c2/desktop-settings.json");
        return JSON.stringify({ linuxPasswordStore: "kwallet6" });
      },
    });

    assert.equal(preference, "kwallet6");
  });

  it("resolves the early linux Electron switches", () => {
    const options = resolveEarlyLinuxElectronOptions({
      env: {
        HAL_C2_HOME: "/home/user/.hal-c2-test",
        XDG_CURRENT_DESKTOP: "niri",
        VITE_DEV_SERVER_URL: "http://127.0.0.1:5173",
      },
      homeDirectory: "/home/user",
      readFileString: (path) => {
        assert.equal(path, "/home/user/.hal-c2-test/config/desktop-settings.json");
        return JSON.stringify({ linuxPasswordStore: "auto" });
      },
    });

    assert.deepEqual(options, {
      isDevelopment: true,
      linuxWmClass: "hal-c2-dev",
      linuxDesktopEntryName: "io.github.halc2.HalC2.Development.desktop",
      passwordStore: "gnome-libsecret",
    });
  });

  it("keeps implicit development settings in the hal-c2-dev config dir when HAL_C2_HOME is unset", () => {
    const preference = resolveEarlyLinuxPasswordStorePreference({
      env: {
        VITE_DEV_SERVER_URL: "http://127.0.0.1:5173",
      },
      homeDirectory: "/home/user",
      readFileString: (path) => {
        assert.equal(path, "/home/user/.config/hal-c2-dev/desktop-settings.json");
        return JSON.stringify({ linuxPasswordStore: "kwallet" });
      },
    });

    assert.equal(preference, "kwallet");
  });

  it("treats whitespace-only HAL_C2_HOME as unconfigured in development", () => {
    const preference = resolveEarlyLinuxPasswordStorePreference({
      env: {
        HAL_C2_HOME: "   ",
        VITE_DEV_SERVER_URL: "http://127.0.0.1:5173",
      },
      homeDirectory: "/home/user",
      readFileString: (path) => {
        assert.equal(path, "/home/user/.config/hal-c2-dev/desktop-settings.json");
        return JSON.stringify({ linuxPasswordStore: "gnome-libsecret" });
      },
    });

    assert.equal(preference, "gnome-libsecret");
  });
});
