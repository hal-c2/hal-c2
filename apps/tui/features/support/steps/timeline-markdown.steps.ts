// features/timeline/markdown.feature on the terminal client: how a reply's
// Markdown is drawn, copied and kept safe. Replies arrive as the MC's
// projection (turnWorld.ts).
import { expect } from "bun:test";
import { TextAttributes } from "@opentui/core";

import { THEME } from "../../../src/theme.ts";
import { step } from "../../steps.ts";
import { findObject, snapshot } from "../world.ts";
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

interface MarkdownWorld extends TurnWorld {
  /** The text of the reply being written. */
  written?: string;
  /** The drawn row of the first paragraph, before the reply grew. */
  firstParagraph?: unknown;
  /** The code block's lines before it was closed. */
  codeBefore?: string[];
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
    const lines = linesOf(reply(ctx));
    // The quote sits behind a bar.
    expect(lines).toContain("│ Old carts keep their totals.");
    // The code block is its source, in the code colour, without its fence.
    const code = codeLines(ctx);
    expect(code.map((line) => plain(line.text)).join("\n")).toBe(SOURCE);
    expect(copyOf(code[0]!)!.text).toBe(SOURCE);
    for (const line of code) expect(line.text.chunks[0]!.fg).toEqual(THEME.warning);
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
  expect(linesOf(reply(ctx))).toEqual(["Open the pricing docs now."]);
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
  await startWriting(
    ctx,
    "Checking the refund path:\n\n```py\ndef refund(order):\n    return order.total",
  );
});

step("the code written so far is shown as a code block", async (ctx: MarkdownWorld) => {
  const code = codeLines(ctx);
  ctx.codeBefore = code.map((line) => plain(line.text));
  expect(ctx.codeBefore).toEqual(["def refund(order):", "    return order.total"]);
  for (const line of code) expect(line.text.chunks[0]!.fg).toEqual(THEME.warning);
  const screen = await snapshot(ctx);
  expect(screen).toContain("def refund(order):");
  expect(screen).not.toContain("```");
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
  const bubble = hostState(ctx, "timeline").items.at(-1);
  expect(bubble).toMatchObject({ kind: "message", boxed: true });
  expect(linesOf(bubble)).toEqual(["Thanks!", "What about refunds?"]);
  const rows = (await snapshot(ctx)).split("\n");
  const first = rows.findIndex((row) => row.includes("Thanks!"));
  expect(first).toBeGreaterThan(-1);
  expect(rows[first + 1]).toContain("What about refunds?");
});
