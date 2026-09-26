// What a user does with the thread list, driven through the real shell:
// clicks and right-clicks on the rows they see, the context menu, the command
// palette and the filter. Steps assert on the host state and the screen.
import { expect } from "bun:test";
import { MouseButtons } from "@opentui/core/testing";

import type { TuiContextMenuState } from "../../src/host/threadActions.ts";
import type { TuiPaletteState } from "../../src/host/paletteState.ts";
import type { TuiSidebarRow, TuiSidebarState } from "../../src/host/sidebarState.ts";
import { flush, ui } from "./environment.ts";
import { findObject, pressKey, snapshot, typeText, type World } from "./world.ts";

export const sidebar = (ctx: World) => ctx.host!.state.get("sidebar") as TuiSidebarState;
export const contextMenu = (ctx: World) =>
  ctx.host!.state.get("contextMenu") as TuiContextMenuState | null;
export const palette = (ctx: World) => ctx.host!.state.get("palette") as TuiPaletteState;
export const statusText = (ctx: World) =>
  (ctx.host!.state.get("status") as { text: string; kind: string }).text;

export type ThreadRow = Extract<TuiSidebarRow, { kind: "thread" }>;

export const threadRows = (ctx: World, rows = sidebar(ctx).rows): ThreadRow[] =>
  rows.filter((row): row is ThreadRow => row.kind === "thread");

/** Titles in list order (every listed row, not only the ones on screen). */
export const listedTitles = (ctx: World) => threadRows(ctx).map((row) => row.thread.title);

export function listedRow(ctx: World, title: string): ThreadRow | undefined {
  return threadRows(ctx).find((row) => row.thread.title === title);
}

/** The list viewport's top-left cell. */
export function listOrigin(ctx: World): { x: number; y: number } {
  const { renderable } = findObject(ctx, "sidebarList") as unknown as {
    renderable: { x: number; y: number };
  };
  return { x: renderable.x, y: renderable.y };
}

/** The screen rows of the thread `title`'s lines on screen (a card has four), top to bottom. */
export function rowLineYs(ctx: World, title: string): number[] {
  const row = listedRow(ctx, title);
  if (!row) throw new Error(`"${title}" is not in the thread list`);
  const origin = listOrigin(ctx);
  const ys: number[] = [];
  sidebar(ctx).lines.forEach((line, index) => {
    if (line.key === row.key) ys.push(origin.y + index);
  });
  return ys;
}

/** Where the title of `title`'s row is on screen; fails when it is scrolled out or unlisted. */
export function rowPosition(ctx: World, title: string): { x: number; y: number } {
  const row = listedRow(ctx, title);
  if (!row) throw new Error(`"${title}" is not in the thread list`);
  // An active thread's card has its title on its second line, inside the card's padding;
  // a shelved row's title follows the selection bar and the status dot.
  const card = row.thread.section === "active";
  const index = sidebar(ctx).lines.findIndex(
    (line) => line.key === row.key && line.part === (card ? 1 : 0),
  );
  if (index < 0) throw new Error(`"${title}" is not on screen in the thread list`);
  const origin = listOrigin(ctx);
  return { x: origin.x + (card ? 3 : 4), y: origin.y + index };
}

/** The first screen cell showing `text` (display-width columns), or null. */
export async function findOnScreen(
  ctx: World,
  text: string,
): Promise<{ x: number; y: number } | null> {
  const lines = (await snapshot(ctx)).split("\n");
  for (const [y, line] of lines.entries()) {
    const index = line.indexOf(text);
    if (index >= 0) return { x: Bun.stringWidth(line.slice(0, index)), y };
  }
  return null;
}

export async function click(ctx: World, at: { x: number; y: number }): Promise<void> {
  await ctx.app!.click(at.x, at.y);
  await flush(ctx);
}

export async function clickText(ctx: World, text: string): Promise<void> {
  const at = await findOnScreen(ctx, text);
  if (!at) throw new Error(`"${text}" is not on screen:\n${await snapshot(ctx)}`);
  await click(ctx, { x: at.x + 1, y: at.y });
}

export async function selectThread(ctx: World, title: string): Promise<void> {
  await ui(ctx);
  await click(ctx, rowPosition(ctx, title));
  expect(sidebar(ctx).activeThreadKey).toBe(listedRow(ctx, title)!.key);
}

export async function rightClick(ctx: World, at: { x: number; y: number }): Promise<void> {
  await ctx.app!.mockMouse.click(at.x, at.y, MouseButtons.RIGHT);
  await ctx.app!.renderOnce();
  await flush(ctx);
}

export async function openMenu(ctx: World, title: string): Promise<TuiContextMenuState> {
  await ui(ctx);
  await rightClick(ctx, rowPosition(ctx, title));
  const menu = contextMenu(ctx);
  expect(menu?.threadKey).toBe(listedRow(ctx, title)!.key);
  return menu!;
}

/** Click a menu item where it is drawn (inside the menu's border). */
export async function chooseMenuItem(ctx: World, label: string): Promise<void> {
  const menu = contextMenu(ctx);
  if (!menu) throw new Error(`no menu is open to choose "${label}"`);
  const index = menu.rows.findIndex((row) => row.kind === "item" && row.label === label);
  if (index < 0) throw new Error(`the menu has no "${label}"`);
  await click(ctx, { x: menu.x + 2, y: menu.y + 1 + index });
}

export async function fromMenu(ctx: World, title: string, label: string): Promise<void> {
  await openMenu(ctx, title);
  await chooseMenuItem(ctx, label);
}

/** Run a palette command by typing its name and pressing Enter. */
export async function runCommand(ctx: World, name: string): Promise<void> {
  await ui(ctx);
  await pressKey(ctx, "Ctrl+K");
  await typeText(ctx, name);
  expect(palette(ctx).commands[0]?.title).toBe(name);
  await pressKey(ctx, "Enter");
  await flush(ctx);
}

/**
 * Choose a palette command among the matches, as the user does: open the
 * palette (Ctrl+K) unless it is open, type the name, arrow down to it, Enter.
 */
export async function chooseCommand(ctx: World, name: string): Promise<void> {
  await ui(ctx);
  // A focused terminal keeps Ctrl+K for its program: hand focus back (Ctrl+P) first.
  if (ctx.host!.state.get("mode") === "terminal") await pressKey(ctx, "Ctrl+P");
  if (!palette(ctx).open) await pressKey(ctx, "Ctrl+K");
  await typeText(ctx, name);
  const index = palette(ctx).commands.findIndex((item) => item.title === name);
  expect(index, `no "${name}" in the palette`).toBeGreaterThanOrEqual(0);
  for (let i = 0; i < index; i += 1) await pressKey(ctx, "Down");
  await pressKey(ctx, "Enter");
  await flush(ctx);
}

export async function filterBy(ctx: World, query: string): Promise<void> {
  await ui(ctx);
  await pressKey(ctx, "Ctrl+F");
  await typeText(ctx, query);
  await flush(ctx);
}

/** Rename through the row's menu: clear the prefilled title, type, Enter. */
export async function rename(ctx: World, title: string, next: string): Promise<void> {
  await fromMenu(ctx, title, "Rename thread");
  for (let i = 0; i < title.length; i += 1) await pressKey(ctx, "Backspace");
  if (next.length > 0) await typeText(ctx, next);
  await pressKey(ctx, "Enter");
  await flush(ctx);
}
