import { HostProcessEnvironment, HostProcessPlatform } from "@hal-c2/shared/hostProcess";
import {
  listLoginShellCandidates,
  mergePathEntries,
  readPathFromLoginShell,
  readPathFromLaunchctl,
  resolveWindowsEnvironment,
} from "@hal-c2/shared/shell";
import { resolveHalC2Location } from "@hal-c2/shared/devHome";
import { halC2HomeRoot, type HalC2DirsEnvironment } from "@hal-c2/shared/xdgDirs";
import * as Config from "effect/Config";
import * as Effect from "effect/Effect";
import * as FileSystem from "effect/FileSystem";
import * as Option from "effect/Option";
import * as Path from "effect/Path";
import * as NodeOS from "node:os";

function logPathHydrationWarning(message: string, error?: unknown): void {
  process.stderr.write(
    `[server] ${message} ${error instanceof Error ? error.message : (error ?? "")}\n`,
  );
}

function hydratePosixPath(env: NodeJS.ProcessEnv, platform: NodeJS.Platform): void {
  let shellPath: string | undefined;
  for (const shell of listLoginShellCandidates(platform, env.SHELL)) {
    try {
      shellPath = readPathFromLoginShell(shell);
    } catch (error) {
      logPathHydrationWarning(`Failed to read PATH from login shell ${shell}.`, error);
    }

    if (shellPath) break;
  }

  const launchctlPath = platform === "darwin" && !shellPath ? readPathFromLaunchctl() : undefined;
  const mergedPath = mergePathEntries(shellPath ?? launchctlPath, env.PATH, platform);
  if (mergedPath) {
    env.PATH = mergedPath;
  }
}

export function hydratePosixHome(
  env: NodeJS.ProcessEnv,
  resolveHomeDir = () => NodeOS.userInfo().homedir,
): void {
  if ((env.HOME?.trim() ?? "").length > 0) return;

  const homeDir = resolveHomeDir();
  if (homeDir.length > 0) {
    env.HOME = homeDir;
  }
}

export const fixPath = Effect.fn("fixPath")(function* (): Effect.fn.Return<
  void,
  never,
  FileSystem.FileSystem | Path.Path
> {
  const platform = yield* HostProcessPlatform;
  const env = yield* HostProcessEnvironment;

  if (platform === "win32") {
    const repairedEnvironment = yield* resolveWindowsEnvironment(env).pipe(
      Effect.catchDefect((defect) =>
        Effect.sync(() => {
          logPathHydrationWarning("Failed to hydrate PATH from the user environment.", defect);
          return {} as Partial<NodeJS.ProcessEnv>;
        }),
      ),
    );
    for (const [key, value] of Object.entries(repairedEnvironment)) {
      if (value !== undefined) {
        env[key] = value;
      }
    }
    return;
  }

  if (platform !== "darwin" && platform !== "linux") return;

  yield* Effect.sync(() => hydratePosixHome(env)).pipe(
    Effect.catchDefect((defect) =>
      Effect.sync(() => {
        logPathHydrationWarning("Failed to hydrate HOME from the user account.", defect);
      }),
    ),
  );
  yield* Effect.sync(() => hydratePosixPath(env, platform)).pipe(
    Effect.catchDefect((defect) =>
      Effect.sync(() => {
        logPathHydrationWarning("Failed to hydrate PATH from the user environment.", defect);
      }),
    ),
  );
});

export const expandHomePath = Effect.fn(function* (input: string) {
  const { join } = yield* Path.Path;
  if (input === "~") {
    return NodeOS.homedir();
  }
  if (input.startsWith("~/") || input.startsWith("~\\")) {
    return join(NodeOS.homedir(), input.slice(2));
  }
  return input;
});

const optionalEnv = (name: string) =>
  Config.String(name).pipe(Config.option, Config.map(Option.getOrUndefined));

/** The variables `@hal-c2/shared/xdgDirs` reads, from the Effect config. */
export const halC2DirsEnvironment: Effect.Effect<HalC2DirsEnvironment, Config.ConfigError> =
  Config.all({
    HAL_C2_HOME: optionalEnv("HAL_C2_HOME"),
    XDG_CONFIG_HOME: optionalEnv("XDG_CONFIG_HOME"),
    XDG_DATA_HOME: optionalEnv("XDG_DATA_HOME"),
    XDG_STATE_HOME: optionalEnv("XDG_STATE_HOME"),
    XDG_CACHE_HOME: optionalEnv("XDG_CACHE_HOME"),
    XDG_RUNTIME_DIR: optionalEnv("XDG_RUNTIME_DIR"),
    APPDATA: optionalEnv("APPDATA"),
    LOCALAPPDATA: optionalEnv("LOCALAPPDATA"),
    T3CODE_HOME: optionalEnv("T3CODE_HOME"),
    T3_HOME: optionalEnv("T3_HOME"),
  });

/**
 * This process's HAL-C2 directories: an explicit root (`--base-dir`, `~`
 * expanded), else `HAL_C2_HOME`, else `fallbackRoot` (the desktop's bootstrap
 * home), else the XDG directories, in the `hal-c2-dev` profile for a
 * development server. The CLI never detects worktrees; the dev runner passes a
 * worktree's root explicitly. `HOME` is read from the config so tests can
 * point it at a temporary directory.
 */
export const resolveCliHalC2Location = Effect.fn("resolveCliHalC2Location")(function* (options: {
  readonly explicitRoot?: string | undefined;
  readonly fallbackRoot?: string | undefined;
  readonly development?: boolean | undefined;
}) {
  const env = yield* halC2DirsEnvironment;
  const platform = yield* HostProcessPlatform;
  const homeDir = yield* Config.String("HOME").pipe(
    Config.map((value) => value.trim()),
    Config.withDefault(""),
  );
  const resolvedHomeDir = homeDir || NodeOS.homedir();
  const explicit = options.explicitRoot?.trim();
  const fallback =
    halC2HomeRoot({ env, homeDir: resolvedHomeDir, platform }) === undefined
      ? options.fallbackRoot?.trim()
      : undefined;
  const raw = explicit || fallback;
  const location = yield* resolveHalC2Location({
    explicitRoot: raw ? yield* expandHomePath(raw) : undefined,
    env,
    homeDir: resolvedHomeDir,
    platform,
    development: options.development,
  });
  return { ...location, env, homeDir: resolvedHomeDir, platform };
});
