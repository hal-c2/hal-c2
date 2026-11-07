// features/timeline/scrolling-and-links.feature on the terminal client: a long
// thread read through the real timeline view (a scroll view over the host's
// rows), its scroll offset read back from the QML object.
import { expect } from "bun:test";
import type { OrchestrationThread } from "@hal-c2/contracts";

import { step } from "../../steps.ts";
import { shell, thread } from "../fakeClient.ts";
import { threadKey } from "../../../src/host/sidebarState.ts";
import {
  hostState,
  latestTurn,
  message,
  openThread,
  plain,
  recorded,
  settle,
  timelineText,
  updateThread,
  type ThreadWorld,
} from "../threadWorld.ts";
import { findObject, pressKey, snapshot } from "../world.ts";

interface ScrollWorld extends ThreadWorld {
  /** The offset the view was at when a step noted it. */
  offset?: number;
  /** The reply the agent is writing, as it stands. */
  reply?: string;
  /** A message being read and the screen row it sat on. */
  anchor?: { text: string; row: number };
}

const LONG = 40;

const timelineView = (ctx: ScrollWorld) => findObject(ctx, "timeline");
const offset = (ctx: ScrollWorld) => Number(timelineView(ctx).get("contentY"));
/** Rows between the bottom of the view and the bottom of the content. */
const fromEnd = (ctx: ScrollWorld) => {
  const view = timelineView(ctx);
  return Number(view.get("contentHeight")) - Number(view.get("layoutHeight")) - offset(ctx);
};
const atEnd = (ctx: ScrollWorld) => fromEnd(ctx) <= 1;

const replies = (count: number, prefix = "Reply", from = 0) =>
  Array.from({ length: count }, (_, i) =>
    message(
      `${prefix}-${i}`,
      "assistant",
      `${prefix} ${i}\n\nSecond paragraph of ${prefix} ${i}.`,
      from + i,
    ),
  );

async function render(ctx: ScrollWorld) {
  await snapshot(ctx);
  await snapshot(ctx);
}

async function scrollUp(ctx: ScrollWorld, pages = 2) {
  for (let i = 0; i < pages; i += 1) {
    await pressKey(ctx, "PgUp");
    await snapshot(ctx);
  }
  expect(atEnd(ctx)).toBe(false);
  ctx.offset = offset(ctx);
}

/** The agent's reply, still streaming, with `text` written so far. */
async function writeReply(ctx: ScrollWorld, text: string) {
  ctx.reply = text;
  await updateThread(ctx, (detail) => ({
    messages: [
      ...detail.messages.filter((entry) => entry.id !== "m-live"),
      message("m-live", "assistant", text, 90, { streaming: true }),
    ],
  }));
  await render(ctx);
}

function addThread(ctx: ScrollWorld, id: string, title: string): string {
  const current = ctx.fake!.latestShell();
  const row = { ...current.threads[0]!, id, title } as (typeof current.threads)[number];
  ctx.fake!.emitShell({ ...current, threads: [...current.threads, row] });
  return threadKey(id as never);
}

async function open(ctx: ScrollWorld, key: string) {
  ctx.host!.dispatch("thread.open", { key });
  await settle();
}

const detailOf = (id: string, title: string, messages: OrchestrationThread["messages"]) =>
  ({ ...thread(), id, title, messages }) as unknown as OrchestrationThread;

// --- following -------------------------------------------------------------------------

step("the user is looking at a long thread in {string}", async (ctx: ScrollWorld) => {
  await openThread(ctx, { ...thread(), messages: replies(LONG) } as never);
  await render(ctx);
  expect(Number(timelineView(ctx).get("contentHeight"))).toBeGreaterThan(
    Number(timelineView(ctx).get("layoutHeight")) * 2,
  );
});

step("the user is at the end of the thread", async (ctx: ScrollWorld) => {
  expect(atEnd(ctx)).toBe(true);
});

step("the agent writes more of its reply", async (ctx: ScrollWorld) => {
  await writeReply(ctx, "Tax is computed per line.");
  await writeReply(ctx, "Tax is computed per line.\n\nThen it is added to the total.");
});

step("the new text stays in view", async (ctx: ScrollWorld) => {
  expect(await snapshot(ctx)).toContain("Then it is added to the total.");
  expect(atEnd(ctx)).toBe(true);
});

step("a reply with a table sits just above the end", async (ctx: ScrollWorld) => {
  const table = "| item | price |\n| --- | --- |\n| cart | 10 |\n| tax | 2 |";
  await updateThread(ctx, (detail) => ({
    messages: [
      ...detail.messages,
      message("m-table", "assistant", table, 80),
      message("m-last", "assistant", "That is the table.", 81),
    ],
  }));
  await render(ctx);
  expect(atEnd(ctx)).toBe(true);
  ctx.offset = offset(ctx);
});

step("nothing new is written", async (ctx: ScrollWorld) => {
  for (let i = 0; i < 3; i += 1) {
    await settle();
    await snapshot(ctx);
  }
});

step("the view does not move", (ctx: ScrollWorld) => {
  expect(offset(ctx)).toBe(ctx.offset!);
});

// --- scrolling away --------------------------------------------------------------------

step("the agent is writing its reply", async (ctx: ScrollWorld) => {
  await writeReply(ctx, "Tax is computed per line.");
});

step("the user scrolls up to an earlier message", (ctx: ScrollWorld) => scrollUp(ctx));

step("the user has scrolled away from the end while the agent writes", async (ctx: ScrollWorld) => {
  await writeReply(ctx, "Tax is computed per line.");
  await scrollUp(ctx);
});

step("the view stays on that message while the reply grows", async (ctx: ScrollWorld) => {
  await writeReply(ctx, `${ctx.reply}\n\nThen it is added to the total.`);
  expect(offset(ctx)).toBe(ctx.offset!);
});

step("the user is offered a way to scroll to the end", async (ctx: ScrollWorld) => {
  expect(await snapshot(ctx)).toContain("Scroll to end");
});

step("the user scrolls to the end", async (ctx: ScrollWorld) => {
  for (let i = 0; i < 40 && !atEnd(ctx); i += 1) {
    await pressKey(ctx, "PgDn");
    await snapshot(ctx);
  }
  expect(atEnd(ctx)).toBe(true);
});

step("the latest output is shown", async (ctx: ScrollWorld) => {
  expect(await snapshot(ctx)).toContain(ctx.reply!.split("\n\n").at(-1)!);
  expect(await snapshot(ctx)).not.toContain("Scroll to end");
});

step("the view follows new output again", async (ctx: ScrollWorld) => {
  await writeReply(ctx, `${ctx.reply}\n\nThe totals are checked.`);
  expect(await snapshot(ctx)).toContain("The totals are checked.");
  expect(atEnd(ctx)).toBe(true);
});

// --- opening a thread ------------------------------------------------------------------

step("the user has scrolled away from the end of the thread", (ctx: ScrollWorld) =>
  scrollUp(ctx, 3),
);

step("the user opens another thread", async (ctx: ScrollWorld) => {
  const key = addThread(ctx, "t2", "Docs");
  await open(ctx, key);
  ctx.fake!.emitThread(detailOf("t2", "Docs", replies(LONG, "Docs")));
  await render(ctx);
});

step("the user opens another thread whose rows arrive in two turns", async (ctx: ScrollWorld) => {
  const key = addThread(ctx, "t2", "Docs");
  await open(ctx, key);
  const all = replies(LONG, "Docs");
  ctx.fake!.emitThread(detailOf("t2", "Docs", all.slice(0, 6)));
  await snapshot(ctx);
  await new Promise((resolve) => setTimeout(resolve, 0));
  ctx.fake!.emitThread(detailOf("t2", "Docs", all));
  await render(ctx);
});

step("the other thread shows its latest output", async (ctx: ScrollWorld) => {
  expect(await snapshot(ctx)).toContain(`Second paragraph of Docs ${LONG - 1}.`);
  expect(atEnd(ctx)).toBe(true);
});

step("the composer is not resting", (ctx: ScrollWorld) => {
  expect(hostState(ctx, "composer").target).toBe("thread:t2");
});

step("the user opens a thread whose agent is still working", async (ctx: ScrollWorld) => {
  const key = addThread(ctx, "t2", "Docs");
  await open(ctx, key);
  await render(ctx);
});

step("the thread's messages arrive", async (ctx: ScrollWorld) => {
  ctx.fake!.emitThread({
    ...detailOf("t2", "Docs", replies(LONG, "Docs")),
    latestTurn: latestTurn("turn-1", 0),
  });
  await render(ctx);
});

step(
  "the view shows the latest output at the end, not the start of the thread",
  async (ctx: ScrollWorld) => {
    const screen = await snapshot(ctx);
    expect(screen).toContain(`Docs ${LONG - 1}`);
    expect(screen).not.toContain("Docs 0\n");
    expect(atEnd(ctx)).toBe(true);
  },
);

step("the user is reading {string}", async (ctx: ScrollWorld, title: string) => {
  const current = ctx.fake!.latestShell();
  ctx.fake!.emitShell({
    ...current,
    threads: current.threads.map((row, i) => (i === 0 ? { ...row, title } : row)),
  });
  await updateThread(ctx, () => ({ title, messages: replies(LONG, "Tax") }));
  await render(ctx);
  expect(await snapshot(ctx)).toContain("Tax");
});

step(
  "the user switches to {string} while its messages are still loading",
  async (ctx: ScrollWorld, title: string) => {
    await open(ctx, addThread(ctx, "t2", title));
    await render(ctx);
  },
);

step(
  "no message of {string} is shown under {string}",
  async (ctx: ScrollWorld, _from: string, title: string) => {
    expect(hostState(ctx, "page")).toMatchObject({ title });
    expect(timelineText(ctx).filter((text) => text.includes("Tax"))).toEqual([]);
    expect(await snapshot(ctx)).not.toMatch(/Tax \d/);
  },
);

// --- earlier turns ---------------------------------------------------------------------

step("the thread has more turns than are loaded", async (ctx: ScrollWorld) => {
  ctx.page = { hasMore: true, loadingOlder: false };
  await updateThread(ctx, () => ({}));
  await render(ctx);
});

step("the user loads earlier turns", async (ctx: ScrollWorld) => {
  await scrollUp(ctx, 2);
  const screen = (await snapshot(ctx)).split("\n");
  const row = screen.findIndex((line) => /Reply \d+/.test(line));
  expect(row).toBeGreaterThanOrEqual(0);
  ctx.anchor = { text: /Reply \d+/.exec(screen[row]!)![0], row };
  ctx.host!.dispatch("timeline.showOlder");
  await settle();
  expect(recorded(ctx, "loadOlderThreadTurns")).toEqual([[ctx.thread!.id]]);
  ctx.page = { hasMore: true, loadingOlder: true };
  await updateThread(ctx, () => ({}));
});

step("the user sees that earlier turns are loading", async (ctx: ScrollWorld) => {
  expect(timelineText(ctx).join("\n")).toContain("Loading earlier turns");
});

step(
  "the earlier turns appear above without moving the message being read",
  async (ctx: ScrollWorld) => {
    ctx.page = { hasMore: false, loadingOlder: false };
    await updateThread(ctx, (detail) => ({
      messages: [...replies(6, "Older"), ...detail.messages],
    }));
    await render(ctx);
    expect(timelineText(ctx).join("\n")).toContain("Older 0");
    const screen = (await snapshot(ctx)).split("\n");
    expect(screen.findIndex((line) => line.includes(ctx.anchor!.text))).toBe(ctx.anchor!.row);
  },
);

step("what is loaded leaves room in the view", async (ctx: ScrollWorld) => {
  await updateThread(ctx, () => ({ messages: replies(2) }));
  await render(ctx);
});

step("the earlier turns are loaded without the user scrolling", (ctx: ScrollWorld) => {
  expect(recorded(ctx, "loadOlderThreadTurns")).toEqual([[ctx.thread!.id]]);
});

// --- links -----------------------------------------------------------------------------

step("the agent writes {string}", async (ctx: ScrollWorld, text: string) => {
  await updateThread(ctx, (detail) => ({
    messages: [
      ...detail.messages,
      message("m-link", "assistant", `${text}\n\nand \`code https://example.com/x\``, 95),
    ],
  }));
  await render(ctx);
});

const chunksOf = (ctx: ScrollWorld) =>
  hostState(ctx, "timeline").items.flatMap((item: any) =>
    item.lines.flatMap((entry: any) => entry.text.chunks),
  ) as Array<{ text: string; link?: { url: string } }>;

step("{string} can be opened as a link", (ctx: ScrollWorld, url: string) => {
  expect(chunksOf(ctx).filter((part) => part.link?.url === url)).not.toHaveLength(0);
});

step("web addresses inside code are left as text", (ctx: ScrollWorld) => {
  expect(chunksOf(ctx).some((part) => part.link?.url === "https://example.com/x")).toBe(false);
  expect(plain({ chunks: chunksOf(ctx) })).toContain("https://example.com/x");
});

// --- long threads ----------------------------------------------------------------------

const PLAIN_ROW = /Long (\d+)\b/;

step("the user is reading a row in a thread of more than 80 rows", async (ctx: ScrollWorld) => {
  await updateThread(ctx, () => ({ messages: replies(90, "Long") }));
  await render(ctx);
  expect(hostState(ctx, "timeline").windowEnd).toBeGreaterThan(80);
  await scrollUp(ctx, 3);
  const screen = (await snapshot(ctx)).split("\n");
  const row = screen.findIndex((line) => PLAIN_ROW.test(line));
  expect(row).toBeGreaterThanOrEqual(0);
  ctx.anchor = { text: PLAIN_ROW.exec(screen[row]!)![0], row };
});

step("the agent streams more rows into the thread", async (ctx: ScrollWorld) => {
  for (const batch of [2, 4, 6]) {
    await updateThread(ctx, (detail) => ({
      // Taller than the rows they push out of the window, so the content grows.
      messages: [
        ...detail.messages,
        ...replies(batch, `Streamed${batch}`, 1000 * batch).map((entry) => ({
          ...entry,
          text: `${entry.text}\n\nA third paragraph.\n\nA fourth paragraph.\n\nA fifth paragraph.\n\nA sixth paragraph.`,
        })),
      ],
    }));
    await render(ctx);
  }
});

step("the row being read stays where it was", async (ctx: ScrollWorld) => {
  const screen = (await snapshot(ctx)).split("\n");
  expect(screen.findIndex((line) => line.includes(ctx.anchor!.text))).toBe(ctx.anchor!.row);
});

step("the user has paged back to an older window of a long thread", async (ctx: ScrollWorld) => {
  await updateThread(ctx, () => ({ messages: replies(120, "Long") }));
  await render(ctx);
  ctx.host!.dispatch("timeline.showOlder");
  await settle();
  await render(ctx);
  const older = hostState(ctx, "timeline");
  expect(older.windowEnd).toBeLessThan(older.rowCount);
});

step("the user presses Ctrl+End", async (ctx: ScrollWorld) => {
  await pressKey(ctx, "Ctrl+End");
  await render(ctx);
});

step("the newest rows are shown at the end", async (ctx: ScrollWorld) => {
  const latest = hostState(ctx, "timeline");
  expect(latest.windowEnd).toBe(latest.rowCount);
  expect(await snapshot(ctx)).toContain("Long 119");
  expect(atEnd(ctx)).toBe(true);
});

step('"Scroll to end" is no longer offered', async (ctx: ScrollWorld) => {
  expect(await snapshot(ctx)).not.toContain("Scroll to end");
});
