// mc/orchestration/*.feature and providers/{capabilities,claude,codex}.feature as the
// terminal client shows them: the thread is the projection the MC sends (turnWorld.ts),
// and the steps read what the timeline, the header and the composer make of it.
import { expect } from "bun:test";
import * as DateTime from "effect/DateTime";

import type { TuiComposerState } from "../../../src/host/composerState.ts";
import { step } from "../../steps.ts";
import { objectRows } from "../design.ts";
import { PROVIDERS, thread as baseThread } from "../fakeClient.ts";
import {
  clickText,
  hostState,
  openThread,
  plain,
  recorded,
  settle,
  type ThreadWorld,
} from "../threadWorld.ts";
import {
  addItem,
  itemsOf,
  lastOf,
  linesOf,
  messageItem,
  NOW_MS,
  setItem,
  setThread,
  shownItems,
  startRun,
  sync,
  turns,
  type TurnWorld,
} from "../turnWorld.ts";
import { pressKey, snapshot, typeText, type World } from "../world.ts";
import { chooseInPicker } from "./controls.steps.ts";

const time = (ms: number) => DateTime.makeUnsafe(new Date(ms));
const composer = (ctx: World) => ctx.host!.state.get("composer") as TuiComposerState;
const workLines = (ctx: ThreadWorld) => itemsOf(ctx, "work").flatMap(linesOf);
const userMessages = (ctx: ThreadWorld) =>
  shownItems(ctx).filter((item) => item.kind === "message" && item.align === "right");
const settleHost = async (ctx: World) => {
  await ctx.host!.settled();
  await settle();
};

// --- Backgrounds -------------------------------------------------------------------------

step(
  "an MC with a project {string} rooted at a git repository",
  (ctx: ThreadWorld, project: string) => {
    ctx.projectTitle = project;
  },
);

step("thread {string} exists in {string}", async (ctx: TurnWorld) => {
  await turns(ctx);
});

step("thread {string} exists in {string} with provider {string}", async (ctx: TurnWorld) => {
  await turns(ctx);
  expect(String(ctx.thread!.modelSelection.instanceId)).toBe("codex");
});

// Codex with two models, so the thread can change model and stay on its provider.
const TWO_MODELS = [
  {
    ...PROVIDERS[0]!,
    models: ["gpt-a", "gpt-b"].map((slug) => ({
      slug,
      name: slug.toUpperCase(),
      isCustom: false,
      capabilities: null,
    })),
  },
] as never;

step(
  "thread {string} has completed runs on {string} with model {string}",
  async (ctx: TurnWorld, _thread: string, instanceId: string, model: string) => {
    const modelSelection = { instanceId, model };
    await openThread(ctx, { ...baseThread(), modelSelection } as never, { providers: TWO_MODELS });
    await startRun(ctx, 120);
    await addItem(ctx, "assistant_message", { id: "answer-1", text: "Tax is added." });
    await endRun(ctx, 0, "completed", 30);
    expect(composer(ctx).selectedModel).toBe(model);
  },
);

/** End the run at `index` (the helper in turnWorld ends the newest, which may be queued). */
async function endRun(ctx: TurnWorld, index: number, status: string, afterSeconds: number) {
  const fixture = await turns(ctx);
  const run = fixture.runs[index]!;
  const began = DateTime.toEpochMillis((run.startedAt ?? run.requestedAt) as DateTime.Utc);
  run.status = status;
  run.completedAt = time(began + afterSeconds * 1000);
  await sync(ctx);
}

// --- A failed turn keeps what it produced ---------------------------------------------------

const PARTIAL = "Half an ans";

step(
  "the provider streamed part of its answer to {string} and then failed",
  async (ctx: TurnWorld) => {
    await startRun(ctx, 20);
    await addItem(ctx, "assistant_message", {
      id: "msg-partial",
      text: PARTIAL,
      streaming: true,
      status: "running",
    });
    expect(linesOf(messageItem(ctx, "msg-partial"))).toContain(PARTIAL);
    expect(hostState(ctx, "timeline").working).not.toBeNull();
  },
);

// The MC closes the message where it stopped and fails the run, naming why.
step("the failure is recorded", async (ctx: TurnWorld) => {
  await setItem(ctx, "msg-partial", { streaming: false, status: "failed" });
  await addItem(ctx, "error", {
    id: "failure",
    status: "failed",
    failure: {
      class: "provider_error",
      message: "The model stopped responding.",
      code: null,
      retryable: false,
    },
  });
  await endRun(ctx, 0, "failed", 12);
});

step("the partial answer stays in the failed run", async (ctx: TurnWorld) => {
  expect(linesOf(messageItem(ctx, "msg-partial"))).toContain(PARTIAL);
  expect(await snapshot(ctx)).toContain(PARTIAL);
  expect(ctx.thread!.messages.find((message) => message.id === "msg-partial")).toMatchObject({
    text: PARTIAL,
    streaming: false,
    turnId: "run-1",
  });
});

step("the run is marked failed", async (ctx: TurnWorld) => {
  expect(ctx.thread!.latestTurn).toMatchObject({ turnId: "run-1", state: "error" });
  expect(ctx.thread!.session).toMatchObject({ status: "error" });
  // Nothing is still running, and the reason is in the work log.
  expect(hostState(ctx, "timeline").working).toBeNull();
  expect(workLines(ctx).join("\n")).toContain("The model stopped responding.");
  const screen = await snapshot(ctx);
  expect(screen).toContain("The model stopped responding.");
  expect(screen).not.toContain("● Working…");
});

// --- A provider retry -----------------------------------------------------------------------

const RETRY = {
  id: "retry",
  status: "running",
  title: "Provider retry",
  failure: {
    class: "transport_error",
    code: "responseStreamDisconnected",
    message: "stream disconnected before completion",
    retryable: true,
  },
};

step("the provider retries a failed request during a turn of {string}", async (ctx: TurnWorld) => {
  await startRun(ctx, 10);
  await addItem(ctx, "error", {
    ...RETRY,
    retry: { attempt: 1, maxAttempts: 5, retryDelayMs: null },
  });
});

// Each attempt updates the one item of the running run.
step("the retry is recorded", async (ctx: TurnWorld) => {
  await setItem(ctx, "retry", { retry: { attempt: 2, maxAttempts: 5, retryDelayMs: null } });
});

step("the turn's work log shows a provider retry", async (ctx: TurnWorld) => {
  const rows = workLines(ctx).filter((line) => line.includes("Provider retry"));
  expect(rows).toHaveLength(1);
  expect(rows[0]).toContain("⟳ Running  attempt 2 of 5 · stream disc");
  expect(ctx.thread!.activities.find((entry) => entry.id === "retry")!.payload).toMatchObject({
    detail: "attempt 2 of 5 · stream disconnected before completion",
  });
  expect(await snapshot(ctx)).toContain("Provider retry");
  // A retry is not the turn's failure: it is still running.
  expect(ctx.thread!.latestTurn).toMatchObject({ turnId: "run-1", state: "running" });
  expect(hostState(ctx, "timeline").working).not.toBeNull();
  const activity = ctx.thread!.activities.find((entry) => entry.id === "retry")!;
  expect(activity.tone).toBe("tool");
});

step("no second user turn is created", async (ctx: TurnWorld) => {
  expect(userMessages(ctx)).toHaveLength(1);
  expect(ctx.thread!.messages.filter((message) => message.role === "user")).toHaveLength(1);
  expect(recorded(ctx, "sendReply")).toEqual([]);
});

// --- Context occupancy across a model change --------------------------------------------------

const meter = (ctx: World) => plain(hostState(ctx, "timeline").context);

async function reportUsage(ctx: TurnWorld, usedTokens: number) {
  const fixture = await turns(ctx);
  fixture.thread = { ...fixture.thread, activeProviderThreadId: "provider-thread-1" };
  fixture.providerThreads = [
    {
      id: "provider-thread-1",
      driver: "codex",
      providerInstanceId: "codex",
      providerSessionId: null,
      nativeThreadRef: null,
      status: "idle",
      contextUsage: { usedTokens, maxTokens: 200_000 },
      createdAt: time(NOW_MS - 3_600_000),
      updatedAt: time(NOW_MS),
    },
  ];
  await sync(ctx);
}

step(
  "{string} has used {int} percent of its provider context",
  async (ctx: TurnWorld, _thread: string, percent: number) => {
    await reportUsage(ctx, 2_000 * percent);
    expect(meter(ctx)).toBe(`context  ▓▓▓▓▓▓░░ ${percent}% · 160k/200k`);
    expect(await snapshot(ctx)).toContain(`${percent}% · 160k/200k`);
  },
);

step("the user changes {string} to another model on the same provider", async (ctx: TurnWorld) => {
  ctx.host!.dispatch("composer.modelPicker.toggle");
  await chooseInPicker(ctx, "GPT-B");
  expect(composer(ctx).selectedModel).toBe("gpt-b");
  // The change alone moves nothing on the provider's thread.
  expect(meter(ctx)).toContain("80% · 160k/200k");
});

step(
  "the next run reports the context occupancy from before the change",
  async (ctx: TurnWorld) => {
    // The MC starts the run on the new model, on the provider thread the old one used.
    ctx.fake!.override("sendReply", async (_thread, _text, _images, model) => {
      await setThread(ctx, { modelSelection: model });
      await startRun(ctx);
    });
    await typeText(ctx, "Now round the totals");
    await pressKey(ctx, "Enter");
    await settleHost(ctx);
    expect(recorded(ctx, "sendReply").at(-1)![3]).toMatchObject({
      instanceId: "codex",
      model: "gpt-b",
    });
    expect(ctx.thread!.latestTurn).toMatchObject({ turnId: "run-2", state: "running" });
    expect(ctx.thread!.modelSelection.model).toBe("gpt-b");
    expect(meter(ctx)).toBe("context  ▓▓▓▓▓▓░░ 80% · 160k/200k");
    expect(await snapshot(ctx)).toContain("80% · 160k/200k");
  },
);

step(
  "the meter does not reset to zero until the provider reports new usage",
  async (ctx: TurnWorld) => {
    // Work arrives on the new model; the meter stays where the provider last put it.
    await addItem(ctx, "command_execution", { input: "bun test", output: "ok", exitCode: 0 });
    expect(meter(ctx)).toContain("80% · 160k/200k");
    await reportUsage(ctx, 1_000);
    expect(meter(ctx)).toBe("context  ░░░░░░░░ 1% · 1k/200k");
    expect(await snapshot(ctx)).toContain("1% · 1k/200k");
  },
);

// --- A usage limit holds the queue ------------------------------------------------------------

async function queueMessage(ctx: TurnWorld, text: string, position: number) {
  await startRun(ctx, 0, "queued");
  const fixture = await turns(ctx);
  fixture.runs.at(-1)!.queuePosition = position;
  fixture.messages.at(-1)!.text = text;
  await sync(ctx);
}

const queuedLines = (ctx: ThreadWorld) =>
  userMessages(ctx)
    .map(linesOf)
    .filter((lines) => lines[0]!.startsWith("⏸ queued"));

step(
  "{string} has a running turn and queued messages {string} and {string}",
  async (ctx: TurnWorld, _thread: string, first: string, second: string) => {
    await startRun(ctx, 30);
    await addItem(ctx, "command_execution", { input: "bun test", output: "ok", exitCode: 0 });
    await queueMessage(ctx, first, 1);
    await queueMessage(ctx, second, 2);
    expect(queuedLines(ctx)).toEqual([
      ["⏸ queued · 1", first],
      ["⏸ queued · 2", second],
    ]);
    // The turn at work is the one that began, not a message waiting behind it.
    expect(ctx.thread!.latestTurn).toMatchObject({ turnId: "run-1", state: "running" });
  },
);

// As the MC records it: the error naming the limit, the failed run, the queue held.
step("the provider stops {string} because its usage limit was reached", async (ctx: TurnWorld) => {
  const fixture = await turns(ctx);
  fixture.created += 1;
  fixture.items.push({
    id: "limit",
    threadId: ctx.thread!.id,
    runId: "run-1",
    nodeId: null,
    providerThreadId: null,
    providerTurnId: null,
    nativeItemRef: null,
    parentItemId: null,
    ordinal: fixture.items.length,
    status: "failed",
    title: null,
    startedAt: time(NOW_MS),
    completedAt: time(NOW_MS),
    updatedAt: time(NOW_MS),
    type: "error",
    failure: {
      class: "usage_limit",
      message: "You've hit your usage limit.",
      code: "usageLimitExceeded",
      retryable: false,
    },
  });
  for (const run of fixture.runs.slice(1)) run.queueHeld = true;
  await endRun(ctx, 0, "failed", 30);
});

step(
  "{string} and {string} stay queued in their original order",
  async (ctx: TurnWorld, first: string, second: string) => {
    expect(queuedLines(ctx)).toEqual([
      ["⏸ queued · 1 · held", first],
      ["⏸ queued · 2 · held", second],
    ]);
    const screen = await snapshot(ctx);
    expect(screen).toContain("⏸ queued · 1 · held");
    expect(screen.indexOf("⏸ queued · 1 · held")).toBeLessThan(
      screen.indexOf("⏸ queued · 2 · held"),
    );
    expect(screen).toContain("You've hit your usage limit.");
  },
);

step("neither is discarded or sent early", async (ctx: TurnWorld) => {
  // The failed turn is the latest one; nothing runs and nothing was sent from here.
  expect(ctx.thread!.latestTurn).toMatchObject({ turnId: "run-1", state: "error" });
  expect(hostState(ctx, "timeline").working).toBeNull();
  expect(await snapshot(ctx)).not.toContain("● Working…");
  expect(recorded(ctx, "sendReply")).toEqual([]);
  expect(ctx.thread!.messages.filter((message) => message.role === "user")).toHaveLength(3);
});

// --- An ACP subagent's own thread ----------------------------------------------------------------

const CHILD = { id: "thread-child", title: "Survey the modules" };
const TASK = "List the modules in lib";
const CHILD_SAID = "Reading lib/a.ex. Summary: lib has three modules";
const RESULT = "lib has three modules";

// Grok's `task` tool: the child works in a session of its own.
step("an ACP agent starts a native child session", async (ctx: TurnWorld) => {
  await turns(ctx);
  const current = ctx.fake!.latestShell();
  const parent = current.threads[0]!;
  ctx.fake!.emitShell({
    ...current,
    threads: [
      ...current.threads,
      {
        ...parent,
        ...CHILD,
        lineage: {
          rootThreadId: parent.id,
          parentThreadId: parent.id,
          relationshipToParent: "subagent",
        },
      },
    ],
  } as never);
  await startRun(ctx);
  await addItem(ctx, "subagent", {
    id: "task",
    subagentId: "task-1",
    origin: "provider_native",
    driver: "grok",
    providerInstanceId: "grok",
    childThreadId: CHILD.id,
    title: CHILD.title,
    prompt: TASK,
    result: null,
    status: "running",
  });
});

// The child's messages land in its thread; the parent's tool call ends with the result.
step("the child sends messages and a final summary", async (ctx: TurnWorld) => {
  ctx.fake!.emitThread({
    ...baseThread(),
    ...CHILD,
    messages: [
      { id: "child-task", role: "user", text: TASK, streaming: false, turnId: "child-run" },
      {
        id: "child-said",
        role: "assistant",
        text: CHILD_SAID,
        streaming: false,
        turnId: "child-run",
      },
    ].map((message) => ({
      ...message,
      createdAt: new Date(NOW_MS).toISOString(),
      updatedAt: new Date(NOW_MS).toISOString(),
    })),
  } as never);
  await setItem(ctx, "task", { status: "completed", result: RESULT });
  await addItem(ctx, "assistant_message", { id: "parent-said", text: "The survey is done." });
});

step("they appear in the child's thread", async (ctx: TurnWorld) => {
  await clickText(ctx, CHILD.title);
  await settleHost(ctx);
  expect(hostState(ctx, "page").threadId).toBe(CHILD.id);
  const shown = shownItems(ctx).flatMap(linesOf).join("\n");
  expect(shown).toContain(TASK);
  expect(shown).toContain(CHILD_SAID);
  expect(await snapshot(ctx)).toContain("Summary: lib has three modules");
  // It says whose subagent it is.
  expect(linesOf(shownItems(ctx)[0]!)).toEqual(["↳ Subagent of Thread one"]);
});

step("the parent receives only the child's result", async (ctx: TurnWorld) => {
  await clickText(ctx, "Subagent of Thread one");
  await settleHost(ctx);
  expect(hostState(ctx, "page").threadId).toBe("t1");
  const shown = shownItems(ctx).flatMap(linesOf).join("\n");
  expect(shown).toContain(RESULT);
  expect(shown).toContain("The survey is done.");
  expect(shown).not.toContain("Reading lib/a.ex");
  expect(await snapshot(ctx)).not.toContain("Reading lib/a.ex");
});

// --- An ACP edit ------------------------------------------------------------------------------------

// The agent named the text it replaced and the text it wrote, and sent no patch.
const OLD = "  return subtotal;";
const NEW = "  const tax = subtotal * rate;\n  return subtotal + tax;";

step(
  "an ACP agent edits a file by giving the old text and the new text",
  async (ctx: TurnWorld) => {
    await startRun(ctx);
    await addItem(ctx, "file_change", {
      id: "edit",
      fileName: "src/cart.ts",
      diffStr: "",
      oldStr: OLD,
      newStr: NEW,
      status: "completed",
    });
    await endRun(ctx, 0, "completed", 5);
  },
);

step("the user looks at the change", async (ctx: TurnWorld) => {
  // Finished work folds behind its turn: open it, then the change's row opens its diff.
  const fold = itemsOf(ctx, "fold").at(-1)!;
  await clickText(ctx, linesOf(fold)[0]!.slice(2));
  await settleHost(ctx);
  const row = workLines(ctx).find((line) => line.includes("src/cart.ts"))!;
  expect(row).toContain("+2 -1");
  await clickText(ctx, "Changed src/cart.ts");
  await settleHost(ctx);
  expect(ctx.host!.state.get("mode")).toBe("diff");
});

const diffState = (ctx: World) =>
  ctx.host!.state.get("diff") as {
    open: boolean;
    title: string;
    status: string;
    files: Array<{ path: string; body: string }>;
  };

step("the diff shows the replaced lines", async (ctx: TurnWorld) => {
  expect(diffState(ctx)).toMatchObject({
    open: true,
    status: "ready",
    title: "diff · src/cart.ts",
  });
  expect(diffState(ctx).files.map((file) => file.path)).toEqual(["src/cart.ts"]);
  const rows = (await objectRows(ctx, "diffViewer")).join("\n");
  expect(rows).toContain("return subtotal;");
  expect(rows).toContain("const tax = subtotal * rate;");
  expect(rows).toContain("return subtotal + tax;");
});

step("the diff is not empty just because the agent sent no patch", (ctx: TurnWorld) => {
  // No patch came with the item: the lines are the old text removed and the new text added.
  expect(diffState(ctx).files[0]!.body.split("\n").slice(2)).toEqual([
    "@@ -1,1 +1,2 @@",
    "-  return subtotal;",
    "+  const tax = subtotal * rate;",
    "+  return subtotal + tax;",
  ]);
});

// --- A Claude monitor --------------------------------------------------------------------------------

step("Claude starts a monitor in the thread", async (ctx: TurnWorld) => {
  await startRun(ctx, 60);
  await addItem(ctx, "assistant_message", { id: "said", text: "Watching the dev server log." });
  const fixture = await turns(ctx);
  fixture.thread = { ...fixture.thread, activeProviderThreadId: "provider-thread-1" };
  fixture.providerThreads = [
    {
      id: "provider-thread-1",
      driver: "claude",
      providerInstanceId: "claude",
      providerSessionId: null,
      nativeThreadRef: null,
      status: "idle",
      // The SDK's roster of what still runs once the turn is over.
      pendingBackgroundTasks: [
        { taskId: "monitor-1", description: "tail -f log/dev.log", taskType: "monitor" },
      ],
      createdAt: time(NOW_MS - 3_600_000),
      updatedAt: time(NOW_MS),
    },
  ];
  await endRun(ctx, 0, "completed", 20);
});

step("the thread lists the monitor as background work", async (ctx: TurnWorld) => {
  expect(linesOf(lastOf(ctx, "background"))).toEqual([
    "◌ Background work · 1 running",
    "  monitor · tail -f log/dev.log",
  ]);
  const screen = await snapshot(ctx);
  expect(screen).toContain("Background work · 1 running");
  expect(screen).toContain("monitor · tail -f log/dev.log");
});

step("the monitor is not shown as a command", (ctx: TurnWorld) => {
  expect(workLines(ctx).join("\n")).not.toContain("tail -f log/dev.log");
  expect(ctx.thread!.activities.map((entry) => entry.summary)).not.toContain("Ran command");
});

// --- A plan Codex marked finished ----------------------------------------------------------------------

const PLAN = "# Add a tax line\n\n1. Read the rate\n2. Add the line";

// Codex ends its plan item when it has finished writing it; the plan itself stays open
// until a run is started from it.
step("Codex proposed a plan and marked it finished", async (ctx: TurnWorld) => {
  await setThread(ctx, { interactionMode: "plan" });
  await startRun(ctx, 60);
  await addItem(ctx, "proposed_plan", {
    planId: "plan-tax",
    markdown: PLAN,
    status: "completed",
    streaming: false,
  });
  await endRun(ctx, 0, "completed", 30);
});

step("the plan is offered for implementation", async (ctx: TurnWorld) => {
  const card = hostState(ctx, "timeline").plan;
  expect(card).not.toBeNull();
  expect(plain(card.title)).toBe("◆ Add a tax line");
  expect(hostState(ctx, "threadHints").items).toContain("^Y implement");
  expect(await snapshot(ctx)).toContain("◆ Add a tax line");
});

step("the user implements the plan", async (ctx: TurnWorld) => {
  // The MC leaves plan mode and starts a turn that carries the plan out.
  ctx.respond!.implementPlan = async (_thread, planId) => {
    const fixture = await turns(ctx);
    fixture.plans.find((entry) => entry.id === planId)!.status = "completed";
    fixture.thread = { ...fixture.thread, interactionMode: "default" };
    await startRun(ctx);
    fixture.runs.at(-1)!.sourcePlanRef = { threadId: ctx.thread!.id, planId };
    await sync(ctx);
  };
  await pressKey(ctx, "Ctrl+Y");
  await settleHost(ctx);
});

step("a new run starts from that plan", async (ctx: TurnWorld) => {
  expect(
    (recorded(ctx, "implementPlan") as Array<[{ id: string }, string]>).map(([, id]) => id),
  ).toEqual(["plan-tax"]);
  expect(ctx.thread!.latestTurn).toMatchObject({
    turnId: "run-2",
    state: "running",
    sourceProposedPlan: { threadId: "t1", planId: "plan-tax" },
  });
  expect(hostState(ctx, "timeline").plan).toBeNull();
  expect(await snapshot(ctx)).toContain("● Working…");
});
