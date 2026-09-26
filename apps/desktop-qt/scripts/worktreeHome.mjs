import * as NodeChildProcess from "node:child_process";
import * as NodePath from "node:path";

const git = (dir, args) => {
  const result = NodeChildProcess.spawnSync("git", ["-C", dir, ...args], { encoding: "utf8" });
  return result.error || result.status !== 0 ? undefined : result.stdout.trim();
};

/**
 * The worktree-local `.hal-c2` root when `dir` is in a linked git worktree, else
 * undefined. Mirrors `resolveWorktreeHalC2Home` in packages/shared/devHome: git
 * puts a linked worktree's git dir at `<common-dir>/worktrees/<name>`.
 */
export function resolveWorktreeHome(dir) {
  const gitDir = git(dir, ["rev-parse", "--absolute-git-dir"]);
  const topLevel = git(dir, ["rev-parse", "--show-toplevel"]);
  if (gitDir === undefined || topLevel === undefined) return undefined;
  const segments = gitDir.split(/[/\\]/).filter((segment) => segment.length > 0);
  const isLinkedWorktree = segments.length >= 3 && segments.at(-2) === "worktrees";
  return isLinkedWorktree ? NodePath.join(topLevel, ".hal-c2") : undefined;
}
