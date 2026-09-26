// Steps for reading a thread (features/tui/timeline.feature): the timeline,
// working indicator, changed files, diff viewer and revert picker.
import { expect } from "bun:test";
import { TextAttributes } from "@opentui/core";

import { step } from "../../steps.ts";
import { advance, findObject, geometry, pressKey, snapshot } from "../world.ts";
import {
  activity,
  checkpoint,
  clickText,
  command,
  deferred,
  hostState,
  latestTurn,
  message,
  openThread,
  recorded,
  plain,
  settle,
  timelineText,
  updateThread,
  type ThreadWorld,
} from "../threadWorld.ts";

type Line = {
  text: {
    chunks: Array<{ text: string; attributes?: number; link?: { url: string }; fg?: unknown }>;
  };
};
type Item = { key: string; kind: string; align: string; boxed: boolean; lines: Line[] };

const items = (ctx: ThreadWorld): Item[] => hostState(ctx, "timeline").items;
const itemText = (item: Item) => item.lines.map((line) => plain(line.text)).join("\n");
const allChunks = (ctx: ThreadWorld) =>
  items(ctx).flatMap((item) => item.lines.flatMap((line) => line.text.chunks));

step("the terminal client is open on a thread", async (ctx: ThreadWorld) => {
  await openThread(ctx);
});

// --- interleaving and tool rows -----------------------------------------------

step(
  "the agent wrote a message, ran two commands, then wrote another message",
  async (ctx: ThreadWorld) => {
    await updateThread(ctx, () => ({
      messages: [
        message("m1", "assistant", "Looking at the build.", 1),
        message("m2", "assistant", "The build passes now.", 10),
      ],
      activities: [command("a1", 2, "bun install"), command("a2", 3, "bun run build")],
    }));
  },
);

step(
  "the timeline shows the message, one group of two tool calls, then the second message",
  async (ctx: ThreadWorld) => {
    const shown = items(ctx);
    expect(shown.map((item) => item.kind)).toEqual(["message", "work", "message"]);
    expect(itemText(shown[0]!)).toBe("Looking at the build.");
    expect(itemText(shown[1]!)).toContain("bun run build");
    expect(itemText(shown[1]!)).toContain("+1 previous tool call");
    expect(itemText(shown[2]!)).toBe("The build passes now.");
    const screen = await snapshot(ctx);
    expect(screen.indexOf("Looking at the build.")).toBeLessThan(screen.indexOf("bun run build"));
    expect(screen.indexOf("bun run build")).toBeLessThan(screen.indexOf("The build passes now."));
  },
);

step("a message and a tool call share a timestamp", async (ctx: ThreadWorld) => {
  await updateThread(ctx, () => ({
    messages: [message("m1", "assistant", "Checking the tests.", 5)],
    activities: [command("a1", 5, "bun test")],
  }));
});

step("the message is shown before the tool call", async (ctx: ThreadWorld) => {
  expect(items(ctx).map((item) => item.kind)).toEqual(["message", "work"]);
  const screen = await snapshot(ctx);
  expect(screen.indexOf("Checking the tests.")).toBeLessThan(screen.indexOf("bun test"));
});

const TOOL_KINDS: Record<string, Parameters<typeof activity>[2]> = {
  command: { itemType: "command_execution", detail: "ls" },
  "file read": { requestKind: "file-read", summary: "Read file", detail: "src/a.ts" },
  "file change": { itemType: "file_change", summary: "Edited file", detail: "src/a.ts" },
  "image view": { itemType: "image_view", summary: "Viewed image", detail: "logo.png" },
  "web search": { itemType: "web_search", summary: "Searched the web", detail: "opentui" },
  MCP: { itemType: "mcp_tool_call", summary: "Called MCP tool", detail: "linear.search" },
  dynamic: { itemType: "dynamic_tool_call", summary: "Called tool", detail: "custom" },
  "user input": { kind: "user-input.resolved", tone: "info", summary: "User answered" },
  thinking: { kind: "task.progress", tone: "info", summary: "Thinking", detail: "Planning" },
  failed: { tone: "error", summary: "Command failed", detail: "exit 1", status: "failed" },
};

step(/^the agent made an? (.+) tool call$/, async (ctx: ThreadWorld, kind: string) => {
  const options = TOOL_KINDS[kind];
  if (!options) throw new Error(`no fixture for a "${kind}" tool call`);
  await updateThread(ctx, () => ({ activities: [activity("tool-1", 1, options)] }));
});

step("its row starts with {string}", async (ctx: ThreadWorld, icon: string) => {
  const work = items(ctx).filter((item) => item.kind === "work");
  expect(work).toHaveLength(1);
  expect(plain(work[0]!.lines[0]!.text).startsWith(`${icon} `)).toBe(true);
  expect(await snapshot(ctx)).toContain(`${icon} `);
});

step("a tool call reported started, progress and completed", async (ctx: ThreadWorld) => {
  const data = { toolCallId: "call-1" };
  const base = { itemType: "command_execution", summary: "Ran command", detail: "bun test", data };
  await updateThread(ctx, () => ({
    activities: [
      activity("s", 1, { ...base, kind: "tool.started" }),
      activity("p", 2, { ...base, kind: "tool.updated", status: "inProgress" }),
      activity("c", 3, { ...base, kind: "tool.completed", status: "completed" }),
    ],
  }));
});

step(
  "the timeline shows one row for that tool call with its final state",
  async (ctx: ThreadWorld) => {
    const work = items(ctx).filter((item) => item.kind === "work");
    expect(work).toHaveLength(1);
    expect(work[0]!.lines.map((line) => plain(line.text))).toEqual(["$ Ran command ✓  bun test"]);
    const screen = await snapshot(ctx);
    expect(screen).toContain("$ Ran command ✓  bun test");
    expect(screen).not.toContain("⟳");
  },
);

step(
  "the agent changed {string} and two other files in one tool call",
  async (ctx: ThreadWorld, first: string) => {
    await updateThread(ctx, () => ({
      activities: [
        activity("edit", 1, {
          itemType: "file_change",
          summary: "Edited files",
          data: { changes: [{ path: first }, { path: "src/b.ts" }, { path: "src/c.ts" }] },
        }),
      ],
    }));
  },
);

step(
  "the row shows {string} and that two more files changed",
  async (ctx: ThreadWorld, first: string) => {
    expect(await snapshot(ctx)).toContain(`${first} +2 more`);
  },
);

// --- working and streaming ----------------------------------------------------

step("the agent is working", async (ctx: ThreadWorld) => {
  await updateThread(ctx, () => ({
    session: { status: "running" } as never,
    latestTurn: latestTurn("turn-1", 0),
    messages: [message("u1", "user", "Fix the build", 0, { turnId: "turn-1" } as never)],
  }));
});

step(
  "the timeline shows that the agent is working with the elapsed seconds",
  async (ctx: ThreadWorld) => {
    const working = hostState(ctx, "timeline").working;
    expect(working.elapsedSeconds).toBeGreaterThanOrEqual(600);
    expect(await snapshot(ctx)).toMatch(/● Working… \d+s/);
  },
);

step("the indicator does not repaint on a timer", async (ctx: ThreadWorld) => {
  const before = await snapshot(ctx);
  const published = hostState(ctx, "timeline");
  await advance(ctx, 5000);
  expect(hostState(ctx, "timeline")).toBe(published);
  expect(await snapshot(ctx)).toBe(before);
});

const replyLines = (count: number) =>
  Array.from({ length: count }, (_, index) => `Reply line ${index + 1}.`).join("\n\n");

step("the agent is writing a reply", async (ctx: ThreadWorld) => {
  await updateThread(ctx, () => ({
    session: { status: "running" } as never,
    latestTurn: latestTurn("turn-1", 0),
    messages: [message("r1", "assistant", replyLines(10), 1, { streaming: true } as never)],
  }));
});

step("the timeline is scrolled to the latest entry", async (ctx: ThreadWorld) => {
  expect(hostState(ctx, "timeline").showingLatest).toBe(true);
  expect(await snapshot(ctx)).toContain("Reply line 10.");
});

step("more of the reply arrives", async (ctx: ThreadWorld) => {
  await updateThread(ctx, (detail) => ({
    messages: detail.messages.map((entry) => ({ ...entry, text: replyLines(40) })),
  }));
});

step("the timeline shows the new text without the user scrolling", async (ctx: ThreadWorld) => {
  const screen = await snapshot(ctx);
  expect(screen).toContain("Reply line 40.");
  expect(screen).not.toContain("Reply line 1.\n");
});

// --- work groups ----------------------------------------------------------------

const TWELVE = Array.from({ length: 12 }, (_, index) => `step-${index + 1}`);

async function twelveToolCalls(ctx: ThreadWorld) {
  await updateThread(ctx, () => ({
    session: { status: "running" } as never,
    latestTurn: latestTurn("turn-1", 0),
    messages: [message("u1", "user", "Run every step", 0, { turnId: "turn-1" } as never)],
    activities: TWELVE.map((name, index) =>
      command(`c${index}`, index + 1, `run ${name}`, "turn-1"),
    ),
  }));
}

step("the running turn has made twelve tool calls", twelveToolCalls);
step("the running turn hides earlier tool calls", twelveToolCalls);

step("only the most recent tool calls are shown", async (ctx: ThreadWorld) => {
  const screen = await snapshot(ctx);
  expect(screen).toContain("run step-12");
  expect(screen).not.toContain("run step-1 ");
  expect(screen).not.toContain("run step-11");
});

step(
  "a row offers the previous tool calls behind {string}",
  async (ctx: ThreadWorld, label: string) => {
    const pattern = new RegExp(label.replace("+N", "\\+(\\d+)"));
    const match = (await snapshot(ctx)).match(pattern);
    expect(match).not.toBeNull();
    expect(Number(match![1])).toBe(11);
  },
);

step("the user expands the previous tool calls", async (ctx: ThreadWorld) => {
  await clickText(ctx, "previous tool calls");
});

step("every tool call in the turn is shown", async (ctx: ThreadWorld) => {
  const text = timelineText(ctx).join("\n");
  for (const name of TWELVE) expect(text).toContain(`run ${name}`);
  expect(await snapshot(ctx)).toContain("run step-12");
});

step("the user can show fewer again", async (ctx: ThreadWorld) => {
  await clickText(ctx, "Show fewer tool calls");
  const screen = await snapshot(ctx);
  expect(screen).toContain("+11 previous tool calls");
  expect(screen).not.toContain("run step-11");
});

// --- turn folds -------------------------------------------------------------------

step("a turn has finished after two minutes of tool work", async (ctx: ThreadWorld) => {
  const turnId = "turn-1";
  await updateThread(ctx, () => ({
    latestTurn: latestTurn(turnId, 0, 120, "final"),
    messages: [
      message("u1", "user", "Tidy the imports", 0, { turnId } as never),
      message("note", "assistant", "Scanning the modules first.", 5, { turnId } as never),
      message("final", "assistant", "Imports are tidy.", 120, { turnId } as never),
    ],
    activities: [
      command("c1", 10, "rg import", turnId),
      command("c2", 60, "bun run lint --fix", turnId),
    ],
  }));
});

step(
  "its tool calls and commentary fold behind a {string} row with the duration",
  async (ctx: ThreadWorld, label: string) => {
    const screen = await snapshot(ctx);
    expect(screen).toContain(`▸ ${label} 2m`);
    expect(screen).not.toContain("Scanning the modules first.");
    expect(screen).not.toContain("rg import");
  },
);

step("the final message stays visible", async (ctx: ThreadWorld) => {
  expect(await snapshot(ctx)).toContain("Imports are tidy.");
});

step("a finished turn that is only a final message", async (ctx: ThreadWorld) => {
  const turnId = "turn-1";
  await updateThread(ctx, () => ({
    latestTurn: latestTurn(turnId, 0, 20, "final"),
    messages: [
      message("u1", "user", "What time is it?", 0, { turnId } as never),
      message("final", "assistant", "Late.", 20, { turnId } as never),
    ],
  }));
});

step("no {string} row is shown", async (ctx: ThreadWorld, label: string) => {
  const screen = await snapshot(ctx);
  expect(screen).toContain("Late.");
  expect(screen).not.toContain(label);
});

// --- header and context window --------------------------------------------------

const contextUpdate = (usedTokens: number, maxTokens?: number) =>
  activity("ctx", 1, {
    kind: "context-window.updated",
    tone: "info",
    summary: "Context window updated",
    payload: { usedTokens, ...(maxTokens !== undefined && { maxTokens }) },
  });

step(
  "the thread is in plan mode and has used part of its context window",
  async (ctx: ThreadWorld) => {
    await updateThread(ctx, () => ({
      interactionMode: "plan",
      activities: [contextUpdate(50_000, 200_000)],
    }));
  },
);

step("the header shows {string}", async (ctx: ThreadWorld, text: string) => {
  const header = hostState(ctx, "timeline").header;
  expect(plain(header.right.text)).toContain(`· ${text}`);
  expect(findObject(ctx, "conversationStatus").get("visible")).toBe(true);
  const firstLine = (await snapshot(ctx)).split("\n")[0]!;
  expect(firstLine).toContain(`· ${text}`);
});

step("it shows a meter with the tokens used and the percentage", async (ctx: ThreadWorld) => {
  expect(await snapshot(ctx)).toContain("context  ▓▓░░░░░░ 25% · 50k/200k");
});

step("the provider reports tokens used but no maximum", async (ctx: ThreadWorld) => {
  await updateThread(ctx, () => ({ activities: [contextUpdate(12_345)] }));
});

step("the meter shows the tokens used without a percentage", async (ctx: ThreadWorld) => {
  const screen = await snapshot(ctx);
  expect(screen).toContain("context  12k used");
  expect(screen).not.toMatch(/context .*%/);
});

// --- long threads -----------------------------------------------------------------

step("a thread with hundreds of turns", async (ctx: ThreadWorld) => {
  const messages = Array.from({ length: 300 }, (_, index) =>
    message(`m${index}`, index % 2 === 0 ? "user" : "assistant", `Entry ${index}`, index),
  );
  await updateThread(ctx, () => ({ messages }));
});

step("only the latest page of the timeline is drawn", async (ctx: ThreadWorld) => {
  const timeline = hostState(ctx, "timeline");
  expect(timeline.rowCount).toBe(300);
  expect(timeline.windowEnd - timeline.windowStart).toBe(80);
  expect(timeline.items[0].key).toBe("pager:older");
  expect(plain(timeline.items[0].lines[0].text)).toBe("▴ 220 earlier entries");
  expect(timelineText(ctx)).not.toContain("Entry 219");
  expect(await snapshot(ctx)).toContain("Entry 299");
});

/** Pages the timeline with `key` until `text` is on screen. */
async function pageUntil(ctx: ThreadWorld, key: "PageUp" | "PageDown", text: string) {
  for (let presses = 0; presses < 100; presses += 1) {
    if ((await snapshot(ctx)).includes(text)) return;
    await pressKey(ctx, key);
    await settle();
  }
  throw new Error(`"${text}" never came into view with ${key}`);
}

step("the user can reveal earlier entries a page at a time", async (ctx: ThreadWorld) => {
  await pageUntil(ctx, "PageUp", "earlier entries");
  await clickText(ctx, "earlier entries");
  let timeline = hostState(ctx, "timeline");
  expect([timeline.windowStart, timeline.windowEnd]).toEqual([140, 220]);
  expect(timelineText(ctx)).toContain("Entry 219");
  expect(await snapshot(ctx)).toContain("▴ 140 earlier entries");
  await pageUntil(ctx, "PageDown", "newer entries");
  await clickText(ctx, "newer entries");
  timeline = hostState(ctx, "timeline");
  expect([timeline.windowStart, timeline.windowEnd]).toEqual([220, 300]);
});

// --- markdown and links -----------------------------------------------------------

step(
  "the agent replied with headings, emphasis, lists and a code block",
  async (ctx: ThreadWorld) => {
    const text = [
      "# Release notes",
      "",
      "This is **important** work.",
      "",
      "- first item",
      "- second item",
      "",
      "```ts",
      "const answer = 42;",
      "```",
    ].join("\n");
    await updateThread(ctx, () => ({ messages: [message("md", "assistant", text, 1)] }));
  },
);

step(
  "headings, bold text, lists and the code block are styled distinctly",
  async (ctx: ThreadWorld) => {
    const lines = items(ctx)[0]!.lines.map((line) => line.text);
    const find = (text: string) => lines.find((line) => plain(line).includes(text))!;
    const bold = (part: { attributes?: number } | undefined) =>
      ((part?.attributes ?? 0) & TextAttributes.BOLD) !== 0;
    expect(find("Release notes").chunks.every(bold)).toBe(true);
    expect(plain(find("Release notes"))).toBe("Release notes");
    const emphasis = find("important").chunks;
    expect(bold(emphasis.find((part) => part.text === "important"))).toBe(true);
    expect(bold(emphasis.find((part) => part.text === "This is "))).toBe(false);
    expect(plain(find("first item"))).toBe("• first item");
    const code = find("const answer");
    expect(code.chunks[0]!.fg).not.toEqual(emphasis[0]!.fg);
    const screen = await snapshot(ctx);
    for (const text of ["Release notes", "• first item", "• second item", "const answer = 42;"]) {
      expect(screen).toContain(text);
    }
    expect(screen).not.toContain("**");
    expect(screen).not.toContain("```");
  },
);

step("the agent wrote {string}", async (ctx: ThreadWorld, text: string) => {
  await updateThread(ctx, () => ({ messages: [message("link", "assistant", text, 1)] }));
});

step(
  "{string} is a terminal hyperlink without the trailing full stop",
  async (ctx: ThreadWorld, url: string) => {
    const linked = allChunks(ctx).filter((part) => part.link);
    expect(linked.map((part) => [part.text, part.link!.url])).toEqual([[url, url]]);
    expect(await snapshot(ctx)).toContain(`${url}.`);
  },
);

step("the agent wrote a URL inside inline code", async (ctx: ThreadWorld) => {
  await updateThread(ctx, () => ({
    messages: [message("code", "assistant", "Run `curl https://example.com/api` to check.", 1)],
  }));
});

step("that URL is not turned into a link", async (ctx: ThreadWorld) => {
  expect(allChunks(ctx).some((part) => part.link)).toBe(false);
  expect(await snapshot(ctx)).toContain("curl https://example.com/api");
});

// --- user messages ----------------------------------------------------------------

const LONG_MESSAGE = Array.from({ length: 30 }, (_, index) => `Requirement ${index + 1}`).join(
  "\n",
);

step("the user sent a long message", async (ctx: ThreadWorld) => {
  await updateThread(ctx, () => ({ messages: [message("long", "user", LONG_MESSAGE, 1)] }));
});

step("the message is aligned to the right and collapsed", async (ctx: ThreadWorld) => {
  const [bubble] = items(ctx);
  expect(bubble).toMatchObject({ align: "right", boxed: true });
  const screen = await snapshot(ctx);
  const row = screen.split("\n").find((line) => line.includes("Requirement 1 "))!;
  const column = findObject(ctx, "timelineColumn");
  const main = geometry(findObject(ctx, "main"));
  // The bubble ends at the column's right edge and starts well right of its left edge.
  expect(row.indexOf("Requirement 1")).toBeGreaterThan(main.x + geometry(column).x + 4);
  expect(screen).toContain("⌄ Show full message");
  expect(screen).not.toContain("Requirement 30");
});

step("expanding it shows the full message", async (ctx: ThreadWorld) => {
  await clickText(ctx, "Show full message");
  expect(timelineText(ctx)).toContain("Requirement 30");
  expect(await snapshot(ctx)).toContain("⌃ Show less");
});

// --- changed files ----------------------------------------------------------------

const NESTED_FILES = [
  { path: "src/components/ui/Button.tsx", additions: 10, deletions: 2 },
  { path: "src/components/ui/Card.tsx", additions: 4, deletions: 0 },
  { path: "src/lib/format.ts", additions: 1, deletions: 1 },
  { path: "README.md", additions: 2, deletions: 0 },
];

async function turnChanged(ctx: ThreadWorld, files: Parameters<typeof checkpoint>[1]) {
  await updateThread(ctx, () => ({
    latestTurn: latestTurn("turn-1", 0, 30, "done"),
    messages: [
      message("ask", "user", "Make the change", 0, { turnId: "turn-1" } as never),
      message("done", "assistant", "Done.", 30, { turnId: "turn-1" } as never),
    ],
    checkpoints: [checkpoint(1, files, 30, "done")],
  }));
}

step("the last turn changed files in nested folders", async (ctx: ThreadWorld) => {
  await turnChanged(ctx, NESTED_FILES);
});

step("a changed-files tree is shown", async (ctx: ThreadWorld) => {
  await turnChanged(ctx, NESTED_FILES);
  expect(await snapshot(ctx)).toContain("changed files (4)");
});

step(
  "the timeline shows a tree of the changed files with additions and deletions",
  async (ctx: ThreadWorld) => {
    const screen = await snapshot(ctx);
    expect(screen).toContain("changed files (4)  +17 -3");
    expect(screen).toMatch(/▾ src\/\s+\+15 -3/);
    expect(screen).toMatch(/◦ Button\.tsx\s+\+10 -2/);
    expect(screen).toMatch(/◦ README\.md\s+\+2 -0/);
  },
);

step("single-child folders are compacted into one row", async (ctx: ThreadWorld) => {
  const screen = await snapshot(ctx);
  expect(screen).toContain("▾ components/ui/");
  expect(screen).not.toMatch(/▾ components\/\s/);
});

step("the user collapses all", async (ctx: ThreadWorld) => {
  await clickText(ctx, "collapse all");
});

step("only the top folders are shown", async (ctx: ThreadWorld) => {
  const screen = await snapshot(ctx);
  expect(screen).toContain("▸ src/");
  expect(screen).toContain("expand all");
  for (const hidden of ["components/ui/", "Button.tsx", "lib/", "format.ts"]) {
    expect(screen).not.toContain(hidden);
  }
});

// --- diff viewer --------------------------------------------------------------------

/** A unified diff touching each path (git quotes paths with non-ASCII bytes). */
function unifiedDiff(paths: ReadonlyArray<string>): string {
  return paths
    .map((path) => {
      const quoted = /[^\x20-\x7e]/.test(path);
      const escape = (prefix: string) =>
        quoted
          ? `"${prefix}${[...new TextEncoder().encode(path)]
              .map((byte) => (byte < 0x80 ? String.fromCharCode(byte) : `\\${byte.toString(8)}`))
              .join("")}"`
          : `${prefix}${path}`;
      return [
        `diff --git ${escape("a/")} ${escape("b/")}`,
        "index 1111111..2222222 100644",
        `--- ${escape("a/")}`,
        `+++ ${escape("b/")}`,
        "@@ -1,2 +1,2 @@",
        " keep",
        "-old line",
        "+new line",
      ].join("\n");
    })
    .join("\n");
}

const TURN_FILES = ["src/a.ts", "src/b.ts", "docs/guide.md"];

async function turnWithDiff(ctx: ThreadWorld, files = TURN_FILES) {
  ctx.respond!.getTurnDiff = async () => unifiedDiff(files);
  ctx.respond!.getFullThreadDiff = async () => unifiedDiff(files);
  await turnChanged(ctx, files);
}

step(
  "the user clicks {string} in the changed-files tree",
  async (ctx: ThreadWorld, path: string) => {
    await turnWithDiff(ctx);
    await clickText(ctx, `◦ ${path.split("/").pop()}`);
  },
);

step(
  "the diff viewer opens scoped to {string} for that turn",
  async (ctx: ThreadWorld, path: string) => {
    expect(recorded(ctx, "getTurnDiff")).toEqual([["t1", 1]]);
    expect(hostState(ctx, "diff")).toMatchObject({
      open: true,
      scopeLabel: "turn 1",
      focusPath: path,
    });
    expect(hostState(ctx, "diff").files.map((file: { path: string }) => file.path)).toEqual([path]);
    const screen = await snapshot(ctx);
    expect(screen).toContain("diff · turn 1");
    expect(screen).toContain(path);
    expect(screen).not.toContain("src/b.ts");
  },
);

step("the user views all changes from the command palette", async (ctx: ThreadWorld) => {
  await turnWithDiff(ctx);
  // The palette's "View all changes" entry dispatches this action.
  ctx.host!.dispatch("diff.all");
  await settle();
});

step("the diff viewer opens with the header {string}", async (ctx: ThreadWorld, label: string) => {
  expect(recorded(ctx, "getFullThreadDiff")).toEqual([["t1", 1]]);
  expect(await snapshot(ctx)).toContain(`diff · ${label}`);
  expect(findObject(ctx, "diffViewer").get("visible")).toBe(true);
});

step("each file has its own section with its language", async (ctx: ThreadWorld) => {
  const screen = await snapshot(ctx);
  const expected: Record<string, string> = {
    "src/a.ts": "typescript",
    "src/b.ts": "typescript",
    "docs/guide.md": "markdown",
  };
  for (const [path, language] of Object.entries(expected)) {
    expect(findObject(ctx, `diffBody-${path}`).get("filetype")).toBe(language);
    expect(screen).toContain(`${path}  · ${language}`);
  }
});

step("the user opens the diff for a file that is not in that turn", async (ctx: ThreadWorld) => {
  await turnWithDiff(ctx);
  ctx.host!.dispatch("diff.open", { turnCount: 1, path: "src/elsewhere.ts" });
  await settle();
});

step("the diff viewer shows every file in the turn", async (ctx: ThreadWorld) => {
  const diff = hostState(ctx, "diff");
  expect(diff.focusPath).toBeNull();
  expect(diff.files.map((file: { path: string }) => file.path)).toEqual(TURN_FILES);
  expect(await snapshot(ctx)).toContain("3 files");
});

async function openTurnDiff(ctx: ThreadWorld) {
  ctx.host!.dispatch("diff.open", { turnCount: 1 });
  await settle();
}

step("the diff viewer shows a stacked diff", async (ctx: ThreadWorld) => {
  await turnWithDiff(ctx);
  await openTurnDiff(ctx);
  expect(findObject(ctx, "diffBody-src/a.ts").get("view")).toBe("unified");
});

step("the diff is shown side by side", async (ctx: ThreadWorld) => {
  await snapshot(ctx);
  expect(hostState(ctx, "diff").view).toBe("split");
  expect(findObject(ctx, "diffBody-src/a.ts").get("view")).toBe("split");
});

step('pressing "s" again returns to stacked', async (ctx: ThreadWorld) => {
  await pressKey(ctx, "s");
  await snapshot(ctx);
  expect(findObject(ctx, "diffBody-src/a.ts").get("view")).toBe("unified");
});

step(
  /^the diff is (still loading|for an empty turn|failed to load)$/,
  async (ctx: ThreadWorld, state: string) => {
    await turnChanged(ctx, TURN_FILES);
    ctx.respond!.getTurnDiff =
      state === "still loading"
        ? () => deferred<string>().promise
        : state === "for an empty turn"
          ? async () => ""
          : async () => {
              throw new Error("checkpoint ref is missing");
            };
    await openTurnDiff(ctx);
  },
);

const DIFF_MESSAGES: Record<string, string> = {
  "a loading hint": "loading…",
  "that there are no changes": "no changes in this turn",
  "the error": "failed to load diff: checkpoint ref is missing",
};

step(
  /^the diff viewer shows (a loading hint|that there are no changes|the error)$/,
  async (ctx: ThreadWorld, which: string) => {
    expect(await snapshot(ctx)).toContain(DIFF_MESSAGES[which]!);
    expect(findObject(ctx, "diffMessage").get("visible")).toBe(true);
  },
);

step("a turn changed {string}", async (ctx: ThreadWorld, path: string) => {
  await turnWithDiff(ctx, [path]);
});

step("the diff viewer names the file {string}", async (ctx: ThreadWorld, path: string) => {
  await openTurnDiff(ctx);
  expect(hostState(ctx, "diff").files.map((file: { path: string }) => file.path)).toEqual([path]);
  expect(await snapshot(ctx)).toContain(path);
});

step("the diff viewer is open", async (ctx: ThreadWorld) => {
  await turnWithDiff(ctx);
  await openTurnDiff(ctx);
  expect(findObject(ctx, "diffViewer").get("visible")).toBe(true);
});

step("the conversation is shown again", async (ctx: ThreadWorld) => {
  const screen = await snapshot(ctx);
  expect(hostState(ctx, "mode")).toBe("compose");
  expect(findObject(ctx, "diffViewer").get("visible")).toBe(false);
  expect(findObject(ctx, "timeline").get("visible")).toBe(true);
  expect(screen).toContain("Done.");
  expect(screen).not.toContain("diff · ");
});

// --- revert picker --------------------------------------------------------------------

async function threeCheckpoints(ctx: ThreadWorld) {
  if ((ctx.thread?.checkpoints.length ?? 0) > 0) return;
  await updateThread(ctx, () => ({
    checkpoints: [
      checkpoint(1, ["a.ts"], 10, null),
      checkpoint(2, ["a.ts", "b.ts"], 20, null),
      checkpoint(3, ["a.ts", "b.ts", "c.ts"], 30, null),
    ],
  }));
}

step('the user opens "Revert to checkpoint…"', async (ctx: ThreadWorld) => {
  await threeCheckpoints(ctx);
  // The palette's "Revert to checkpoint…" entry dispatches this action.
  ctx.host!.dispatch("checkpoint.revert.open");
  await settle();
});

step("the revert picker is open", async (ctx: ThreadWorld) => {
  await threeCheckpoints(ctx);
  ctx.host!.dispatch("checkpoint.revert.open");
  await settle();
  expect(findObject(ctx, "revertPicker").get("visible")).toBe(true);
});

step(
  "checkpoints are listed newest first with their changed file counts",
  async (ctx: ThreadWorld) => {
    const screen = await snapshot(ctx);
    const rows = ["▸ turn 3 · 3 files", "  turn 2 · 2 files", "  turn 1 · 1 file "];
    const positions = rows.map((row) => screen.indexOf(row));
    expect(positions.every((position) => position >= 0)).toBe(true);
    expect([...positions].sort((a, b) => a - b)).toEqual(positions);
  },
);

step("confirming one restores the workspace to that checkpoint", async (ctx: ThreadWorld) => {
  await pressKey(ctx, "Enter");
  await settle();
  expect(recorded(ctx, "revertCheckpoint")).toEqual([["t1", 3]]);
  expect(hostState(ctx, "status")).toEqual({ kind: "success", text: "Reverted to turn 3." });
  expect(findObject(ctx, "revertPicker").get("visible")).toBe(false);
});

step("the workspace is unchanged", async (ctx: ThreadWorld) => {
  await settle();
  expect(recorded(ctx, "revertCheckpoint")).toEqual([]);
  expect(findObject(ctx, "revertPicker").get("visible")).toBe(false);
  expect(hostState(ctx, "mode")).toBe("compose");
});
