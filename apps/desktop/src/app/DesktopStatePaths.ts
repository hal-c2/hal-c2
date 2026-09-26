import {
  HAL_C2_APP_DIR,
  HAL_C2_DEV_APP_DIR,
  halC2HomeRoot,
  resolveHalC2Dirs,
  type HalC2Dirs,
  type HalC2DirsEnvironment,
  type HalC2Profile,
} from "@hal-c2/shared/xdgDirs";

export interface DesktopStorage {
  /** Where each kind of file lives: config, data, state, cache and runtime. */
  readonly dirs: HalC2Dirs;
  /**
   * The explicit `HAL_C2_HOME` root, or undefined when the desktop follows XDG.
   * Only an explicit root is handed to the hosted server as its `--base-dir`.
   */
  readonly root: string | undefined;
  /** `hal-c2-dev` for a development build without a root, so dev never shares state. */
  readonly profile: HalC2Profile;
}

/** Resolves the desktop app's storage the same way the hosted server does. */
export function resolveDesktopStorage(input: {
  readonly env: HalC2DirsEnvironment;
  readonly homeDirectory: string;
  readonly platform: NodeJS.Platform;
  readonly isDevelopment: boolean;
}): DesktopStorage {
  const root = halC2HomeRoot({
    env: input.env,
    homeDir: input.homeDirectory,
    platform: input.platform,
  });
  const profile = input.isDevelopment && root === undefined ? HAL_C2_DEV_APP_DIR : HAL_C2_APP_DIR;
  return {
    dirs: resolveHalC2Dirs({
      env: input.env,
      homeDir: input.homeDirectory,
      platform: input.platform,
      profile,
    }),
    root,
    profile,
  };
}
