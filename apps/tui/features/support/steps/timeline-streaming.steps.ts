// features/timeline/streaming.feature on the terminal client: reasoning, turn
// folds, stopped turns and long messages, over the MC's projection (turnWorld.ts).
import { expect } from "bun:test";

import { step } from "../../steps.ts";
import { chooseCommand } from "../threadUi.ts";
import { pressKey, snapshot } from "../world.ts";
import { clickText, hostState, plain, recorded, settle } from "../threadWorld.ts";
import {
  addCommand,
  addItem,
  itemsOf,
  lastOf,
  linesOf,
  messageItem,
  setItem,
  settleRun,
  shownItems,
  startRun,
  sync,
  turns,
  type TurnWorld,
} from "../turnWorld.ts";

interface StreamWorld extends TurnWorld {
  /** Seconds the scenario's run had been going when it was stopped. */
  ranFor?: number;
  /** The rows on screen before the step under test. */
  rowsBefore?: string[];
}

const ANSWER = "The cart now shows tax.";

// --- reasoning -------------------------------------------------------------------------

step("the agent is reasoning before it answers", async (ctx: StreamWorld) => {
  await startRun(ctx);
  await addItem(ctx, "reasoning", {
    id: "reasoning",
    streaming: true,
    status: "running",
    text: "The cart total needs",
  });
});

step("the reasoning is streaming", async (ctx: StreamWorld) => {
  // Streamed text redraws its row; the rows stay the ones they were.
  const before = shownItems(ctx).map((item) => item.key);
  await setItem(ctx, "reasoning", { text: "The cart total needs a tax line" });
  expect(shownItems(ctx).map((item) => item.key)).toEqual(before);
  expect(await snapshot(ctx)).toContain("The cart total needs a tax line");
});

step("the reasoning is finished", async (ctx: StreamWorld) => {
  await setItem(ctx, "reasoning", { streaming: false, status: "completed" });
});

step("the reasoning is labelled {string}", async (ctx: StreamWorld, label: string) => {
  const row = lastOf(ctx, "work").lines.at(-1)!;
  // icon, then the label.
  expect(row.text.chunks[1]!.text).toBe(label);
  expect(await snapshot(ctx)).toContain(`${row.text.chunks[0]!.text}${label}`);
});

// --- turn folds ------------------------------------------------------------------------

async function fourCallsAndAnswer(ctx: StreamWorld) {
  await startRun(ctx);
  for (let n = 1; n <= 4; n += 1) await addCommand(ctx, n);
  await addItem(ctx, "assistant_message", { id: "answer", text: ANSWER });
}

function foldRow(ctx: StreamWorld) {
  return plain(lastOf(ctx, "fold").lines[0]!.text);
}

async function expectFolded(ctx: StreamWorld, label: string) {
  expect(foldRow(ctx)).toBe(`▸ ${label}`);
  expect(itemsOf(ctx, "work")).toEqual([]);
  const screen = await snapshot(ctx);
  expect(screen).toContain(`▸ ${label}`);
  expect(screen).not.toContain("bun test cart-");
}

step("the agent ran four tool calls and then answered", fourCallsAndAnswer);

step(/^the turn completes after (\d+) minutes?$/, async (ctx: StreamWorld, minutes: string) => {
  await settleRun(ctx, "completed", Number(minutes) * 60);
});

step("the tool calls fold behind {string}", expectFolded);

step("the answer stays visible", async (ctx: StreamWorld) => {
  expect(linesOf(messageItem(ctx, "answer"))).toContain(ANSWER);
  expect(await snapshot(ctx)).toContain(ANSWER);
});

step("a finished turn is folded behind {string}", async (ctx: StreamWorld, label: string) => {
  await fourCallsAndAnswer(ctx);
  await settleRun(ctx, "completed", 120);
  await expectFolded(ctx, label);
});

step("the user opens the folded work", async (ctx: StreamWorld) => {
  await clickText(ctx, foldRow(ctx).slice(2));
});

step("its tool calls are shown", async (ctx: StreamWorld) => {
  expect(foldRow(ctx).startsWith("▾ ")).toBe(true);
  // The group shows its latest call and counts the three before it.
  const group = linesOf(lastOf(ctx, "work"));
  expect(group[0]).toContain("bun test cart-4");
  expect(group[1]!.trim()).toBe("⌄ +3 previous tool calls");
  expect(await snapshot(ctx)).toContain("bun test cart-4");
});

step("the user closes it again", async (ctx: StreamWorld) => {
  await clickText(ctx, foldRow(ctx).slice(2));
});

step("the tool calls fold away", async (ctx: StreamWorld) => {
  expect(foldRow(ctx).startsWith("▸ ")).toBe(true);
  expect(itemsOf(ctx, "work")).toEqual([]);
  expect(await snapshot(ctx)).not.toContain("bun test cart-");
});

// --- stopped turns ---------------------------------------------------------------------

step(
  "the user interrupted a turn after {int} seconds",
  async (ctx: StreamWorld, seconds: number) => {
    ctx.ranFor = seconds;
    await startRun(ctx, seconds);
    await addCommand(ctx, 1, "interrupted");
  },
);

step("the user interrupted a turn before it did any work", async (ctx: StreamWorld) => {
  ctx.ranFor = 0;
  await startRun(ctx, 0, "starting");
  await addItem(ctx, "run_interrupt_result", { message: "Interrupted by the user" });
});

// The user stops the turn here, with the key the prompt gives it.
step("the user interrupted the running turn a moment ago", async (ctx: StreamWorld) => {
  ctx.ranFor = 5;
  await startRun(ctx, 5);
  await addCommand(ctx, 1);
  await addCommand(ctx, 2, "running");
  await pressKey(ctx, "Esc");
  await settle();
  expect(recorded(ctx, "interrupt")).toEqual([["t1"]]);
});

step("the turn settles", async (ctx: StreamWorld) => {
  await settleRun(ctx, "interrupted", ctx.ranFor ?? 0);
});

step("its work folds behind {string}", async (ctx: StreamWorld, label: string) => {
  expect(foldRow(ctx)).toBe(`▸ ${label}`);
  expect(await snapshot(ctx)).toContain(`▸ ${label}`);
});

step("its work stays expanded so the user can see where it stopped", async (ctx: StreamWorld) => {
  expect(foldRow(ctx)).toBe("▾ You stopped after 5.0s");
  const group = linesOf(lastOf(ctx, "work"));
  expect(group[0]).toContain("Stopped");
  expect(group[0]).toContain("bun test cart-2");
  const screen = await snapshot(ctx);
  expect(screen).toContain("▾ You stopped after 5.0s");
  expect(screen).toContain("bun test cart-2");
});

// --- long messages ---------------------------------------------------------------------

const LONG_MESSAGE = Array.from({ length: 30 }, (_, index) => `Requirement ${index + 1}`).join(
  "\n",
);

step("a message longer than the preview length", async (ctx: StreamWorld) => {
  await startRun(ctx);
  const fixture = await turns(ctx);
  fixture.messages[fixture.messages.length - 1]!.text = LONG_MESSAGE;
  await sync(ctx);
  const screen = await snapshot(ctx);
  expect(screen).toContain("Requirement 1 ");
  expect(screen).not.toContain("Requirement 30");
});

step("the user shows the full message", async (ctx: StreamWorld) => {
  await clickText(ctx, "Show full");
});

step("the whole message is shown", async (ctx: StreamWorld) => {
  const lines = linesOf(lastOf(ctx, "message"));
  for (let line = 1; line <= 30; line += 1) expect(lines).toContain(`Requirement ${line}`);
  const screen = await snapshot(ctx);
  expect(screen).toContain("Requirement 30");
  expect(screen).toContain("⌃ Show less");
});

step("the user shows less", async (ctx: StreamWorld) => {
  await clickText(ctx, "Show less");
});

step("the message returns to its preview", async (ctx: StreamWorld) => {
  const lines = linesOf(lastOf(ctx, "message"));
  expect(lines).not.toContain("Requirement 30");
  const screen = await snapshot(ctx);
  expect(screen).toContain("Requirement 1 ");
  expect(screen).toContain("⌄ Show full");
  expect(screen).not.toContain("Requirement 30");
});

// --- copying a reply -------------------------------------------------------------------

const REPLY = "Tax is **8%** on the subtotal.\n\n- applied per line\n- rounded once";

step("the agent has answered", async (ctx: StreamWorld) => {
  await startRun(ctx, 30);
  await addItem(ctx, "assistant_message", { id: "answer", text: REPLY });
  await settleRun(ctx, "completed", 30);
});

step("the user copies the reply", async (ctx: StreamWorld) => {
  await chooseCommand(ctx, "Copy reply");
});

step("the reply's markdown is on the clipboard", async (ctx: StreamWorld) => {
  expect(ctx.clipboard).toEqual([REPLY]);
  expect(hostState(ctx, "status")).toEqual({ kind: "success", text: "Reply copied." });
});
