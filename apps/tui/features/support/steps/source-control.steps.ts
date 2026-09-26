// Steps for source-control/commit-and-generated-messages.feature, errors.feature,
// push-pull-and-default-branch.feature and status-and-changes.feature as the
// terminal client runs them through its source-control panel.
import { expect } from "bun:test";

import { step } from "../../steps.ts";
import {
  changes,
  focusPanel,
  gitState,
  hostMode,
  runAction,
  runFromPanel,
  scm,
  serverResult,
  setCheckout,
  settle,
  statusText,
  vcsStatus,
} from "../gitWorld.ts";
import { pressKey, typeText, type World } from "../world.ts";

const CWD = "/workspace/shop";

/** Start the Commit menu entry and stop at its message prompt. */
async function startCommit(ctx: World): Promise<void> {
  await runFromPanel(ctx, "Commit");
  expect(hostMode(ctx)).toBe("commit");
}

// --- setup ---

step("a connected environment with the project {string} in a git repository", (ctx: World) => {
  scm(ctx);
});

step(
  "a connected environment with a thread in the git project {string} with the remote {string}",
  (ctx: World) => {
    scm(ctx);
  },
);

step("the user has changed {string} and {string}", (ctx: World, a: string, b: string) => {
  setCheckout(ctx, vcsStatus(changes(a, b)));
});

step("the working tree is clean", (ctx: World) => setCheckout(ctx, vcsStatus()));

step("the working tree is clean and the branch is ahead of its upstream", (ctx: World) =>
  setCheckout(ctx, vcsStatus({ aheadCount: 1 })),
);

step(
  "{string} tracks {string} and is {int} commit ahead",
  (ctx: World, branch: string, _upstream: string, ahead: number) => {
    setCheckout(ctx, vcsStatus({ refName: branch, aheadCount: ahead }));
    ctx.fake!.setGitOutcome({ kind: "succeed", result: serverResult("push") });
  },
);

step(
  "{string} is {int} commits behind its upstream and has no local commits",
  (ctx: World, branch: string, behind: number) => {
    setCheckout(ctx, vcsStatus({ refName: branch, behindCount: behind }));
  },
);

step("the push will be rejected by the remote", (ctx: World) => {
  setCheckout(ctx, vcsStatus({ aheadCount: 1 }));
  ctx.fake!.setGitOutcome({
    kind: "fail",
    message: "! [rejected] feature/tax -> feature/tax (fetch first)",
  });
});

// --- committing ---

step("the user commits with the message {string}", async (ctx: World, message: string) => {
  ctx.fake!.setGitOutcome({
    kind: "succeed",
    result: serverResult("commit", { subject: message }),
  });
  await startCommit(ctx);
  await typeText(ctx, message);
  await pressKey(ctx, "Enter");
  await settle(ctx);
});

step("a commit {string} holds both files", async (ctx: World, message: string) => {
  await settle(ctx);
  expect(ctx.fake!.gitCalls).toEqual([
    { method: "runGitStackedAction", cwd: CWD, action: "commit", commitMessage: message },
  ]);
  // The server commits the whole working tree the panel summed up.
  expect(gitState(ctx).changesLine).toBe("2 files · +6 -2");
  expect(scm(ctx).status!.workingTree.files.map((file) => file.path)).toEqual([
    "src/cart.ts",
    "src/tax.ts",
  ]);
});

step("the user is told the commit was made with its short hash", async (ctx: World) => {
  const screen = await settle(ctx);
  expect(statusText(ctx)).toBe("Committed 1a2b3c4");
  expect(screen).toContain("Committed 1a2b3c4");
});

step("the user commits from the terminal client with an empty message", async (ctx: World) => {
  await startCommit(ctx);
  await pressKey(ctx, "Enter");
  await settle(ctx);
});

step("nothing is committed", async (ctx: World) => {
  await settle(ctx);
  expect(ctx.fake!.gitCalls).toEqual([]);
});

step("the user starts a commit and then cancels it", async (ctx: World) => {
  await startCommit(ctx);
  await typeText(ctx, "wip");
  await pressKey(ctx, "Esc");
  await settle(ctx);
});

step("nothing is committed and both files are still changed", async (ctx: World) => {
  const screen = await settle(ctx);
  expect(ctx.fake!.gitCalls).toEqual([]);
  expect(gitState(ctx).commitPrompt).toBeNull();
  expect(gitState(ctx).changesLine).toBe("2 files · +6 -2");
  // RightPanel.tsx sums the tree up on one line; it lists no files.
  expect(screen).toContain("2 files · +6 -2");
  expect(scm(ctx).status!.workingTree.files.map((file) => file.path)).toEqual([
    "src/cart.ts",
    "src/tax.ts",
  ]);
});

step("the user runs a commit from the terminal client", (ctx: World) => runAction(ctx, "Commit"));
step("the user runs commit and push from the terminal client", (ctx: World) =>
  runAction(ctx, "Commit & push"),
);

step("no commit message is asked for and the branch is pushed", async (ctx: World) => {
  await settle(ctx);
  expect(ctx.fake!.gitCalls).toEqual([{ method: "runGitStackedAction", cwd: CWD, action: "push" }]);
  expect(gitState(ctx).commitPrompt).toBeNull();
  expect(hostMode(ctx)).not.toBe("commit");
});

// --- pushing and pulling ---

step("the user pushes", (ctx: World) => runAction(ctx, "Push"));
step("the user pushes from the terminal client", (ctx: World) => runAction(ctx, "Push"));

step("{string} has the new commit", async (ctx: World) => {
  await settle(ctx);
  expect(ctx.fake!.gitCalls).toEqual([{ method: "runGitStackedAction", cwd: CWD, action: "push" }]);
});

step("the user is told where the branch was pushed", async (ctx: World) => {
  const screen = await settle(ctx);
  expect(statusText(ctx)).toBe("Pushed to origin/feature/tax");
  expect(screen).toContain("Pushed to origin/feature/tax");
});

step("the user pulls", async (ctx: World) => {
  // The server fast-forwards, then the status stream reports the new position.
  const state = scm(ctx);
  const refName = state.status?.refName ?? null;
  state.onPull = () => setCheckout(ctx, vcsStatus({ refName }));
  await runAction(ctx, "Pull");
});

step("the branch has the {int} new commits", async (ctx: World) => {
  const screen = await settle(ctx);
  expect(ctx.fake!.gitCalls).toEqual([{ method: "runGitPull", cwd: CWD }]);
  expect(statusText(ctx)).toBe("Pulled.");
  expect(gitState(ctx).syncLine).toBe("up to date with upstream");
  expect(screen).toContain("up to date with upstream");
});

step("the status line reads the failure starting {string}", async (ctx: World, prefix: string) => {
  const screen = await settle(ctx);
  const status = ctx.host!.state.get("status") as { text: string; kind: string };
  expect(status.text.startsWith(prefix)).toBe(true);
  expect(status.text).toContain("[rejected]");
  expect(status.kind).toBe("error");
  expect(screen).toContain(prefix);
});

// --- status ---

// "the user is looking at a thread in {string}" is threads.steps.ts (its git world opens the panel).

step("the agent's turn ends after editing a file", async (ctx: World) => {
  setCheckout(ctx, vcsStatus(changes("src/cart.ts")));
  await settle(ctx);
});

step(
  "the thread's status shows the new change without the user asking for a refresh",
  async (ctx: World) => {
    const screen = await settle(ctx);
    expect(gitState(ctx).changesLine).toBe("1 file · +3 -1");
    expect(screen).toContain("1 file · +3 -1");
    expect(ctx.fake!.gitCalls).toEqual([]);
  },
);
