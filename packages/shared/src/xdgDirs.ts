// @effect-diagnostics nodeBuiltinImport:off - pure path arithmetic, usable from scripts and Electron without an Effect runtime.
/**
 * Where HAL-C2 keeps its files: the XDG Base Directory layout, or one root.
 *
 * Every client and server resolves its directories through this module so
 * they agree on the same five places (`features/node/platform/storage-layout.feature`):
 *
 * - config: settings, keybindings, themes, the user's shell
 * - data:   the database, secrets, attachments, worktrees; what cannot be got back
 * - state:  logs, runtime records, the migration record
 * - cache:  re-downloadable tools and derived data
 * - runtime: the desktop control socket; `$XDG_RUNTIME_DIR/hal-c2`, else the state dir
 *
 * With nothing configured each kind sits under its XDG base in a directory
 * named `hal-c2` (`hal-c2-dev` for a development profile). Windows uses
 * `%APPDATA%\hal-c2\config` and `%LOCALAPPDATA%\hal-c2\{data,state,cache}`. The
 * `XDG_*` variables are honoured on every OS, but only when absolute, as the
 * specification says; macOS gets the XDG defaults, not `~/Library`.
 *
 * `HAL_C2_HOME=<dir>`, a worktree's `.hal-c2`, `--home-dir` and `--base-dir`
 * all put the four kinds under one root as `<dir>/{config,data,state,cache}`,
 * with runtime in `<dir>/state`. Under a root there is one profile: no
 * `dev`/`userdata` level. There are no per-kind `HAL_C2_*_DIR` overrides.
 *
 * `~/.t3` and `~/.hal-c2` are never a root. A `HAL_C2_HOME` that names one of
 * them (old service units did) is ignored here and left for the migration to
 * copy from (`legacyHomeCandidates`).
 *
 * This module is pure and synchronous so scripts, Electron, the TUI and Effect
 * code can all use it. Existence checks belong to the caller.
 */

import * as NodePath from "node:path";

export type HalC2DirKind = "config" | "data" | "state" | "cache" | "runtime";

export interface HalC2Dirs {
  readonly config: string;
  readonly data: string;
  readonly state: string;
  readonly cache: string;
  readonly runtime: string;
}

export const HAL_C2_APP_DIR = "hal-c2";
export const HAL_C2_DEV_APP_DIR = "hal-c2-dev";
export type HalC2Profile = typeof HAL_C2_APP_DIR | typeof HAL_C2_DEV_APP_DIR;

/** The old homes that only the migration may read. */
export const LEGACY_HOME_DIR_NAMES = [".hal-c2", ".t3"] as const;

/** The variables this module reads. Anything else in `process.env` is ignored. */
export interface HalC2DirsEnvironment {
  readonly HAL_C2_HOME?: string | undefined;
  readonly XDG_CONFIG_HOME?: string | undefined;
  readonly XDG_DATA_HOME?: string | undefined;
  readonly XDG_STATE_HOME?: string | undefined;
  readonly XDG_CACHE_HOME?: string | undefined;
  readonly XDG_RUNTIME_DIR?: string | undefined;
  readonly APPDATA?: string | undefined;
  readonly LOCALAPPDATA?: string | undefined;
  readonly T3CODE_HOME?: string | undefined;
  readonly T3_HOME?: string | undefined;
}

export interface HalC2DirsOptions {
  readonly env: HalC2DirsEnvironment;
  /** The user's home directory, `os.homedir()`. */
  readonly homeDir: string;
  /** `process.platform`; only `win32` changes the defaults. */
  readonly platform: NodeJS.Platform;
  /** `hal-c2` unless the caller is a development server with no root. */
  readonly profile?: HalC2Profile | undefined;
  /**
   * A root the caller already decided on: `--base-dir`, `--home-dir` or a
   * worktree's `.hal-c2`. Outranks `HAL_C2_HOME` and the XDG variables.
   */
  readonly root?: string | undefined;
}

const pathFor = (platform: NodeJS.Platform) =>
  platform === "win32" ? NodePath.win32 : NodePath.posix;

/** A trimmed absolute path, or undefined: the spec says relative values are ignored. */
export const absoluteEnvPath = (
  value: string | undefined,
  platform: NodeJS.Platform,
): string | undefined => {
  const trimmed = value?.trim();
  if (!trimmed) {
    return undefined;
  }
  return pathFor(platform).isAbsolute(trimmed) ? trimmed : undefined;
};

const normalize = (dir: string, platform: NodeJS.Platform): string => {
  const path = pathFor(platform);
  const normalized = path.normalize(dir).replace(/[\\/]+$/, "");
  return platform === "win32" ? normalized.toLowerCase() : normalized;
};

/** True when `dir` is `~/.hal-c2` or `~/.t3`: a migration source, never a root. */
export const isLegacyHome = (
  dir: string,
  options: Pick<HalC2DirsOptions, "homeDir" | "platform">,
): boolean => {
  const path = pathFor(options.platform);
  const candidate = normalize(dir, options.platform);
  return LEGACY_HOME_DIR_NAMES.some(
    (name) => normalize(path.join(options.homeDir, name), options.platform) === candidate,
  );
};

/** The four kinds plus runtime under one root. */
export const halC2DirsUnder = (root: string, platform: NodeJS.Platform): HalC2Dirs => {
  const path = pathFor(platform);
  const state = path.join(root, "state");
  return {
    config: path.join(root, "config"),
    data: path.join(root, "data"),
    state,
    cache: path.join(root, "cache"),
    runtime: state,
  };
};

/**
 * The `HAL_C2_HOME` root, or undefined when it is unset, relative, or names an
 * old home.
 */
export const halC2HomeRoot = (
  options: Pick<HalC2DirsOptions, "env" | "homeDir" | "platform">,
): string | undefined => {
  const root = absoluteEnvPath(options.env.HAL_C2_HOME, options.platform);
  if (root === undefined || isLegacyHome(root, options)) {
    return undefined;
  }
  return root;
};

const xdgDefaults = (options: Pick<HalC2DirsOptions, "env" | "homeDir" | "platform">) => {
  const { env, homeDir, platform } = options;
  const path = pathFor(platform);
  if (platform === "win32") {
    const appData =
      absoluteEnvPath(env.APPDATA, platform) ?? path.join(homeDir, "AppData", "Roaming");
    const localAppData =
      absoluteEnvPath(env.LOCALAPPDATA, platform) ?? path.join(homeDir, "AppData", "Local");
    return { config: appData, data: localAppData, state: localAppData, cache: localAppData };
  }
  return {
    config: path.join(homeDir, ".config"),
    data: path.join(homeDir, ".local", "share"),
    state: path.join(homeDir, ".local", "state"),
    cache: path.join(homeDir, ".cache"),
  };
};

/**
 * HAL-C2's directories for this process. `root` wins, then `HAL_C2_HOME`, then
 * the XDG variables and platform defaults with the profile's directory name.
 */
export const resolveHalC2Dirs = (options: HalC2DirsOptions): HalC2Dirs => {
  const { env, platform } = options;
  const root = options.root?.trim() || halC2HomeRoot(options);
  if (root) {
    return halC2DirsUnder(root, platform);
  }
  const path = pathFor(platform);
  const appDir = options.profile ?? HAL_C2_APP_DIR;
  const defaults = xdgDefaults(options);
  // An XDG variable is already a base for one kind. Only the Windows defaults
  // need the kind nested under the app dir (`%LOCALAPPDATA%\hal-c2\data`),
  // because data, state and cache share one base there.
  const under = (variable: string | undefined, fallback: string, kind: HalC2DirKind) => {
    const configured = absoluteEnvPath(variable, platform);
    if (configured !== undefined) {
      return path.join(configured, appDir);
    }
    return platform === "win32" ? path.join(fallback, appDir, kind) : path.join(fallback, appDir);
  };
  const state = under(env.XDG_STATE_HOME, defaults.state, "state");
  const runtimeBase = absoluteEnvPath(env.XDG_RUNTIME_DIR, platform);
  return {
    config: under(env.XDG_CONFIG_HOME, defaults.config, "config"),
    data: under(env.XDG_DATA_HOME, defaults.data, "data"),
    state,
    cache: under(env.XDG_CACHE_HOME, defaults.cache, "cache"),
    runtime: runtimeBase === undefined ? state : path.join(runtimeBase, appDir),
  };
};

/**
 * The old homes the migration may copy from, most specific first: a relocated
 * T3 Code install named by `T3CODE_HOME` or `T3_HOME`, then `~/.hal-c2`, then
 * `~/.t3`. The caller keeps the first one that exists. A `HAL_C2_HOME` that
 * names an old home counts too, since old service units wrote such units.
 */
export const legacyHomeCandidates = (
  options: Pick<HalC2DirsOptions, "env" | "homeDir" | "platform">,
): readonly string[] => {
  const { env, homeDir, platform } = options;
  const path = pathFor(platform);
  const oldHomeAsRoot = absoluteEnvPath(env.HAL_C2_HOME, platform);
  const named = [
    oldHomeAsRoot !== undefined && isLegacyHome(oldHomeAsRoot, options) ? oldHomeAsRoot : undefined,
    absoluteEnvPath(env.T3CODE_HOME, platform),
    absoluteEnvPath(env.T3_HOME, platform),
  ].filter((value): value is string => value !== undefined);
  const homes = LEGACY_HOME_DIR_NAMES.map((name) => path.join(homeDir, name));
  const seen = new Set<string>();
  const ordered: string[] = [];
  for (const candidate of [...named, ...homes]) {
    const key = normalize(candidate, platform);
    if (!seen.has(key)) {
      seen.add(key);
      ordered.push(candidate);
    }
  }
  return ordered;
};
