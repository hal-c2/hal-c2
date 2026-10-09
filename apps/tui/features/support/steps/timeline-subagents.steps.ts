// features/timeline/plans-and-subagents.feature: moving between a subagent's
// thread and its parent, and a message another agent sent. The subagent's
// thread is in the thread list with its lineage, as the MC lists it.
import { expect } from "bun:test";

import { step } from "../../steps.ts";
import { thread as baseThread } from "../fakeClient.ts";
import { snapshot } from "../world.ts";
import { clickText, hostState, plain, settle } from "../threadWorld.ts";
import {
  addItem,
  linesOf,
  shownItems,
  startRun,
  sync,
  turns,
  type TurnWorld,
} from "../turnWorld.ts";

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
