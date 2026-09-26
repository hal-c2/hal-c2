import { describe, expect, it } from "bun:test";

import { resolveShellConfigDir } from "./shellConfigDir.ts";

const resolve = (env: Record<string, string>) =>
  resolveShellConfigDir({ env, homeDir: "/home/me", platform: "linux" });

describe("resolveShellConfigDir", () => {
  it("defaults to the XDG config directory", () => {
    expect(resolve({})).toBe("/home/me/.config/hal-c2/shell/tui");
  });

  it("follows an absolute XDG_CONFIG_HOME and ignores a relative one", () => {
    expect(resolve({ XDG_CONFIG_HOME: "/xdg/config" })).toBe("/xdg/config/hal-c2/shell/tui");
    expect(resolve({ XDG_CONFIG_HOME: "xdg/config" })).toBe("/home/me/.config/hal-c2/shell/tui");
  });

  it("uses the config directory under HAL_C2_HOME, unless it names a legacy home", () => {
    expect(resolve({ HAL_C2_HOME: "/srv/hal-c2" })).toBe("/srv/hal-c2/config/shell/tui");
    expect(resolve({ HAL_C2_HOME: "/home/me/.hal-c2" })).toBe("/home/me/.config/hal-c2/shell/tui");
  });

  it("lets HAL_C2_TUI_SHELL_DIR outrank everything", () => {
    expect(resolve({ HAL_C2_TUI_SHELL_DIR: "/opt/tui-shell", HAL_C2_HOME: "/srv/hal-c2" })).toBe(
      "/opt/tui-shell",
    );
  });
});
