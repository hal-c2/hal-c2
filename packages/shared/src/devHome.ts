/**
 * Where HAL-C2 keeps its state, and how to keep development state away from
 * the shared home that a user's installed HAL-C2 runs against.
 *
 * The base dir is resolved in one place so the server, the service launcher
 * and the dev scripts agree:
 *
 * 1. `HALC2_HOME`.
 * 2. The legacy `T3CODE_HOME`, still honoured (with one deprecation warning)
 *    so service units and shell profiles written before the rename keep
 *    working.
 * 3. `~/.hal-c2` when it exists.
 * 4. `~/.t3` when it exists: an install from before the rename is used in
 *    place, read-write, with no copy or migration.
 * 5. `~/.hal-c2`, created on first use.
 *
 * A linked git worktree gets its own (gitignored) `.hal-c2`, with the same
 * fallback to an existing `.t3`: feature work in a throwaway branch must not
 * share a database with the real app, and an ambient `HALC2_HOME` counts as an
 * explicit base dir — flipping the state directory from `<base>/dev` to
 * `<base>/userdata`, the live production database.
 */

import * as Effect from "effect/Effect";
import * as FileSystem from "effect/FileSystem";
import * as Option from "effect/Option";
import * as Path from "effect/Path";

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

/**
 * The worktree-local data directory for `cwd`, or undefined outside a linked
 * worktree. Deliberately does not require the directory to exist yet: falling
 * back because it is missing would send callers at the shared home.
 */
export const resolveWorktreeHalC2Home = (
  cwd: string,
): Effect.Effect<string | undefined, never, FileSystem.FileSystem | Path.Path> =>
  Effect.gen(function* () {
    const worktreePath = yield* resolveGitWorktreePath(cwd);
    if (worktreePath === undefined) {
      return undefined;
    }
    return yield* resolveStateDirIn(worktreePath);
  });

export const HALC2_HOME_DIR_NAME = ".hal-c2";
/** The state dir name used before the rename; read in place when it is the only one present. */
export const LEGACY_HOME_DIR_NAME = ".t3";

/** The environment variables that name a base dir. */
export interface HalC2HomeEnvironment {
  readonly HALC2_HOME?: string | undefined;
  readonly T3CODE_HOME?: string | undefined;
}

let legacyHomeEnvWarned = false;

/**
 * The base dir the environment names, or undefined when it names none.
 * `HALC2_HOME` wins; the legacy `T3CODE_HOME` is honoured and logs a
 * deprecation warning once per process. Values are trimmed, and a blank value
 * is no selection.
 */
export const configuredHalC2Home = (env: HalC2HomeEnvironment): Effect.Effect<string | undefined> =>
  Effect.gen(function* () {
    const current = env.HALC2_HOME?.trim();
    if (current) {
      return current;
    }
    const legacy = env.T3CODE_HOME?.trim();
    if (!legacy) {
      return undefined;
    }
    if (!legacyHomeEnvWarned) {
      legacyHomeEnvWarned = true;
      yield* Effect.logWarning("T3CODE_HOME is deprecated; set HALC2_HOME instead.");
    }
    return legacy;
  });

/**
 * `<parent>/.hal-c2` when it exists, else an existing `<parent>/.t3`, else
 * `<parent>/.hal-c2` (not created here). Used for both the user home and a
 * worktree's dev state.
 */
export const resolveStateDirIn = (
  parent: string,
): Effect.Effect<string, never, FileSystem.FileSystem | Path.Path> =>
  Effect.gen(function* () {
    const fileSystem = yield* FileSystem.FileSystem;
    const path = yield* Path.Path;
    const current = path.join(parent, HALC2_HOME_DIR_NAME);
    const isDirectory = (candidate: string) =>
      fileSystem.stat(candidate).pipe(
        Effect.map((info) => info.type === "Directory"),
        Effect.orElseSucceed(() => false),
      );
    if (yield* isDirectory(current)) {
      return current;
    }
    const legacy = path.join(parent, LEGACY_HOME_DIR_NAME);
    return (yield* isDirectory(legacy)) ? legacy : current;
  });

/**
 * The HAL-C2 base dir in the order documented at the top of this file. An
 * explicit `--base-dir` style value belongs to the caller and outranks all of
 * it; `homeDir` is the user's home directory (`os.homedir()`).
 */
export const resolveHalC2Home = (options: {
  readonly env: HalC2HomeEnvironment;
  readonly homeDir: string;
}): Effect.Effect<string, never, FileSystem.FileSystem | Path.Path> =>
  Effect.gen(function* () {
    const configured = yield* configuredHalC2Home(options.env);
    return configured ?? (yield* resolveStateDirIn(options.homeDir));
  });
