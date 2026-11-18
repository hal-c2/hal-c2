// features/tui/agents.feature: the agents panel beside the conversation. The
// open thread ("Delegating") delegated three workers, each with its own
// thread in the thread list; one of those threads waits on an approval.
import { expect } from "bun:test";
import * as DateTime from "effect/DateTime";

import { step } from "../../steps.ts";
import { thread as baseThread } from "../fakeClient.ts";
import { chooseCommand, click } from "../threadUi.ts";
import { hostState, recorded, settle } from "../threadWorld.ts";
import { NOW_MS, sync, turns, type TurnWorld } from "../turnWorld.ts";
import { clickObject, pressKey, resize, snapshot, typeText } from "../world.ts";

const time = (secondsAgo: number) => DateTime.makeUnsafe(new Date(NOW_MS - secondsAgo * 1000));

const PARENT_TITLE = "Delegating";
const WORKERS = [
  { id: "task-tests", title: "Fix the tests", child: "thread-tests" },
  { id: "task-docs", title: "Review the docs", child: "thread-docs" },
  { id: "task-notes", title: "Write notes", child: "thread-notes" },
] as const;

/** The glyph each worker's row starts with, by its state in the Background. */
const GLYPH_OF: Record<string, string> = {
  "Review the docs": "!",
  "Fix the tests": "●",
  "Write notes": "✓",
};

/** What the parent and each worker said, so the conversation on screen tells them apart. */
const PARENT_SAID = "Three workers are on it.";
const workerSaid = (title: string) => `${title}: on my way.`;

/** A message as the MC's projection (`at` a DateTime) or a thread's detail (`at` ISO) holds it. */
const said = (id: string, threadId: string, text: string, at: unknown) => ({
  id,
  threadId,
  runId: null,
  nodeId: null,
  turnId: null,
  role: "assistant",
  text,
  attachments: [],
  streaming: false,
  createdAt: at,
  updatedAt: at,
  createdBy: "agent",
  creationSource: "provider",
});

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
    fixture.messages.push(said("parent-said", "t1", PARENT_SAID, time(60)));
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

/** Move the highlight to `title` with the arrow keys, up or down as it lies. */
const moveTo = async (ctx: TurnWorld, title: string) => {
  for (let step = 0; step < WORKERS.length; step += 1) {
    const rows: ReadonlyArray<{ title: string; selected: boolean }> = hostState(ctx, "agents").rows;
    const at = rows.findIndex((row) => row.selected);
    const target = rows.findIndex((row) => row.title.trim() === title);
    if (target < 0) break;
    if (at === target) return;
    await pressKey(ctx, target > at ? "Down" : "Up");
  }
  throw new Error(`"${title}" is not in the agents panel`);
};

step(
  "the user moves the selection to the worker {string}",
  async (ctx: TurnWorld, title: string) => {
    await moveTo(ctx, title);
    await settle();
  },
);

step(
  "the user selects the worker {string} and presses {string}",
  async (ctx: TurnWorld, title: string, key: string) => {
    await moveTo(ctx, title);
    await pressKey(ctx, key);
    await settle();
  },
);

const showsWorker = async (ctx: TurnWorld, title: string) => {
  // What the worker's own thread holds, as the MC sends it once it is opened.
  const child = childOf(title);
  ctx.fake!.emitThread({
    ...baseThread(),
    id: child,
    title,
    messages: [
      said(`${child}-said`, child, workerSaid(title), new Date(NOW_MS - 60_000).toISOString()),
    ],
  } as never);
  await settle();
  expect(hostState(ctx, "page").threadId).toBe(child);
  expect(hostState(ctx, "mode")).toBe("compose");
  // Its conversation is drawn, not just selected.
  const screen = await snapshot(ctx);
  expect(screen).toContain(workerSaid(title));
  expect(screen).not.toContain(PARENT_SAID);
};

step("the conversation shows the worker's thread", (ctx: TurnWorld) =>
  showsWorker(ctx, "Fix the tests"),
);
step("the conversation shows the thread of {string}", showsWorker);

step("the conversation shows {string}", async (ctx: TurnWorld, title: string) => {
  await settle();
  const selection = ctx
    .fake!.latestShell()
    .threads.find((thread: { title: string }) => thread.title === title);
  expect(hostState(ctx, "page").threadId).toBe(selection!.id);
  // The parent's conversation is the one drawn.
  const screen = await snapshot(ctx);
  expect(screen).toContain(PARENT_SAID);
  for (const worker of WORKERS) expect(screen).not.toContain(workerSaid(worker.title));
});

const clickWorker = async (ctx: TurnWorld, title: string) => {
  // The worker's threads are listed in the sidebar too: the panel's row is the one
  // to the right of the border it draws ("│ ! Review the docs").
  const lines = (await snapshot(ctx)).split("\n");
  const y = lines.findIndex((line) => line.includes(`│ ${GLYPH_OF[title]} ${title}`));
  expect(y, `"${title}" is not drawn in the agents panel`).toBeGreaterThanOrEqual(0);
  const line = lines[y]!;
  await click(ctx, { x: Bun.stringWidth(line.slice(0, line.lastIndexOf(title))), y });
  await settle();
};

step("the user clicks the worker {string}", clickWorker);
step("the user clicked the worker {string}", clickWorker);

step("the agents panel selects the worker {string}", (ctx: TurnWorld, title: string) => {
  const selected = hostState(ctx, "agents").rows.filter(
    (row: { selected: boolean }) => row.selected,
  );
  expect(selected.map((row: { title: string }) => row.title.trim())).toEqual([title]);
});

step("the user clicks the prompt", async (ctx: TurnWorld) => {
  await clickObject(ctx, "composerEditorRow");
  await settle();
});

step("the thread list is filtered to {string}", async (ctx: TurnWorld, query: string) => {
  await pressKey(ctx, "Ctrl+F");
  await typeText(ctx, query);
  await pressKey(ctx, "Enter");
  await settle();
  expect(hostState(ctx, "mode")).toBe("compose");
  expect(hostState(ctx, "sidebar").filter).toBe(query);
});

step(
  "the thread list is no longer filtered and the worker's thread stays selected",
  async (ctx: TurnWorld) => {
    // The next shell update rebuilds the list: the opened worker is still in it.
    ctx.fake!.emitShell(ctx.fake!.latestShell());
    await settle();
    const sidebar = await snapshot(ctx);
    expect(hostState(ctx, "sidebar").filter).toBe("");
    expect(sidebar).toContain("Fix the tests");
    expect(hostState(ctx, "page").threadId).toBe(childOf("Fix the tests"));
  },
);

step("the user browses the open thread's files", async (ctx: TurnWorld) => {
  await chooseCommand(ctx, "Browse files");
  await settle();
  expect(hostState(ctx, "files").open).toBe(true);
});

step("the file browser is closed", async (ctx: TurnWorld) => {
  await snapshot(ctx);
  expect(hostState(ctx, "files").open).toBe(false);
  expect(hostState(ctx, "layout").rightPanel).toMatchObject({ kind: "agents", visible: true });
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

step("the worker {string} has no run to interrupt", (ctx: TurnWorld, title: string) => {
  const child = childOf(title);
  ctx.fake!.override("interruptibleRun", async (threadId) =>
    threadId === child ? null : `run-${threadId}`,
  );
});

step(
  "reading the run of {string} waits",
  (ctx: TurnWorld & { readRun?: () => void }, title: string) => {
    const child = childOf(title);
    ctx.fake!.override("interruptibleRun", (threadId) =>
      threadId === child
        ? new Promise<string>((resolve) => {
            ctx.readRun = () => resolve(`run-${threadId}`);
          })
        : Promise.resolve(`run-${threadId}`),
    );
  },
);

step(
  "the run of {string} is read",
  async (ctx: TurnWorld & { readRun?: () => void }, _title: string) => {
    expect(ctx.readRun, "nothing is reading the run").toBeDefined();
    ctx.readRun!();
    await settle();
    await settle();
  },
);

step("no question is asked", async (ctx: TurnWorld) => {
  expect(hostState(ctx, "select").open).toBe(false);
  expect(await snapshot(ctx)).not.toContain("Stop Fix the tests?");
  expect(hostState(ctx, "mode")).toBe("compose");
});

step("the worker {string} starts another run", (ctx: TurnWorld, title: string) => {
  const child = childOf(title);
  ctx.fake!.override("interruptibleRun", async (threadId) =>
    threadId === child ? `run-${threadId}-next` : `run-${threadId}`,
  );
});

step("the client requests an interrupt of the run the user was asked about", (ctx: TurnWorld) => {
  // The run read when the user was asked, not whichever is active when they answer.
  expect(recorded(ctx, "interrupt")).toEqual([
    [childOf("Fix the tests"), `run-${childOf("Fix the tests")}`],
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
  expect(hostState(ctx, "layout").rightPanel).toMatchObject({
    kind: "agents",
    visible: true,
    focused: false,
  });
  // The hint follows the keys: the panel no longer offers Enter.
  expect(await snapshot(ctx)).toContain("^X a focus");
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
