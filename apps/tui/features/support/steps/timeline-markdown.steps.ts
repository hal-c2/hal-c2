// features/timeline/markdown.feature on the terminal client: how a reply's
// Markdown is drawn, copied and kept safe. Replies arrive as the MC's
// projection (turnWorld.ts).
import { expect, spyOn } from "bun:test";
import { getTreeSitterClient, TextAttributes, type RGBA } from "@opentui/core";

import { setColourTheme, THEME } from "../../../src/theme.ts";
import { step } from "../../steps.ts";
import {
  BROKEN_FLOWCHART,
  MERMAID_SOURCES,
  mermaidAsks,
  mermaidDrawing,
  mermaidFence,
  serveMermaid,
} from "../fakeMermaid.ts";
import { expectSource, type MermaidWorld } from "./mermaid.steps.ts";
import { findObject, settle as settleUi, snapshot, type World } from "../world.ts";
import { clickText, hostState, plain, recorded, settle } from "../threadWorld.ts";
import {
  addItem,
  linesOf,
  messageItem,
  setItem,
  settleRun,
  startRun,
  sync,
  turns,
  type ShownLine,
  type TurnWorld,
} from "../turnWorld.ts";

interface MarkdownWorld extends TurnWorld, MermaidWorld {
  /** The text of the reply being written. */
  written?: string;
  /** The drawn row of the first paragraph, before the reply grew. */
  firstParagraph?: unknown;
  /** The code block's lines before it was closed. */
  codeBefore?: string[];
  /** The code the agent has written so far, in the block it is still writing. */
  codeSoFar?: string[];
  /** Code tree-sitter was asked to read, from when the scenario first watched. */
  codeReads?: string[];
  /** How many readings may go through, and who waits for the next change. */
  reads?: { allowed: number; wake: Array<() => void> };
  /** The reads seen when the code block was first shown coloured. */
  readsWhenColoured?: number;
}

const SOURCE =
  "const total = cart.lines.reduce((sum, line) => sum + line.price, 0);\nreturn roundToCent(total * (1 + rate));";
const TABLE = '| Region | Rate |\n|---|---:|\n| EU, north | 21% |\n| a\\|b | "q" |';

async function answer(ctx: MarkdownWorld, text: string) {
  await startRun(ctx, 30);
  await addItem(ctx, "assistant_message", { id: "reply", text });
  await settleRun(ctx, "completed", 30);
}

async function startWriting(ctx: MarkdownWorld, text: string) {
  ctx.written = text;
  await startRun(ctx, 30);
  await addItem(ctx, "assistant_message", {
    id: "reply",
    streaming: true,
    status: "running",
    text,
  });
}

async function write(ctx: MarkdownWorld, more: string) {
  ctx.written += more;
  await setItem(ctx, "reply", { text: ctx.written });
}

const reply = (ctx: MarkdownWorld) => messageItem(ctx, "reply");
const copyOf = (line: ShownLine) =>
  line.action === "timeline.copy" ? (line.payload as { text: string; key: string }) : null;
const codeLines = (ctx: MarkdownWorld) => reply(ctx).lines.filter((line) => copyOf(line) !== null);
const isBold = (part: { attributes?: number } | undefined) =>
  ((part?.attributes ?? 0) & TextAttributes.BOLD) !== 0;
/** The table's rows as drawn: the lines between its borders. */
const tableRows = (ctx: MarkdownWorld) =>
  linesOf(reply(ctx)).filter((line) => line.startsWith("│"));

// --- formatting ------------------------------------------------------------------------

step(
  "the agent answers with a heading, a list, a quote, a code block and a table",
  async (ctx: MarkdownWorld) => {
    await answer(
      ctx,
      `# Cart totals\n\n- Discounts first\n- Tax second\n\n> Old carts keep their totals.\n\n\`\`\`ts\n${SOURCE}\n\`\`\`\n\n${TABLE}`,
    );
  },
);

step("the heading and the list are shown as text", async (ctx: MarkdownWorld) => {
  const lines = reply(ctx).lines;
  const heading = lines.find((line) => plain(line.text) === "Cart totals")!;
  expect(heading.text.chunks.every(isBold)).toBe(true);
  expect(linesOf(reply(ctx))).toEqual(
    expect.arrayContaining(["Cart totals", "- Discounts first", "- Tax second"]),
  );
  const screen = await snapshot(ctx);
  expect(screen).toContain("Cart totals");
  expect(screen).toContain("- Tax second");
  expect(screen).not.toContain("# Cart totals");
});

step(
  "the quote, the code block and the table are each shown in their own form",
  async (ctx: MarkdownWorld) => {
    await settleUi(ctx);
    const lines = linesOf(reply(ctx));
    // The quote sits behind a bar.
    expect(lines).toContain("│ Old carts keep their totals.");
    // The code block is its source, in the code colour, without its fence.
    const code = codeLines(ctx);
    expect(code.map((line) => plain(line.text)).join("\n")).toBe(SOURCE);
    expect(copyOf(code[0]!)!.text).toBe(SOURCE);
    // Its lines open with keywords, in the keyword colour, once tree-sitter has read them.
    for (const line of code) expect(line.text.chunks[0]!.fg).toEqual(THEME.keyword);
    expect(lines.join("\n")).not.toContain("```");
    // The table is a box of its six cells.
    const boxed = lines.filter(
      (line) =>
        /^[┌├└│]/.test(line) && line !== lines[lines.indexOf("│ Old carts keep their totals.")],
    );
    expect(boxed[0]!.startsWith("┌")).toBe(true);
    const cells = boxed
      .filter((line) => line.startsWith("│"))
      .flatMap((line) => line.split("│").map((cell) => cell.trim()))
      .filter((cell) => cell !== "");
    expect(cells).toEqual(["Region", "Rate", "EU, north", "21%", "a|b", '"q"']);
    const screen = await snapshot(ctx);
    expect(screen).toContain("│ Old carts keep their totals.");
    expect(screen).toContain("return roundToCent(total * (1 + rate));");
    expect(screen).toContain("EU, north");
  },
);

// --- code blocks -----------------------------------------------------------------------

step("the agent's reply has a code block", async (ctx: MarkdownWorld) => {
  await answer(ctx, `Here it is:\n\n\`\`\`ts\n${SOURCE}\n\`\`\``);
});

// A click on the code copies the block.
step("the user copies the code block", async (ctx: MarkdownWorld) => {
  await clickText(ctx, "return roundToCent");
});

step("the code block's source is on the clipboard", (ctx: MarkdownWorld) => {
  expect(ctx.clipboard).toEqual([SOURCE]);
});

step("the code block shows it was copied", async (ctx: MarkdownWorld) => {
  const code = codeLines(ctx);
  expect(code).toHaveLength(2);
  for (const line of code) expect(line.text.chunks[0]!.fg).toEqual(THEME.success);
  expect(hostState(ctx, "status")).toEqual({ kind: "success", text: "Code block copied." });
  expect(await snapshot(ctx)).toContain("Code block copied.");
});

// --- code colours (OpenTUI's tree-sitter, host/codeColours.ts) ------------------------

// Code in each language, opening with a keyword the language colours.
const SAMPLES: Record<string, string> = {
  ts: SOURCE,
  py: "def refund(order):\n    return order.total",
  exs: "defmodule Cart do\n  def total(cart), do: 0\nend",
  qml: "import QtQuick\n\nItem {\n  id: root\n}",
};

/**
 * Counts tree-sitter's readings. With `hold`, each waits until `release` lets one more
 * through, so a scenario can look at the screen while a reading is under way.
 */
function watchReads(ctx: MarkdownWorld, hold = false) {
  if (ctx.codeReads) return;
  const reads: string[] = (ctx.codeReads = []);
  const gate: NonNullable<MarkdownWorld["reads"]> = { allowed: hold ? 0 : Infinity, wake: [] };
  ctx.reads = gate;
  const client = getTreeSitterClient();
  const read = client.highlightOnce.bind(client);
  const spy = spyOn(client, "highlightOnce").mockImplementation(async (text, filetype) => {
    const turn = reads.push(text) - 1;
    for (const wake of gate.wake.splice(0)) wake();
    while (turn >= gate.allowed) await new Promise<void>((go) => gate.wake.push(go));
    return read(text, filetype);
  });
  ctx.cleanups.push(() => {
    release(ctx, Infinity);
    spy.mockRestore();
  });
}

/** Lets `count` more held readings through. */
function release(ctx: MarkdownWorld, count = 1) {
  ctx.reads!.allowed += count;
  for (const wake of ctx.reads!.wake.splice(0)) wake();
}

/** Resolves once tree-sitter has been asked for `count` readings in all. */
async function asked(ctx: MarkdownWorld, count: number) {
  while (ctx.codeReads!.length < count) {
    await new Promise<void>((go) => ctx.reads!.wake.push(go));
  }
}

const isColour = (fg: unknown, colour: RGBA) => colour.equals(fg as RGBA | undefined);
/** Is the line in the plain code colour, as code nothing has read? */
const plainCode = (line: ShownLine) =>
  line.text.chunks.every((part) => isColour(part.fg, THEME.warning));
/** Does the line open with its keyword in the keyword colour? */
const keywordFirst = (line: ShownLine) => {
  const [first] = line.text.chunks;
  return /^\w+$/.test(first?.text ?? "") && isColour(first!.fg, THEME.keyword);
};

step(
  "the agent's reply has a code block whose fence reads {string}",
  async (ctx: MarkdownWorld, fence: string) => {
    watchReads(ctx);
    await answer(ctx, `Here it is:\n\n\`\`\`${fence}\n${SAMPLES[fence] ?? SOURCE}\n\`\`\``);
  },
);

step("the user reads the reply", async (ctx: World) => {
  await settleUi(ctx);
});

step(
  /^the code block is shown coloured as (TypeScript|Python|Elixir|QML)$/,
  async (ctx: MarkdownWorld) => {
    await settleUi(ctx);
    const code = codeLines(ctx);
    expect(code.length).toBeGreaterThan(0);
    expect(keywordFirst(code[0]!)).toBe(true);
    ctx.readsWhenColoured = ctx.codeReads!.length;
    expect(await snapshot(ctx)).toContain(plain(code.at(-1)!.text));
  },
);

step("the code block is shown as plain text", async (ctx: MarkdownWorld) => {
  const code = codeLines(ctx);
  expect(code.map((line) => plain(line.text)).join("\n")).toBe(SOURCE);
  expect(code.every(plainCode)).toBe(true);
});

const STREAMED = ["const a = 1;", "const b = 2;", "const c = 3;"];

step(
  "the agent is writing a code block whose fence reads {string}",
  async (ctx: MarkdownWorld, fence: string) => {
    watchReads(ctx, true);
    await startWriting(ctx, `Totals:\n\n\`\`\`${fence}\n${STREAMED.join("\n")}\n`);
  },
);

step("its first three lines are coloured", async (ctx: MarkdownWorld) => {
  await asked(ctx, 1);
  release(ctx);
  await settleUi(ctx);
  const code = codeLines(ctx);
  expect(code.map((line) => plain(line.text))).toEqual(STREAMED);
  expect(code.every(keywordFirst)).toBe(true);
});

step("the agent adds a fourth line", async (ctx: MarkdownWorld) => {
  await write(ctx, "const d = 4;");
  await snapshot(ctx);
});

step(
  "the first three lines stay coloured while the new line waits to be coloured",
  async (ctx: MarkdownWorld) => {
    // The line being written is not read until it is finished.
    expect(ctx.codeReads).toHaveLength(1);
    const code = codeLines(ctx);
    expect(code.map((line) => plain(line.text))).toEqual([...STREAMED, "const d = 4;"]);
    expect(code.slice(0, 3).every(keywordFirst)).toBe(true);
    expect(plainCode(code[3]!)).toBe(true);
    expect(await snapshot(ctx)).toContain("const d = 4;");
  },
);

step("the block does not flash back to plain text", async (ctx: MarkdownWorld) => {
  // The line is finished: while it is read (held back), the lines read before keep theirs.
  await write(ctx, "\n");
  await asked(ctx, 2);
  expect(ctx.codeReads!.at(-1)).toContain("const d = 4;");
  await snapshot(ctx);
  expect(codeLines(ctx).slice(0, 3).every(keywordFirst)).toBe(true);
  release(ctx);
  await settleUi(ctx);
  expect(codeLines(ctx).every(keywordFirst)).toBe(true);
  expect(ctx.codeReads).toHaveLength(2);
});

// The terminal client has no light or dark appearance of its own; its colour themes stand
// for them: the terminal's own palette (the default) as light, gruvbox as dark.
step("the appearance is Light", (ctx: MarkdownWorld) => {
  ctx.cleanups.push(() => setColourTheme("terminal"));
  setColourTheme("terminal");
});

step("the user switches the app from light to dark", async (ctx: MarkdownWorld) => {
  ctx.host!.dispatch("theme.set", { id: "gruvbox" });
  await settleUi(ctx);
});

step("the code block is coloured for the dark theme", async (ctx: MarkdownWorld) => {
  const code = codeLines(ctx);
  expect(THEME.keyword.intent).toBe("rgb");
  expect(keywordFirst(code[0]!)).toBe(true);
});

step("its code was not read again", (ctx: MarkdownWorld) => {
  expect(ctx.codeReads!.length).toBe(ctx.readsWhenColoured!);
});

// --- tables ----------------------------------------------------------------------------

step("the agent's reply has a table", async (ctx: MarkdownWorld) => {
  await answer(ctx, TABLE);
});

step(
  /^the user copies the table as (Markdown|CSV)$/,
  async (ctx: MarkdownWorld, format: string) => {
    await clickText(ctx, `⧉ ${format}`);
  },
);

const COPIED_TABLE: Record<string, string> = {
  Markdown: '| Region | Rate |\n| --- | ---: |\n| EU, north | 21% |\n| a\\|b | "q" |',
  CSV: 'Region,Rate\n"EU, north",21%\na|b,"""q"""',
};

step(
  /^the table is on the clipboard as (Markdown|CSV)$/,
  async (ctx: MarkdownWorld, format: string) => {
    expect(ctx.clipboard).toEqual([COPIED_TABLE[format]!]);
    expect(await snapshot(ctx)).toContain(`✓ Copied ${format}`);
  },
);

step("the agent's reply has a table with a long cell", async (ctx: MarkdownWorld) => {
  await answer(
    ctx,
    `| Region | Rounding |\n|---|---|\n| EU | ${"per line, then once more ".repeat(8)}|`,
  );
});

step(
  /^the user (collapses|expands) the table cells$/,
  async (ctx: MarkdownWorld, change: string) => {
    await clickText(ctx, change === "collapses" ? "Collapse cells" : "Expand cells");
  },
);

step(/^the long cell (stays on one line|wraps)$/, async (ctx: MarkdownWorld, how: string) => {
  // The header row, then the one body row on as many lines as its long cell takes.
  const body = tableRows(ctx).slice(1);
  const screen = await snapshot(ctx);
  const cells = body.map((line) => line.split("│")[2]!.trim());
  const drawn = cells.filter((cell) => screen.includes(cell)).length;
  if (how === "wraps") {
    expect(body.length).toBeGreaterThan(1);
    // Nothing of the cell is lost: its lines read as the whole text.
    expect(cells.join(" ")).toBe("per line, then once more ".repeat(8).trim());
    expect(drawn).toBe(body.length);
  } else {
    expect(body).toHaveLength(1);
    expect(drawn).toBe(1);
    expect(screen).not.toContain("⇱ Collapse cells");
  }
});

// --- untrusted text --------------------------------------------------------------------

const HTML = '<script>alert(1)</script> <b>bold?</b> <img src="https://example.com/x.png">';

step("the agent answers with HTML and an image", async (ctx: MarkdownWorld) => {
  await answer(ctx, `${HTML}\n\n![pic](https://example.com/y.png)`);
});

step("the HTML is shown as written", async (ctx: MarkdownWorld) => {
  expect(linesOf(reply(ctx))[0]).toBe(HTML);
  const screen = await snapshot(ctx);
  expect(screen).toContain("<script>alert(1)</script> <b>bold?</b>");
});

step(
  "the image is a link to its address and nothing is loaded from the web",
  async (ctx: MarkdownWorld) => {
    const chunks = reply(ctx).lines.flatMap((line) => line.text.chunks);
    const picture = chunks.find((part) => part.text === "pic");
    expect(picture?.link?.url).toBe("https://example.com/y.png");
    // No picture is drawn and nothing was fetched for one.
    expect(reply(ctx).lines.every((line) => !("image" in line) || line.image === null)).toBe(true);
    expect(recorded(ctx, "getAttachmentImage")).toEqual([]);
    expect(recorded(ctx, "getAttachmentUrl")).toEqual([]);
    expect(await snapshot(ctx)).not.toContain("![pic]");
  },
);

step("the agent answers with a link to {string}", async (ctx: MarkdownWorld, url: string) => {
  await answer(ctx, `Open [the pricing docs](${url}) now.`);
});

step("the link's text is shown and nothing can be opened", async (ctx: MarkdownWorld) => {
  const lines = reply(ctx).lines;
  // The reply's text, above its time-and-copy row.
  expect(linesOf(reply(ctx))[0]).toBe("Open the pricing docs now.");
  expect(lines.flatMap((line) => line.text.chunks).some((part) => part.link)).toBe(false);
  expect(await snapshot(ctx)).not.toContain("javascript:");
  const before = ctx.dispatched!.length;
  await clickText(ctx, "the pricing docs");
  expect(ctx.dispatched!.slice(before)).toEqual([]);
});

// --- a reply being written -------------------------------------------------------------

/** The drawn row (the QML object) of the reply's first line. */
function firstRow(ctx: MarkdownWorld): unknown {
  const column = findObject(ctx, "timelineItem-reply").children.find(
    (child) => child.get("visible") === true,
  );
  // The column's children are its Repeater, then one row per line.
  return column?.children[1];
}

step("the agent is writing a reply of several paragraphs", async (ctx: MarkdownWorld) => {
  await startWriting(ctx, "Discounts apply first.\n\nTax rounds to the cent.");
  await snapshot(ctx);
  ctx.firstParagraph = firstRow(ctx);
  expect(ctx.firstParagraph).toBeDefined();
});

step("the reply grows by another paragraph", async (ctx: MarkdownWorld) => {
  await write(ctx, " Per line for VAT.");
  await write(ctx, "\n\nTotals are cached");
  await write(ctx, " until the cart changes.");
});

step("the paragraphs already shown are not drawn again", async (ctx: MarkdownWorld) => {
  expect(await snapshot(ctx)).toContain("Totals are cached until the cart changes.");
  expect(linesOf(reply(ctx))[0]).toBe("Discounts apply first.");
  // The first paragraph is still the row that was drawn before the reply grew.
  expect(firstRow(ctx)).toBe(ctx.firstParagraph);
});

step("the agent is writing a code block", async (ctx: MarkdownWorld) => {
  ctx.codeSoFar = ["def refund(order):", "    return order.total"];
  await startWriting(ctx, `Checking the refund path:\n\n\`\`\`py\n${ctx.codeSoFar.join("\n")}`);
});

step("the code written so far is shown as a code block", async (ctx: MarkdownWorld) => {
  const code = codeLines(ctx);
  ctx.codeBefore = code.map((line) => plain(line.text));
  expect(ctx.codeBefore).toEqual(ctx.codeSoFar!);
  for (const line of code) expect(line.text.chunks[0]!.fg).toEqual(THEME.warning);
  const screen = await snapshot(ctx);
  expect(screen).toContain(ctx.codeSoFar![0]!);
  expect(screen).not.toContain("```");
  // Nothing is drawn from a block the agent is still writing.
  expect(ctx.fake!.settings.callsTo("mermaid.render")).toEqual([]);
});

step("the agent closes the code block", async (ctx: MarkdownWorld) => {
  await write(ctx, "\n```");
});

step("the same code block is shown, finished", async (ctx: MarkdownWorld) => {
  const code = codeLines(ctx);
  expect(code.map((line) => plain(line.text))).toEqual(ctx.codeBefore!);
  expect(linesOf(reply(ctx)).at(-1)).toBe("    return order.total");
  expect(await snapshot(ctx)).not.toContain("```");
});

// --- alerts ----------------------------------------------------------------------------

step("the agent answers with a {string} alert", async (ctx: MarkdownWorld, marker: string) => {
  await answer(ctx, `> [!${marker}]\n> Refunds reuse the old rate.`);
});

step("the quote is titled {string}", async (ctx: MarkdownWorld, title: string) => {
  const [head, body] = reply(ctx).lines;
  expect(plain(head!.text)).toBe(`│ ${title}`);
  expect(isBold(head!.text.chunks[1])).toBe(true);
  expect(plain(body!.text)).toBe("│ Refunds reuse the old rate.");
  const screen = await snapshot(ctx);
  expect(screen).toContain(`│ ${title}`);
  expect(screen).not.toContain("[!");
});

// --- the user's own message ------------------------------------------------------------

step("the user's message has two lines", async (ctx: MarkdownWorld) => {
  await startRun(ctx, 30);
  const fixture = await turns(ctx);
  fixture.messages.at(-1)!.text = "Thanks!\nWhat about refunds?";
  await sync(ctx);
  await settle();
});

step("the message is shown on two lines", async (ctx: MarkdownWorld) => {
  // The last message, above the time it was sent.
  const bubble = hostState(ctx, "timeline").items.findLast(
    (item: { kind: string }) => item.kind === "message",
  );
  expect(bubble).toMatchObject({ kind: "message", boxed: true });
  expect(linesOf(bubble)).toEqual(["Thanks!", "What about refunds?"]);
  const rows = (await snapshot(ctx)).split("\n");
  const first = rows.findIndex((row) => row.includes("Thanks!"));
  expect(first).toBeGreaterThan(-1);
  expect(rows[first + 1]).toContain("What about refunds?");
});

// --- Mermaid diagrams (the MC draws them in characters: fakeMermaid.ts) ----------------

/** The reply's diagram is the one on screen; its lines are the reply's. */
const showsDiagram = (ctx: MarkdownWorld, source: string) => {
  ctx.diagram = { source, lines: async () => linesOf(reply(ctx)) };
};

step(
  /^the agent answers with a "mermaid" code block holding a flowchart( with an unclosed bracket)?$/,
  async (ctx: MarkdownWorld, broken?: string) => {
    serveMermaid(ctx);
    const source = broken ? BROKEN_FLOWCHART : MERMAID_SOURCES.flowchart!;
    await answer(ctx, `Here is the checkout:\n\n${mermaidFence(source)}`);
    await settleUi(ctx);
    showsDiagram(ctx, source);
  },
);

step("the user can switch to the diagram's source and copy it", async (ctx: MarkdownWorld) => {
  const source = ctx.diagram!.source;
  await clickText(ctx, "⇄ Source");
  await expectSource(ctx);
  expect(linesOf(reply(ctx))).toContain("◇ flowchart diagram · source");
  await clickText(ctx, source.split("\n")[1]!.trim());
  expect(ctx.clipboard).toEqual([source]);
  await clickText(ctx, "⇄ Drawing");
  expect(linesOf(reply(ctx))).toContain(mermaidDrawing(source)[1]!);
});

step("the diagram's source is shown as a code block", async (ctx: MarkdownWorld) => {
  await expectSource(ctx);
  const code = codeLines(ctx).filter((line) => copyOf(line)!.text === ctx.diagram!.source);
  const sourceLines = ctx.diagram!.source.split("\n");
  const shownSource = code.filter((line) => sourceLines.includes(plain(line.text)));
  expect(shownSource).toHaveLength(sourceLines.length);
  for (const line of shownSource) expect(line.text.chunks[0]!.fg).toEqual(THEME.warning);
});

step(
  "the agent is still writing a {string} code block",
  async (ctx: MarkdownWorld, info: string) => {
    serveMermaid(ctx);
    const source = MERMAID_SOURCES.flowchart!;
    ctx.codeSoFar = source.split("\n");
    await startWriting(ctx, `Here is the checkout:\n\n\`\`\`${info}\n${source}`);
    showsDiagram(ctx, source);
  },
);

step("the diagram is drawn", async (ctx: MarkdownWorld) => {
  await settleUi(ctx);
  const { source } = ctx.diagram!;
  const lines = linesOf(reply(ctx));
  expect(lines).toContain("◇ flowchart diagram");
  for (const text of mermaidDrawing(source)) expect(lines).toContain(text);
  expect(mermaidAsks(ctx, source)).toBe(1);
});
