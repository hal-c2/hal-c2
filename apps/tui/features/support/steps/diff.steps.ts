// Steps for source-control/checkpoint-diffs.feature and review-diffs.feature:
// the checkpoint diff viewer over the conversation. The palette's "View all
// changes" and the timeline's changed-files rows open it with `diff.open`.
import { expect } from "bun:test";
import type { OrchestrationThread } from "@t3tools/contracts";

import { step } from "../../steps.ts";
import { ready, scm, setCheckout, setDetail, settle, vcsStatus } from "../gitWorld.ts";
import type { QmlObject } from "opentui-qml";

import { findObject, pressKey, type World } from "../world.ts";

const OLD_LINE = "const tax = 0;";
const NEW_LINE = "const tax = rate * total;";

function fileDiff(path: string): string {
  return [
    `diff --git a/${path} b/${path}`,
    "index 1111111..2222222 100644",
    `--- a/${path}`,
    `+++ b/${path}`,
    "@@ -1,2 +1,2 @@",
    " export {};",
    `-${OLD_LINE}`,
    `+${NEW_LINE}`,
    "",
  ].join("\n");
}

const turnFile = (turn: number) => `src/turn${turn}.ts`;

function checkpoint(turn: number, paths: string[]): OrchestrationThread["checkpoints"][number] {
  return {
    turnId: `turn-${turn}`,
    checkpointTurnCount: turn,
    checkpointRef: `refs/t3/checkpoints/${turn}`,
    status: "ready",
    files: paths.map((path) => ({ path, kind: "modified", additions: 1, deletions: 1 })),
    assistantMessageId: null,
    completedAt: `2026-07-13T00:0${turn}:00.000Z`,
  } as unknown as OrchestrationThread["checkpoints"][number];
}

/** Checkpoints for turns 1..count, each editing its own file. */
function finishTurns(ctx: World, count: number): void {
  const state = scm(ctx);
  const turns = Array.from({ length: count }, (_, i) => i + 1);
  for (const turn of turns) state.diffs.set(String(turn), fileDiff(turnFile(turn)));
  state.diffs.set("all", turns.map((turn) => fileDiff(turnFile(turn))).join(""));
  setDetail(ctx, {
    ...state.detail,
    checkpoints: turns.map((turn) => checkpoint(turn, [turnFile(turn)])),
  });
}

/** One turn that changed these files. */
function changeFiles(ctx: World, paths: string[]): void {
  const state = scm(ctx);
  const text = paths.map(fileDiff).join("");
  state.diffs.set("1", text);
  state.diffs.set("all", text);
  setDetail(ctx, { ...state.detail, checkpoints: [checkpoint(1, paths)] });
}

interface DiffState {
  open: boolean;
  scopeLabel: string;
  status: string;
  view: string;
  files: Array<{ path: string; filetype: string }>;
}
const diffState = (ctx: World) => ctx.host!.state.get("diff") as DiffState;

async function openDiff(ctx: World, turnCount?: number): Promise<string> {
  await ready(ctx);
  ctx.host!.dispatch("diff.open", turnCount === undefined ? {} : { turnCount });
  const screen = await settle(ctx);
  expect(ctx.host!.state.get("mode")).toBe("diff");
  return screen;
}

function findAll(ctx: World, objectName: string): QmlObject[] {
  const found: QmlObject[] = [];
  const queue: QmlObject[] = [ctx.app!.root];
  while (queue.length > 0) {
    const object = queue.shift()!;
    if (object.get("objectName") === objectName) found.push(object);
    queue.push(...object.children);
  }
  return found;
}

/** The screen rows showing each of the diff's two changed lines. */
function changedRows(screen: string): { old: number[]; next: number[] } {
  const rows = screen.split("\n");
  const where = (text: string) => rows.flatMap((row, index) => (row.includes(text) ? [index] : []));
  return { old: where(OLD_LINE), next: where(NEW_LINE) };
}

// --- setup ---

step(
  "a connected environment with the thread {string} in the git project {string}",
  (ctx: World, title: string) => {
    scm(ctx, { title });
  },
);

step(
  "a connected environment with a thread in the git project {string} on the branch {string}",
  (ctx: World, _project: string, branch: string) => {
    scm(ctx);
    setCheckout(ctx, vcsStatus({ refName: branch }));
  },
);

step(
  "the agent finished {int} turns in {string} that each edited files",
  (ctx: World, count: number) => finishTurns(ctx, count),
);

step("turn {int} only answered a question", (ctx: World, turn: number) => {
  const state = scm(ctx);
  state.diffs.set(String(turn), "");
  setDetail(ctx, {
    ...state.detail,
    checkpoints: state.detail.checkpoints.map((entry) =>
      entry.checkpointTurnCount === turn ? checkpoint(turn, []) : entry,
    ),
  });
});

step("the node cannot read the checkpoints of {string}", (ctx: World) => {
  scm(ctx).diffs.set("all", new Error("checkpoint ref is missing"));
});

step("the diff changes {string} and {string}", (ctx: World, first: string, second: string) =>
  changeFiles(ctx, [first, second]),
);

// --- opening and stepping ---

step("the user opens the diff of turn {int}", async (ctx: World, turn: number) => {
  await openDiff(ctx, turn);
});

step("the user opens all changes of {string}", async (ctx: World) => {
  await openDiff(ctx);
});

step("the user opens the diff in the terminal client", async (ctx: World) => {
  await openDiff(ctx);
});

step(
  "only the changes the agent made during turn {int} are shown",
  async (ctx: World, turn: number) => {
    const screen = await settle(ctx);
    expect(ctx.fake!.diffCalls.at(-1)).toMatchObject({ method: "getTurnDiff", toTurnCount: turn });
    expect(diffState(ctx)).toMatchObject({ scopeLabel: `turn ${turn}`, status: "ready" });
    expect(diffState(ctx).files.map((file) => file.path)).toEqual([turnFile(turn)]);
    expect(screen).toContain(`diff · turn ${turn}`);
    expect(screen).toContain(turnFile(turn));
  },
);

step(
  "the changes of turns {int} to {int} are shown together against the checkout before turn {int}",
  async (ctx: World, first: number, last: number) => {
    const screen = await settle(ctx);
    expect(ctx.fake!.diffCalls).toEqual([
      { method: "getFullThreadDiff", threadId: "t1", toTurnCount: last },
    ]);
    const turns = Array.from({ length: last - first + 1 }, (_, i) => first + i);
    expect(diffState(ctx).files.map((file) => file.path)).toEqual(turns.map(turnFile));
    expect(screen).toContain("diff · all changes");
    for (const turn of turns) expect(screen).toContain(turnFile(turn));
  },
);

step("all changes are shown first", async (ctx: World) => {
  const screen = await settle(ctx);
  expect(diffState(ctx)).toMatchObject({ scopeLabel: "all changes", status: "ready" });
  expect(screen).toContain("diff · all changes");
  expect(screen).toContain("3 files");
});

step("the user can step to each turn's own diff", async (ctx: World) => {
  for (const turn of [3, 2, 1]) {
    await pressKey(ctx, "Down");
    const screen = await settle(ctx);
    expect(diffState(ctx).scopeLabel).toBe(`turn ${turn}`);
    expect(ctx.fake!.diffCalls.at(-1)).toMatchObject({ method: "getTurnDiff", toTurnCount: turn });
    expect(screen).toContain(turnFile(turn));
    expect(screen).not.toContain(turnFile(turn === 1 ? 2 : 1));
  }
  await pressKey(ctx, "Down");
  await settle(ctx);
  expect(diffState(ctx).scopeLabel).toBe("all changes");
});

step("the user is told there are no changes", async (ctx: World) => {
  const screen = await settle(ctx);
  expect(diffState(ctx).status).toBe("empty");
  expect(screen).toContain("no changes in this turn");
});

step("the diff viewer reports an error instead of an empty diff", async (ctx: World) => {
  const screen = await settle(ctx);
  expect(diffState(ctx).status).toBe("error");
  expect(screen).toContain("failed to load diff");
  expect(screen).not.toContain("no changes in this turn");
});

// --- highlighting and views ---

step("each file is shown on its own with the highlighting of its language", async (ctx: World) => {
  const screen = await settle(ctx);
  expect(diffState(ctx).files.map(({ path, filetype }) => ({ path, filetype }))).toEqual([
    { path: "src/cart.ts", filetype: "typescript" },
    { path: "README.md", filetype: "markdown" },
  ]);
  const views = findAll(ctx, "diffFile");
  expect(views.map((view) => view.get("filetype"))).toEqual(["typescript", "markdown"]);
  expect(screen).toContain("src/cart.ts  · typescript");
  expect(screen).toContain("README.md  · markdown");
});

async function showDiff(ctx: World, view: "unified" | "split"): Promise<void> {
  changeFiles(ctx, ["src/cart.ts"]);
  await openDiff(ctx);
  if (diffState(ctx).view !== view) await pressKey(ctx, "s");
  await settle(ctx);
  expect(diffState(ctx).view).toBe(view);
}

step("the diff is shown stacked in the terminal client", (ctx: World) => showDiff(ctx, "unified"));
step("the diff is shown split in the terminal client", (ctx: World) => showDiff(ctx, "split"));

async function switchView(ctx: World, view: "unified" | "split"): Promise<void> {
  await pressKey(ctx, "s");
  await settle(ctx);
  expect(diffState(ctx).view).toBe(view);
}

step("the user switches to the split view", (ctx: World) => switchView(ctx, "split"));
step("the user switches to the stacked view", (ctx: World) => switchView(ctx, "unified"));

step("the old and new lines are shown side by side", async (ctx: World) => {
  const screen = await settle(ctx);
  expect(findObject(ctx, "diffFile").get("view")).toBe("split");
  const { old, next } = changedRows(screen);
  expect(old.length).toBeGreaterThan(0);
  expect(old).toEqual(next);
});

step("the old and new lines are shown one above the other", async (ctx: World) => {
  const screen = await settle(ctx);
  expect(findObject(ctx, "diffFile").get("view")).toBe("unified");
  const { old, next } = changedRows(screen);
  expect(old).toHaveLength(1);
  expect(next).toHaveLength(1);
  expect(next[0]).toBeGreaterThan(old[0]!);
});
