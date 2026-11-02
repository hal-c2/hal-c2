// features/timeline/streaming.feature on the terminal client: reasoning, turn
// folds, stopped turns and long messages, over the MC's projection (turnWorld.ts).
import { expect } from "bun:test";
import * as DateTime from "effect/DateTime";

import { step } from "../../steps.ts";
import { advance, pressKey, snapshot } from "../world.ts";
import { project } from "../fakeClient.ts";
import { chooseCommand, palette } from "../threadUi.ts";
import { clickText, hostState, plain, recorded, settle } from "../threadWorld.ts";
import {
  addCommand,
  addItem,
  itemsOf,
  lastOf,
  linesOf,
  messageItem,
  NOW_MS,
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

step("the agent reasoned in Markdown", async (ctx: StreamWorld) => {
  await startRun(ctx);
  await addItem(ctx, "reasoning", {
    id: "reasoning",
    streaming: false,
    status: "completed",
    text: "## **Checking** the `cart` total\n\n![a chart](chart.png)",
  });
});

// --- the working timer -----------------------------------------------------------------

/** The working row as the host publishes it, and as it is on screen. */
async function workingRow(ctx: StreamWorld): Promise<string> {
  const working = hostState(ctx, "timeline").working;
  expect(working).not.toBeNull();
  const text = plain(working.text);
  expect(await snapshot(ctx)).toContain(text);
  return text;
}

step("the agent has been working for {int} seconds", async (ctx: StreamWorld, seconds: number) => {
  await startRun(ctx, seconds);
  await addCommand(ctx, 1, "running");
});

step("the thread says the agent is working", async (ctx: StreamWorld) => {
  expect(await workingRow(ctx)).toMatch(/^● Working for \d+s$/);
});

// The row's own timer moves it a second on: no stream update is needed.
step("the elapsed time keeps counting", async (ctx: StreamWorld) => {
  const before = await workingRow(ctx);
  const { refreshInMs } = hostState(ctx, "timeline").working;
  expect(refreshInMs).toBeGreaterThan(0);
  expect(refreshInMs).toBeLessThanOrEqual(1000);
  ctx.nowMs! += 1000;
  await advance(ctx, refreshInMs);
  await settle();
  const seconds = (text: string) => Number(/(\d+)s$/.exec(text)![1]);
  expect(seconds(await workingRow(ctx))).toBe(seconds(before) + 1);
});

step(
  "the user sent a message and the agent's session is still starting",
  async (ctx: StreamWorld) => {
    await startRun(ctx, 7, "starting");
  },
);

step("the agent has not yet begun the turn", async (ctx: StreamWorld) => {
  const fixture = await turns(ctx);
  expect(fixture.runs.at(-1)!.startedAt).toBeNull();
});

step("the elapsed time counts from when the message was sent", async (ctx: StreamWorld) => {
  expect(await workingRow(ctx)).toBe("● Working for 7s");
});

step("it does not disappear and come back when the agent begins", async (ctx: StreamWorld) => {
  const fixture = await turns(ctx);
  const run = fixture.runs.at(-1)!;
  // The agent begins two seconds on (`turns` pins the clock, so it moves after).
  const begun = NOW_MS + 2000;
  run.status = "running";
  run.startedAt = DateTime.makeUnsafe(new Date(begun));
  ctx.nowMs = begun;
  await sync(ctx);
  expect(await workingRow(ctx)).toBe("● Working for 9s");
});

// --- durations -------------------------------------------------------------------------

const UNIT_MS: Record<string, number> = {
  millisecond: 1,
  second: 1000,
  minute: 60_000,
  hour: 3_600_000,
};

/** "1 hour 5 seconds" in milliseconds. */
function durationMs(text: string): number {
  let total = 0;
  for (const [, amount, unit] of text.matchAll(/([\d.]+) (millisecond|second|minute|hour)s?/g)) {
    total += Number(amount) * UNIT_MS[unit!]!;
  }
  return total;
}

// A finished turn folds behind how long it took: the duration the thread shows.
step(/^the thread shows a duration of (.+)$/, async (ctx: StreamWorld, duration: string) => {
  await startRun(ctx);
  await addCommand(ctx, 1);
  await addItem(ctx, "assistant_message", { id: "answer", text: ANSWER });
  await settleRun(ctx, "completed", durationMs(duration) / 1000);
});

step("it reads {string}", async (ctx: StreamWorld, shown: string) => {
  await expectFolded(ctx, `Worked for ${shown}`);
});

// --- when a message the user sent is shortened -----------------------------------------

const SENT: Record<string, string> = {
  "600 characters on one line": "a".repeat(600),
  "601 characters on one line": "a".repeat(601),
  "8 short lines": Array.from({ length: 8 }, (_, n) => `line ${n + 1}`).join("\n"),
  "9 short lines": Array.from({ length: 9 }, (_, n) => `line ${n + 1}`).join("\n"),
  "only spaces and blank lines": Array.from({ length: 12 }, () => "   ").join("\n"),
};

step(/^the user sent a message of (.+)$/, async (ctx: StreamWorld, kind: string) => {
  const text = SENT[kind];
  if (text === undefined) throw new Error(`no message of ${kind}`);
  await startRun(ctx);
  const fixture = await turns(ctx);
  fixture.messages[fixture.messages.length - 1]!.text = text;
});

step("the user looks at it in the conversation", async (ctx: StreamWorld) => {
  await sync(ctx);
});

step(/^it is (shown in full|shortened)$/, async (ctx: StreamWorld, shown: string) => {
  const sent = lastOf(ctx, "message");
  const screen = await snapshot(ctx);
  if (shown === "shortened") {
    expect(sent.clip).not.toBeNull();
    expect(linesOf(sent).at(-1)).toBe("⌄ Show full message");
    // The bubble stays as narrow as its text, so the toggle may wrap.
    expect(screen).toContain("⌄ Show");
  } else {
    expect(sent.clip).toBeNull();
    expect(linesOf(sent).join("\n")).not.toContain("Show full message");
    expect(screen).not.toContain("Show full message");
  }
});

// --- running a reply's shell command -----------------------------------------------------

const SHELL_BLOCKS: Record<string, { readonly fence: string; readonly streaming?: boolean }> = {
  "a single-line shell command": { fence: "```bash\nbun test\n```" },
  "a shell command still streaming": { fence: "```bash\nbun test\n```", streaming: true },
  "a shell command that spans several lines": { fence: "```bash\ncd web\nbun test\n```" },
  "an empty shell block": { fence: "```bash\n\n```" },
  "a shell command ending in a backslash": { fence: "```bash\nbun test \\\n```" },
  "a Python snippet": { fence: "```python\nprint('tax')\n```" },
};

const SCRIPTS = [
  { id: "test", name: "Test", command: "bun test", icon: "test", runOnWorktreeCreate: false },
  { id: "lint", name: "Lint", command: "bun run lint", icon: "lint", runOnWorktreeCreate: false },
];

step(/^the agent's reply has (.+) in a code block$/, async (ctx: StreamWorld, kind: string) => {
  const block = SHELL_BLOCKS[kind];
  if (!block) throw new Error(`no code block for ${kind}`);
  await turns(ctx);
  const current = ctx.fake!.latestShell();
  ctx.fake!.emitShell({
    ...current,
    projects: current.projects.map((entry) => ({ ...entry, scripts: SCRIPTS })),
  } as never);
  await settle();
  // The user last ran Lint, so the palette offers it first.
  ctx.host!.dispatch("script.run", { id: "lint" });
  await settle();
  ctx.fake!.calls.length = 0;
  ctx.fake!.terminals.clear();
  await startRun(ctx);
  const id = await addItem(ctx, "assistant_message", {
    id: "answer",
    text: `Run the tests:\n\n${block.fence}`,
    streaming: block.streaming === true,
  });
  if (!block.streaming) {
    await settleRun(ctx, "completed", 5);
    return;
  }
  await setItem(ctx, id, { streaming: true });
});

step("the user runs the command from its code block", async (ctx: StreamWorld) => {
  await clickText(ctx, "▶ Run");
  await settle();
});

step(
  "the command runs in the thread's terminal in the thread's folder",
  async (ctx: StreamWorld) => {
    const opened = ctx.fake!.calls.find((call) => call.method === "terminalOpen");
    expect(opened).toBeDefined();
    const input = opened!.args[0] as { threadId: string; cwd: string; worktreePath: string | null };
    expect(input.threadId).toBe(ctx.thread!.id);
    expect(input.cwd).toBe(ctx.thread!.worktreePath ?? project.workspaceRoot);
    const writes = [...ctx.fake!.terminals.values()].flatMap((terminal) => terminal.writes);
    expect(writes).toEqual(["bun test\r"]);
  },
);

step("the project's selected script is not changed", async (ctx: StreamWorld) => {
  await pressKey(ctx, "Ctrl+K");
  const titles = palette(ctx).commands.map((command) => command.title);
  expect(titles).toContain("Run Lint");
  expect(titles).not.toContain("Run Chat code block");
  await pressKey(ctx, "Escape");
});

step("the code block offers no run action", async (ctx: StreamWorld) => {
  const answer = messageItem(ctx, "answer");
  expect(answer.lines.some((line) => line.right && plain(line.right.text) === "▶ Run")).toBe(false);
  expect(await snapshot(ctx)).not.toContain("▶ Run");
});
