// tui/terminal.feature: terminals the MC kept (from an earlier client
// session, or opened through another MC of the cluster) and ones it dropped.
import { expect } from "bun:test";

import type { TuiTerminalState } from "../../../src/host/terminalState.ts";
import { step } from "../../steps.ts";
import { objectRows } from "../design.ts";
import { chooseCommand } from "../threadUi.ts";
import { pressKey, settle, type World } from "../world.ts";
import { haveTerminals, openDrawer, openThread, type TerminalWorld } from "./terminal.steps.ts";

const THREAD_ID = "t1";
const terminal = (ctx: World) => ctx.host!.state.get("terminal") as TuiTerminalState;
const tabIds = (ctx: World) => terminal(ctx).tabs.map((tab) => tab.id);
const screen = (ctx: World) =>
  terminal(ctx)
    .lines.map((line) => line.chunks.map((part) => part.text).join(""))
    .join("\n");

/** What the MC answers when asked for the thread's terminals. */
function mcKeeps(ctx: TerminalWorld, ids: string[]) {
  ctx.overrides = { ...ctx.overrides, listTerminalIds: () => Promise.resolve(ids) };
}

// --- Terminals that outlived the client ------------------------------------------------

step("a thread whose terminals outlived the terminal client session", (ctx: TerminalWorld) => {
  // An earlier session left three terminals; the MC kept them and their output.
  mcKeeps(ctx, ["term-1", "term-2", "term-3"]);
  ctx.history = {
    "term-1": "$ bun dev\r\nVITE ready in 120 ms\r\n",
    "term-2": "$ bun test --watch\r\n42 pass\r\n",
    "term-3": "$ tail -f log/dev.log\r\n",
  };
});

step("the terminal client opens the thread", async (ctx: TerminalWorld) => {
  await openThread(ctx);
  // The Background already had this thread open: come to it from another one.
  ctx.host!.dispatch("thread.open", { key: "local:t2" });
  await settle(ctx);
  ctx.host!.dispatch("thread.open", { key: `local:${THREAD_ID}` });
  await settle(ctx);
  await pressKey(ctx, "Ctrl+E");
  await settle(ctx);
});

step("its tabs list every terminal the MC kept", async (ctx: TerminalWorld) => {
  expect(ctx.fake!.calls.filter((call) => call.method === "terminalClose")).toEqual([]);
  expect(tabIds(ctx)).toEqual(["term-1", "term-2", "term-3"]);
  expect((await objectRows(ctx, "drawer")).join("\n")).toContain("1 ✕   2   3 + new");
  // They are the same sessions, not new shells: each comes back with what it had printed.
  expect(screen(ctx)).toContain("VITE ready in 120 ms");
  ctx.host!.dispatch("terminal.select", { id: "term-2" });
  await settle(ctx);
  expect(screen(ctx)).toContain("42 pass");
  expect(ctx.fake!.terminals.get(`${THREAD_ID}:term-2`)?.attach).toMatchObject({
    threadId: THREAD_ID,
    terminalId: "term-2",
  });
});

// --- A closed terminal stays closed ------------------------------------------------------

step("the user closed a terminal", async (ctx: TerminalWorld) => {
  mcKeeps(ctx, ["term-1", "term-2", "term-3"]);
  await haveTerminals(ctx, 3, 2);
  await chooseCommand(ctx, "Close terminal");
  await settle(ctx);
  expect(tabIds(ctx)).toEqual(["term-1", "term-3"]);
  // Closing ends the session on the MC, history and all: it no longer lists it.
  expect(
    ctx.fake!.calls.filter((call) => call.method === "terminalClose").map((call) => call.args),
  ).toEqual([[THREAD_ID, "term-2"]]);
  mcKeeps(ctx, ["term-1", "term-3"]);
});

step("the terminal client lists the thread's terminals again", async (ctx: TerminalWorld) => {
  // Leaving the thread and coming back asks the MC afresh.
  ctx.host!.dispatch("thread.open", { key: "local:t2" });
  await settle(ctx);
  ctx.host!.dispatch("thread.open", { key: `local:${THREAD_ID}` });
  await settle(ctx);
  if (!terminal(ctx).open) await pressKey(ctx, "Ctrl+E");
  await settle(ctx);
});

step("the closed terminal is gone", async (ctx: World) => {
  expect(terminal(ctx).open).toBe(true);
  expect(tabIds(ctx)).toEqual(["term-1", "term-3"]);
  const tabs = (await objectRows(ctx, "drawer")).find((row) => row.includes("+ new"))!;
  expect(tabs).toMatch(/1 .*3 .*\+ new/);
  expect(tabs).not.toMatch(/\b2\b/);
  expect(ctx.fake!.terminals.get(`${THREAD_ID}:term-2`)?.listener ?? null).toBeNull();
});

// --- A cluster ---------------------------------------------------------------------------

step("the terminal client is connected to one MC of a cluster", async (ctx: TerminalWorld) => {
  await openDrawer(ctx);
  ctx.fake!.cluster.members = [
    { id: "env-studio", label: "studio", addresses: ["studio:47730"], connected: true },
  ];
  await ctx.host!.dispatch("cluster.refresh");
  await settle(ctx);
  expect(
    (ctx.host!.state.get("cluster") as { status: { members: unknown[] } }).status.members,
  ).toHaveLength(1);
});

// The client cannot tell which MC a thread runs on: the MC it is connected to
// relays the thread and its terminals, so nothing differs on this side.
step("the thread runs on another MC of the cluster", (ctx: World) => {
  expect(tabIds(ctx)).toEqual(["term-1"]);
});

step("another client opens a terminal on that thread", async (ctx: World) => {
  ctx.fake!.emitTerminalMetadata({
    type: "upsert",
    terminal: { threadId: THREAD_ID, terminalId: "term-2" },
  } as never);
  await settle(ctx);
});

step("a tab for it appears in the terminal client", async (ctx: World) => {
  expect(tabIds(ctx)).toEqual(["term-1", "term-2"]);
  expect(terminal(ctx).activeId).toBe("term-1");
  expect((await objectRows(ctx, "drawer")).join("\n")).toContain("1 ✕   2 + new");
  // And it attaches through the same connection when the user switches to it.
  ctx.host!.dispatch("terminal.select", { id: "term-2" });
  await settle(ctx);
  expect(ctx.fake!.terminals.get(`${THREAD_ID}:term-2`)?.attachCount).toBe(1);
});
