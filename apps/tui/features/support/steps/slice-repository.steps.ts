// tui/git.feature: the repository beyond the panel's stacked actions
// (branches, worktrees, pull requests, init, providers, publishing) and what a
// running or failed action leaves in the panel.
import { expect } from "bun:test";

import type { TuiSelectState } from "../../../src/host/composerState.ts";
import { step } from "../../steps.ts";
import { objectRows } from "../design.ts";
import {
  gitState,
  hostMode,
  ready,
  scm,
  setCheckout,
  settle,
  statusText,
  vcsStatus,
} from "../gitWorld.ts";
import { chooseCommand, palette } from "../threadUi.ts";
import { pressKey, typeText, type World } from "../world.ts";

const CWD = "/workspace/shop";
const select = (ctx: World) => ctx.host!.state.get("select") as TuiSelectState;
const status = (ctx: World) => ctx.host!.state.get("status") as { text: string; kind: string };
const callsTo = (ctx: World, method: string) =>
  ctx.fake!.calls.filter((call) => call.method === method).map((call) => [...call.args]);

export async function command(ctx: World, title: string) {
  await ready(ctx);
  await chooseCommand(ctx, title);
  await settle(ctx);
}
/** Move the picker's highlight to `label`, then Enter. */
export async function pick(ctx: World, label: string) {
  const index = select(ctx).options.findIndex((option) => option.label === label);
  expect(index, `no "${label}" in the picker`).toBeGreaterThanOrEqual(0);
  const moves = index - select(ctx).index;
  for (let i = 0; i < Math.abs(moves); i += 1) await pressKey(ctx, moves > 0 ? "Down" : "Up");
  await pressKey(ctx, "Enter");
  await settle(ctx);
}
export async function answer(ctx: World, text: string) {
  expect(hostMode(ctx)).toBe("ask");
  await typeText(ctx, text);
  await pressKey(ctx, "Enter");
  await settle(ctx);
}
const offered = async (ctx: World, title: string) => {
  await pressKey(ctx, "Ctrl+K");
  const titles = palette(ctx).commands.map((entry) => entry.title);
  await pressKey(ctx, "Esc");
  return titles.includes(title);
};

/** The repository's branches, with the worktrees the fake MC holds. */
export function serveRefs(ctx: World, branches: string[]) {
  ctx.fake!.override("listRefs", async () => {
    const current = ctx.fake!.server.worktrees;
    const names = [...new Set([...branches, ...current.map((worktree) => worktree.refName)])];
    return {
      refs: names.map((name) => ({
        name,
        current: name === "feature/tax",
        isDefault: name === "main",
        worktreePath: current.find((worktree) => worktree.refName === name)?.path ?? null,
      })),
      isRepo: true,
      hasPrimaryRemote: true,
      nextCursor: null,
      totalCount: names.length,
    } as never;
  });
}

// --- Branches -------------------------------------------------------------------------

step(
  "the user switches the workspace to the new branch {string}",
  async (ctx: World, branch: string) => {
    scm(ctx);
    setCheckout(ctx, vcsStatus());
    await ready(ctx);
    serveRefs(ctx, ["main", "feature/tax"]);
    await command(ctx, "Switch or create a branch…");
    // The repository's branches, the current one marked, and a way to make a new one.
    expect(select(ctx).options).toEqual([
      {
        label: "＋ New branch…",
        description: "Create it from feature/tax and switch to it.",
      },
      { label: "main", description: "local branch" },
      { label: "feature/tax", description: "current" },
    ]);
    await pick(ctx, "＋ New branch…");
    await answer(ctx, branch);
  },
);

step("the workspace is on {string}", async (ctx: World, branch: string) => {
  expect(callsTo(ctx, "createRef")).toEqual([[CWD, branch]]);
  expect(statusText(ctx)).toBe(`Created ${branch} and switched to it.`);
  expect(gitState(ctx).branch).toBe(branch);
  // Under the composer too: the thread's checkout names its branch.
  expect((await objectRows(ctx, "composerContext")).join("")).toContain(`branch ${branch}`);
});

// --- Worktrees ---------------------------------------------------------------------------

step("the user creates a worktree for {string}", async (ctx: World, branch: string) => {
  scm(ctx);
  setCheckout(ctx, vcsStatus());
  await ready(ctx);
  serveRefs(ctx, ["main", "feature/tax"]);
  await command(ctx, "Worktrees…");
  expect(select(ctx).options.map((option) => option.label)).toEqual(["＋ New worktree…"]);
  await pick(ctx, "＋ New worktree…");
  await answer(ctx, branch);
});

step("the worktree is listed", async (ctx: World) => {
  expect(callsTo(ctx, "createWorktree")).toEqual([[CWD, "feature/tax", "fix/login"]]);
  const path = `${CWD}-worktrees/fix-login`;
  expect(statusText(ctx)).toBe(`Worktree for fix/login at ${path}.`);
  await command(ctx, "Worktrees…");
  expect(select(ctx).options).toEqual([
    {
      label: "＋ New worktree…",
      description: "A new branch off feature/tax, in its own folder.",
    },
    { label: "fix/login", description: path },
  ]);
  expect((await objectRows(ctx, "selectOverlay")).join("\n")).toContain("fix/login");
});

step("removing it deletes the worktree and keeps the branch", async (ctx: World) => {
  const path = `${CWD}-worktrees/fix-login`;
  serveRefs(ctx, ["main", "feature/tax", "fix/login"]);
  await pick(ctx, "fix/login");
  expect(select(ctx).options[1]).toEqual({
    label: "Remove the worktree",
    description: `Deletes ${path}; the branch fix/login stays.`,
  });
  await pick(ctx, "Remove the worktree");
  // The folder is what goes: one request, naming the path.
  expect(callsTo(ctx, "removeWorktree")).toEqual([[CWD, path]]);
  expect(statusText(ctx)).toBe(`Removed the worktree at ${path}; fix/login is kept.`);
  await command(ctx, "Worktrees…");
  expect(select(ctx).options.map((option) => option.label)).toEqual(["＋ New worktree…"]);
  await pressKey(ctx, "Esc");
  // The branch is still there to switch to.
  await command(ctx, "Switch or create a branch…");
  expect(select(ctx).options).toContainEqual({ label: "fix/login", description: "local branch" });
});

// --- Pull requests ---------------------------------------------------------------------------

type PullRequestWorld = World & { reference?: string; mode?: "local" | "worktree" };

step("the user checks out the pull request {string}", async (ctx: PullRequestWorld, reference) => {
  await ready(ctx);
  ctx.fake!.server.pullRequests = [
    {
      number: 42,
      title: "Add tax to the cart",
      url: "https://github.com/acme/shop/pull/42",
      baseBranch: "main",
      headBranch: "feature/tax",
      state: "open",
    },
  ];
  ctx.reference = reference;
  // A link is reviewed beside the work in hand; a number or a gh line replaces the checkout.
  ctx.mode = reference.startsWith("http") ? "worktree" : "local";
  await command(ctx, "Check out a pull request…");
  await answer(ctx, reference);
  expect(select(ctx).title).toBe("#42 Add tax to the cart · feature/tax → main");
  await pick(ctx, ctx.mode === "worktree" ? "Check out in a worktree" : "Check out here");
});

step(
  "the pull request is resolved and a local checkout or worktree is prepared",
  (ctx: PullRequestWorld) => {
    // Whatever the user typed goes to the server as typed; it finds the pull request.
    expect(callsTo(ctx, "resolvePullRequest")).toEqual([[CWD, ctx.reference]]);
    expect(callsTo(ctx, "preparePullRequest")).toEqual([
      [{ cwd: CWD, reference: ctx.reference, mode: ctx.mode, threadId: "t1" }],
    ]);
    expect(statusText(ctx)).toBe(
      ctx.mode === "worktree"
        ? `#42 is on feature/tax in ${CWD}-worktrees/pr-42.`
        : "#42 is on feature/tax.",
    );
    expect(status(ctx).kind).toBe("success");
  },
);

// --- Init ---------------------------------------------------------------------------------------

// "the thread's workspace is not a git repository" is git.steps.ts's.
step("the user initializes a repository", async (ctx: World) => {
  await ready(ctx);
  expect(gitState(ctx).isRepo).toBe(false);
  // Nothing that needs a repository is offered.
  expect(await offered(ctx, "Switch or create a branch…")).toBe(false);
  await command(ctx, "Initialize a repository");
});

step("the workspace becomes a git repository", async (ctx: World) => {
  expect(callsTo(ctx, "initRepository")).toEqual([[CWD]]);
  expect(statusText(ctx)).toBe("Repository initialized.");
  expect(gitState(ctx)).toMatchObject({ isRepo: true, branch: "main" });
  expect(await offered(ctx, "Initialize a repository")).toBe(false);
  expect(await offered(ctx, "Switch or create a branch…")).toBe(true);
});

// --- Providers and publishing ---------------------------------------------------------------------

const some = <T>(value: T) => ({ _id: "Option", _tag: "Some", value }) as never;
const none = { _id: "Option", _tag: "None" } as never;

function serveProviders(ctx: World) {
  ctx.fake!.override(
    "discoverSourceControl",
    async () =>
      ({
        versionControlSystems: [
          {
            kind: "git",
            implemented: true,
            label: "Git",
            status: "available",
            version: some("2.45.1"),
            installHint: "Install git",
            detail: none,
          },
        ],
        sourceControlProviders: [
          {
            kind: "github",
            label: "GitHub",
            status: "available",
            version: some("2.60.0"),
            installHint: "Install the GitHub CLI (gh)",
            detail: none,
            auth: { status: "authenticated", account: some("sam"), host: none, detail: none },
          },
          {
            kind: "gitlab",
            label: "GitLab",
            status: "missing",
            version: none,
            installHint: "Install the GitLab CLI (glab)",
            detail: none,
            auth: { status: "unknown", account: none, host: none, detail: none },
          },
        ],
      }) as never,
  );
}

step("the user opens source-control providers", async (ctx: World) => {
  await ready(ctx);
  serveProviders(ctx);
  await command(ctx, "Source-control providers");
});

step("each provider is listed with whether it is installed and signed in", async (ctx: World) => {
  expect(select(ctx).options).toEqual([
    { label: "Git", description: "installed 2.45.1" },
    { label: "GitHub", description: "installed 2.60.0 · signed in as sam" },
    {
      label: "GitLab",
      description: "not installed: Install the GitLab CLI (glab) · sign-in unknown",
    },
  ]);
  const rows = (await objectRows(ctx, "selectOverlay")).join("\n");
  expect(rows).toContain("installed 2.60.0 · signed in as sam");
  expect(rows).toContain("not installed");
});

step("the repository has no remote and a source provider is signed in", async (ctx: World) => {
  scm(ctx);
  setCheckout(ctx, vcsStatus({ refName: "main", hasPrimaryRemote: false, hasUpstream: false }));
  await ready(ctx);
  serveProviders(ctx);
});

step("the user publishes the repository", async (ctx: World) => {
  await command(ctx, "Publish repository…");
  // One provider is signed in, so it goes straight to the repository's name.
  await answer(ctx, "acme/shop");
  expect(select(ctx).options.map((option) => option.label)).toEqual(["Private", "Public"]);
  await pick(ctx, "Private");
  expect(select(ctx).options.map((option) => option.label)).toEqual(["Automatic", "SSH", "HTTPS"]);
  await pick(ctx, "Automatic");
});

step("the repository is created on the provider and set as the remote", async (ctx: World) => {
  expect(callsTo(ctx, "publishRepository")).toEqual([
    [
      {
        cwd: CWD,
        provider: "github",
        repository: "acme/shop",
        visibility: "private",
        protocol: "auto",
      },
    ],
  ]);
  expect(statusText(ctx)).toBe(
    "Published to https://github.com/acme/shop; origin is git@github.com:acme/shop.git.",
  );
  // The checkout has its remote now: nothing left to publish.
  expect(gitState(ctx).available).toBe(true);
  expect(scm(ctx).status).not.toBeNull();
  expect(await offered(ctx, "Publish repository…")).toBe(false);
});

// --- Progress and failure ---------------------------------------------------------------------------

const logText = (ctx: World) => gitState(ctx).log.map((line) => line.text);

step("the panel shows each phase and hook output as it runs", async (ctx: World) => {
  // A clean tree: "Commit, push & PR" had nothing to commit, so it pushed and opened the PR.
  expect(ctx.fake!.gitCalls.map((call) => "action" in call && call.action)).toEqual(["create_pr"]);
  await pressKey(ctx, "Ctrl+L");
  await settle(ctx);
  expect(logText(ctx)).toEqual([
    "▸ Pushing",
    "⚙ hook pre-push",
    "  tests: 42 passed",
    "▸ Creating pull request",
  ]);
  const rows = (await objectRows(ctx, "gitLog")).map((row) => row.trimEnd());
  expect(rows.map((row) => row.trim())).toEqual([
    "▸ Pushing",
    "⚙ hook pre-push",
    "tests: 42 passed",
    "▸ Creating pull request",
  ]);
  // While an action is still running the same lines are there already.
  ctx.fake!.setGitOutcome({ kind: "hang" });
  ctx.host!.dispatch("git.run", { action: "push", label: "Push" });
  await settle(ctx);
  expect(gitState(ctx).busy).toBe(true);
  expect(logText(ctx)).toEqual(["▸ Pushing", "⚙ hook pre-push", "  tests: 42 passed"]);
  expect((await objectRows(ctx, "sourceControlPanel")).join("\n")).toContain("tests: 42 passed");
});

step("a push fails because of a hook", async (ctx: World) => {
  scm(ctx);
  setCheckout(ctx, vcsStatus({ aheadCount: 0 }));
  await ready(ctx);
  // The hook refuses the push; the commit made just before it is still there.
  ctx.fake!.override("runGitStackedAction", async (input, onProgress) => {
    const base = { actionId: "a1", cwd: input.cwd, action: input.action };
    for (const event of [
      { ...base, kind: "phase_started", phase: "push", label: "Pushing" },
      { ...base, kind: "hook_started", hookName: "pre-push" },
      {
        ...base,
        kind: "hook_output",
        hookName: "pre-push",
        stream: "stderr",
        text: "eslint: 2 errors",
      },
      { ...base, kind: "hook_finished", hookName: "pre-push", exitCode: 1, durationMs: 40 },
    ]) {
      onProgress?.(event as never);
    }
    throw new Error("pre-push hook failed (exit 1)");
  });
  ctx.fake!.override("refreshVcsStatus", async () => vcsStatus({ aheadCount: 1 }));
  await pressKey(ctx, "Ctrl+L");
  ctx.host!.dispatch("git.run", { action: "push", label: "Push" });
  await settle(ctx);
});

step("the error stays visible until dismissed", async (ctx: World) => {
  const failure = "✗ push failed: pre-push hook failed (exit 1)";
  expect(gitState(ctx)).toMatchObject({ busy: false, failed: true });
  expect(logText(ctx)).toEqual(["▸ Pushing", "⚙ hook pre-push", "  eslint: 2 errors", failure]);
  expect((await objectRows(ctx, "gitLog")).join("\n")).toContain(failure);
  // The status line moves on with the next snapshot; the panel keeps the error.
  ctx.fake!.emitShell(ctx.fake!.latestShell());
  await settle(ctx);
  expect(statusText(ctx)).not.toContain("failed");
  expect((await objectRows(ctx, "gitLog")).join("\n")).toContain(failure);
  expect((await objectRows(ctx, "gitLog")).join("\n")).toContain("x dismiss");
  // Dismissing it is one key in the panel.
  expect(hostMode(ctx)).toBe("panel");
  await pressKey(ctx, "x");
  await settle(ctx);
  expect(gitState(ctx).failed).toBe(false);
  expect(logText(ctx)).toEqual([]);
});

step("the git status is refreshed", (ctx: World) => {
  expect(callsTo(ctx, "refreshVcsStatus")).toEqual([[CWD]]);
  // What the refresh found shows: the commit that did not get pushed.
  expect(gitState(ctx).syncLine).toContain("↑1");
});
