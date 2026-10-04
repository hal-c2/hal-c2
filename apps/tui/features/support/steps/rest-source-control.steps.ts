// source-control/*.feature as the terminal client delivers them beyond the panel's
// stacked actions: a commit message left to the writer model, a running action's
// stage, a failed hook, publishing, the host's name for a pull request, a pull
// request seen before it is checked out, the default-branch question, branches,
// review against another base, a note over several diff lines, `git init`, and a
// thread started in a worktree of its own.
import { expect } from "bun:test";
import type { GitActionProgressEvent, GitRunStackedActionResult } from "@hal-c2/contracts";

import type { TuiComposerState, TuiNewThreadState } from "../../../src/host/composerState.ts";
import { step } from "../../steps.ts";
import { objectRows } from "../design.ts";
import { addProject, env, flush, ui } from "../environment.ts";
import { shell } from "../fakeClient.ts";
import {
  changes,
  gitState,
  hostMode,
  ready,
  runFromPanel,
  scm,
  serverResult,
  setCheckout,
  settle,
  statusText,
  vcsStatus,
} from "../gitWorld.ts";
import { deferred } from "../threadWorld.ts";
import { pasteText, pressKey, snapshot, typeText, type World } from "../world.ts";
import { select } from "./controls.steps.ts";
import { answer, command, pick, serveRefs } from "./slice-repository.steps.ts";

const CWD = "/workspace/shop";
const callsTo = (ctx: World, method: string) =>
  ctx.fake!.calls.filter((call) => call.method === method).map((call) => [...call.args]);
const logText = (ctx: World) => gitState(ctx).log.map((line) => line.text);
const composer = (ctx: World) => ctx.host!.state.get("composer") as TuiComposerState;

// --- A commit the MC runs, phase by phase ------------------------------------------------

interface CommitWorld extends World {
  /** Report one more thing the MC did in the running action. */
  report?: (event: Record<string, unknown>) => void;
  finishAction?: (result: GitRunStackedActionResult | null) => void;
}

/**
 * The MC's side of a commit, held open so the scenario plays each report in turn:
 * with no message it names the writer model's stage before the commit's own.
 */
function holdAction(ctx: CommitWorld) {
  ctx.fake!.override("runGitStackedAction", (input, onProgress) => {
    const done = deferred<GitRunStackedActionResult | null>();
    const base = { actionId: "a1", cwd: input.cwd, action: input.action };
    ctx.report = (event) => onProgress?.({ ...base, ...event } as GitActionProgressEvent);
    ctx.finishAction = done.resolve;
    ctx.report({ kind: "action_started", phases: ["commit"] });
    if (!input.commitMessage) {
      ctx.report({ kind: "phase_started", phase: "commit", label: "Generating commit message..." });
    }
    return done.promise;
  });
}

/** Open the commit prompt and leave the message to the writer model (Tab). */
async function commitUnwritten(ctx: World) {
  await runFromPanel(ctx, "Commit");
  expect(hostMode(ctx)).toBe("commit");
  await pressKey(ctx, "Tab");
  await settle(ctx);
}

step("the user commits from the terminal client without writing a message", async (ctx: World) => {
  await ready(ctx);
  holdAction(ctx);
  await commitUnwritten(ctx);
});

step("the writer model writes the commit message", async (ctx: CommitWorld) => {
  // No message went with the commit: the MC's writer model is asked for one.
  expect(ctx.fake!.gitCalls).toEqual([
    { method: "runGitStackedAction", cwd: CWD, action: "commit" },
  ]);
  expect(gitState(ctx).commitPrompt).toBeNull();
  expect(gitState(ctx).busy).toBe(true);
  expect(logText(ctx)).toEqual(["▸ Generating commit message..."]);
  ctx.report!({ kind: "phase_started", phase: "commit", label: "Committing..." });
  ctx.finishAction!(serverResult("commit", { subject: "Add tax to the cart total" }));
  const screen = await settle(ctx);
  expect(statusText(ctx)).toBe("Committed 1a2b3c4");
  expect(screen).toContain("Committed 1a2b3c4");
  expect(gitState(ctx).busy).toBe(false);
});

// The clock is the scenario's: the hook takes seconds.
const T0 = Date.parse("2026-07-15T12:00:00.000Z");

step("the repository has a slow pre-commit hook", async (ctx: CommitWorld) => {
  ctx.nowMs = T0;
  await ready(ctx);
  holdAction(ctx);
});

step("the user commits without writing a message", commitUnwritten);

const progress = (ctx: World) => gitState(ctx).progress;
const progressRow = async (ctx: World) =>
  (await objectRows(ctx, "gitProgress")).join("").replace(/\s+/g, " ").trim();

step(
  "the user sees {string} and then {string} with the elapsed time",
  async (ctx: CommitWorld, generating: string, committing: string) => {
    expect(progress(ctx)).toEqual({ stage: generating, elapsed: "0s" });
    expect(await progressRow(ctx)).toMatch(/^Generating commit me.* 0s$/);
    expect(statusText(ctx)).toBe(`${generating} 0s`);
    // The writer model took four seconds; then the commit starts and its hook runs.
    ctx.nowMs = T0 + 4_000;
    ctx.report!({ kind: "phase_started", phase: "commit", label: committing });
    await settle(ctx);
    expect(progress(ctx)).toEqual({ stage: committing, elapsed: "4s" });
    expect(await progressRow(ctx)).toBe(`${committing} 4s`);
    ctx.report!({ kind: "hook_started", hookName: "pre-commit" });
    ctx.nowMs = T0 + 7_000;
    ctx.report!({
      kind: "hook_output",
      hookName: "pre-commit",
      stream: "stdout",
      text: "eslint: checking 12 files",
    });
    ctx.nowMs = T0 + 71_000;
    ctx.report!({
      kind: "hook_output",
      hookName: "pre-commit",
      stream: "stdout",
      text: "tsc: 0 errors",
    });
    await settle(ctx);
    // The time moved with the hook's reports.
    expect(progress(ctx)).toEqual({ stage: committing, elapsed: "1m 11s" });
    expect(await progressRow(ctx)).toBe(`${committing} 1m 11s`);
    expect(statusText(ctx)).toBe(`${committing} 1m 11s`);
  },
);

step("the last line the hook printed", async (ctx: CommitWorld) => {
  expect(logText(ctx).at(-1)).toBe("  tsc: 0 errors");
  const rows = (await objectRows(ctx, "gitLog")).map((row) => row.trim());
  expect(rows.at(-1)).toBe("tsc: 0 errors");
  // Finished, the stage goes and the MC's summary stands.
  ctx.finishAction!(serverResult("commit", { subject: "Add tax" }));
  await settle(ctx);
  expect(progress(ctx)).toBeNull();
  expect(statusText(ctx)).toBe("Committed 1a2b3c4");
});

// --- A hook that refuses the commit ---------------------------------------------------------

step("the pre-commit hook fails with {string}", (ctx: World, output: string) => {
  setCheckout(ctx, vcsStatus(changes("src/cart.ts")));
  ctx.fake!.override("runGitStackedAction", async (input, onProgress) => {
    const base = { actionId: "a1", cwd: input.cwd, action: input.action };
    for (const event of [
      { kind: "action_started", phases: ["commit"] },
      { kind: "phase_started", phase: "commit", label: "Committing..." },
      { kind: "hook_started", hookName: "pre-commit" },
      { kind: "hook_output", hookName: "pre-commit", stream: "stderr", text: output },
      { kind: "hook_finished", hookName: "pre-commit", exitCode: 1, durationMs: 30 },
    ]) {
      onProgress?.({ ...base, ...event } as GitActionProgressEvent);
    }
    throw new Error("pre-commit hook failed (exit 1)");
  });
});

step("the user commits from the terminal client", async (ctx: World) => {
  await runFromPanel(ctx, "Commit");
  await typeText(ctx, "Add tax to the cart");
  await pressKey(ctx, "Enter");
  await settle(ctx);
});

step(
  "the user sees that the commit phase failed and the hook printed {string}",
  async (ctx: World, output: string) => {
    const failure = "✗ commit failed: pre-commit hook failed (exit 1)";
    expect(gitState(ctx)).toMatchObject({ busy: false, failed: true });
    expect(logText(ctx)).toEqual(["▸ Committing...", "⚙ hook pre-commit", `  ${output}`, failure]);
    // Kept: the next snapshot moves the status line on, not the panel.
    ctx.fake!.emitShell(ctx.fake!.latestShell());
    await settle(ctx);
    const rows = (await objectRows(ctx, "gitLog")).map((row) => row.trim());
    expect(rows.slice(0, 4)).toEqual(["▸ Committing...", "⚙ hook pre-commit", output, failure]);
    // Nothing was committed: the file is still changed.
    expect(gitState(ctx).changesLine).toBe("1 file · +3 -1");
  },
);

// --- Publishing -------------------------------------------------------------------------------

const some = <T>(value: T) => ({ _id: "Option", _tag: "Some", value }) as never;
const none = { _id: "Option", _tag: "None" } as never;
const signedIn = (kind: string, label: string) => ({
  kind,
  label,
  status: "available",
  version: some("2.60.0"),
  installHint: `Install the ${label} CLI`,
  detail: none,
  auth: { status: "authenticated", account: some("sam"), host: none, detail: none },
});

interface PublishWorld extends World {
  /** What each step of the flow asked, in order. */
  asked?: string[];
}

step("the user publishes the repository from the terminal client", async (ctx: PublishWorld) => {
  await ready(ctx);
  ctx.fake!.override(
    "discoverSourceControl",
    async () =>
      ({
        versionControlSystems: [],
        sourceControlProviders: [signedIn("github", "GitHub"), signedIn("gitlab", "GitLab")],
      }) as never,
  );
  const page = ctx.host!.state.get("page");
  const ask = () => (ctx.host!.state.get("ask") as { label: string }).label;
  await command(ctx, "Publish repository…");
  ctx.asked = [select(ctx).title];
  expect(select(ctx).options.map((option) => option.label)).toEqual(["GitHub", "GitLab"]);
  await pick(ctx, "GitHub");
  ctx.asked.push(ask());
  await answer(ctx, "acme/shop");
  ctx.asked.push(select(ctx).title);
  expect(select(ctx).options.map((option) => option.label)).toEqual(["Private", "Public"]);
  await pick(ctx, "Public");
  ctx.asked.push(select(ctx).title);
  expect(select(ctx).options.map((option) => option.label)).toEqual(["Automatic", "SSH", "HTTPS"]);
  expect((await objectRows(ctx, "selectOverlay")).join("\n")).toContain("git@host:owner/name.git");
  // In place: the conversation is still the page under each question.
  expect(ctx.host!.state.get("page")).toEqual(page);
  await pick(ctx, "SSH");
});

step(
  "the terminal client guides provider, repository, visibility and protocol in place",
  (ctx: PublishWorld) => {
    expect(ctx.asked).toEqual(["publish to", "repository", "publish acme/shop", "remote protocol"]);
    expect(callsTo(ctx, "publishRepository")).toEqual([
      [
        {
          cwd: CWD,
          provider: "github",
          repository: "acme/shop",
          visibility: "public",
          protocol: "ssh",
        },
      ],
    ]);
    expect(statusText(ctx)).toBe(
      "Published to https://github.com/acme/shop; origin is git@github.com:acme/shop.git.",
    );
    expect(hostMode(ctx)).toBe("compose");
  },
);

// --- The host's name for a pull request --------------------------------------------------------

step(/^the project's primary remote is on (GitHub|GitLab)$/, (ctx: World, host: string) => {
  setCheckout(
    ctx,
    vcsStatus({
      aheadOfDefaultCount: 2,
      sourceControlProvider: {
        kind: host.toLowerCase(),
        name: host,
        baseUrl: `https://${host.toLowerCase()}.com`,
      },
    } as never),
  );
});

step("the pull request entry is called {string}", async (ctx: World, name: string) => {
  const entry = gitState(ctx).actions.find((action) => action.id === "menu-pr");
  expect(entry).toMatchObject({ label: name, disabled: false, action: "create_pr" });
  // The recommended action names it the same way.
  expect(gitState(ctx).quickAction.label).toBe(name);
  expect((await objectRows(ctx, "sourceControlPanel")).join("\n")).toContain(name);
});

// --- A pull request, seen before it is checked out -----------------------------------------------

step("a connected environment with the GitHub project {string}", (ctx: World) => {
  scm(ctx);
});

step(
  "the user pastes {string} to start a pull request thread",
  async (ctx: World, link: string) => {
    await ready(ctx);
    ctx.fake!.server.pullRequests = [
      {
        number: 42,
        title: "Add tax to the cart",
        url: link,
        baseBranch: "main",
        headBranch: "feature/tax",
        state: "open",
      },
    ];
    await command(ctx, "Check out a pull request…");
    expect(hostMode(ctx)).toBe("ask");
    await pasteText(ctx, link);
    await pressKey(ctx, "Enter");
    await settle(ctx);
    expect(callsTo(ctx, "resolvePullRequest")).toEqual([[CWD, link]]);
  },
);

step(
  "the user sees the pull request's title and branches before choosing local or worktree",
  async (ctx: World) => {
    expect(select(ctx)).toMatchObject({
      open: true,
      title: "#42 Add tax to the cart · feature/tax → main",
    });
    expect(select(ctx).options.map((option) => option.label)).toEqual([
      "Check out here",
      "Check out in a worktree",
    ]);
    const rows = (await objectRows(ctx, "selectOverlay")).join("\n");
    expect(rows).toContain("#42 Add tax to the cart · feature/tax → main");
    expect(rows).toContain("Check out in a worktree");
    // Nothing was checked out to show it.
    expect(callsTo(ctx, "preparePullRequest")).toEqual([]);
    await pick(ctx, "Check out in a worktree");
    expect(callsTo(ctx, "preparePullRequest")).toMatchObject([[{ mode: "worktree" }]]);
  },
);

// --- The default branch asks first -----------------------------------------------------------------

step("the checkout is on the default branch {string}", (ctx: World, branch: string) => {
  setCheckout(
    ctx,
    vcsStatus({ ...changes("src/cart.ts", "src/tax.ts"), refName: branch, isDefaultRef: true }),
  );
});

step(
  "the user is asked to confirm before anything reaches {string}",
  async (ctx: World, branch: string) => {
    expect(select(ctx)).toMatchObject({
      open: true,
      title: `Commit & push on the default branch ${branch}?`,
    });
    expect(select(ctx).options.map((option) => option.label)).toEqual([
      `Continue on ${branch}`,
      "Create a feature branch and continue",
      "Cancel",
    ]);
    expect((await objectRows(ctx, "selectOverlay")).join("\n")).toContain(`Continue on ${branch}`);
    // Not even the commit message is asked for yet, and Enter as it stands cancels.
    expect(gitState(ctx).commitPrompt).toBeNull();
    expect(ctx.fake!.gitCalls).toEqual([]);
    await pressKey(ctx, "Enter");
    await settle(ctx);
    expect(select(ctx).open).toBe(false);
    expect(gitState(ctx).commitPrompt).toBeNull();
    expect(ctx.fake!.gitCalls).toEqual([]);
    // Asked again, the user moves the work onto a branch of its own.
    await runFromPanel(ctx, "Commit & push");
    await pick(ctx, "Create a feature branch and continue");
    expect(hostMode(ctx)).toBe("commit");
    await typeText(ctx, "Add tax");
    await pressKey(ctx, "Enter");
    await settle(ctx);
    expect(ctx.fake!.gitCalls).toEqual([
      {
        method: "runGitStackedAction",
        cwd: CWD,
        action: "commit_push",
        commitMessage: "Add tax",
        featureBranch: true,
      },
    ]);
  },
);

// --- Branches -------------------------------------------------------------------------------------------

step(
  "the user switches the thread to {string} from the terminal client",
  async (ctx: World, branch: string) => {
    await ready(ctx);
    serveRefs(ctx, ["main", "feature/tax"]);
    // The MC's status stream follows the checkout.
    ctx.fake!.override("switchRef", async (_cwd, refName) => {
      setCheckout(ctx, vcsStatus({ refName, isDefaultRef: refName === "main" }));
      return { refName } as never;
    });
    expect(gitState(ctx).branch).toBe("feature/tax");
    await command(ctx, "Switch or create a branch…");
    expect(select(ctx).options.map((option) => option.label)).toEqual([
      "＋ New branch…",
      "main",
      "feature/tax",
    ]);
    await pick(ctx, branch);
  },
);

step(
  "the checkout is on {string} and the thread's branch reads {string}",
  async (ctx: World, branch: string, shown: string) => {
    expect(callsTo(ctx, "switchRef")).toEqual([[CWD, branch]]);
    expect(statusText(ctx)).toBe(`Switched to ${branch}.`);
    expect(gitState(ctx).branch).toBe(branch);
    expect((await objectRows(ctx, "composerContext")).join("")).toContain(`branch ${shown}`);
  },
);

// --- Review against another base ------------------------------------------------------------------------

const fileDiff = (path: string, hunk: string) =>
  [`diff --git a/${path} b/${path}`, `--- a/${path}`, `+++ b/${path}`, hunk].join("\n");
const diff = (ctx: World) =>
  ctx.host!.state.get("diff") as {
    open: boolean;
    title: string;
    status: string;
    files: Array<{ path: string; body: string }>;
  };

function serveReviewRefs(ctx: World) {
  ctx.fake!.override(
    "listRefs",
    async () =>
      ({
        refs: [
          { name: "main", current: false, isDefault: true, worktreePath: null },
          { name: "feature/tax", current: true, isDefault: false, worktreePath: null },
          {
            name: "origin/main",
            isRemote: true,
            remoteName: "origin",
            current: false,
            isDefault: false,
            worktreePath: null,
          },
        ],
        isRepo: true,
        hasPrimaryRemote: true,
        nextCursor: null,
        totalCount: 3,
      }) as never,
  );
}

step(
  "the user compares the branch against {string} instead of {string}",
  async (ctx: World, base: string, usual: string) => {
    await ready(ctx);
    serveReviewRefs(ctx);
    // The local default branch is behind its remote: against it one more file shows.
    ctx.fake!.server.reviewDiffs.set(
      `${usual}:all`,
      [
        fileDiff("src/cart.ts", "@@ -1 +1 @@\n-total\n+total + tax"),
        fileDiff("src/rates.ts", "@@ -1 +1 @@\n-old rate\n+new rate"),
      ].join("\n"),
    );
    ctx.fake!.server.reviewDiffs.set(
      `${base}:all`,
      fileDiff("src/cart.ts", "@@ -1 +1 @@\n-total\n+total + tax"),
    );
    await command(ctx, "Review changes against a base…");
    // The default branch is the one offered first; the user picks the other.
    expect(select(ctx).options.map((option) => option.label)).toEqual([usual, base]);
    expect(select(ctx).options[select(ctx).index]!.label).toBe(usual);
    await pick(ctx, base);
    await pick(ctx, "Every change");
  },
);

step("the diff shows the changes against {string}", async (ctx: World, base: string) => {
  expect(callsTo(ctx, "reviewDiff")).toEqual([[CWD, base, false]]);
  expect(hostMode(ctx)).toBe("diff");
  expect(diff(ctx)).toMatchObject({
    open: true,
    status: "ready",
    title: `diff · ${base}…feature/tax`,
  });
  expect(diff(ctx).files.map((file) => file.path)).toEqual(["src/cart.ts"]);
  const rows = (await objectRows(ctx, "diffViewer")).join("\n");
  expect(rows).toContain(`${base}…feature/tax`);
  expect(rows).toContain("total + tax");
  expect(rows).not.toContain("src/rates.ts");
});

// --- A note over several lines ---------------------------------------------------------------------------

const REFERENCE = /\[([^\]]+)\]\(hal-c2-context:\/\/v1\/([a-z-]+)\/([a-z0-9_-]+)\)/i;
// Lines 10 to 12 of the file are new; line 9 and 13 are context.
const TAX_LINES = [
  "+  const rate = 0.08;",
  "+  const tax = subtotal * rate;",
  "+  return subtotal + tax;",
];
const CART_DIFF = fileDiff(
  "src/cart.ts",
  [
    "@@ -9,3 +9,5 @@",
    " export function total(subtotal) {",
    ...TAX_LINES,
    "-  return subtotal;",
    " }",
  ].join("\n"),
);

step(
  "the user comments {string} on lines {int} to {int} of {string}",
  async (ctx: World, note: string, first: number, last: number, path: string) => {
    await ready(ctx);
    serveReviewRefs(ctx);
    ctx.fake!.server.reviewDiffs.set("main:all", CART_DIFF);
    await command(ctx, "Review changes against a base…");
    await pick(ctx, "main");
    await pick(ctx, "Every change");
    expect(hostMode(ctx)).toBe("diff");
    await pressKey(ctx, "c");
    await settle(ctx);
    // Each changed line is offered by its place in the file.
    expect(select(ctx).options.map((option) => option.description)).toEqual([
      `${path} · line 10`,
      `${path} · line 11`,
      `${path} · line 12`,
      // A removed line is numbered by the file as it was.
      `${path} · line 10`,
    ]);
    await pick(ctx, TAX_LINES[first - 10]!);
    expect(select(ctx).title).toBe(`note from line ${first} through`);
    await pick(ctx, `Line ${last}`);
    expect(ctx.host!.state.get("ask")).toMatchObject({ label: "note" });
    await typeText(ctx, note);
    await pressKey(ctx, "Enter");
    await settle(ctx);
  },
);

step("the composer carries that comment with the file and line range", async (ctx: World) => {
  expect(statusText(ctx)).toBe("Note on src/cart.ts lines 10 to 12 added to the prompt.");
  expect(composer(ctx).contexts).toHaveLength(1);
  expect(composer(ctx).contexts[0]).toMatchObject({
    kind: "review-comment",
    label: "src/cart.ts L10-12",
  });
  await pressKey(ctx, "Esc");
  await settle(ctx);
  const [row] = await objectRows(ctx, "composerReferences");
  expect(row!.trim()).toBe("× src/cart.ts L10-12");
  // Sent, the message names the chip and carries the comment, the file and the lines.
  await typeText(ctx, "Please fix this");
  await pressKey(ctx, "Enter");
  await settle(ctx);
  const [, text, , , context] = ctx.fake!.calls.find((call) => call.method === "sendReply")!
    .args as [unknown, string, unknown, unknown, { records: Array<Record<string, unknown>> }];
  expect(REFERENCE.exec(text)?.[1]).toBe("src/cart.ts L10-12");
  expect(context.records).toMatchObject([
    {
      kind: "review-comment",
      filePath: "src/cart.ts",
      rangeLabel: "+10 to +12",
      text: "Use the tax table",
      diff: TAX_LINES.join("\n"),
    },
  ]);
});

// --- git init ----------------------------------------------------------------------------------------------

step("the project {string} is not in a git repository", (ctx: World) => {
  setCheckout(ctx, vcsStatus({ isRepo: false, hasPrimaryRemote: false, hasUpstream: false }));
});

step(
  "the user initializes Git for {string} from the terminal client",
  async (ctx: World, title: string) => {
    await ready(ctx);
    // The thread's project is the one named; its folder has no repository.
    const current = ctx.fake!.latestShell();
    ctx.fake!.emitShell(
      shell(current.threads, current.projects.map((project) => ({ ...project, title })) as never),
    );
    expect(await settle(ctx)).toContain(title);
    expect(gitState(ctx).isRepo).toBe(false);
    await command(ctx, "Initialize a repository");
  },
);

step("{string} becomes a git repository", async (ctx: World) => {
  expect(callsTo(ctx, "initRepository")).toEqual([[CWD]]);
  expect(statusText(ctx)).toBe("Repository initialized.");
  expect(gitState(ctx)).toMatchObject({ isRepo: true, branch: "main" });
  expect((await objectRows(ctx, "composerContext")).join("")).toContain("branch main");
});

// --- A thread in a worktree of its own -------------------------------------------------------------------------

step(
  "a connected environment with the git project {string} whose default branch is {string}",
  (ctx: World, title: string, branch: string) => {
    addProject(ctx, title);
    env(ctx).refs = [{ name: branch, current: true, isDefault: true, worktreePath: null } as never];
  },
);

const newThread = (ctx: World) => ctx.host!.state.get("newThread") as TuiNewThreadState | null;

step(
  "the user starts a thread in a new worktree of {string}",
  async (ctx: World, title: string) => {
    await ui(ctx);
    await pressKey(ctx, "Ctrl+N");
    await flush(ctx);
    expect(newThread(ctx)).toMatchObject({ projectName: title, workspaceMode: "current" });
    // The workspace is chosen in the draft: this checkout, or a worktree of its own.
    ctx.host!.dispatch("palette.open");
    await typeText(ctx, "change workspace");
    await pressKey(ctx, "Enter");
    await flush(ctx);
    expect(select(ctx).options.map((option) => option.label)).toContain("New worktree");
    await pick(ctx, "New worktree");
    await flush(ctx);
    expect(newThread(ctx)).toMatchObject({ workspaceMode: "new-worktree", branch: "main" });
    expect(await snapshot(ctx)).toContain("New worktree ▾");
    await typeText(ctx, "Build the cart page");
    await pressKey(ctx, "Enter");
    await flush(ctx);
  },
);

step("the thread starts in a worktree of its own", (ctx: World) => {
  expect(callsTo(ctx, "createThread")).toMatchObject([
    [
      {
        title: "Build the cart page",
        firstMessage: "Build the cart page",
        branch: "main",
        worktreePath: null,
        createWorktree: true,
      },
    ],
  ]);
  expect(newThread(ctx)).toBeNull();
});
