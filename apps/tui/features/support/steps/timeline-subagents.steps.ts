// features/timeline/plans-and-subagents.feature: moving between a subagent's
// thread and its parent, and a message another agent sent. The subagent's
// thread is in the thread list with its lineage, as the MC lists it.
import { expect } from "bun:test";

import { step } from "../../steps.ts";
import { thread as baseThread } from "../fakeClient.ts";
import * as DateTime from "effect/DateTime";

import { findObject, pressKey, snapshot } from "../world.ts";
import { clickText, hostState, plain, recorded, settle } from "../threadWorld.ts";
import {
  addItem,
  lastOf,
  linesOf,
  NOW_MS,
  setItem,
  setRequest,
  settleRun,
  shownItems,
  startRun,
  sync,
  turns,
  type TurnWorld,
} from "../turnWorld.ts";

const time = (ms: number) => DateTime.makeUnsafe(new Date(ms));

const CHILD = { id: "thread-child", title: "Tax tests" };

/** The MC lists the subagent's thread under its parent. */
async function listChildThread(ctx: TurnWorld) {
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
  // What the subagent's own thread holds, for when it is opened.
  ctx.fake!.emitThread({ ...baseThread(), ...CHILD } as never);
  await settle();
}

const openThreadId = (ctx: TurnWorld) => hostState(ctx, "page").threadId as string;

// --- a subagent and its parent ---------------------------------------------------------

step("the agent has a subagent", async (ctx: TurnWorld) => {
  await listChildThread(ctx);
  await startRun(ctx);
  await addItem(ctx, "subagent", {
    subagentId: "task-1",
    origin: "app_owned",
    driver: "codex",
    providerInstanceId: "codex",
    childThreadId: CHILD.id,
    title: CHILD.title,
    prompt: "write the tax tests",
    result: null,
    status: "running",
  });
});

step("the user opens the subagent's thread", async (ctx: TurnWorld) => {
  await clickText(ctx, CHILD.title);
  await settle();
  expect(openThreadId(ctx)).toBe(CHILD.id);
});

step("the thread says it is a subagent of the parent", async (ctx: TurnWorld) => {
  const [first] = shownItems(ctx);
  expect(first).toMatchObject({ kind: "lineage" });
  expect(linesOf(first!)).toEqual(["↳ Subagent of Thread one"]);
  expect(await snapshot(ctx)).toContain("↳ Subagent of Thread one");
});

step("the user opens the parent thread", async (ctx: TurnWorld) => {
  await clickText(ctx, "Subagent of Thread one");
  await settle();
});

step("the parent thread is shown", async (ctx: TurnWorld) => {
  expect(openThreadId(ctx)).toBe("t1");
  expect(hostState(ctx, "page").title).toBe("Thread one");
  // The parent's timeline is back, with the subagent's row and no lineage line.
  expect(shownItems(ctx).some((item) => item.kind === "lineage")).toBe(false);
  expect(await snapshot(ctx)).toContain("write the tax tests");
});

// --- a message from another agent ------------------------------------------------------

step("a subagent sent a message to its parent", async (ctx: TurnWorld) => {
  await listChildThread(ctx);
  await startRun(ctx);
  // The MC records the sending thread on the message (createdBy "agent", senderThreadId).
  const fixture = await turns(ctx);
  Object.assign(fixture.messages.at(-1)!, {
    text: "12 tests added",
    createdBy: "agent",
    senderThreadId: CHILD.id,
  });
  await sync(ctx);
});

step("the user reads the message in the parent thread", async (ctx: TurnWorld) => {
  expect(openThreadId(ctx)).toBe("t1");
  expect(await snapshot(ctx)).toContain("12 tests added");
});

step("it says which thread it came from", async (ctx: TurnWorld) => {
  const bubble = shownItems(ctx).find((item) => item.kind === "message")!;
  expect(linesOf(bubble)).toEqual([`↩ from ${CHILD.title}`, "12 tests added"]);
  expect(plain(bubble.lines[0]!.text)).toBe(`↩ from ${CHILD.title}`);
  expect(await snapshot(ctx)).toContain(`↩ from ${CHILD.title}`);
});

step("the user can open that thread", async (ctx: TurnWorld) => {
  await clickText(ctx, `↩ from ${CHILD.title}`);
  await settle();
  expect(openThreadId(ctx)).toBe(CHILD.id);
  expect(hostState(ctx, "page").title).toBe(CHILD.title);
});

// --- what the MC sent the agent for itself ---------------------------------------------

/** A run the MC started for the agent: its message carries the notification its item shows. */
async function startNotifiedRun(ctx: TurnWorld, text: string, notification: object) {
  const run = await startRun(ctx);
  const fixture = await turns(ctx);
  Object.assign(fixture.messages.at(-1)!, { text, notification });
  await addItem(ctx, "notification", { id: `turn-item:user:message:${run}`, ...notification });
}

step("a task the agent delegated as {string} finished", async (ctx: TurnWorld, title: string) => {
  await listChildThread(ctx);
  // delegation.ex: the agent reads the envelope, the timeline the notification.
  await startNotifiedRun(
    ctx,
    `<delegated_task_result taskId="task-1" title="${title}" status="completed" childThreadId="${CHILD.id}">\n12 tests added\n</delegated_task_result>`,
    {
      source: { kind: "delegated_task", taskIds: ["task-1"] },
      outcome: "completed",
      summary: `${title} finished`,
    },
  );
  const fixture = await turns(ctx);
  Object.assign(fixture.messages.at(-1)!, {
    createdBy: "system",
    creationSource: "server",
    delegatedCompletion: { taskId: "task-1", status: "completed" },
  });
  await sync(ctx);
});

step(
  "a task the agent delegated as {string} finished with {string}",
  async (ctx: TurnWorld, title: string, result: string) => {
    await listChildThread(ctx);
    // delegation.ex: the notification names the worker and carries its result.
    await startNotifiedRun(
      ctx,
      `<delegated_task_result taskId="task-1">\n${result}\n</delegated_task_result>`,
      {
        source: { kind: "delegated_task", taskIds: ["task-1"] },
        outcome: "completed",
        summary: `${title} finished`,
        workerThreadId: CHILD.id,
        workerTitle: title,
        detail: result,
      },
    );
  },
);

step("the worker's notification reads {string}", async (ctx: TurnWorld, text: string) => {
  expect(
    shownItems(ctx)
      .flatMap(linesOf)
      .some((line) => line.includes(text)),
  ).toBe(true);
  expect(await snapshot(ctx)).toContain(text);
});

step("the notification links to the worker's thread", async (ctx: TurnWorld) => {
  await clickText(ctx, `${CHILD.title} finished`);
  await settle();
  expect(openThreadId(ctx)).toBe(CHILD.id);
});

step("the worker's notification previews {string}", async (ctx: TurnWorld, text: string) => {
  expect(
    shownItems(ctx)
      .flatMap(linesOf)
      .some((line) => line.includes(`${CHILD.title} finished`) && line.includes(text)),
  ).toBe(true);
});

step("the agent's background work woke it up", async (ctx: TurnWorld) => {
  // claude/thread_runtime.ex wake.
  await startNotifiedRun(ctx, "Background task completed.", {
    source: { kind: "background_task" },
    outcome: "updated",
    summary: "Background activity updated",
  });
  const fixture = await turns(ctx);
  Object.assign(fixture.messages.at(-1)!, { createdBy: "agent", creationSource: "provider" });
  await sync(ctx);
});

step(
  "a pull request the thread owns woke its agent because its checks failed",
  async (ctx: TurnWorld) => {
    // pull_requests/wakes.ex wake.
    await startNotifiedRun(ctx, "Pull request acme/app#12 needs your attention.", {
      source: { kind: "pull_request", pullRequests: ["github.com/acme/app#12"] },
      outcome: "failed",
      summary: "acme/app#12: checks failing",
    });
    const fixture = await turns(ctx);
    Object.assign(fixture.messages.at(-1)!, { createdBy: "system", creationSource: "server" });
    await sync(ctx);
  },
);

// --- what a thread stored as a user message --------------------------------------------

/** A run whose user message is all a thread kept: no notification, no older marks. */
async function startStoredRun(ctx: TurnWorld, text: string, fields: Record<string, unknown>) {
  await startRun(ctx);
  const fixture = await turns(ctx);
  Object.assign(fixture.messages.at(-1)!, { text, ...fields });
  await sync(ctx);
}

step(
  "a thread stored the failed result of the delegated task {string} as a user message",
  async (ctx: TurnWorld, title: string) => {
    await listChildThread(ctx);
    await startStoredRun(
      ctx,
      `<delegated_task_result taskId="task-1" title="${title}" status="failed" childThreadId="${CHILD.id}">\nThe tax tests do not compile\n</delegated_task_result>`,
      { createdBy: "system", creationSource: "server" },
    );
  },
);

step("a thread stored the agent's own wake-up as a user message", async (ctx: TurnWorld) => {
  await startStoredRun(ctx, "Background task completed.", {
    createdBy: "agent",
    creationSource: "provider",
  });
});

// --- a subagent's latest word ----------------------------------------------------------

/** The subagent's row, opening the work group it sits in when that is closed. */
async function subagentRow(ctx: TurnWorld) {
  const find = () =>
    lastOf(ctx, "work")
      .lines.map((line) => plain(line.text))
      .find((line) => line.includes(CHILD.title));
  if (find()) return find();
  const summary = linesOf(lastOf(ctx, "work"))[0]!;
  if (summary.startsWith("▸ ")) await clickText(ctx, summary.slice(2));
  else if (linesOf(lastOf(ctx, "work")).some((line) => line.includes("previous tool call")))
    await clickText(ctx, "previous tool call");
  return find();
}

const SUBAGENT = {
  subagentId: "task-1",
  origin: "app_owned",
  driver: "codex",
  providerInstanceId: "codex",
  childThreadId: CHILD.id,
  title: CHILD.title,
  prompt: "write the tax tests",
};

step(
  "a subagent that reported {string} and then finished with {string}",
  async (ctx: TurnWorld, progress: string, result: string) => {
    await startRun(ctx);
    await addItem(ctx, "subagent", { ...SUBAGENT, status: "completed", progress, result });
  },
);

step(
  "a subagent that is still working after reporting {string}",
  async (ctx: TurnWorld, progress: string) => {
    await startRun(ctx);
    await addItem(ctx, "subagent", { ...SUBAGENT, status: "running", progress, result: null });
  },
);

step("the subagent's row reads {string}", async (ctx: TurnWorld, text: string) => {
  const row = await subagentRow(ctx);
  if (!row) throw new Error("the timeline shows no subagent");
  // The row's detail is the subagent's latest word, and nothing older.
  expect(row).toEndWith(text);
  expect(row).not.toContain(text === "12 tests added" ? "Reading the tax code" : "12 tests added");
  expect(await snapshot(ctx)).toContain(text);
});

// --- a subagent's work in the parent ---------------------------------------------------

step(
  "a subagent returned its result while background work it started is still running",
  async (ctx: TurnWorld) => {
    await startRun(ctx, 60);
    await addItem(ctx, "subagent", {
      ...SUBAGENT,
      status: "completed",
      result: "Dev server started",
    });
    await settleRun(ctx, "completed", 30);
    // The command the subagent started outlives the turn.
    await addItem(ctx, "command_execution", {
      id: "call-dev",
      status: "running",
      input: "npm run dev",
      output: "",
    });
  },
);

step("the user looks at the parent thread", async (ctx: TurnWorld) => {
  expect(openThreadId(ctx)).toBe("t1");
  // The settled turn folds its work behind how long it took; the user opens it.
  const fold = shownItems(ctx).findLast((item) => item.kind === "fold");
  const label = fold ? linesOf(fold)[0]! : "";
  if (label.startsWith("▸ ")) await clickText(ctx, label.slice(2));
});

step("the subagent's result is shown", async (ctx: TurnWorld) => {
  const row = await subagentRow(ctx);
  expect(row).toContain("Completed");
  expect(row).toContain("Dev server started");
  expect(await snapshot(ctx)).toContain("Dev server started");
});

step("its background work is still shown as running", async (ctx: TurnWorld) => {
  expect(ctx.thread!.latestTurn?.state).toBe("completed");
  expect(linesOf(lastOf(ctx, "background"))).toEqual([
    "◌ Background work · 1 running",
    "  command_execution · npm run dev",
  ]);
  expect(await snapshot(ctx)).toContain("Background work · 1 running");
});

step("a subagent asks for approval to run a command", async (ctx: TurnWorld) => {
  await listChildThread(ctx);
  await startRun(ctx);
  await addItem(ctx, "subagent", { ...SUBAGENT, status: "waiting", result: null });
  // The MC raises the subagent's request on the parent's stream (delegation.ex).
  await addItem(ctx, "approval_request", {
    id: "approval-1",
    requestId: "request-1",
    requestKind: "command",
    prompt: "Bash: npm test",
    status: "waiting",
  });
});

step("the approval is listed there", async (ctx: TurnWorld) => {
  expect(hostState(ctx, "approvals")).toMatchObject({ count: 1, canRespond: true });
  expect(findObject(ctx, "approvals").get("visible")).toBe(true);
  const screen = await snapshot(ctx);
  expect(screen).toContain("Approval required");
  expect(screen).toContain("npm test");
});

step("the user answers it", async (ctx: TurnWorld) => {
  // The MC hands the answer to the subagent and closes the request.
  ctx.respond!.approve = async (_thread, requestId) => {
    await setRequest(ctx, requestId, { status: "resolved", resolvedAt: time(NOW_MS) });
    await setItem(ctx, "approval-1", { status: "completed" });
    await setItem(
      ctx,
      (await turns(ctx)).items.find((item) => item.type === "subagent")!.id as string,
      {
        status: "running",
      },
    );
  };
  await pressKey(ctx, "Ctrl+A");
  await settle();
});

step("the subagent continues with the answer", async (ctx: TurnWorld) => {
  expect(recorded(ctx, "approve")).toEqual([["t1", "request-1", "accept"]]);
  expect(hostState(ctx, "approvals").count).toBe(0);
  const row = await subagentRow(ctx);
  expect(row).toContain("Working");
  expect(await snapshot(ctx)).not.toContain("Approval required");
});

step("the user reads the parent thread", (ctx: TurnWorld) => {
  expect(openThreadId(ctx)).toBe("t1");
});

step("the timeline says {string}", async (ctx: TurnWorld, text: string) => {
  expect(
    shownItems(ctx)
      .flatMap(linesOf)
      .some((line) => line.includes(text)),
  ).toBe(true);
  expect(await snapshot(ctx)).toContain(text);
});

step("the result is not shown as a message of the user's", async (ctx: TurnWorld) => {
  expect(shownItems(ctx).filter((item) => item.kind === "message")).toEqual([]);
  expect(await snapshot(ctx)).not.toContain("delegated_task_result");
});

step("nothing says a message was sent by another agent", async (ctx: TurnWorld) => {
  expect(shownItems(ctx).filter((item) => item.kind === "message")).toEqual([]);
  const screen = await snapshot(ctx);
  expect(screen).not.toContain("↩");
  expect(screen).not.toContain("Background task completed.");
});
