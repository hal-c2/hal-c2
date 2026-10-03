// tui/threads.feature: the archive (archived threads listed in a searchable
// picker, sorted by archive date; one opens to be unarchived or deleted).
import { expect } from "bun:test";

import type { TuiSelectState } from "../../../src/host/composerState.ts";
import { step } from "../../steps.ts";
import { objectRows } from "../design.ts";
import { addThread, DEFAULT_NOW_MS, env, flush, ui } from "../environment.ts";
import { chooseCommand } from "../threadUi.ts";
import { pressKey, typeText, type World } from "../world.ts";

const DAY_MS = 24 * 60 * 60_000;
const select = (ctx: World) => ctx.host!.state.get("select") as TuiSelectState;
const listed = (ctx: World) => select(ctx).options.map((option) => option.label);

/** A thread archived `days` ago. */
function archived(ctx: World, title: string, days: number, project = "shop") {
  addThread(ctx, title, {
    project,
    archivedAt: new Date(DEFAULT_NOW_MS - days * DAY_MS).toISOString(),
  });
}

async function openArchive(ctx: World) {
  await ui(ctx);
  await chooseCommand(ctx, "Archived threads");
  expect(select(ctx)).toMatchObject({ open: true, title: "archive", searchable: true });
}

/** Move the highlight to `label` and press Enter. */
async function choose(ctx: World, label: string) {
  const index = listed(ctx).indexOf(label);
  expect(index, `"${label}" is not in the picker`).toBeGreaterThanOrEqual(0);
  const moves = index - select(ctx).index;
  for (let i = 0; i < Math.abs(moves); i += 1) await pressKey(ctx, moves > 0 ? "Down" : "Up");
  await pressKey(ctx, "Enter");
  await flush(ctx);
}

step("the user opens archived threads", async (ctx: World) => {
  archived(ctx, "Old spike", 3);
  archived(ctx, "Tax rounding", 1);
  archived(ctx, "Spike the docs search", 9, "docs");
  await openArchive(ctx);
});

step("archived threads are listed with search and sort by date", async (ctx: World) => {
  // Newest archived first; none of them is in the thread list.
  expect(listed(ctx)).toEqual([
    "Sort: newest first",
    "Tax rounding",
    "Old spike",
    "Spike the docs search",
  ]);
  expect(select(ctx).options[1]!.description).toBe("shop · archived 1d");
  const rows = (await objectRows(ctx, "selectOverlay")).join("\n");
  expect(rows).toContain("Tax rounding");
  expect(rows).toContain("shop · archived 1d");
  for (const title of ["Tax rounding", "Old spike", "Spike the docs search"]) {
    expect(env(ctx).threads.find((thread) => thread.title === title)?.archivedAt).not.toBeNull();
  }

  // Search: by title, and by the project in the description.
  await typeText(ctx, "spike");
  await flush(ctx);
  expect(listed(ctx)).toEqual(["Old spike", "Spike the docs search"]);
  for (let i = 0; i < "spike".length; i += 1) await pressKey(ctx, "Backspace");
  await typeText(ctx, "docs");
  await flush(ctx);
  expect(listed(ctx)).toEqual(["Spike the docs search"]);
  for (let i = 0; i < "docs".length; i += 1) await pressKey(ctx, "Backspace");
  await flush(ctx);
  expect(listed(ctx)).toHaveLength(4);

  // Sort: the first row switches the order.
  await choose(ctx, "Sort: newest first");
  expect(listed(ctx)).toEqual([
    "Sort: oldest first",
    "Spike the docs search",
    "Old spike",
    "Tax rounding",
  ]);
});

// Opening it from the archive is how the palette's thread actions reach it:
// "the user unarchives …" (threads.steps.ts) runs "Unarchive thread" on the open thread.
step("the archive lists the thread {string}", async (ctx: World, title: string) => {
  archived(ctx, title, 3);
  await openArchive(ctx);
  expect(listed(ctx)).toContain(title);
  await choose(ctx, title);
  expect(select(ctx).open).toBe(false);
  expect(ctx.host!.state.get("page")).toMatchObject({ kind: "thread", title });
});
