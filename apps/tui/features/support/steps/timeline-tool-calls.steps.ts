// features/timeline/tool-calls.feature on the terminal client: the thread is
// the MC's projection (turnWorld.ts), read through the client's adapter.
import { expect } from "bun:test";

import { TOOL_ICONS } from "../../../src/icons.ts";
import { step } from "../../steps.ts";
import { findObject, snapshot } from "../world.ts";
import { project } from "../fakeClient.ts";
import { clickText, hostState, plain, recorded, settle } from "../threadWorld.ts";
import { readsDuration } from "./timeline-streaming.steps.ts";
import {
  addCommand,
  addItem,
  currentRun,
  itemsOf,
  lastOf,
  linesOf,
  messageItem,
  setItem,
  settleRun,
  startRun,
  turns,
  type ShownItem,
  type TurnWorld,
} from "../turnWorld.ts";

interface ToolWorld extends TurnWorld {
  changedFiles?: string[];
}

/** The newest tool call's row: the last line of the last work group that is not its toggle. */
function lastCall(ctx: TurnWorld) {
  const row = lastOf(ctx, "work").lines.findLast(isCallRow);
  if (!row) throw new Error("the work group shows no tool call");
  return row;
}

// A command's row opens its output; its output lines below it are not calls.
const isCallRow = (line: ShownItem["lines"][number]) =>
  line.action === null || line.action === "command.toggle";
const callRows = (group: ShownItem) => group.lines.filter(isCallRow);

// --- groups of calls -------------------------------------------------------------------

step("the agent has run five tool calls in a row in the running turn", async (ctx: TurnWorld) => {
  await startRun(ctx);
  for (let n = 1; n <= 5; n += 1) await addCommand(ctx, n);
});

step("the latest tool call is shown", async (ctx: TurnWorld) => {
  expect(plain(lastCall(ctx).text)).toContain("bun test cart-5");
  expect(await snapshot(ctx)).toContain("bun test cart-5");
});

step("the other four are behind {string}", async (ctx: TurnWorld, label: string) => {
  const group = lastOf(ctx, "work");
  expect(callRows(group)).toHaveLength(1);
  expect(plain(group.lines.at(-1)!.right!.text)).toBe(label);
  const screen = await snapshot(ctx);
  expect(screen).toContain(label);
  for (const hidden of [1, 2, 3, 4]) expect(screen).not.toContain(`bun test cart-${hidden}`);
});

step("the user shows the previous tool calls", async (ctx: TurnWorld) => {
  await clickText(ctx, "previous tool calls");
});

step("all five tool calls are shown", async (ctx: TurnWorld) => {
  const group = lastOf(ctx, "work");
  expect(callRows(group)).toHaveLength(5);
  const screen = await snapshot(ctx);
  for (const shown of [1, 2, 3, 4, 5]) expect(screen).toContain(`bun test cart-${shown}`);
});

step("the user hides them again", async (ctx: TurnWorld) => {
  await clickText(ctx, "Show fewer tool calls");
});

// The running group is one row: the latest call, the count of the ones before it beside it.
async function oneLiveRow(ctx: TurnWorld, call: string, label: string) {
  const group = lastOf(ctx, "work");
  expect(group.lines).toHaveLength(1);
  const [row] = group.lines;
  expect(plain(row!.text)).toContain(call);
  expect(plain(row!.right!.text)).toBe(label);
  const screen = (await snapshot(ctx)).split("\n").find((shown) => shown.includes(call));
  expect(screen).toContain(label);
}

step(
  "one row shows the latest tool call with {string} beside it",
  async (ctx: TurnWorld, label: string) => oneLiveRow(ctx, "bun test cart-5", label),
);

step("the agent starts a sixth tool call", async (ctx: TurnWorld) => {
  await addCommand(ctx, 6);
});

step(
  "the row shows the sixth tool call with {string} beside it",
  async (ctx: TurnWorld, label: string) => oneLiveRow(ctx, "bun test cart-6", label),
);

step("the user opens the row", async (ctx: TurnWorld) => {
  await clickText(ctx, "previous tool calls");
});

step("all six tool calls are shown", async (ctx: TurnWorld) => {
  expect(callRows(lastOf(ctx, "work"))).toHaveLength(6);
  const screen = await snapshot(ctx);
  for (const shown of [1, 2, 3, 4, 5, 6]) expect(screen).toContain(`bun test cart-${shown}`);
});

// --- how a call ended ------------------------------------------------------------------

step("the agent's tool call is still running", async (ctx: TurnWorld) => {
  await startRun(ctx);
  await addCommand(ctx, 1, "running");
});

step("the agent's tool call failed", async (ctx: TurnWorld) => {
  await startRun(ctx);
  await addCommand(ctx, 1, "failed");
});

step("the agent's tool call was interrupted", async (ctx: TurnWorld) => {
  await startRun(ctx);
  await addCommand(ctx, 1, "interrupted");
});

step("the agent's tool call was declined by the user", async (ctx: TurnWorld) => {
  await startRun(ctx);
  (await turns(ctx)).requests.push({
    id: "request-1",
    kind: "command",
    status: "resolved",
    decision: "decline",
    responseCapability: { type: "live", providerSessionId: "session-1" },
  });
  await addItem(ctx, "approval_request", {
    requestId: "request-1",
    requestKind: "command",
    prompt: "Run rm -rf dist?",
  });
});

step("the call is marked {string}", async (ctx: TurnWorld, status: string) => {
  // icon, label, then the status glyph and word.
  const [, , mark] = lastCall(ctx).text.chunks;
  expect(mark?.text.trim().split(" ").slice(1).join(" ")).toBe(status);
  expect(await snapshot(ctx)).toContain(mark!.text.trim());
});

// --- what kind of work a call was ------------------------------------------------------

const CALLS: Record<string, [type: string, fields: Record<string, unknown>]> = {
  "ran a command": ["command_execution", { input: "bun test", output: "ok" }],
  "changed a file": ["file_change", { fileName: "src/cart.ts" }],
  "searched the files": ["file_search", { pattern: "TODO" }],
  "searched the web": ["web_search", { patterns: ["tax rates"] }],
  "called an MCP tool": ["dynamic_tool", { toolName: "linear.search", input: {} }],
  "asked for approval": [
    "approval_request",
    { requestId: "request-1", requestKind: "command", prompt: "Run rm -rf dist?" },
  ],
};

step(/^the agent's most recent tool call (.+)$/, async (ctx: TurnWorld, call: string) => {
  const fixture = CALLS[call];
  if (!fixture) throw new Error(`unknown tool call: ${call}`);
  await startRun(ctx);
  await addItem(ctx, ...fixture);
});

step("the call is shown with the {string} icon", async (ctx: TurnWorld, icon: string) => {
  const glyphs = Object.values(TOOL_ICONS).filter((entry) => entry.webIcon === icon);
  expect(glyphs.map((entry): string => entry.webIcon)).toEqual([icon]);
  const row = lastCall(ctx);
  expect(row.text.chunks[0]!.text).toBe(`${glyphs[0]!.glyph} `);
  expect(await snapshot(ctx)).toContain(plain(row.text).slice(0, 12));
});

// --- what a finished turn's group of calls did ----------------------------------------

type Call = [type: string, fields: Record<string, unknown>];

const halC2 = (tool: string, input: Record<string, unknown>, output: unknown = {}): Call => [
  "dynamic_tool",
  { toolName: `mcp__hal-c2__${tool}`, input, output: { structuredContent: output } },
];

/** A message HAL-C2's tool sent to `thread`, or the error it answered with. */
const sendMessage = (thread: string, n: number, failed = false): Call =>
  failed
    ? [
        "dynamic_tool",
        {
          toolName: "mcp__hal-c2__hal_c2_thread_send",
          input: { threadId: thread, message: "Check the cart" },
          output: { isError: true, content: [{ type: "text", text: "thread not found" }] },
        },
      ]
    : halC2(
        "hal_c2_thread_send",
        { threadId: thread, message: "Check the cart" },
        {
          threadId: thread,
          messageId: `message-${n}`,
        },
      );

const command = (n: number, fields: Record<string, unknown> = {}): Call => [
  "command_execution",
  { input: `bun test cart-${n}`, output: "ok", exitCode: 0, ...fields },
];
const edit = (fileName: string): Call => ["file_change", { fileName }];
const webSearch: Call = ["web_search", { patterns: ["tax rates"] }];
const fileRead: Call = [
  "file_search",
  { pattern: "src/cart.ts", results: [{ fileName: "src/cart.ts" }] },
];
// A thought with no words, which a lone row labels "Thought" (streaming.feature reads one with words).
const thought: Call = ["reasoning", { text: "" }];
const through = (name: string, kind: string, key = name.toLowerCase()): Call => [
  "dynamic_tool",
  { toolName: "navigate", input: {}, toolSource: { key, name, kind } },
];
const times = <T>(count: number, make: (n: number) => T) =>
  Array.from({ length: count }, (_, index) => make(index + 1));

const GROUPS: Record<string, Call[]> = {
  "one file read": [fileRead],
  "edits to three different files": [edit("src/a.ts"), edit("src/b.ts"), edit("src/c.ts")],
  "two edits to the same file": [edit("src/cart.ts"), edit("src/cart.ts")],
  "one command": [command(1)],
  "two web searches": [webSearch, webSearch],
  "one search of the project's code": [["file_search", { pattern: "TODO" }]],
  "three browser calls": times(3, () => halC2("preview_click", { selector: "#buy" })),
  "two device controls": times(2, () => halC2("device_screenshot", {})),
  "one tool with no more specific kind": [
    ["dynamic_tool", { toolName: "linear.search", input: {} }],
  ],
  "two progress updates": times(2, (n): Call => ["system_notice", { message: `Step ${n}` }]),
  "one thread the agent created": [["thread_created", { threadId: "thread-2" }]],
  "two links of a pull request and one check": [
    ...times(2, (n) => halC2("link_pull_request", { url: `https://github.com/o/r/pull/${n}` })),
    halC2("list_thread_pull_requests", {}),
  ],
  "one pull request unlinked": [
    halC2("unlink_pull_request", { url: "https://github.com/o/r/pull/1" }),
  ],
  "two checks of the linked pull requests": times(2, () => halC2("list_thread_pull_requests", {})),
  "two thoughts and one command": [thought, thought, command(1)],
  "one thought": [thought],
  "three thoughts": [thought, thought, thought],
  'two calls through the "Chrome" integration and one command': [
    through("Chrome", "integration"),
    through("Chrome", "integration"),
    command(1),
  ],
  'calls through the "Chrome" and "Slack" integrations': [
    through("Chrome", "integration"),
    through("Slack", "integration"),
  ],
  'calls through the "Chrome", "Slack" and "Linear" integrations': [
    through("Chrome", "integration"),
    through("Slack", "integration"),
    through("Linear", "integration"),
  ],
  "calls through the built-in browser and computer controls": [
    through("Browser", "browser"),
    through("Computer Use", "computer"),
  ],
  "commands, file changes and four web searches": [
    command(1),
    command(2),
    edit("src/cart.ts"),
    ...times(4, () => webSearch),
  ],
  "two tasks delegated to subagents": times(2, (n) =>
    halC2("delegate_task", { prompt: "Survey the cart" }, { taskId: `task-${n}` }),
  ),
  "the same task cancelled twice": times(2, () => halC2("task_cancel", { taskId: "task-1" })),
  "one thread read and the same thread read again": times(2, () =>
    halC2("hal_c2_thread_read", { threadId: "thread-2" }),
  ),
  "one wait on a thread": [halC2("hal_c2_thread_wait", { threadId: "thread-2" })],
  "one scheduled task created": [
    halC2("schedule_task", { prompt: "Check CI" }, { scheduledTaskId: "schedule-1" }),
  ],
  "one scheduled task run on request": [
    halC2("run_scheduled_task_now", { scheduledTaskId: "schedule-1" }),
  ],
  "a queued message edited and another reordered": [
    halC2("hal_c2_queue_edit", { queuedRunId: "queued-1", message: "Add tax" }),
    halC2("hal_c2_queue_reorder", { queuedRunId: "queued-2", position: 0 }),
  ],
  "a pending question answered": [
    halC2("hal_c2_pending_request_respond", { requestId: "request-1", answer: "yes" }),
  ],
  "one handoff to a worktree": [
    halC2("hal_c2_worktree_handoff", { worktreePath: "/workspace/project-one-tax" }),
  ],
  "one project registered and one cloned": [
    halC2("hal_c2_project_create", { workspaceRoot: "/workspace/shop" }, { projectId: "p2" }),
    halC2("hal_c2_project_clone", { url: "https://github.com/o/r", cwd: "/workspace/r" }),
  ],
  "two attachments sent to one thread": [
    halC2(
      "hal_c2_thread_send_attachments",
      { threadId: "thread-2", attachments: ["a.png", "b.png"] },
      { threadId: "thread-2", messageId: "message-1" },
    ),
  ],
  // Sends that named no thread, refused before they reached one.
  "two attempts to send a message that both failed": times(2, (): Call => [
    "dynamic_tool",
    {
      toolName: "mcp__hal-c2__hal_c2_thread_send",
      input: { message: "Check the cart" },
      output: { isError: true, content: [{ type: "text", text: "threadId is required" }] },
    },
  ]),
  "a command that exited with a failure": [command(1, { status: "failed", exitCode: 1 })],
};

/** A finished turn whose work is `calls`, ending with the agent's reply. */
async function finishTurn(ctx: TurnWorld, calls: ReadonlyArray<Call>): Promise<void> {
  await startRun(ctx);
  for (const call of calls) await addItem(ctx, ...call);
  await addItem(ctx, "assistant_message", { text: "Done." });
  await settleRun(ctx, "completed", 30);
}

/** The finished turn's group of calls, its summary first. */
const group = (ctx: TurnWorld) => linesOf(lastOf(ctx, "work"));
const summary = (ctx: TurnWorld) => group(ctx)[0]!.slice(2).replace(/ ✗$/, "");
/** Whether the group is one call, which reads as itself instead of a summary. */
const lone = (ctx: TurnWorld) => !/^[▸▾] /.test(group(ctx)[0]!);
/** What the group reads as: its summary, or a lone call's label. */
const groupLine = (ctx: TurnWorld) =>
  lone(ctx) ? lastOf(ctx, "work").lines[0]!.text.chunks[1]!.text : summary(ctx);

step("the agent ran two commands and sent messages to three threads", (ctx: TurnWorld) =>
  finishTurn(ctx, [command(1), command(2), ...times(3, (n) => sendMessage(`thread-${n}`, n))]),
);

step("the agent ran commands, changed files, searched the web and read files", (ctx: TurnWorld) =>
  finishTurn(ctx, [
    ["dynamic_tool", { toolName: "Read", input: { path: "src/cart.ts" } }],
    webSearch,
    command(1),
    command(2),
    edit("src/cart.ts"),
  ]),
);

step("the agent sent three messages and one of them failed", (ctx: TurnWorld) =>
  finishTurn(ctx, [
    sendMessage("thread-2", 1),
    sendMessage("thread-2", 2),
    sendMessage("thread-3", 3, true),
  ]),
);

// A thought, which a summary does not count, keeps a lone call from reading as itself.
step(
  /^the activity group holds (a thought and )?(.+)$/,
  (ctx: TurnWorld, withThought: string | undefined, calls: string) => {
    const fixture = GROUPS[calls];
    if (!fixture) throw new Error(`unknown activity group: ${calls}`);
    return finishTurn(ctx, withThought ? [thought, ...fixture] : fixture);
  },
);

async function openFold(ctx: TurnWorld) {
  const fold = linesOf(lastOf(ctx, "fold"))[0]!;
  if (fold.startsWith("▸ ")) await clickText(ctx, fold.slice(2));
}

step("the user reads the activity group", async (ctx: TurnWorld) => {
  await openFold(ctx);
  // The group stays closed: one line saying what its calls did, or a lone call's own.
  expect(group(ctx)).toHaveLength(1);
  if (!lone(ctx)) expect(group(ctx)[0]!.startsWith("▸ ")).toBe(true);
});

async function toggleGroup(ctx: TurnWorld) {
  await clickText(ctx, summary(ctx));
}

step("the user opens the activity group", async (ctx: TurnWorld) => {
  await openFold(ctx);
  await toggleGroup(ctx);
});

step("it reads {string}", async (ctx: TurnWorld & { durationShown?: boolean }, text: string) => {
  if (ctx.durationShown) return readsDuration(ctx, text);
  expect(groupLine(ctx)).toBe(text);
  expect(await snapshot(ctx)).toContain(text);
});

step("it ends with {string}", (ctx: TurnWorld, text: string) => {
  // Mid-sentence the summary lower-cases what it adds.
  expect(summary(ctx).toLowerCase().endsWith(text.toLowerCase())).toBe(true);
});

step("the summary names commands and file changes", (ctx: TurnWorld) => {
  expect(summary(ctx)).toStartWith("Ran 2 commands, changed 1 file, and ");
});

step("it counts the rest instead of naming them", (ctx: TurnWorld) => {
  expect(summary(ctx)).toBe("Ran 2 commands, changed 1 file, and performed 2 other actions");
});

step("the summary counts two messages sent", async (ctx: TurnWorld) => {
  expect(summary(ctx)).toBe("Sent 2 messages to 1 thread");
  expect(group(ctx)[0]!.endsWith(" ✗")).toBe(true);
});

step("the group is marked as having a failure", async (ctx: TurnWorld) => {
  // A lone call is marked on its own row.
  if (lone(ctx)) {
    expect(plain(lastCall(ctx).text)).toContain("✗ Failed");
    return;
  }
  const head = lastOf(ctx, "work").lines[0]!.text.chunks;
  expect(head.at(-1)!.text).toBe(" ✗");
  expect(await snapshot(ctx)).toContain(`${summary(ctx)} ✗`);
});

/** The opened group's row for the call labelled `label`. */
function callRow(ctx: TurnWorld, label: string): string {
  const row = group(ctx).find((line) => line.includes(label));
  if (!row) throw new Error(`the group shows no call "${label}": ${group(ctx).join(" | ")}`);
  return row;
}

step("the provider reported a HAL-C2 tool call as completed", async (ctx: TurnWorld) => {
  await startRun(ctx);
  await addItem(ctx, ...halC2("hal_c2_thread_read", { threadId: "thread-2" }));
});

step("the tool's answer says it is an error", async (ctx: TurnWorld) => {
  const { items } = await turns(ctx);
  const call = items.at(-1)!;
  call.output = { isError: true, content: [{ type: "text", text: "thread not found" }] };
  await addItem(ctx, "assistant_message", { text: "Done." });
  await settleRun(ctx, "completed", 30);
});

step("the call is shown as failed", (ctx: TurnWorld) => {
  // The call is alone in its group, which reads as the call.
  expect(callRow(ctx, "Read a HAL-C2 thread")).toContain("✗ Failed");
});

step("the provider reported a command as completed", async (ctx: TurnWorld) => {
  await startRun(ctx);
  await addItem(ctx, "command_execution", { input: "cat src/x.ts", status: "completed" });
});

step("the command's output says {string}", async (ctx: TurnWorld, output: string) => {
  const { items } = await turns(ctx);
  const call = items.at(-1)!;
  call.output = output;
  // The MC reads the output when the command finishes (turn_writer.ex), as legacy
  // toolOutputIndicatesFailure did: an exit code of 0 is not a failure.
  if (!/exit code 0\b/.test(output)) call.outputIndicatesFailure = true;
  await addItem(ctx, "assistant_message", { text: "Done." });
  await settleRun(ctx, "completed", 30);
});

step(/^the command is shown as (failed|succeeded)$/, async (ctx: TurnWorld, how: string) => {
  // The command is alone in its group, which reads as the command.
  const row = plain(lastCall(ctx).text);
  expect(row).toContain(how === "failed" ? "✗ Failed" : "✓");
  expect(row.includes("✗")).toBe(how === "failed");
});

// --- a call to one of HAL-C2's own tools ------------------------------------------------

step("the agent called HAL-C2's {string} tool", async (ctx: TurnWorld, tool: string) => {
  await startRun(ctx);
  await addItem(ctx, "dynamic_tool", { toolName: `mcp__hal-c2__${tool}`, input: {} });
});

step(
  "the agent called HAL-C2's thread-reading tool and the provider named it {string}",
  async (ctx: TurnWorld, name: string) => {
    await startRun(ctx);
    await addItem(ctx, "dynamic_tool", { toolName: name, input: { threadId: "thread-2" } });
  },
);

step("the agent called a tool named {string}", async (ctx: TurnWorld, name: string) => {
  await startRun(ctx);
  await addItem(ctx, "dynamic_tool", { toolName: name, input: {} });
});

step("the call reads {string}", async (ctx: TurnWorld, label: string) => {
  // icon, then the label.
  expect(lastCall(ctx).text.chunks[1]!.text).toBe(label);
  expect(await snapshot(ctx)).toContain(label);
});

step("the call is shown as an ordinary tool call", (ctx: TurnWorld) => {
  const [icon, label] = lastCall(ctx).text.chunks;
  expect(icon!.text).toBe(`${TOOL_ICONS.mcp.glyph} `);
  expect(label!.text).toBe("mcp__other-server__hal_c2_thread_read");
});

step("it does not carry HAL-C2's name for the tool", async (ctx: TurnWorld) => {
  expect(plain(lastCall(ctx).text)).not.toContain("Read a HAL-C2 thread");
  expect(await snapshot(ctx)).not.toContain("Read a HAL-C2 thread");
});

// --- opening a group --------------------------------------------------------------------

step("a collapsed group of tool calls", async (ctx: TurnWorld) => {
  await finishTurn(ctx, [
    command(1, { input: "bun test cart", exitCode: 0 }),
    command(2, { input: "bun lint", status: "failed", exitCode: 2 }),
    sendMessage("thread-2", 1),
  ]);
  await openFold(ctx);
  expect(group(ctx)).toEqual(["▸ Ran 2 commands and sent 1 message to 1 thread ✗"]);
});

step("the user opens the group", toggleGroup);
step("the user closes the group", toggleGroup);

step(
  "each call shows its command or input, its status and its exit code",
  async (ctx: TurnWorld) => {
    expect(group(ctx)[0]!.startsWith("▾ ")).toBe(true);
    expect(callRow(ctx, "bun test cart")).toContain("✓");
    expect(callRow(ctx, "bun test cart")).toContain("exit 0");
    expect(callRow(ctx, "bun lint")).toContain("✗ Failed");
    expect(callRow(ctx, "bun lint")).toContain("exit 2");
    expect(callRow(ctx, "Send to a HAL-C2 thread")).toContain('"threadId":"thread-2"');
    const screen = await snapshot(ctx);
    for (const shown of ["bun test cart", "bun lint", "exit 2"]) expect(screen).toContain(shown);
  },
);

step("the calls collapse back into the summary", async (ctx: TurnWorld) => {
  expect(group(ctx)).toEqual(["▸ Ran 2 commands and sent 1 message to 1 thread ✗"]);
  expect(await snapshot(ctx)).not.toContain("bun lint");
});

step(
  "the agent ran {string} through a shell and changed a file in the workspace",
  (ctx: TurnWorld, script: string) =>
    finishTurn(ctx, [
      command(1, { input: `bash -lc '${script}'` }),
      edit(`${project.workspaceRoot}/src/cart.ts`),
    ]),
);

step(
  "the command is labelled {string} and the file change {string}",
  async (ctx: TurnWorld, script: string, file: string) => {
    // The summary, then each call: icon, label, status.
    const [command, change] = lastOf(ctx, "work")
      .lines.slice(1)
      .map((line) => line.text.chunks[1]!.text);
    expect([command, change]).toEqual([script, file]);
    const screen = await snapshot(ctx);
    expect(screen).toContain(script);
    expect(screen).not.toContain("bash -lc");
    expect(screen).not.toContain(project.workspaceRoot);
  },
);

// --- a command's progress inside a message ----------------------------------------------

step("the agent is writing a message", async (ctx: TurnWorld) => {
  await startRun(ctx);
  await addItem(ctx, "assistant_message", {
    id: "answer",
    status: "running",
    streaming: true,
    text: "| Item | Price |\n| --- | --- |\n",
  });
});

step(
  "a command it started in the background reports progress in the middle of the message",
  async (ctx: TurnWorld) => {
    await addItem(ctx, "command_execution", {
      status: "running",
      input: "bun run watch",
      output: "[watch] rebuilt in 40ms\n",
    });
    // The provider keeps writing the same message after the progress (the MC keys
    // it by the provider's message, not by what came last).
    await setItem(ctx, "answer", {
      text: "| Item | Price |\n| --- | --- |\n| Apple | 1.20 |\n",
    });
  },
);

const assistantMessages = (ctx: TurnWorld) =>
  itemsOf(ctx, "message").filter((item) => item.key !== `message:${currentRun(ctx)}`);

step("the message stays one message", async (ctx: TurnWorld) => {
  expect(assistantMessages(ctx).map((item) => item.key)).toEqual(["answer"]);
});

step("the text the agent writes after the progress is part of it", async (ctx: TurnWorld) => {
  const shown = linesOf(messageItem(ctx, "answer")).join("\n");
  expect(shown).toContain("Item");
  expect(shown).toContain("Apple");
  expect(await snapshot(ctx)).toContain("Apple");
});

// --- an ACP agent's read, search and fetch ----------------------------------------------

// What the MC projects for each ACP tool kind (acp/thread_runtime.ex tool_kind,
// asserted by apps/server-ex/test/steps/timeline/tool_calls_steps.exs).
const ACP_PROJECTED: Record<string, [type: string, fields: Record<string, unknown>]> = {
  read: ["file_search", { pattern: "src/app.ts", results: [{ fileName: "src/app.ts" }] }],
  search: ["file_search", { pattern: "TODO" }],
  fetch: ["web_search", { patterns: ["https://example.com/docs"] }],
};

step("an ACP agent's tool call is of kind {string}", async (ctx: TurnWorld, kind: string) => {
  const projected = ACP_PROJECTED[kind];
  if (!projected) throw new Error(`unknown ACP tool kind: ${kind}`);
  await startRun(ctx);
  await addItem(ctx, ...projected);
});

// The fixture above is the projected call; the client has it once it is streamed.
step("the MC projects the call", async (ctx: TurnWorld) => {
  expect(itemsOf(ctx, "work")).toHaveLength(1);
});

const ACP_SHOWN: Record<string, { icon: string; label: string; what: string }> = {
  "a file read": { icon: TOOL_ICONS.fileRead.glyph, label: "Read file", what: "src/app.ts" },
  "a file search": { icon: TOOL_ICONS.fileSearch.glyph, label: "Searched files", what: "TODO" },
  "a web search": {
    icon: TOOL_ICONS.webSearch.glyph,
    label: "Searched the web",
    what: "https://example.com/docs",
  },
};

step(
  /^the timeline shows it as (a file read|a file search|a web search)$/,
  async (ctx: TurnWorld, kind: string) => {
    const { icon, label, what } = ACP_SHOWN[kind]!;
    const row = `${icon} ${label} ✓  ${what}`;
    expect(plain(lastCall(ctx).text)).toBe(row);
    expect(await snapshot(ctx)).toContain(row);
  },
);

// --- files a turn changed ----------------------------------------------------------------

/** A unified diff touching each path. */
const unifiedDiff = (paths: ReadonlyArray<string>): string =>
  paths
    .map((path) =>
      [
        `diff --git a/${path} b/${path}`,
        "index 1111111..2222222 100644",
        `--- a/${path}`,
        `+++ b/${path}`,
        "@@ -1,2 +1,2 @@",
        " keep",
        "-old line",
        "+new line",
      ].join("\n"),
    )
    .join("\n");

async function changeFiles(ctx: ToolWorld, paths: string[]) {
  await startRun(ctx);
  for (const path of paths) await addItem(ctx, "file_change", { fileName: path });
  await addItem(ctx, "assistant_message", { text: "Both files are updated." });
  ctx.changedFiles = paths;
}

async function completeWithCheckpoint(ctx: ToolWorld) {
  const files = ctx.changedFiles!.map((path, index) => ({
    path,
    kind: "modified",
    additions: 10 * (index + 1),
    deletions: index + 1,
  }));
  await addItem(ctx, "checkpoint", { checkpointId: "checkpoint", scopeId: "scope-1", files });
  await settleRun(ctx, "completed", 60);
}

step(
  "the agent changed {string} and {string} in one turn",
  async (ctx: ToolWorld, first: string, second: string) => {
    await changeFiles(ctx, [first, second]);
  },
);

step("the turn completes", (ctx: ToolWorld) => completeWithCheckpoint(ctx));

step("the reply lists both files with their added and removed lines", async (ctx: ToolWorld) => {
  const shown = itemsOf(ctx, "message").at(-1)!;
  const files = lastOf(ctx, "files");
  // The list belongs to the reply: it is the row right under it.
  const all = hostState(ctx, "timeline").items as ShownItem[];
  expect(all.indexOf(files)).toBe(all.indexOf(shown) + 1);
  expect(files.key).toBe(`files:${shown.key}`);
  const lines = linesOf(files);
  expect(lines[0]).toContain("changed files (2)  +30 -3");
  const screen = await snapshot(ctx);
  ctx.changedFiles!.forEach((path, index) => {
    const name = path.split("/").pop()!;
    const row = lines.find((line) => line.includes(`◦ ${name}`));
    expect(row).toBe(`    ◦ ${name}  +${10 * (index + 1)} -${index + 1}`);
    expect(screen).toContain(row!.trim());
  });
});

// An earlier turn changed another file, so "only that turn" can be told apart.
async function twoTurns(ctx: ToolWorld, paths: string[]) {
  ctx.respond ??= {};
  await changeFiles(ctx, ["src/tax.ts"]);
  await completeWithCheckpoint(ctx);
  await changeFiles(ctx, paths);
  await completeWithCheckpoint(ctx);
  ctx.respond.getTurnDiff = async (_thread, turnCount) =>
    unifiedDiff(turnCount === 2 ? paths : ["src/tax.ts"]);
  ctx.respond.getFullThreadDiff = async () => unifiedDiff(["src/tax.ts", ...paths]);
}

step("a turn changed two files", (ctx: ToolWorld) =>
  twoTurns(ctx, ["src/cart.ts", "src/checkout.ts"]),
);

step("a turn changed {string} and {string}", (ctx: ToolWorld, first: string, second: string) =>
  twoTurns(ctx, [first, second]),
);

step("the user opens that turn's changes", async (ctx: ToolWorld) => {
  await clickText(ctx, "changed files (2)");
  await settle();
});

step("the diff shows only what that turn changed, split per file", async (ctx: ToolWorld) => {
  expect(recorded(ctx, "getTurnDiff")).toEqual([["t1", 2]]);
  expect(recorded(ctx, "getFullThreadDiff")).toEqual([]);
  const diff = hostState(ctx, "diff");
  expect(diff).toMatchObject({ open: true, scopeLabel: "turn 2", focusPath: null });
  expect(diff.files.map((file: { path: string }) => file.path)).toEqual(ctx.changedFiles);
  const screen = await snapshot(ctx);
  expect(screen).toContain("diff · turn 2");
  for (const path of ctx.changedFiles!) {
    expect(findObject(ctx, `diffBody-${path}`).get("visible")).toBe(true);
    expect(screen).toContain(path);
  }
  expect(screen).not.toContain("src/tax.ts");
});

step(
  "the user opens {string} from the list of changed files",
  async (ctx: ToolWorld, path: string) => {
    await clickText(ctx, `◦ ${path.split("/").pop()}`);
    await settle();
  },
);

step("the diff shows only {string}", async (ctx: ToolWorld, path: string) => {
  expect(recorded(ctx, "getTurnDiff")).toEqual([["t1", 2]]);
  const diff = hostState(ctx, "diff");
  expect(diff).toMatchObject({ open: true, scopeLabel: "turn 2", focusPath: path });
  expect(diff.files.map((file: { path: string }) => file.path)).toEqual([path]);
  const screen = await snapshot(ctx);
  expect(screen).toContain(path);
  for (const other of ctx.changedFiles!.filter((entry) => entry !== path)) {
    expect(screen).not.toContain(other);
  }
});

// --- a command's output --------------------------------------------------------------------

interface CommandWorld extends TurnWorld {
  /** What the MC would answer `orchestration.getCommandOutput` with. */
  printed?: string;
}

/** The MC's answer to a command's output is whatever the scenario says it has printed. */
function servesOutput(ctx: CommandWorld, running: boolean) {
  ctx.fake!.override("getCommandOutput", async () => ({ output: ctx.printed ?? "", running }));
}

step("the agent's command is still running and printing", async (ctx: CommandWorld) => {
  await startRun(ctx);
  ctx.printed = "compiling\nlinking\n";
  servesOutput(ctx, true);
  await addCommand(ctx, 1, "running");
  await setItem(ctx, "call-1", { outputSize: ctx.printed.length });
});

step("the agent ran a command that finished", async (ctx: CommandWorld) => {
  await startRun(ctx);
  ctx.printed = "3 passed\n";
  servesOutput(ctx, false);
  await addCommand(ctx, 1);
});

step("the user opens the command's details", async (ctx: CommandWorld) => {
  await clickText(ctx, "bun test cart-1");
});

step("the output printed so far is shown", async (ctx: CommandWorld) => {
  const screen = await snapshot(ctx);
  expect(screen).toContain("compiling");
  expect(screen).toContain("linking");
});

step("new output is added as it is printed, at most every 100 ms", async (ctx: CommandWorld) => {
  const before = recorded(ctx, "getCommandOutput").length;
  // Five bursts of output inside one window are one fetch, not five.
  for (const word of ["a", "b", "c", "d", "e"]) {
    ctx.printed = `${ctx.printed ?? ""}${word}\n`;
    await setItem(ctx, "call-1", { outputSize: ctx.printed.length });
  }
  expect(recorded(ctx, "getCommandOutput").length - before).toBeLessThanOrEqual(2);
  // The window is the one thing here that is time itself.
  await Bun.sleep(150);
  await settle();
  const screen = await snapshot(ctx);
  for (const word of ["a", "b", "c", "d", "e"]) expect(screen).toContain(`    ${word}`);
});

step(
  "once the command ends the output is replaced by the output the thread kept",
  async (ctx: CommandWorld) => {
    ctx.printed = "the kept output\n";
    servesOutput(ctx, false);
    await setItem(ctx, "call-1", { status: "completed", output: "", exitCode: 0 });
    await Bun.sleep(150);
    await settle();
    const screen = await snapshot(ctx);
    expect(screen).toContain("the kept output");
    expect(screen).not.toContain("compiling");
  },
);

step("the command's final output is shown", async (ctx: CommandWorld) => {
  expect(recorded(ctx, "getCommandOutput").map(([, item]) => item)).toEqual(["call-1"]);
  expect(await snapshot(ctx)).toContain("3 passed");
});

step("the user expands a tool call", async (ctx: CommandWorld) => {
  await startRun(ctx);
  ctx.printed = "3 passed\n";
  servesOutput(ctx, false);
  await addCommand(ctx, 1);
  await clickText(ctx, "bun test cart-1");
  await settle();
});

step(
  "the full call shows first and its result below it, muted, without cards or labels",
  async (ctx: CommandWorld) => {
    const [call, result, ...rest] = lastOf(ctx, "work").lines;
    expect(plain(call!.text)).toContain("bun test cart-1");
    // The result is its text alone: no label, no box, set apart by being dim.
    expect(plain(result!.text).trim()).toBe("3 passed");
    expect(rest).toHaveLength(0);
    const colour = (text: NonNullable<typeof call>["text"], at: number) => text.chunks[at]!.fg;
    expect(colour(result!.text, 0)).not.toEqual(colour(call!.text, 1));
  },
);
