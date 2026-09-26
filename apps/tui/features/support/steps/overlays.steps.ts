// The overlays as the OpenTUI client draws them (CommandPalette, SelectOverlay,
// ContextMenu, ThreadOverlays, AddProjectOverlay, SettingsView and the rename
// and commit prompts): features/tui/threads.feature, composer-controls.feature,
// settings.feature, git.feature and timeline.feature.
import { expect } from "bun:test";

import type { TuiAddProjectState } from "../../../src/host/addProjectState.ts";
import { THEME } from "../../../src/theme.ts";
import { step } from "../../steps.ts";
import {
  expectColour,
  expectRoundedFrame,
  rectOf,
  regionCells,
  textWithin,
  type Rect,
} from "../design.ts";
import { chooseCommand, contextMenu, palette } from "../threadUi.ts";
import { findObject, geometry, pressKey, resize, settle, snapshot, type World } from "../world.ts";
import { chooseSource } from "./projects.steps.ts";

type Colour = keyof typeof THEME;
const colour = (name: string) => {
  const value = THEME[(name === "background" ? "bg" : name) as Colour];
  if (!value) throw new Error(`no "${name}" colour in the theme`);
  return value;
};

const visible = (ctx: World, objectName: string) => {
  try {
    return geometry(findObject(ctx, objectName)).visible;
  } catch {
    return false;
  }
};

// The boxes scenarios name, by the object that draws them.
const BOXES: Record<string, (ctx: World) => string> = {
  palette: () => "commandPalette",
  picker: () => "selectOverlay",
  "add-project box": () => "addProject",
  "settings pane": () => "settingsPage",
  "context menu": () => "contextMenu",
  // The rename and commit prompts take the prompt's place.
  prompt: (ctx) => (visible(ctx, "composerAux") ? "composerAux" : "composer"),
  box: (ctx) => (visible(ctx, "threadOverlay") ? "threadOverlay" : "revertPicker"),
};
const BOX = Object.keys(BOXES)
  .map((name) => name.replace("-", "\\-"))
  .join("|");
const boxName = (ctx: World, name: string) => BOXES[name]!(ctx);

/** Inside the border and the one cell of padding on each side. */
async function inner(ctx: World, name: string): Promise<Rect> {
  await settle(ctx);
  const { x, y, width, height } = rectOf(ctx, boxName(ctx, name));
  return { x: x + 2, y: y + 1, width: width - 4, height: height - 2 };
}

async function innerRows(ctx: World, name: string): Promise<string[]> {
  const rect = await inner(ctx, name);
  return (await regionCells(ctx, rect)).map((row) => row.map((cell) => cell.text).join(""));
}

const ORDINALS = ["first", "second", "third"];
function rowIndex(rows: readonly unknown[], ordinal: string): number {
  return ordinal === "last" ? rows.length - 1 : ORDINALS.indexOf(ordinal);
}

/** One inner row as a rect, by ordinal. */
async function rowRect(ctx: World, name: string, ordinal: string): Promise<Rect> {
  const rect = await inner(ctx, name);
  const index = ordinal === "last" ? rect.height - 1 : ORDINALS.indexOf(ordinal);
  return { ...rect, y: rect.y + index, height: 1 };
}

/** Every non-blank cell of `text` where it sits in `rect` has the colour. */
async function expectTextColour(ctx: World, rect: Rect, text: string, name: string) {
  const at = await textWithin(ctx, rect, text);
  const row = (await regionCells(ctx, { ...rect, y: at.y, height: 1 }))[0]!;
  let x = at.x - rect.x;
  for (const glyph of text) {
    const cell = row[x];
    if (glyph.trim() !== "" && cell) expectColour(cell.span.fg, colour(name));
    x += Bun.stringWidth(glyph) || 1;
  }
}

const screen = (ctx: World): Rect => ({
  x: 0,
  y: 0,
  width: ctx.columns ?? 100,
  height: ctx.rows ?? 40,
});

// --- Frames and rows -------------------------------------------------------------------

step(
  new RegExp(`^the (${BOX}) has a rounded border in the (\\w+) colour$`),
  async (ctx: World, name: string, fg: string) => {
    await settle(ctx);
    await expectRoundedFrame(ctx, rectOf(ctx, boxName(ctx, name)), colour(fg));
  },
);

step(
  /^a box with a rounded border in the (\w+) colour sits above the prompt$/,
  async (ctx: World, fg: string) => {
    await settle(ctx);
    const box = rectOf(ctx, boxName(ctx, "box"));
    await expectRoundedFrame(ctx, box, colour(fg));
    expect(box.y + box.height).toBeLessThanOrEqual(rectOf(ctx, "composer").y);
  },
);

step(
  new RegExp(`^the prompt is still shown under the (${BOX})$`),
  async (ctx: World, name: string) => {
    await settle(ctx);
    const box = rectOf(ctx, boxName(ctx, name));
    expect(visible(ctx, "composer")).toBe(true);
    expect(rectOf(ctx, "composer").y).toBeGreaterThanOrEqual(box.y + box.height);
  },
);

step(
  new RegExp(
    `^the (${BOX})'s (first|second|third|last) row reads "([^"]*)"(?: in the (\\w+) colour)?$`,
  ),
  async (ctx: World, name: string, ordinal: string, text: string, fg?: string) => {
    const rows = await innerRows(ctx, name);
    expect(rows[rowIndex(rows, ordinal)]!.trimEnd()).toBe(text);
    if (fg) await expectTextColour(ctx, await rowRect(ctx, name, ordinal), text.trim(), fg);
  },
);

step(
  new RegExp(`^the (${BOX})'s (first|second|third|last) row is in the (\\w+) colour$`),
  async (ctx: World, name: string, ordinal: string, fg: string) => {
    const rows = await innerRows(ctx, name);
    const text = rows[rowIndex(rows, ordinal)]!.trim();
    expect(text).not.toBe("");
    await expectTextColour(ctx, await rowRect(ctx, name, ordinal), text, fg);
  },
);

step(
  new RegExp(
    `^the (${BOX})'s "([^"]*)" is in the (\\w+) colour and "([^"]*)" in the (\\w+) colour$`,
  ),
  async (ctx: World, name: string, first: string, a: string, second: string, b: string) => {
    const rect = await inner(ctx, name);
    await expectTextColour(ctx, rect, first, a);
    await expectTextColour(ctx, rect, second, b);
  },
);

step(
  /^"([^"]*)" is in the (\w+) colour and "([^"]*)" in the (\w+) colour$/,
  async (ctx: World, first: string, a: string, second: string, b: string) => {
    await settle(ctx);
    const at = await textWithin(ctx, screen(ctx), first);
    const row = { ...screen(ctx), y: at.y, height: 1 };
    await expectTextColour(ctx, row, first, a);
    await expectTextColour(ctx, row, second, b);
  },
);

step(
  /^"([^"]*)" is in the (\w+) colour, "([^"]*)" in the (\w+) colour and "([^"]*)" in the (\w+) colour$/,
  async (ctx: World, ...pairs: string[]) => {
    await settle(ctx);
    const at = await textWithin(ctx, screen(ctx), pairs[0]!);
    const row = { ...screen(ctx), y: at.y, height: 1 };
    for (let i = 0; i < pairs.length; i += 2)
      await expectTextColour(ctx, row, pairs[i]!, pairs[i + 1]!);
  },
);

// --- The command palette ---------------------------------------------------------------

/** The palette's highlighted row: its cells inside the padding. */
async function paletteRow(ctx: World, ordinal: string) {
  const rect = await rowRect(ctx, "palette", ordinal);
  return { rect, cells: (await regionCells(ctx, rect))[0]! };
}

step("that row has the selected background across the palette", async (ctx: World) => {
  const { cells } = await paletteRow(ctx, "second");
  for (const cell of cells) expectColour(cell.span.bg, THEME.selectedBg);
});

step(
  /^its "([^"]*)" is in the (\w+) colour, "([^"]*)" in the (\w+) colour and "([^"]*)" in the (\w+) colour$/,
  async (ctx: World, ...pairs: string[]) => {
    const { rect } = await paletteRow(ctx, "second");
    for (let i = 0; i < pairs.length; i += 2)
      await expectTextColour(ctx, rect, pairs[i]!, pairs[i + 1]!);
  },
);

step(
  "the terminal is {int} columns wide and {int} rows tall",
  async (ctx: World, columns, rows) => {
    await resize(ctx, columns, rows);
  },
);

step("the last command is highlighted and shown in the palette", async (ctx: World) => {
  const state = palette(ctx);
  const last = state.commands.at(-1)!;
  expect(state.index).toBe(state.commands.length - 1);
  const rows = await innerRows(ctx, "palette");
  expect(rows.some((row) => row.trimEnd().startsWith(`▸ ${last.title}`))).toBe(true);
});

step("{string} is not shown in the palette", async (ctx: World, text: string) => {
  expect((await innerRows(ctx, "palette")).join("\n")).not.toContain(text);
});

// --- The context menu ------------------------------------------------------------------

type MenuItem = Extract<
  NonNullable<ReturnType<typeof contextMenu>>["rows"][number],
  { kind: "item" }
>;
const menuItems = (ctx: World) =>
  contextMenu(ctx)!.rows.filter((row): row is MenuItem => row.kind === "item");

/** The menu's inner row showing `label`, with its cells. */
async function menuRow(ctx: World, label: string) {
  const rect = await inner(ctx, "context menu");
  const at = await textWithin(ctx, rect, label);
  const row = { ...rect, y: at.y, height: 1 };
  return { row, at, cells: (await regionCells(ctx, row))[0]! };
}

step(
  'the highlighted item is marked "▸" in the accent colour and reads in the text colour on the selected background',
  async (ctx: World) => {
    const active = menuItems(ctx).find((item) => item.active)!;
    const { row, cells } = await menuRow(ctx, active.label);
    expect(cells[0]!.text).toBe("▸");
    expectColour(cells[0]!.span.fg, THEME.accent);
    await expectTextColour(ctx, row, active.label, "text");
    for (const cell of cells) expectColour(cell.span.bg, THEME.selectedBg);
  },
);

step("the other enabled items are in the dim colour", async (ctx: World) => {
  const others = menuItems(ctx).filter(
    (item) => !item.active && !item.disabled && !item.destructive,
  );
  expect(others.length).toBeGreaterThan(0);
  for (const item of others) {
    const { row, cells } = await menuRow(ctx, item.label);
    await expectTextColour(ctx, row, item.label, "dim");
    for (const cell of cells) expectColour(cell.span.bg, THEME.bg);
  }
});

step("every separator is a faint line as wide as the items", async (ctx: World) => {
  const rect = await inner(ctx, "context menu");
  const rows = await regionCells(ctx, rect);
  const separators = rows.filter((row) => row[0]?.text === "─");
  expect(separators.length).toBe(
    contextMenu(ctx)!.rows.filter((row) => row.kind === "separator").length,
  );
  for (const row of separators) {
    expect(row.map((cell) => cell.text).join("")).toBe("─".repeat(rect.width));
    for (const cell of row) expectColour(cell.span.fg, THEME.faint);
  }
});

step("the pointer moves over {string}", async (ctx: World, label: string) => {
  const { at } = await menuRow(ctx, label);
  await ctx.app!.mockMouse.moveTo(at.x + 1, at.y);
  await settle(ctx);
});

step("{string} is highlighted", async (ctx: World, label: string) => {
  expect(menuItems(ctx).find((item) => item.active)?.label).toBe(label);
  const { cells } = await menuRow(ctx, label);
  expect(cells[0]!.text).toBe("▸");
  for (const cell of cells) expectColour(cell.span.bg, THEME.selectedBg);
});

// --- Pickers ---------------------------------------------------------------------------

step(/^the model list (is still loading|fails to load|is empty)$/, async (ctx: World, how) => {
  await snapshot(ctx);
  // A request that never answers would hold every settle; let settles skip it.
  if (how === "is still loading") ctx.held = (ctx.held ?? 0) + 1;
  ctx.fake!.override(
    "listModels",
    how === "is still loading"
      ? () => new Promise<never>(() => {})
      : how === "fails to load"
        ? () => Promise.reject(new Error("offline"))
        : async () => [],
  );
});

step("the picker's rows read:", async (ctx: World, table: string[][]) => {
  const rows = (await innerRows(ctx, "picker")).slice(1).map((row) => row.trim());
  // Gherkin trims table cells, so the indents are the host's rows (checked by colour below).
  expect(rows.slice(0, table.length - 1)).toEqual(table.slice(1).map(([row]) => row!.trim()));
});

/** The two screen rows of a picker option: its name and its description. */
async function optionRows(ctx: World, label: string) {
  const rect = await inner(ctx, "picker");
  const at = await textWithin(ctx, rect, label);
  const rows = await regionCells(ctx, { ...rect, y: at.y, height: 2 });
  return { rect: { ...rect, y: at.y, height: 2 }, rows };
}

step("both rows of {string} have the selected background", async (ctx: World, label: string) => {
  const { rows } = await optionRows(ctx, label);
  for (const row of rows) for (const cell of row) expectColour(cell.span.bg, THEME.selectedBg);
});

step(
  /^the description of "([^"]*)" is in the (\w+) colour$/,
  async (ctx: World, label: string, fg: string) => {
    const { rect, rows } = await optionRows(ctx, label);
    const description = rows[1]!
      .map((cell) => cell.text)
      .join("")
      .trim();
    await expectTextColour(ctx, { ...rect, y: rect.y + 1, height: 1 }, description, fg);
  },
);

step(
  /^"([^"]*)" and its description are in the (\w+) colour$/,
  async (ctx: World, label: string, fg: string) => {
    const { rect, rows } = await optionRows(ctx, label);
    await expectTextColour(ctx, { ...rect, height: 1 }, label, fg);
    const description = rows[1]!
      .map((cell) => cell.text)
      .join("")
      .trim();
    await expectTextColour(ctx, { ...rect, y: rect.y + 1, height: 1 }, description, fg);
  },
);

// --- Adding a project ------------------------------------------------------------------

const flow = (ctx: World) => ctx.host!.state.get("addProject") as TuiAddProjectState;

step(
  /^the add-project box's first row (?:reads "([^"]*)" with|ends with) "([^"]*)"(?: at its right end)? in the (\w+) colour$/,
  async (ctx: World, left: string | undefined, right: string, fg: string) => {
    const rows = await innerRows(ctx, "add-project box");
    const row = rows[0]!;
    if (left !== undefined) expect(row.startsWith(left)).toBe(true);
    expect(row.trimEnd().endsWith(right)).toBe(true);
    expect(row.length).toBe(row.trimEnd().length);
    const rect = await rowRect(ctx, "add-project box", "first");
    await expectTextColour(
      ctx,
      { ...rect, x: rect.x + rect.width - right.length, width: right.length },
      right,
      fg,
    );
  },
);

step(
  /^the add-project box's next rows read "([^"]*)" and "([^"]*)"$/,
  async (ctx: World, first: string, second: string) => {
    const rows = await innerRows(ctx, "add-project box");
    expect(rows.slice(2, 4).map((row) => row.trimEnd())).toEqual([first, second]);
  },
);

step(
  /^"([^"]*)" is followed by "([^"]*)" in the (\w+) colour$/,
  async (ctx: World, text: string, next: string, fg: string) => {
    await settle(ctx);
    const at = await textWithin(ctx, screen(ctx), `${text}${next}`);
    const row = { ...screen(ctx), y: at.y, height: 1 };
    await expectTextColour(ctx, row, next.trim(), fg);
  },
);

step("the user chose {string} from the command palette", async (ctx: World, name: string) => {
  await chooseCommand(ctx, name);
  await settle(ctx);
});

step("the user chooses the {string} source", async (ctx: World, title: string) => {
  await chooseSource(ctx, title);
});

step("the add-project field has the keys", async (ctx: World) => {
  await settle(ctx);
  expect(flow(ctx).listFocused).toBe(false);
  expect(findObject(ctx, "addProjectInput").get("focus")).toBe(true);
});

step("the add-project list has the keys again", async (ctx: World) => {
  await settle(ctx);
  expect(flow(ctx).listFocused).toBe(true);
  expect(visible(ctx, "addProjectInput")).toBe(false);
});

// --- Settings --------------------------------------------------------------------------

/** The settings rows inside the border and padding, under the title row. */
async function settingsRows(ctx: World): Promise<string[]> {
  return (await innerRows(ctx, "settings pane")).slice(1);
}

step("the settings pane's rows start:", async (ctx: World, table: string[][]) => {
  const expected = table.slice(1).map(([row]) => row!.trim());
  const rows = (await settingsRows(ctx)).slice(0, expected.length);
  // Gherkin trims table cells; each row starts with the expected label.
  expect(
    rows.map((row, i) =>
      expected[i] === "" ? row.trim() : row.trim().slice(0, expected[i]!.length),
    ),
  ).toEqual(expected);
});

const settingsGroups = (ctx: World) =>
  (
    ctx.host!.state.get("settings") as {
      groups: Array<{ rows: Array<{ label: string; value: string; keys: boolean }> }>;
    }
  ).groups;

step("every setting's value starts 18 cells into the row", async (ctx: World) => {
  const rows = await settingsRows(ctx);
  const settings = settingsGroups(ctx)
    .flatMap((group) => group.rows)
    .filter((row) => !row.keys);
  for (const setting of settings) {
    const row = rows.find((candidate) => candidate.startsWith(`  ${setting.label.padEnd(16)}`));
    if (!row) continue; // scrolled out of view
    expect(row.slice(0, 18)).toBe(`  ${setting.label}`.padEnd(18));
    expect(row[18]).not.toBe(" ");
  }
});

step("the labels are in the dim colour and the values in the text colour", async (ctx: World) => {
  const rect = await inner(ctx, "settings pane");
  const setting = settingsGroups(ctx)[0]!.rows[0]!;
  const at = await textWithin(ctx, rect, `  ${setting.label}`);
  const row = { ...rect, y: at.y, height: 1 };
  await expectTextColour(ctx, row, setting.label, "dim");
  const value = (await regionCells(ctx, { ...row, x: rect.x + 18, width: rect.width - 18 }))[0]!
    .map((cell) => cell.text)
    .join("")
    .trim();
  await expectTextColour(ctx, { ...row, x: rect.x + 18, width: rect.width - 18 }, value, "text");
});

step("every key binding's keys are padded to 16 cells in the accent colour", async (ctx: World) => {
  // Scroll to the keybinding groups first: they sit under the providers and git state.
  const keys = settingsGroups(ctx)
    .flatMap((group) => group.rows)
    .filter((row) => row.keys);
  expect(keys.length).toBeGreaterThan(0);
  const rect = await inner(ctx, "settings pane");
  const rows = await regionCells(ctx, rect);
  let seen = 0;
  for (const cells of rows) {
    const text = cells.map((cell) => cell.text).join("");
    const key = keys.find((row) => text.startsWith(`  ${row.label.padEnd(16)}`));
    if (!key) continue;
    seen += 1;
    for (const cell of cells.slice(2, 2 + key.label.length)) {
      if (cell.text.trim() !== "") expectColour(cell.span.fg, THEME.accent);
    }
  }
  expect(seen).toBeGreaterThan(0);
});

step("the source-control panel is open beside the conversation", async (ctx: World) => {
  // The terminal size step has already started the client, so no checkout is set up.
  await settle(ctx);
  if (!visible(ctx, "sourceControlPanel")) await pressKey(ctx, "Ctrl+L");
  // Open beside the conversation, the keys back in the prompt.
  if (ctx.host!.state.get("mode") === "panel") await pressKey(ctx, "Ctrl+P");
  await settle(ctx);
  expect(visible(ctx, "sourceControlPanel")).toBe(true);
  expect(rectOf(ctx, "sourceControlPanel").x).toBeGreaterThan(rectOf(ctx, "conversationPane").x);
});

step(/^the source-control panel is (not shown|shown again)$/, async (ctx: World, how: string) => {
  await settle(ctx);
  expect(visible(ctx, "sourceControlPanel")).toBe(how === "shown again");
});

// --- The revert picker -----------------------------------------------------------------

step(
  /^"([^"]*)" is in the (\w+) colour and the rest of the row in the (\w+) colour$/,
  async (ctx: World, text: string, first: string, rest: string) => {
    await settle(ctx);
    const at = await textWithin(ctx, screen(ctx), text);
    const row = { ...screen(ctx), y: at.y, height: 1 };
    await expectTextColour(ctx, row, text, first);
    const box = await inner(ctx, "box");
    const cells = (await regionCells(ctx, { ...box, y: at.y, height: 1 }))[0]!;
    const tail = cells
      .map((cell) => cell.text)
      .join("")
      .slice(text.length)
      .trim();
    await expectTextColour(ctx, row, tail, rest);
  },
);

step(
  /^the box's second row reads "([^"]*)" with "([^"]*)" in the (\w+) colour and the rest in the (\w+) colour$/,
  async (ctx: World, text: string, marker: string, first: string, rest: string) => {
    // The row goes on with the checkpoint's relative age, which depends on the clock.
    const rows = await innerRows(ctx, "box");
    expect(rows[1]!.startsWith(text)).toBe(true);
    const rect = await rowRect(ctx, "box", "second");
    const cells = (await regionCells(ctx, rect))[0]!;
    expect(cells[0]!.text).toBe(marker);
    expectColour(cells[0]!.span.fg, colour(first));
    await expectTextColour(ctx, rect, rows[1]!.slice(marker.length).trim(), rest);
  },
);
