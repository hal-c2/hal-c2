// Context for the next prompt picked outside it (tui/terminal.feature,
// tui/timeline.feature): terminal output and a note on a diff line, each a chip
// on the prompt and a typed record on the message that is sent.
import { expect } from "bun:test";

import type { TuiComposerState, TuiSelectState } from "../../../src/host/composerState.ts";
import { TERMINAL_CONTEXT_MAX_LINES } from "../../../src/host/features/context.ts";
import { step } from "../../steps.ts";
import { objectRows } from "../design.ts";
import { thread } from "../fakeClient.ts";
import { chooseCommand } from "../threadUi.ts";
import { checkpoint, updateThread, type ThreadWorld } from "../threadWorld.ts";
import { pressKey, settle, typeText, type World } from "../world.ts";
import { openDrawer, type TerminalWorld } from "./terminal.steps.ts";

const composer = (ctx: World) => ctx.host!.state.get("composer") as TuiComposerState;
const select = (ctx: World) => ctx.host!.state.get("select") as TuiSelectState;
const status = (ctx: World) => ctx.host!.state.get("status") as { text: string; kind: string };
const sent = (ctx: World) => ctx.fake!.calls.filter((call) => call.method === "sendReply");
const REFERENCE = /\[([^\]]+)\]\(hal-c2-context:\/\/v1\/([a-z-]+)\/([a-z0-9_-]+)\)/i;

async function pick(ctx: World, label: string) {
  const index = select(ctx).options.findIndex((option) => option.label === label);
  expect(index, `no "${label}" in the picker`).toBeGreaterThanOrEqual(0);
  const moves = index - select(ctx).index;
  for (let i = 0; i < Math.abs(moves); i += 1) await pressKey(ctx, moves > 0 ? "Down" : "Up");
}

/** Send what the prompt holds and return the message's text and context. */
async function send(ctx: World, words: string) {
  await typeText(ctx, words);
  await pressKey(ctx, "Enter");
  await settle(ctx);
  expect(sent(ctx)).toHaveLength(1);
  const [, text, , , context] = sent(ctx)[0]!.args as [
    unknown,
    string,
    unknown,
    unknown,
    { version: number; records: Array<Record<string, unknown>> } | undefined,
  ];
  return { text, context };
}

// --- Terminal output ----------------------------------------------------------------

const OUTPUT = Array.from({ length: 9 }, (_, index) => `test ${index + 1} ... ok`);
const TAIL = [...OUTPUT.slice(-3), "", "FAIL cart.test.ts: expected 10.50, got 10.51"];

step("the user selected lines of terminal output", async (ctx: TerminalWorld) => {
  await openDrawer(ctx);
  // The prompt belongs to a thread the server knows.
  ctx.fake!.emitThread(thread());
  const [terminal] = [...ctx.fake!.terminals.values()];
  terminal!.emit({
    type: "output",
    threadId: terminal!.threadId,
    terminalId: terminal!.terminalId,
    createdAt: "2026-07-13T00:00:00.000Z",
    data: `${[...OUTPUT, "", TAIL.at(-1)].join("\r\n")}`,
  } as never);
  await settle(ctx);
  await chooseCommand(ctx, "Add terminal output to the prompt…");
  await settle(ctx);
  // The screen, or its last lines: the failure and what led to it.
  expect(select(ctx).options.map((option) => option.label)).toEqual([
    "The screen (11 lines)",
    "The last 10 lines",
    "The last 5 lines",
  ]);
  await pick(ctx, "The last 5 lines");
});

step("the user adds the selection to the prompt", async (ctx: World) => {
  await pressKey(ctx, "Enter");
  await settle(ctx);
});

step("a bounded chip with that output is attached to the prompt", async (ctx: World) => {
  expect(status(ctx)).toEqual({ kind: "success", text: "Added 5 terminal lines to the prompt." });
  expect(composer(ctx).contexts).toHaveLength(1);
  expect(composer(ctx).contexts[0]).toMatchObject({
    kind: "terminal",
    label: "terminal · 5 lines",
  });
  // The chip names what it holds; the output itself is not poured into the prompt.
  expect(composer(ctx).text).toBe("");
  const [row] = await objectRows(ctx, "composerReferences");
  expect(row!.trim()).toBe("× terminal · 5 lines");
  expect(TERMINAL_CONTEXT_MAX_LINES).toBe(200);
  // Sent, the message names the chip and carries exactly the lines that were picked.
  const { text, context } = await send(ctx, "Why does this fail?");
  const reference = REFERENCE.exec(text);
  expect(text.startsWith("Why does this fail?\n\n[terminal · 5 lines](")).toBe(true);
  expect(reference?.[2]).toBe("terminal");
  expect(context?.version).toBe(1);
  expect(context?.records).toHaveLength(1);
  expect(context!.records[0]).toMatchObject({
    kind: "terminal",
    contextId: reference![3],
    terminalId: "term-1",
    text: TAIL.join("\n"),
    lineStart: 6,
    lineEnd: 10,
  });
  // The prompt is clear again.
  expect(composer(ctx).contexts).toEqual([]);
});

// --- A note on a diff line ----------------------------------------------------------------

const CHANGED = "+  return round(sum(items));";
const DIFF = [
  "diff --git a/src/cart.ts b/src/cart.ts",
  "--- a/src/cart.ts",
  "+++ b/src/cart.ts",
  "@@ -1,3 +1,3 @@",
  " export function total(items) {",
  "-  return sum(items);",
  CHANGED,
  " }",
].join("\n");
const NOTE = "Round once, at the end";

step("the user adds a note on a diff line", async (ctx: ThreadWorld) => {
  ctx.respond!.getFullThreadDiff = async () => DIFF;
  await updateThread(ctx, () => ({ checkpoints: [checkpoint(1, ["src/cart.ts"], 5, null)] }));
  ctx.host!.dispatch("diff.all");
  await settle(ctx);
  expect(ctx.host!.state.get("mode")).toBe("diff");
  await pressKey(ctx, "c");
  await settle(ctx);
  // The lines that changed, to pick from (or search).
  expect(select(ctx).options.map((option) => option.label)).toEqual([
    "-  return sum(items);",
    CHANGED,
  ]);
  await pick(ctx, CHANGED);
  await pressKey(ctx, "Enter");
  await settle(ctx);
  expect(ctx.host!.state.get("ask")).toMatchObject({ label: "note" });
  await typeText(ctx, NOTE);
  await pressKey(ctx, "Enter");
  await settle(ctx);
});

step("the note and the line are attached to the prompt as context", async (ctx: World) => {
  expect(composer(ctx).contexts).toHaveLength(1);
  const [chip] = composer(ctx).contexts;
  expect(chip).toMatchObject({ kind: "review-comment" });
  expect(chip!.label).toMatch(/^src\/cart\.ts L\d+$/);
  // Still in the diff, to note another line; back at the prompt the chip is there.
  expect(ctx.host!.state.get("mode")).toBe("diff");
  await pressKey(ctx, "Esc");
  await settle(ctx);
  const [row] = await objectRows(ctx, "composerReferences");
  expect(row!.trim()).toBe(`× ${chip!.label}`);
  const { text, context } = await send(ctx, "Please fix this");
  const reference = REFERENCE.exec(text);
  expect(reference?.[1]).toBe(chip!.label);
  expect(reference?.[2]).toBe("review-comment");
  expect(context!.records).toHaveLength(1);
  expect(context!.records[0]).toMatchObject({
    kind: "review-comment",
    contextId: reference![3],
    filePath: "src/cart.ts",
    text: NOTE,
    diff: CHANGED,
  });
});
