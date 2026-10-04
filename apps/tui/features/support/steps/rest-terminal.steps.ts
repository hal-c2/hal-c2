// terminal/composer-context.feature and terminal/tabs.feature: terminal output picked
// for the prompt, and the terminals an MC still holds after it restarted.
import { expect } from "bun:test";

import type { TuiComposerState, TuiSelectState } from "../../../src/host/composerState.ts";
import type { TuiTerminalState } from "../../../src/host/terminalState.ts";
import { step } from "../../steps.ts";
import { objectRows } from "../design.ts";
import { thread } from "../fakeClient.ts";
import { chooseCommand } from "../threadUi.ts";
import { pressKey, settle, type World } from "../world.ts";
import { openDrawer, printToTerminal, type TerminalWorld } from "./terminal.steps.ts";

const composer = (ctx: World) => ctx.host!.state.get("composer") as TuiComposerState;
const select = (ctx: World) => ctx.host!.state.get("select") as TuiSelectState;
const terminal = (ctx: World) => ctx.host!.state.get("terminal") as TuiTerminalState;
const screen = (ctx: World) =>
  terminal(ctx)
    .lines.map((line) => line.chunks.map((part) => part.text).join(""))
    .join("\n");

// --- An excerpt for the prompt ---------------------------------------------------------

const OUTPUT = ["$ bun test", "cart.test.ts:", "FAIL total adds tax: expected 10.50, got 10.51"];

step("the terminal client shows a thread's terminal with output", async (ctx: TerminalWorld) => {
  await openDrawer(ctx);
  // The prompt belongs to a thread the server knows.
  ctx.fake!.emitThread(thread());
  await printToTerminal(ctx, OUTPUT.join("\r\n"));
  expect(screen(ctx)).toContain(OUTPUT[2]!);
});

step("the user adds the selected output to the prompt", async (ctx: World) => {
  await chooseCommand(ctx, "Add terminal output to the prompt…");
  await settle(ctx);
  // What to take is chosen from what the screen shows: all of it here.
  expect(select(ctx).options[select(ctx).index]!.label).toBe("The screen (3 lines)");
  await pressKey(ctx, "Enter");
  await settle(ctx);
});

step("the prompt gains a removable excerpt naming the terminal", async (ctx: World) => {
  expect(composer(ctx).contexts).toHaveLength(1);
  const chip = composer(ctx).contexts[0]!;
  expect(chip).toMatchObject({ kind: "terminal", label: "Terminal 1 · 3 lines" });
  // A chip above the prompt, not the output poured into it.
  expect(composer(ctx).text).toBe("");
  const [row] = await objectRows(ctx, "composerReferences");
  expect(row!.trim()).toBe("× Terminal 1 · 3 lines");
  // Removable from the keyboard (the palette); a click on the chip does the same.
  await chooseCommand(ctx, "Remove last context chip");
  await settle(ctx);
  expect(composer(ctx).contexts).toEqual([]);
  expect(await settle(ctx)).not.toContain("Terminal 1 · 3 lines");
});

// --- Terminals from before a restart --------------------------------------------------------

step("the thread had terminals 1 and 2 before the MC restarted", async (ctx: TerminalWorld) => {
  // The MC kept both sessions and what they had printed; this client only knew the first.
  ctx.overrides = {
    ...ctx.overrides,
    listTerminalIds: () => Promise.resolve(["term-1", "term-2"]),
  };
  ctx.history = {
    "term-1": "$ bun dev\r\nVITE ready in 120 ms\r\n",
    "term-2": "$ bun test --watch\r\n42 pass\r\n",
  };
  expect(terminal(ctx).tabs.map((tab) => tab.id)).toEqual(["term-1"]);
  // The restart reads here as the connection dropping and coming back.
  ctx.fake!.emitConnection("reconnecting");
  ctx.fake!.emitConnection("connected");
  await settle(ctx);
});

step("both terminals are listed", async (ctx: World) => {
  // The drawer was open before the restart, so coming back with Ctrl+E hid it: show it.
  if (!terminal(ctx).open) await pressKey(ctx, "Ctrl+E");
  await settle(ctx);
  expect(terminal(ctx).tabs.map((tab) => tab.number)).toEqual([1, 2]);
  expect((await objectRows(ctx, "drawer")).join("\n")).toMatch(/1 ✕ +2 \+ new/);
  // Listed, not started: nothing was opened or closed on the MC for them.
  expect(ctx.fake!.calls.filter((call) => call.method === "terminalClose")).toEqual([]);
});

step("opening one shows its earlier output", async (ctx: World) => {
  ctx.host!.dispatch("terminal.select", { id: "term-2" });
  await settle(ctx);
  expect(terminal(ctx).activeId).toBe("term-2");
  expect(screen(ctx)).toContain("42 pass");
  expect((await objectRows(ctx, "drawer")).join("\n")).toContain("42 pass");
});
