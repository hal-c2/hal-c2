// timeline/streaming.feature: a thread caught up after a drop, a cut catch-up and a
// resync, and a thread whose MC leaves the cluster. The real client follows the
// thread on a fake MC (streamSyncWorld.ts); the timeline shows what it made of it.
import { expect } from "bun:test";

import { step } from "../../steps.ts";
import {
  dropThreadConnection,
  finishReply,
  keepsRows,
  reply,
  synced,
  writingReply,
  type SyncWorld,
} from "../streamSyncWorld.ts";
import { timelineText } from "../threadWorld.ts";
import { startRun, turns } from "../turnWorld.ts";
import { settle } from "../world.ts";

const CANNOT_BE_REACHED = "cannot be reached";

/** Waits for the client to show the reply finished. */
async function replyFinished(ctx: SyncWorld) {
  const state = ctx.synced!;
  const lines = state.replyLines;
  await state.until(
    () => reply(ctx)?.streaming === false && reply(ctx)!.text.includes(`Reply line ${lines}.`),
    "the finished reply",
  );
  await settle(ctx);
}

step("the agent finishes the reply while the shell is disconnected", async (ctx: SyncWorld) => {
  const state = await writingReply(ctx);
  state.mc.append(finishReply(ctx, 2));
});

step("the shell reconnects to the MC", async (ctx: SyncWorld) => {
  const state = ctx.synced!;
  state.mc.reachable();
  await state.mc.until(() => state.mc.subs.length > state.subsBefore!, "a new subscription");
  await replyFinished(ctx);
});

step("the whole reply is shown", async (ctx: SyncWorld) => {
  await replyFinished(ctx);
  const shown = timelineText(ctx).join("\n");
  for (let line = 1; line <= ctx.synced!.replyLines; line++) {
    // Once: a catch-up applied twice would write its text twice.
    expect(shown.split(`Reply line ${line}.`).length - 1).toBe(1);
  }
  expect(shown).not.toContain(`Reply line ${ctx.synced!.replyLines + 1}.`);
});

step("the rows shown before are kept", (ctx: SyncWorld) => {
  expect(keepsRows(ctx.synced!.shownBefore, timelineText(ctx))).toEqual([]);
});

step("the MC sends only what the client lacks", (ctx: SyncWorld) => {
  const state = ctx.synced!;
  const [resumed] = state.mc.subs.slice(state.subsBefore);
  expect(resumed).toMatchObject({ offset: state.offsetBefore, answer: "events" });
  expect(resumed!.sent).toEqual(
    Array.from(
      { length: state.mc.head - state.offsetBefore! },
      (_, i) => state.offsetBefore! + i + 1,
    ),
  );
});

step("the agent finishes the reply while the MC cannot be reached", async (ctx: SyncWorld) => {
  const state = await writingReply(ctx);
  await dropThreadConnection(ctx);
  state.mc.append(finishReply(ctx, 2));
});

step(
  "the MC is back and the connection drops again part-way through the catch-up",
  async (ctx: SyncWorld) => {
    const state = ctx.synced!;
    const { mc } = state;
    mc.cutNextCatchUp();
    mc.reachable();
    await mc.until(
      () => mc.subs.slice(state.subsBefore).some((sub) => sub.sent.length > 0),
      "the first part of the catch-up",
    );
    // The part that arrived is shown before the connection drops again.
    const lines = state.replyLines;
    await state.until(
      () => reply(ctx)?.text.includes(`Reply line ${lines}.`) === true,
      "the part of the catch-up that arrived",
    );
    state.offsetBefore = mc.subs.at(-1)!.sent.at(-1)!;
    state.subsBefore = mc.subs.length;
    mc.drop();
  },
);

step("the client asked again from where it was", (ctx: SyncWorld) => {
  const state = ctx.synced!;
  const [again] = state.mc.subs.slice(state.subsBefore);
  expect(again).toMatchObject({ offset: state.offsetBefore, answer: "events" });
});

step("the agent writes more than the shell has read", async (ctx: SyncWorld) => {
  const state = await writingReply(ctx);
  state.subsBefore = state.mc.subs.length;
  state.mc.append(finishReply(ctx, 2), true);
});

step("the MC tells the shell to resync the thread", async (ctx: SyncWorld) => {
  const state = ctx.synced!;
  state.mc.resync();
  await state.mc.until(() => state.mc.subs.length > state.subsBefore!, "a new subscription");
  expect(state.mc.subs.at(-1)!.answer).toBe("events");
});

step("the user is looking at a thread on another MC of the cluster", async (ctx: SyncWorld) => {
  await turns(ctx);
  await startRun(ctx, 30);
  await synced(ctx, { cluster: true });
});

step("the agent has answered {string}", async (ctx: SyncWorld, answer: string) => {
  const state = ctx.synced!;
  const run = ctx.turns!.runs.at(-1)!;
  const at = new Date(Date.parse(String(run.requestedAt ?? "")) || Date.now()).toISOString();
  const entity = {
    threadId: ctx.thread!.id,
    runId: run.id,
    nodeId: null,
    createdAt: at,
    updatedAt: at,
  };
  state.mc.append([
    [
      "message",
      "answer",
      {
        s: {
          ...entity,
          id: "answer",
          createdBy: "agent",
          creationSource: "provider",
          role: "assistant",
          text: answer,
          attachments: [],
          streaming: false,
        },
      },
    ],
    [
      "turn-item",
      "answer",
      {
        s: {
          ...entity,
          id: "answer",
          providerThreadId: null,
          providerTurnId: null,
          nativeItemRef: null,
          parentItemId: null,
          ordinal: 1,
          status: "completed",
          title: null,
          startedAt: at,
          completedAt: at,
          type: "assistant_message",
          messageId: "answer",
          text: answer,
          streaming: false,
        },
      },
    ],
  ]);
  await state.until(
    () => ctx.thread?.messages.some((entry) => entry.text === answer) === true,
    "the answer",
  );
  await settle(ctx);
});

step("that MC leaves the cluster", async (ctx: SyncWorld) => {
  const state = ctx.synced!;
  state.subsBefore = state.mc.subs.length;
  await state.setMemberConnected!(false);
  await state.until(() => Boolean(state.page?.unreachable), "the thread to say so");
  await settle(ctx);
});

step("the thread says its MC cannot be reached", (ctx: SyncWorld) => {
  expect(timelineText(ctx).some((line) => line.includes(CANNOT_BE_REACHED))).toBe(true);
});

step("the answer {string} is still shown", (ctx: SyncWorld, answer: string) => {
  expect(timelineText(ctx).some((line) => line.includes(answer))).toBe(true);
});

step("that MC rejoins the cluster", async (ctx: SyncWorld) => {
  const state = ctx.synced!;
  state.subsBefore = state.mc.subs.length;
  await state.setMemberConnected!(true);
  await state.until(() => !state.page?.unreachable, "the notice to go");
  await state.mc.until(() => state.mc.subs.length > state.subsBefore!, "the thread asked again");
  await settle(ctx);
});

step("the thread follows its MC again", (ctx: SyncWorld) => {
  const state = ctx.synced!;
  expect(timelineText(ctx).some((line) => line.includes(CANNOT_BE_REACHED))).toBe(false);
  // Asked again from where it was, not loaded anew.
  expect(state.mc.subs.at(-1)).toMatchObject({ answer: "events" });
});
