import * as NodePath from "node:path";

import { resolveHalC2Dirs, type HalC2DirsEnvironment } from "@hal-c2/shared/xdgDirs";

/**
 * Where a user's `shell.qml` (and extra `qml/` modules) override the default
 * shell: `HAL_C2_TUI_SHELL_DIR`, else `shell/tui` in HAL-C2's config directory
 * (`HAL_C2_HOME/config`, `XDG_CONFIG_HOME/hal-c2` or `~/.config/hal-c2`).
 */
export function resolveShellConfigDir(input: {
  readonly env: HalC2DirsEnvironment & Readonly<Record<string, string | undefined>>;
  readonly homeDir: string;
  readonly platform: NodeJS.Platform;
}): string {
  const explicit = input.env.HAL_C2_TUI_SHELL_DIR?.trim();
  if (explicit) {
    return explicit;
  }
  const { config } = resolveHalC2Dirs(input);
  const path = input.platform === "win32" ? NodePath.win32 : NodePath.posix;
  return path.join(config, "shell", "tui");
}
