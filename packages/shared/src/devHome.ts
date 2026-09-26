/**
 * Where a HAL-C2 process keeps its files, and how to keep development state
 * away from the directories a user's installed HAL-C2 runs against.
 *
 * `@hal-c2/shared/xdgDirs` does the path arithmetic. This module adds the one
 * thing it cannot do synchronously, finding a linked git worktree, and decides
 * the root and profile in one order so the server, the dev runner and the
 * scripts agree:
 *
 * 1. An explicit root (`--base-dir`, `--home-dir`).
 * 2. The linked worktree's own gitignored `.hal-c2`, when the caller asks for
 *    worktree detection. Feature work in a throwaway branch must not share a
 *    database with the real app, so this outranks an ambient `HAL_C2_HOME`.
 * 3. `HAL_C2_HOME`, unless it names an old home (`~/.t3`, `~/.hal-c2`).
 * 4. The XDG directories, in `hal-c2-dev` for a development server and
 *    `hal-c2` otherwise.
 *
 * Under a root there is one profile. `T3CODE_HOME` and `T3_HOME` never pick a
 * home; they only tell the migration where an old one is.
 */

import * as Effect from "effect/Effect";
import * as FileSystem from "effect/FileSystem";
import * as Option from "effect/Option";
import * as Path from "effect/Path";

import {
  HAL_C2_APP_DIR,
  HAL_C2_DEV_APP_DIR,
  halC2HomeRoot,
  isLegacyHome,
  resolveHalC2Dirs,
  type HalC2Dirs,
  type HalC2DirsEnvironment,
  type HalC2Profile,
} from "./xdgDirs.ts";

/**
 * A `.git` file points at the real git directory. A linked worktree's lives at
 * `<common-dir>/worktrees/<name>`; a submodule's at
 * `<super-git-dir>/modules/<name>`. Both are files, so the pointer — not the
 * file-vs-directory distinction alone — is what identifies a worktree.
 *
 * The common dir is not necessarily named `.git`: a worktree of a bare repo
 * points at `<repo>.git/worktrees/<name>`, and `$GIT_COMMON_DIR` can be
 * anything. So match on the `worktrees/<name>` tail, which git always uses,
 * rather than on the name of the directory containing it.
 */
const pointsAtLinkedWorktree = (gitFileContents: string, path: Path.Path): boolean => {
  const gitdir = gitFileContents
    .split(/\r?\n/)
    .map((line) => line.trim())
    .find((line) => line.startsWith("gitdir:"))
    ?.slice("gitdir:".length)
    .trim();
  if (gitdir === undefined || gitdir.length === 0) {
    return false;
  }
  // Compare as path segments so a directory merely named `…worktrees…` cannot
  // match as a substring. Trailing separators normalize away first.
  const segments = path
    .normalize(gitdir.replaceAll("\\", "/"))
    .split(/[/\\]/)
    .filter((segment) => segment.length > 0);
  // `<common-dir>/worktrees/<name>`: `worktrees` is the penultimate segment,
  // and something must precede it. This excludes `<git-dir>/modules/<name>`.
  return segments.length >= 3 && segments.at(-2) === "worktrees";
};

/**
 * The path of the linked git worktree containing `cwd`, or undefined when
 * `cwd` is not inside one. Git marks a linked worktree by making `.git` a file
 * whose `gitdir:` points into the repository's `.git/worktrees`.
 *
 * Walks up to the repository root, so running from a subdirectory resolves the
 * same worktree as running from the top.
 */
export const resolveGitWorktreePath = (
  cwd: string,
): Effect.Effect<string | undefined, never, FileSystem.FileSystem | Path.Path> =>
  Effect.gen(function* () {
    const fileSystem = yield* FileSystem.FileSystem;
    const path = yield* Path.Path;

    let directory = path.resolve(cwd);
    for (;;) {
      const gitPath = path.join(directory, ".git");
      const info = yield* fileSystem.stat(gitPath).pipe(Effect.option);
      if (Option.isSome(info)) {
        // A directory means the main checkout. Stop either way: nesting one
        // repository inside another does not make the outer one this root.
        if (info.value.type !== "File") {
          return undefined;
        }
        // A submodule also has a `.git` file, but it is not a worktree of this
        // repository and gets no worktree-local home.
        const contents = yield* fileSystem
          .readFileString(gitPath)
          .pipe(Effect.orElseSucceed(() => ""));
        return pointsAtLinkedWorktree(contents, path) ? directory : undefined;
      }
      const parent = path.dirname(directory);
      if (parent === directory) {
        return undefined;
      }
      directory = parent;
    }
  });

export const HAL_C2_HOME_DIR_NAME = ".hal-c2";

/**
 * The worktree-local root for `cwd`, `<worktree>/.hal-c2`, or undefined outside
 * a linked worktree. It need not exist yet: falling back because it is missing
 * would send callers at the user's real directories.
 */
export const resolveWorktreeHalC2Home = (
  cwd: string,
): Effect.Effect<string | undefined, never, FileSystem.FileSystem | Path.Path> =>
  Effect.gen(function* () {
    const path = yield* Path.Path;
    const worktreePath = yield* resolveGitWorktreePath(cwd);
    return worktreePath === undefined ? undefined : path.join(worktreePath, HAL_C2_HOME_DIR_NAME);
  });

/** Which rule picked the root, or undefined for the XDG directories. */
export type HalC2RootSource = "explicit" | "worktree" | "env";

export interface HalC2Location {
  readonly dirs: HalC2Dirs;
  /** The single root every kind lives under, or undefined for XDG. */
  readonly root: string | undefined;
  readonly rootSource: HalC2RootSource | undefined;
  /** `hal-c2-dev` only for a development process with no root. */
  readonly profile: HalC2Profile;
}

export interface ResolveHalC2LocationOptions {
  /** `--base-dir` or `--home-dir`; resolved against the working directory. */
  readonly explicitRoot?: string | undefined;
  /**
   * Detect a linked worktree from here. Only development tooling passes it: an
   * installed `hal-c2` started inside a user's own worktree keeps using XDG.
   */
  readonly worktreeCwd?: string | undefined;
  readonly env: HalC2DirsEnvironment;
  /** The user's home directory, `os.homedir()`. */
  readonly homeDir: string;
  readonly platform: NodeJS.Platform;
  /** A development server: picks the `hal-c2-dev` profile when there is no root. */
  readonly development?: boolean | undefined;
}

/**
 * The root, profile and directories in the order documented at the top of
 * this file. An explicit root that names an old home is ignored with a
 * warning: the old homes are only ever read by the migration.
 */
export const resolveHalC2Location = (
  options: ResolveHalC2LocationOptions,
): Effect.Effect<HalC2Location, never, FileSystem.FileSystem | Path.Path> =>
  Effect.gen(function* () {
    const path = yield* Path.Path;
    const { env, homeDir, platform } = options;
    const pick = (root: string, rootSource: HalC2RootSource): HalC2Location => ({
      dirs: resolveHalC2Dirs({ env, homeDir, platform, root }),
      root,
      rootSource,
      profile: HAL_C2_APP_DIR,
    });

    const explicit = options.explicitRoot?.trim();
    if (explicit) {
      const root = path.resolve(explicit);
      if (!isLegacyHome(root, { homeDir, platform })) {
        return pick(root, "explicit");
      }
      yield* Effect.logWarning(
        `Ignoring ${root} as a HAL-C2 home: it is an old home that HAL-C2 only migrates from.`,
      );
    }

    if (options.worktreeCwd !== undefined) {
      const worktreeRoot = yield* resolveWorktreeHalC2Home(options.worktreeCwd);
      if (worktreeRoot !== undefined) {
        return pick(worktreeRoot, "worktree");
      }
    }

    const envRoot = halC2HomeRoot({ env, homeDir, platform });
    if (envRoot !== undefined) {
      return pick(envRoot, "env");
    }

    const profile = options.development ? HAL_C2_DEV_APP_DIR : HAL_C2_APP_DIR;
    return {
      dirs: resolveHalC2Dirs({ env, homeDir, platform, profile }),
      root: undefined,
      rootSource: undefined,
      profile,
    };
  });
