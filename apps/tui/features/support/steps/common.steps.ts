// Steps shared across feature areas. Workers append their own sections
// (`// --- added by Tn ---`) or add feature-area files next to this one.
import { expect } from "bun:test";

import { step } from "../../steps.ts";
import { LIST_PANE_WIDTH } from "../../../src/components/ChatView.layout.ts";
import {
  boot,
  findObject,
  geometry,
  pressKey,
  resize,
  settle,
  snapshot,
  type World,
} from "../world.ts";

const NARROW_COLUMNS = 70;
const STATUS_ROWS = 1;

step("the terminal is {int} columns wide", async (ctx: World, columns: number) => {
  await resize(ctx, columns);
});

step("the user presses {string}", async (ctx: World, key: string) => {
  await pressKey(ctx, key);
});

step("the thread list is docked beside the conversation at full height", async (ctx: World) => {
  await snapshot(ctx);
  const sidebar = geometry(findObject(ctx, "sidebar"));
  const main = geometry(findObject(ctx, "main"));
  expect(sidebar).toMatchObject({ visible: true, x: 0, width: LIST_PANE_WIDTH });
  expect(sidebar.height).toBe(ctx.rows! - STATUS_ROWS);
  expect(main).toMatchObject({ visible: true, x: LIST_PANE_WIDTH });
  expect(main.width).toBe(ctx.columns! - LIST_PANE_WIDTH);
});

step("the thread list is hidden", async (ctx: World) => {
  await snapshot(ctx);
  expect(geometry(findObject(ctx, "sidebar")).visible).toBe(false);
});

step("the conversation takes the full width", async (ctx: World) => {
  await snapshot(ctx);
  expect(geometry(findObject(ctx, "main"))).toMatchObject({
    visible: true,
    x: 0,
    width: ctx.columns!,
  });
});

async function expectListOverConversation(ctx: World): Promise<void> {
  await snapshot(ctx);
  expect(geometry(findObject(ctx, "sidebar"))).toMatchObject({
    visible: true,
    x: 0,
    width: ctx.columns!,
  });
  expect(geometry(findObject(ctx, "main")).visible).toBe(false);
  expect(findObject(ctx, "sidebarFilter").get("focused")).toBe(true);
}

step(
  "the thread list opens over the conversation with the filter focused",
  expectListOverConversation,
);

step("the thread list is open over the conversation on a narrow terminal", async (ctx: World) => {
  await resize(ctx, NARROW_COLUMNS);
  await pressKey(ctx, "Ctrl+F");
  await expectListOverConversation(ctx);
});

step("the thread list closes and the conversation has the full width again", async (ctx: World) => {
  await snapshot(ctx);
  expect(geometry(findObject(ctx, "sidebar")).visible).toBe(false);
  expect(findObject(ctx, "sidebarFilter").get("focused")).toBe(false);
  expect(geometry(findObject(ctx, "main"))).toMatchObject({
    visible: true,
    x: 0,
    width: ctx.columns!,
  });
});

step(
  "the status line says {string} until the first snapshot arrives",
  async (ctx: World, text: string) => {
    const app = await boot(ctx);
    expect(findObject(ctx, "statusText").get("text")).toBe(text);
    expect(await app.snapshot()).toContain(text);
    ctx.fake!.connect();
    expect(await app.snapshot()).not.toContain(text);
  },
);

// --- added by T3 ---

/** The status line reads (or contains) this text. */
step("the status line says {string}", async (ctx: World, text: string) => {
  await settle(ctx);
  expect(String(findObject(ctx, "statusText").get("text"))).toContain(text);
});

/** Feedback the user reads: the status line carries it. */
step("the user is told {string}", async (ctx: World, text: string) => {
  await settle(ctx);
  expect(String(findObject(ctx, "statusText").get("text"))).toContain(text);
});
