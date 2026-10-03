// The @tui scenarios of features/threads/ that came off the backlog: the empty
// new-thread draft, what an offline environment refuses, and snoozing.
import { expect } from "bun:test";

import type { TuiNewThreadState } from "../../../src/host/composerState.ts";
import { step } from "../../steps.ts";
import { addThread, change, flush, threadNamed, ui } from "../environment.ts";
import { contextMenu, listedTitles, openMenu, sidebar, statusText } from "../threadUi.ts";
import { pressKey, snapshot, type World } from "../world.ts";

const status = (ctx: World) => ctx.host!.state.get("status") as { kind: string; text: string };
const statusLabel = (ctx: World) => (ctx.host!.state.get("statusRow") as { label: string }).label;
const callsTo = (ctx: World, method: string) =>
  ctx.fake!.calls.filter((call) => call.method === method);

// --- The empty draft ---------------------------------------------------------

step("the thread list does not list the empty draft", async (ctx: World) => {
  await flush(ctx);
  // The draft is open and holds nothing.
  const draft = ctx.host!.state.get("newThread") as TuiNewThreadState | null;
  expect(draft).not.toBeNull();
  expect((ctx.host!.state.get("composer") as { text: string }).text).toBe("");
  expect(sidebar(ctx).rows.filter((row) => row.kind === "draft")).toEqual([]);
  expect(sidebar(ctx).drafts).toEqual([]);
  expect(await snapshot(ctx)).not.toContain("+ New thread");
  // Its threads are still listed.
  expect(listedTitles(ctx).length).toBeGreaterThan(0);
});

// --- An offline environment ---------------------------------------------------

// The connection was up and is lost: the client keeps what it last knew.
step("the environment is unreachable", async (ctx: World) => {
  await ui(ctx);
  ctx.fake!.emitConnection("connected");
  ctx.fake!.emitConnection("reconnecting");
  await flush(ctx);
  expect((ctx.host!.state.get("connection") as { state: string }).state).toBe("reconnecting");
});

step("{string} is kept", async (ctx: World, title: string) => {
  await flush(ctx);
  expect(listedTitles(ctx)).toContain(title);
  expect(callsTo(ctx, "deleteThread")).toEqual([]);
  // Nothing is left asking, either.
  expect(ctx.host!.state.get("overlay")).toBeNull();
});

step("the user is told the delete failed", async (ctx: World) => {
  expect(status(ctx).kind).toBe("error");
  expect(statusText(ctx)).toBe("Delete failed: the environment is offline.");
  expect(await snapshot(ctx)).toContain(statusLabel(ctx));
});

step("the user is told the environment is offline", async (ctx: World) => {
  expect(status(ctx).kind).toBe("error");
  expect(statusText(ctx)).toBe("The environment is offline.");
  expect(await snapshot(ctx)).toContain(statusLabel(ctx));
});

step("no draft is sent to the environment", async (ctx: World) => {
  expect(ctx.host!.state.get("newThread")).toBeNull();
  expect((ctx.host!.state.get("page") as { kind: string }).kind).not.toBe("draft");
  // Even with Enter pressed where the draft would have been.
  await pressKey(ctx, "Enter");
  await flush(ctx);
  expect(callsTo(ctx, "createThread")).toEqual([]);
});

// --- Snoozing -------------------------------------------------------------------

step("a connected environment with the idle thread {string}", (ctx: World, title: string) => {
  addThread(ctx, title);
});

// 15 July 2026, the pinned day of the environment's clock, is a Wednesday.
step("the local time is Wednesday 10:00", (ctx: World) => {
  const wednesday = new Date(2026, 6, 15, 10, 0, 0);
  expect(wednesday.getDay()).toBe(3);
  ctx.nowMs = wednesday.getTime();
});

// The other two states of the outline are threads.steps.ts' thread states.
step("{string} has a turn queued that has not started", (ctx: World, title: string) => {
  change(ctx, () => {
    const thread = threadNamed(ctx, title);
    // The message was sent ten seconds ago and no turn has picked it up.
    thread.latestUserMessageAt = new Date(ctx.nowMs! - 10_000).toISOString();
    thread.latestTurn = null;
    thread.session = null;
  });
});

step("the user tries to snooze {string}", async (ctx: World, title: string) => {
  await openMenu(ctx, title);
});

step("snoozing is unavailable", async (ctx: World) => {
  const menu = contextMenu(ctx)!;
  const item = menu.rows.find((row) => row.kind === "item" && row.id === "snooze");
  expect(item).toMatchObject({ kind: "item", label: "Snooze", disabled: true });
  expect(await snapshot(ctx)).toContain("Snooze");
  // Choosing it anyway does nothing: no times are offered and nothing is sent.
  ctx.host!.dispatch("contextMenu.select", { requestId: menu.requestId, id: "snooze" });
  await flush(ctx);
  expect(contextMenu(ctx)?.requestId).toBe(menu.requestId);
  expect(callsTo(ctx, "snoozeThread")).toEqual([]);
});
