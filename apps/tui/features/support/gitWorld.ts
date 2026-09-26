// Source-control helpers for the git, diff and settings steps: a thread whose
// workspace is a git checkout, the checkout states the features name, and the
// keyboard paths through the source-control panel.
import { expect } from "bun:test";
import type {
  GitRunStackedActionResult,
  GitStackedAction,
  OrchestrationThread,
  VcsStatusResult,
} from "@t3tools/contracts";

import type { TuiGitState } from "../../src/host/gitState.ts";
import { shell, thread } from "./fakeClient.ts";
import { boot, pressKey, snapshot, useClient, type World } from "./world.ts";

export const PR_URL = "https://github.com/acme/shop/pull/42";

const openPr = {
  number: 42,
  title: "Add tax to the cart",
  url: PR_URL,
  baseRef: "main",
  headRef: "feature/tax",
  state: "open" as const,
};

/** A clean feature branch in step with its upstream, overridden per scenario. */
export function vcsStatus(over: Partial<VcsStatusResult> = {}): VcsStatusResult {
  return {
    isRepo: true,
    hasPrimaryRemote: true,
    isDefaultRef: false,
    refName: "feature/tax",
    hasWorkingTreeChanges: false,
    workingTree: { files: [], insertions: 0, deletions: 0 },
    hasUpstream: true,
    aheadCount: 0,
    behindCount: 0,
    pr: null,
    ...over,
  } as VcsStatusResult;
}

/** Uncommitted edits to these files. */
export function changes(...paths: string[]): Partial<VcsStatusResult> {
  const files = paths.map((path) => ({ path, insertions: 3, deletions: 1 }));
  return {
    hasWorkingTreeChanges: true,
    workingTree: { files, insertions: 3 * files.length, deletions: files.length },
  } as Partial<VcsStatusResult>;
}

const CHANGED = changes("src/cart.ts", "src/tax.ts");
const ON_MAIN = { refName: "main", isDefaultRef: true };
const NO_REMOTE = { hasPrimaryRemote: false, hasUpstream: false };

/** Checkout states as git.feature and git-actions.feature spell them. */
export const CHECKOUTS: Readonly<Record<string, Partial<VcsStatusResult>>> = {
  "is a feature branch with changes and an upstream": CHANGED,
  "is the default branch with changes": { ...CHANGED, ...ON_MAIN },
  "has changes and no remote at all": { ...CHANGED, ...NO_REMOTE },
  "is a feature branch ahead of its upstream with no PR": { aheadCount: 1 },
  "has an open PR and is up to date": { pr: openPr },
  "is behind its upstream": { behindCount: 2 },
  "is a clean default branch ahead of its upstream": { ...ON_MAIN, aheadCount: 1 },
  "has diverged from its upstream": { aheadCount: 1, behindCount: 1 },
  "has no upstream and nothing to push": { hasUpstream: false },
  "is up to date with nothing to do": {},
  "has uncommitted changes and no remote": { ...CHANGED, ...NO_REMOTE },
  "has uncommitted changes on the default branch": { ...CHANGED, ...ON_MAIN },
  "has uncommitted changes on a branch with an open pull request": { ...CHANGED, pr: openPr },
  "has uncommitted changes on a feature branch with a remote": CHANGED,
  "has commits on a feature branch with no upstream": { hasUpstream: false, aheadCount: 2 },
  "is ahead of its upstream with an open pull request": { aheadCount: 1, pr: openPr },
  "is pushed and ahead of the default branch with no pull request": { aheadOfDefaultCount: 2 },
  "is up to date with an open pull request": { pr: openPr },
  "has no upstream and no local commits": { hasUpstream: false },
  "has no uncommitted changes": {},
  "has uncommitted changes": CHANGED,
  "is on a detached HEAD with changes": { ...CHANGED, refName: null },
  "has commits and no remote": { ...NO_REMOTE, aheadCount: 2 },
  "'s branch has an open pull request": { pr: openPr },
};

/** Per-scenario source-control setup, read lazily by the fake client. */
interface Scm {
  status: VcsStatusResult | null;
  detail: OrchestrationThread;
  /** Diff text by "all" or turn count; an Error fails the fetch. */
  diffs: Map<string, string | Error>;
  /** Runs when a pull succeeds (the server's status stream catching up). */
  onPull?: () => void;
}

/** The scenario's thread and checkout; the first call may name the thread. */
export function scm(ctx: World, options: { title?: string } = {}): Scm {
  const world = ctx as World & { scm?: Scm };
  if (!world.scm) {
    const title = options.title ?? "Thread one";
    const state: Scm = {
      status: vcsStatus(),
      detail: { ...thread(), title, worktreePath: "/workspace/shop" } as OrchestrationThread,
      diffs: new Map(),
    };
    world.scm = state;
    ctx.connectOnBoot = true;
    const diff = (key: string) => {
      const value = state.diffs.get(key) ?? "";
      return value instanceof Error ? Promise.reject(value) : Promise.resolve(value);
    };
    const listed = shell();
    useClient(ctx, {
      detail: state.detail,
      shellSnapshot: shell(listed.threads.map((row) => ({ ...row, title }))),
      getFullThreadDiff: () => diff("all"),
      getTurnDiff: (_thread, turn) => diff(String(turn)),
      runGitPull: async () => {
        state.onPull?.();
      },
    }).setVcsStatus(state.status);
  }
  return world.scm;
}

/** Replace the thread (checkpoints, controls) before or after boot. */
export function setDetail(ctx: World, detail: OrchestrationThread): void {
  scm(ctx).detail = detail;
  ctx.fake!.emitThread(detail);
}

/** Set the checkout before or after boot. */
export function setCheckout(ctx: World, status: VcsStatusResult | null): void {
  const state = scm(ctx);
  state.status = status;
  ctx.fake!.setVcsStatus(status);
}

/** Boot (if needed; the first snapshot arrives with it) and let the thread open. */
export async function ready(ctx: World): Promise<void> {
  scm(ctx);
  await boot(ctx);
  await settle(ctx);
}

/** Let pending client promises land, then render. */
export async function settle(ctx: World): Promise<string> {
  for (let i = 0; i < 3; i += 1) await new Promise((resolve) => setImmediate(resolve));
  return snapshot(ctx);
}

export const gitState = (ctx: World) => ctx.host!.state.get("git") as TuiGitState;
export const hostMode = (ctx: World) => ctx.host!.state.get("mode") as string;
export const panelState = (ctx: World) =>
  ctx.host!.state.get("rightPanel") as { isOpen: boolean; focused: boolean };
export const statusText = (ctx: World) =>
  (ctx.host!.state.get("status") as { text: string; kind: string }).text;

/** Open the source-control panel with the keys on it (Ctrl+L). */
export async function focusPanel(ctx: World): Promise<void> {
  await ready(ctx);
  if (!panelState(ctx).isOpen) await pressKey(ctx, "Ctrl+L");
  expect(hostMode(ctx)).toBe("panel");
}

/** Walk the highlight onto the row with this label. */
export async function moveTo(ctx: World, label: string): Promise<void> {
  await focusPanel(ctx);
  const target = gitState(ctx).actions.findIndex((action) => action.label === label);
  if (target < 0) {
    throw new Error(
      `no "${label}" in ${gitState(ctx)
        .actions.map((a) => a.label)
        .join(", ")}`,
    );
  }
  while (gitState(ctx).selectedIndex !== target) await pressKey(ctx, "Down");
  await settle(ctx);
}

/** Highlight the row and press Enter on it. */
export async function runFromPanel(ctx: World, label: string): Promise<void> {
  await moveTo(ctx, label);
  await pressKey(ctx, "Enter");
  await settle(ctx);
}

/**
 * Run an action by name: through the panel when it offers the action, or
 * straight at the host (as the palette does) when the checkout means the panel
 * would not list it as runnable.
 */
export async function runAction(ctx: World, label: string): Promise<void> {
  await ready(ctx);
  const row = gitState(ctx).actions.find((action) => action.label === label && !action.disabled);
  if (row) {
    await runFromPanel(ctx, label);
    return;
  }
  const ACTIONS: Record<string, string> = {
    Commit: "commit",
    "Commit & push": "commit_push",
    "Commit, push & PR": "commit_push_pr",
    Push: "push",
    "Create PR": "create_pr",
  };
  const action = ACTIONS[label];
  if (!action) throw new Error(`no runnable "${label}" for this checkout`);
  ctx.host!.dispatch("git.run", { action, label });
  await settle(ctx);
}

/** A finished run as the server reports it (toast titles as GitManager words them). */
export function serverResult(
  action: GitStackedAction,
  commit?: { subject: string },
): GitRunStackedActionResult {
  const sha = "1a2b3c4d5e6f7a8b9c0d";
  const committed = commit !== undefined;
  const pushed = action !== "commit";
  const shortSha = committed ? ` ${sha.slice(0, 7)}` : "";
  const title =
    action === "create_pr" || action === "commit_push_pr"
      ? "Created PR #43"
      : pushed
        ? `Pushed${shortSha} to origin/feature/tax`
        : `Committed${shortSha}`;
  return {
    action,
    branch: { status: "skipped_not_requested" },
    commit: committed
      ? { status: "created", commitSha: sha, subject: commit.subject }
      : { status: "skipped_not_requested" },
    push: pushed
      ? { status: "pushed", branch: "feature/tax", upstreamBranch: "origin/feature/tax" }
      : { status: "skipped_not_requested" },
    pr: { status: "skipped_not_requested" },
    toast: { title, cta: { kind: "none" } },
  } as unknown as GitRunStackedActionResult;
}
