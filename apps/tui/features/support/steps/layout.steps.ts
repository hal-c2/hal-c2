// The remaining features/tui/layout.feature scenarios: the detail panel and
// drawer slots, the capped content column, resizing, the prompt's height and
// wide characters. Assertions read `layout` and the laid-out objects.
import { expect } from "bun:test";

import {
  CHAT_CONTENT_MAX_WIDTH,
  COMPOSER_MAX_EDITOR_ROWS,
  COMPOSER_MIN_EDITOR_ROWS,
  MIN_TERMINAL_DRAWER_ROWS,
  MIN_TIMELINE_ROWS,
} from "../../../src/components/ChatView.layout.ts";
import type { TuiLayoutState } from "../../../src/host/layoutState.ts";
import { step } from "../../steps.ts";
import { addThread, flush, ui } from "../environment.ts";
import { ready } from "../gitWorld.ts";
import { sidebar, threadRows } from "../threadUi.ts";
import {
  boot,
  findObject,
  geometry,
  pressKey,
  resize,
  snapshot,
  typeText,
  type World,
} from "../world.ts";

interface LayoutWorld extends World {
  drawerRows?: number;
}

const layout = (ctx: World) => ctx.host!.state.get("layout") as TuiLayoutState;
const box = (ctx: World, objectName: string) => geometry(findObject(ctx, objectName));

async function press(ctx: World, key: string): Promise<void> {
  await pressKey(ctx, key);
  await flush(ctx);
}

/** Words that wrap to more than `lines` rows at the current width, marked at both ends. */
function longPrompt(ctx: World, lines: number): string {
  const words = Math.ceil(((lines + 2) * (ctx.columns ?? 100)) / 5);
  return `START ${Array.from({ length: words }, () => "word").join(" ")} END`;
}

// --- Detail panel -----------------------------------------------------------

// Shared with the git steps: a git world (gitWorld.ts `scm`) boots on its thread first.
step("the user opens the source-control panel", async (ctx: World) => {
  if ((ctx as World & { scm?: unknown }).scm) await ready(ctx);
  else await boot(ctx);
  await press(ctx, "Ctrl+L");
  expect(layout(ctx).rightPanel).toMatchObject({ visible: true, kind: "sourceControl" });
});

step("the panel sits beside the conversation", async (ctx: World) => {
  expect(layout(ctx).rightPanel.asMain).toBe(false);
  const main = box(ctx, "main");
  const panel = box(ctx, "rightPanel");
  expect(main.visible).toBe(true);
  expect(panel.visible).toBe(true);
  expect(panel.width).toBe(layout(ctx).rightPanel.width);
  expect(panel.x).toBeGreaterThanOrEqual(main.x + main.width);
  expect(panel.x + panel.width).toBeLessThanOrEqual(ctx.columns!);
});

step("the panel replaces the conversation until it is closed", async (ctx: World) => {
  expect(layout(ctx).rightPanel.asMain).toBe(true);
  expect(box(ctx, "main").visible).toBe(false);
  expect(box(ctx, "rightPanel")).toMatchObject({ visible: true, width: layout(ctx).mainWidth });
  await press(ctx, "Ctrl+L");
  expect(layout(ctx).rightPanel.visible).toBe(false);
  expect(box(ctx, "rightPanel").visible).toBe(false);
  expect(box(ctx, "main").visible).toBe(true);
});

// --- Content column ---------------------------------------------------------

step(
  "the conversation and prompt are no wider than {int} columns and centred",
  async (ctx: World, cap: number) => {
    expect(cap).toBe(CHAT_CONTENT_MAX_WIDTH);
    await snapshot(ctx);
    const main = box(ctx, "main");
    const content = box(ctx, "content");
    expect(content.width).toBe(cap);
    expect(box(ctx, "conversation").width).toBeLessThanOrEqual(cap);
    expect(box(ctx, "composer").width).toBeLessThanOrEqual(cap);
    // Centred in the main column (within a cell of rounding).
    const left = content.x;
    const right = main.width - content.x - content.width;
    expect(Math.abs(left - right)).toBeLessThanOrEqual(1);
    expect(left).toBeGreaterThan(0);
  },
);

// --- Resizing ---------------------------------------------------------------

step("the terminal client is open at {int} by {int}", async (ctx: World, columns, rows) => {
  addThread(ctx, "Resize the checkout page");
  await resize(ctx, columns, rows);
  await ui(ctx);
  const lines = (await snapshot(ctx)).split("\n");
  expect(lines.some((line) => Bun.stringWidth(line.trimEnd()) > 80)).toBe(true);
});

step("the terminal is resized to {int} by {int}", async (ctx: World, columns, rows) => {
  await resize(ctx, columns, rows);
  await flush(ctx);
});

step("every pane is redrawn inside the new size", async (ctx: World) => {
  const lines = (await snapshot(ctx)).replace(/\n$/, "").split("\n");
  expect(lines.length).toBeLessThanOrEqual(ctx.rows!);
  for (const line of lines) expect(Bun.stringWidth(line)).toBeLessThanOrEqual(ctx.columns!);
  for (const name of ["sidebar", "main", "statusLine"]) {
    const pane = box(ctx, name);
    if (!pane.visible) continue;
    expect(pane.x + pane.width).toBeLessThanOrEqual(ctx.columns!);
    expect(pane.y + pane.height).toBeLessThanOrEqual(ctx.rows!);
  }
  expect(layout(ctx).panesRows + layout(ctx).composerRows).toBeLessThan(ctx.rows!);
});

step("no text is left from the previous layout", async (ctx: World) => {
  const screen = await snapshot(ctx);
  // Each piece of chrome is drawn once, where the new layout puts it.
  const count = (text: string) => screen.split(text).length - 1;
  expect(count(" Threads ")).toBe(box(ctx, "sidebar").visible ? 1 : 0);
  expect(count("1 project(s)")).toBe(1);
  const lastLine = screen.replace(/\n$/, "").split("\n")[ctx.rows! - 1] ?? "";
  expect(lastLine).toContain("1 project(s)");
});

// --- Prompt height ----------------------------------------------------------

step("the prompt shows {int} editable rows", async (ctx: World, rows: number) => {
  expect(rows).toBe(COMPOSER_MIN_EDITOR_ROWS);
  expect(layout(ctx).editorRows).toBe(rows);
  expect(box(ctx, "composerInput")).toMatchObject({ visible: true, height: rows });
});

step("the user types a prompt longer than {int} wrapped lines", async (ctx: World, lines) => {
  // The prompt belongs to a thread (or a new-thread draft).
  await openFirstThread(ctx);
  await typeText(ctx, longPrompt(ctx, lines));
  await flush(ctx);
});

step("the prompt stops growing at {int} rows", async (ctx: World, rows: number) => {
  expect(rows).toBe(COMPOSER_MAX_EDITOR_ROWS);
  expect(layout(ctx).editorRows).toBe(rows);
  expect(box(ctx, "composerInput").height).toBe(rows);
});

step("the prompt scrolls to keep the cursor visible", async (ctx: World) => {
  const screen = await snapshot(ctx);
  expect(screen).toContain("END");
  expect(screen).not.toContain("START");
});

// --- Terminal drawer --------------------------------------------------------

/**
 * Show the drawer: it is the selected thread's terminal, so the first listed
 * thread is opened first. Opening focuses the terminal; Ctrl+P hands the
 * keys back to the prompt.
 */
async function openFirstThread(ctx: World) {
  await boot(ctx);
  if ((ctx.host!.state.get("page") as { kind: string }).kind === "thread") return;
  ctx.fake!.connect();
  await flush(ctx);
  const first = threadRows(ctx)[0];
  expect(first, "no thread to open").toBeDefined();
  ctx.host!.dispatch("thread.open", { key: first!.key });
  await ctx.host!.settled();
}

async function showDrawer(ctx: World) {
  await boot(ctx);
  if (!(ctx.host!.state.get("terminal") as { available: boolean }).available) {
    await openFirstThread(ctx);
  }
  await press(ctx, "Ctrl+E");
  await ctx.host!.settled();
  if (ctx.host!.state.get("mode") === "terminal") await press(ctx, "Ctrl+P");
}

step("the terminal drawer is open", async (ctx: World) => {
  await showDrawer(ctx);
  expect(layout(ctx).drawer.open).toBe(true);
  expect(box(ctx, "drawer").visible).toBe(true);
});

step("the user types a very long prompt on a short terminal", async (ctx: World) => {
  await resize(ctx, ctx.columns!, 24);
  await typeText(ctx, longPrompt(ctx, COMPOSER_MAX_EDITOR_ROWS));
  await flush(ctx);
  expect(layout(ctx).editorRows).toBeGreaterThan(COMPOSER_MIN_EDITOR_ROWS);
});

step("the terminal drawer keeps at least {int} rows", async (ctx: World, rows: number) => {
  expect(rows).toBe(MIN_TERMINAL_DRAWER_ROWS);
  expect(layout(ctx).drawer.rows).toBeGreaterThanOrEqual(rows);
  expect(box(ctx, "drawer").height).toBeGreaterThanOrEqual(rows);
});

step("the timeline keeps at least {int} rows", async (ctx: World, rows: number) => {
  expect(rows).toBe(MIN_TIMELINE_ROWS);
  expect(box(ctx, "conversation").height).toBeGreaterThanOrEqual(rows);
});

step("the terminal drawer is open at its preferred size", async (ctx: LayoutWorld) => {
  await showDrawer(ctx);
  ctx.drawerRows = Math.floor(ctx.rows! * 0.4);
  expect(layout(ctx).drawer.rows).toBe(ctx.drawerRows);
  expect(box(ctx, "drawer").height).toBe(ctx.drawerRows);
});

step("a picker opens above the prompt", async (ctx: World) => {
  await press(ctx, "Ctrl+K");
  expect(box(ctx, "commandPalette").visible).toBe(true);
  expect(layout(ctx).popoverRows).toBeGreaterThan(0);
});

step("the terminal drawer keeps its preferred size", async (ctx: LayoutWorld) => {
  expect(layout(ctx).drawer.rows).toBe(ctx.drawerRows!);
  expect(box(ctx, "drawer").height).toBe(ctx.drawerRows!);
});

// --- Wide characters --------------------------------------------------------

const WIDE_TITLE = "修复登录页面 🚀 的错误并且检查所有的边界情况 🎉🎉";

step("a thread title that contains emoji and CJK characters", async (ctx: World) => {
  addThread(ctx, WIDE_TITLE);
  addThread(ctx, "Plain ascii title");
  await ui(ctx);
});

step(
  "the title is clipped by display width and never pushes other columns out of line",
  async (ctx: World) => {
    const lines = (await snapshot(ctx)).split("\n");
    const width = layout(ctx).listWidth;
    const rowY = (title: string) =>
      2 +
      sidebar(ctx).visibleRows.findIndex(
        (row) => row.kind === "thread" && row.thread.title === title,
      );
    const wide = lines[rowY(WIDE_TITLE)]!;
    const plain = lines[rowY("Plain ascii title")]!;
    // The title is clipped: it does not fit whole in the list pane.
    expect(wide).toContain("修复登录");
    expect(wide).toContain("...");
    expect(wide).not.toContain(WIDE_TITLE);
    // The pane's right border sits in the same column on both rows.
    const borderAt = (line: string) => {
      let column = 0;
      for (const char of line) {
        if (char === "│" && column > 0) return column;
        column += Bun.stringWidth(char);
      }
      return -1;
    };
    expect(borderAt(wide)).toBe(width - 1);
    expect(borderAt(plain)).toBe(width - 1);
    for (const line of lines) expect(Bun.stringWidth(line)).toBeLessThanOrEqual(ctx.columns!);
  },
);
