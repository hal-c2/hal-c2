// features/tui/agents.feature: the agents panel beside the conversation. The
// open thread ("Delegating") delegated three workers, each with its own
// thread in the thread list; one of those threads waits on an approval.
import { expect } from "bun:test";
import * as DateTime from "effect/DateTime";

import { step } from "../../steps.ts";
import { thread as baseThread } from "../fakeClient.ts";
import { hostState, recorded, settle } from "../threadWorld.ts";
import { NOW_MS, sync, turns, type TurnWorld } from "../turnWorld.ts";
import { pressKey, resize, snapshot } from "../world.ts";

const time = (secondsAgo: number) => DateTime.makeUnsafe(new Date(NOW_MS - secondsAgo * 1000));

const PARENT_TITLE = "Delegating";
const WORKERS = [
  { id: "task-tests", title: "Fix the tests", child: "thread-tests" },
  { id: "task-docs", title: "Review the docs", child: "thread-docs" },
  { id: "task-notes", title: "Write notes", child: "thread-notes" },
] as const;

const childOf = (title: string) => WORKERS.find((worker) => worker.title === title)!.child;

function subagent(
  worker: (typeof WORKERS)[number],
  fields: Record<string, unknown>,
): Record<string, unknown> {
  return {
    id: worker.id,
    threadId: "t1",
    runId: null,
    parentNodeId: "node-1",
    origin: "app_owned",
    createdBy: "agent",
    driver: "codex",
    providerInstanceId: "codex",
    providerThreadId: null,
    childThreadId: worker.child,
    nativeTaskRef: null,
    prompt: worker.title,
    title: worker.title,
    model: "gpt-5.5",
    status: "running",
    result: null,
    progress: null,
    startedAt: time(90),
    completedAt: null,
    updatedAt: time(5),
    ...fields,
  };
}

step("the terminal is {int} by {int}", (ctx: TurnWorld, columns: number, rows: number) => {
  ctx.columns = columns;
  ctx.rows = rows;
});

step("the terminal is narrowed to {int} columns", async (ctx: TurnWorld, columns: number) => {
  await resize(ctx, columns);
  await settle();
});

step(
  "the open thread has delegated three workers, one waiting on an approval",
  async (ctx: TurnWorld) => {
    const fixture = await turns(ctx);
    fixture.thread = { title: PARENT_TITLE };
    fixture.subagents.push(
      subagent(WORKERS[0], { progress: "Running bun test cart", startedAt: time(184) }),
      subagent(WORKERS[1], {
        driver: "claudeAgent",
        providerInstanceId: "claudeAgent",
        model: "claude-opus-4-7",
        progress: "Wants to run git push",
        startedAt: time(42),
      }),
      subagent(WORKERS[2], {
        status: "completed",
        result: "Notes are in NOTES.md",
        startedAt: time(600),
        completedAt: time(525),
        updatedAt: time(525),
      }),
    );
    // Each worker's own thread is listed under the open one, as the MC lists it.
    const current = ctx.fake!.latestShell();
    const parent = { ...current.threads[0]!, title: PARENT_TITLE };
    ctx.fake!.emitShell({
      ...current,
      threads: [
        parent,
        ...WORKERS.map((worker) => ({
          ...parent,
          id: worker.child,
          title: worker.title,
          hasPendingApprovals: worker.child === "thread-docs",
          lineage: {
            rootThreadId: parent.id,
            parentThreadId: parent.id,
            relationshipToParent: "subagent",
          },
        })),
      ],
    } as never);
    await sync(ctx);
  },
);

const openPanel = async (ctx: TurnWorld) => {
  await pressKey(ctx, "Ctrl+X");
  await pressKey(ctx, "a");
  await settle();
  expect(hostState(ctx, "layout").rightPanel).toMatchObject({ kind: "agents", visible: true });
  if ((ctx.columns ?? 80) < 80) expect(hostState(ctx, "layout").rightPanel.asMain).toBe(true);
};

step("the user opens the agents panel", openPanel);
step("the agents panel is open", openPanel);

/** The panel's rows as the screen shows them: title line, state line, activity. */
const panelText = async (ctx: TurnWorld) => {
  await snapshot(ctx);
  return hostState(ctx, "agents");
};

step(
  "the agents panel lists, in order:",
  async (ctx: TurnWorld, table: ReadonlyArray<ReadonlyArray<string>>) => {
    const agents = await panelText(ctx);
    expect(
      agents.rows.map((row: { title: string; stateLabel: string }) => [
        row.title.trim(),
        row.stateLabel,
      ]),
    ).toEqual(table.map((cells) => [...cells]));
    // Drawn, at 80 by 24, in that order.
    const screen = await snapshot(ctx);
    const at = table.map(([title]) => screen.indexOf(title!));
    expect(at.every((index) => index >= 0)).toBe(true);
    expect(at).toEqual([...at].sort((a, b) => a - b));
    expect(screen).toContain("! Review the docs");
  },
);

step("each worker shows its provider, model and how long it has run", async (ctx: TurnWorld) => {
  const screen = await snapshot(ctx);
  // The panel is 32 columns at 80: what does not fit is clipped, never wrapped.
  expect(screen).toContain("Needs approval · Claude ·…");
  expect(screen).toContain("Working · Codex · GPT-5.5");
  // Live work counts to now; what ended, to when it ended.
  expect(screen).toContain("3m 04s");
  expect(screen).toContain("42s");
  expect(screen).toContain("1m 15s");
  expect(screen).toContain("Running bun test cart");
  expect(screen).toContain("Notes are in NOTES.md");
});

step("the agents panel's summary counts {string}", async (ctx: TurnWorld, summary: string) => {
  expect(await snapshot(ctx)).toContain(`│ Agents · ${summary} `);
  expect(hostState(ctx, "agents").summary).toBe(summary);
});

const moveTo = async (ctx: TurnWorld, title: string) => {
  for (let step = 0; step < WORKERS.length; step += 1) {
    const agents = hostState(ctx, "agents");
    const selected = agents.rows.find((row: { selected: boolean }) => row.selected);
    if (selected?.title.trim() === title) return;
    await pressKey(ctx, "Down");
  }
  throw new Error(`"${title}" is not in the agents panel`);
};

step(
  "the user selects the worker {string} and presses {string}",
  async (ctx: TurnWorld, title: string, key: string) => {
    await moveTo(ctx, title);
    await pressKey(ctx, key);
    await settle();
  },
);

step("the conversation shows the worker's thread", async (ctx: TurnWorld) => {
  // What the worker's own thread holds, as the MC sends it once it is opened.
  ctx.fake!.emitThread({
    ...baseThread(),
    id: childOf("Fix the tests"),
    title: "Fix the tests",
  } as never);
  await settle();
  expect(hostState(ctx, "page").threadId).toBe(childOf("Fix the tests"));
  expect(hostState(ctx, "mode")).toBe("compose");
});

step("the agents panel is closed and the prompt has the keys", async (ctx: TurnWorld) => {
  await snapshot(ctx);
  expect(hostState(ctx, "layout").rightPanel.visible).toBe(false);
  expect(hostState(ctx, "mode")).toBe("compose");
});

step("the agents panel offers the way back to {string}", async (ctx: TurnWorld, title: string) => {
  const screen = await snapshot(ctx);
  expect(screen).toContain(`↳ ${title}`);
  expect(hostState(ctx, "agents").parent).toBe(title);
});

step(
  "the client asks {string} with {string} chosen",
  async (ctx: TurnWorld, title: string, chosen: string) => {
    const select = hostState(ctx, "select");
    expect(select).toMatchObject({ open: true, title });
    expect(select.options[select.index].label).toBe(chosen);
    expect(await snapshot(ctx)).toContain(title);
  },
);

step("the user chooses {string} in the question", async (ctx: TurnWorld, label: string) => {
  const select = hostState(ctx, "select");
  const target = select.options.findIndex((option: { label: string }) => option.label === label);
  for (let index = select.index; index > target; index -= 1) await pressKey(ctx, "Up");
  for (let index = select.index; index < target; index += 1) await pressKey(ctx, "Down");
  await pressKey(ctx, "Enter");
  await settle();
});

step("the client stops the run of the worker's thread", (ctx: TurnWorld) => {
  expect(recorded(ctx, "interrupt").map(([threadId]) => threadId)).toEqual([
    childOf("Fix the tests"),
  ]);
  expect(hostState(ctx, "status")).toMatchObject({
    text: "Asked Fix the tests to stop.",
    kind: "info",
  });
});

step("the status says {string}", (ctx: TurnWorld, text: string) => {
  expect(hostState(ctx, "status").text).toBe(text);
});

step("nothing was stopped", (ctx: TurnWorld) => {
  expect(recorded(ctx, "interrupt")).toEqual([]);
});

step("the prompt has the keys and the agents panel stays open", async (ctx: TurnWorld) => {
  await snapshot(ctx);
  expect(hostState(ctx, "mode")).toBe("compose");
  expect(hostState(ctx, "layout").rightPanel).toMatchObject({ kind: "agents", focused: false });
});

step("the agents panel has the keys", (ctx: TurnWorld) => {
  expect(hostState(ctx, "mode")).toBe("agents");
  expect(hostState(ctx, "layout").rightPanel).toMatchObject({ kind: "agents", focused: true });
});

step("the agents panel is closed", async (ctx: TurnWorld) => {
  const screen = await snapshot(ctx);
  expect(hostState(ctx, "layout").rightPanel.visible).toBe(false);
  expect(screen).not.toContain("Review the docs");
});
