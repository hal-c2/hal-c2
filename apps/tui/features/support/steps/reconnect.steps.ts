// tui/reconnect.feature: the thread the user is on (T2's thread view) rides
// through a dropped connection (see reconnectWorld.ts); the fake client's
// detail map stands in for the real client's warm thread cache (`peekThread`).
import type { OrchestrationThread } from "@hal-c2/contracts";
import { expect } from "bun:test";

import { step } from "../../steps.ts";
import { threadKey } from "../../../src/host/sidebarState.ts";
import { shell, thread } from "../fakeClient.ts";
import { startConnection, type ConnectionHarness, type ReconnectWorld } from "../reconnectWorld.ts";
import {
  activity,
  approvalRequest,
  deferred,
  hostState,
  message,
  openThread,
  recorded,
  settle,
  timelineText,
  updateThread,
  type ThreadWorld,
} from "../threadWorld.ts";
import { pressKey, snapshot } from "../world.ts";

type World = ReconnectWorld & ThreadWorld;

function connection(ctx: World): ConnectionHarness {
  if (!ctx.connection) throw new Error("the client is not connected");
  return ctx.connection;
}

const shownPage = (ctx: World) => ctx.host!.state.get("page") as { kind: string; key?: string };

const connectionState = (ctx: World) =>
  (ctx.host!.state.get("connection") as { state: string }).state;

step("the terminal client is connected and showing a thread", async (ctx: World) => {
  await openThread(ctx);
  await startConnection(ctx);
  const key = threadKey(ctx.thread!.id);
  ctx.host!.dispatch("thread.open", { key });
  await snapshot(ctx);
  expect(shownPage(ctx)).toMatchObject({ kind: "thread", key });
  expect(connectionState(ctx)).toBe("connected");
});

// --- the thread the user is on ------------------------------------------------------

step("the connection dropped and came back", async (ctx: World) => {
  ctx.pageBeforeDrop = shownPage(ctx);
  const conn = connection(ctx);
  await conn.drop();
  // While the socket was down the agent kept writing; the resubscribed stream
  // brings the thread up to date.
  await updateThread(ctx, (detail) => ({
    messages: [...detail.messages, message("m-after", "assistant", "Written while away", 5)],
  }));
  await conn.connected(2);
  await snapshot(ctx);
});

step("the same thread is selected", (ctx: World) => {
  expect(connectionState(ctx)).toBe("connected");
  expect(shownPage(ctx)).toMatchObject({ kind: "thread", key: ctx.pageBeforeDrop!.key });
});

step("its timeline catches up to the server's state", (ctx: World) => {
  expect(timelineText(ctx).join("\n")).toContain("Written while away");
});

// --- the warm thread cache ----------------------------------------------------------

/** Add a thread to the environment's list; returns its sidebar key. */
function addThread(ctx: World, id: string, title: string): string {
  const current = ctx.fake!.latestShell();
  const row = { ...current.threads[0]!, id, title } as (typeof current.threads)[number];
  ctx.fake!.emitShell({ ...current, threads: [...current.threads, row] });
  return threadKey(id as never);
}

async function open(ctx: World, key: string) {
  ctx.host!.dispatch("thread.open", { key });
  await settle();
}

/** Open a thread and let its detail stream in once (it is now warm). */
async function visit(ctx: World, id: string, title: string, text: string): Promise<string> {
  const key = addThread(ctx, id, title);
  await open(ctx, key);
  ctx.fake!.emitThread({
    ...thread(),
    id,
    title,
    messages: [message(`${id}-m1`, "assistant", text, 1)],
  } as unknown as OrchestrationThread);
  await settle();
  expect(hostState(ctx, "page")).toMatchObject({ kind: "thread", title });
  return key;
}

const titleShown = (ctx: World) => (hostState(ctx, "page") as { title?: string }).title;

interface WarmWorld extends World {
  warmKey?: string;
  subscriptionsBefore?: number;
}

step("the user opened the thread {string} a moment ago", async (ctx: WarmWorld, title: string) => {
  ctx.warmKey = await visit(ctx, "t-warm", title, `${title}: last answer`);
});

step("the user switches away and back to {string}", async (ctx: WarmWorld, title: string) => {
  await open(ctx, threadKey(ctx.thread!.id));
  expect(titleShown(ctx)).not.toBe(title);
  ctx.subscriptionsBefore = ctx.fake!.subscribedThreadIds.length;
  await open(ctx, ctx.warmKey!);
});

step("{string} shows immediately from the warm cache", (ctx: WarmWorld, title: string) => {
  // Nothing has streamed since the switch: the page is the cached detail.
  expect(titleShown(ctx)).toBe(title);
  expect(timelineText(ctx).join("\n")).toContain(`${title}: last answer`);
});

step("it refreshes from the server in the background", async (ctx: WarmWorld) => {
  expect(ctx.fake!.subscribedThreadIds.slice(ctx.subscriptionsBefore)).toEqual(["t-warm"]);
  ctx.fake!.emitThread({
    ...thread(),
    id: "t-warm",
    title: titleShown(ctx),
    messages: [message("t-warm-m2", "assistant", "Fresh from the server", 2)],
  } as unknown as OrchestrationThread);
  await settle();
  expect(timelineText(ctx).join("\n")).toContain("Fresh from the server");
});

step("the thread {string} is in the warm cache", async (ctx: WarmWorld, title: string) => {
  ctx.warmKey = await visit(ctx, "t-old", title, `${title}: notes`);
  await open(ctx, threadKey(ctx.thread!.id));
});

step("another client deletes {string}", async (ctx: WarmWorld, title: string) => {
  const current = ctx.fake!.latestShell();
  ctx.fake!.emitShell({
    ...current,
    threads: current.threads.filter((each) => each.title !== title),
  });
  await snapshot(ctx);
});

step("switching threads never shows {string} again", async (ctx: WarmWorld, title: string) => {
  const threads = ctx.fake!.latestShell().threads.length;
  for (const action of ["thread.next", "thread.previous"]) {
    for (let index = 0; index <= threads; index += 1) {
      ctx.host!.dispatch(action);
      await settle();
      expect(titleShown(ctx)).not.toBe(title);
    }
  }
  expect(await snapshot(ctx)).not.toContain(title);
});

// --- older history ------------------------------------------------------------------

step("the thread has more history than the latest page", async (ctx: World) => {
  ctx.page = { hasMore: true, loadingOlder: false };
  await updateThread(ctx, () => ({
    messages: [message("m-new", "assistant", "The latest answer", 10)],
  }));
  expect(timelineText(ctx).join("\n")).toContain("Load earlier turns");
});

step("the user asks to load earlier turns", async (ctx: World) => {
  ctx.host!.dispatch("timeline.showOlder");
  await settle();
  expect(recorded(ctx, "loadOlderThreadTurns")).toEqual([[ctx.thread!.id]]);
  // The client fetches the page over HTTP and marks the thread as loading meanwhile.
  ctx.page = { hasMore: true, loadingOlder: true };
  await updateThread(ctx, () => ({}));
});

step("the timeline says it is loading earlier turns", (ctx: World) => {
  expect(timelineText(ctx).join("\n")).toContain("Loading earlier turns");
});

step("the next older page appears above the current one", async (ctx: World) => {
  ctx.page = { hasMore: false, loadingOlder: false };
  await updateThread(ctx, (detail) => ({
    messages: [message("m-old", "assistant", "An older answer", 1), ...detail.messages],
  }));
  // The view stays on the page that arrived; the current one is below it.
  expect(timelineText(ctx)).toEqual(["An older answer", "▾ 1 newer entries"]);
});

// --- answering an approval ----------------------------------------------------------

interface ApprovalWorld extends World {
  approveReply?: ReturnType<typeof deferred<void>>;
}

step("an approval prompt is open", async (ctx: ApprovalWorld) => {
  await updateThread(ctx, (detail) => ({
    activities: [...detail.activities, approvalRequest("r1", "rm -rf build", 1)],
  }));
  expect(hostState(ctx, "approvals").count).toBe(1);
});

async function answerAndFail(ctx: ApprovalWorld, detail: string) {
  const reply = deferred();
  ctx.respond!.approve = () => reply.promise;
  await pressKey(ctx, "Ctrl+A");
  expect(recorded(ctx, "approve")).toEqual([[ctx.thread!.id, "r1", "accept"]]);
  reply.reject(new Error(detail));
  await updateThread(ctx, (thread) => ({
    activities: [
      ...thread.activities,
      activity("act-r1-failed", 2, {
        tone: "error",
        kind: "provider.approval.respond.failed",
        summary: "Approval response failed",
        payload: { requestId: "r1", detail },
      }),
    ],
  }));
}

step(
  "the user answers it and the provider reports the request as stale or unknown",
  (ctx: ApprovalWorld) => answerAndFail(ctx, "Stale pending approval request: r1"),
);

step(
  "the user answers it and the provider reports a failure that is not about a stale request",
  (ctx: ApprovalWorld) => answerAndFail(ctx, "provider process exited"),
);

step("the approval prompt closes", async (ctx: ApprovalWorld) => {
  expect(hostState(ctx, "approvals").count).toBe(0);
  expect(await snapshot(ctx)).not.toContain("Approval required");
});

step("the approval prompt stays open so the user can answer again", async (ctx: ApprovalWorld) => {
  expect(hostState(ctx, "approvals").count).toBe(1);
  ctx.respond!.approve = async () => {};
  await pressKey(ctx, "Ctrl+A");
  await settle();
  expect(recorded(ctx, "approve")).toHaveLength(2);
});
