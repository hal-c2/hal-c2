// features/timeline/tool-calls.feature on the terminal client: the thread is
// the MC's projection (turnWorld.ts), read through the client's adapter.
import { expect } from "bun:test";

import { TOOL_ICONS } from "../../../src/icons.ts";
import { step } from "../../steps.ts";
import { findObject, snapshot } from "../world.ts";
import { clickText, hostState, plain, recorded, settle } from "../threadWorld.ts";
import {
  addCommand,
  addItem,
  itemsOf,
  lastOf,
  linesOf,
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
  const row = lastOf(ctx, "work").lines.findLast((line) => line.action === null);
  if (!row) throw new Error("the work group shows no tool call");
  return row;
}

const callRows = (group: ShownItem) => group.lines.filter((line) => line.action === null);

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
  expect(linesOf(group).at(-1)!.trim()).toBe(`⌄ ${label}`);
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
  expect(glyphs.map((entry) => entry.webIcon)).toEqual([icon]);
  const row = lastCall(ctx);
  expect(row.text.chunks[0]!.text).toBe(`${glyphs[0]!.glyph} `);
  expect(await snapshot(ctx)).toContain(plain(row.text).slice(0, 12));
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
