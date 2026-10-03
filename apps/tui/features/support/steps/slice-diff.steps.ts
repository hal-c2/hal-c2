// tui/timeline.feature: the thread's changes against a base ref (with or
// without whitespace-only lines), and a diff that keeps its place on refresh.
import { expect } from "bun:test";

import type { TuiSelectState } from "../../../src/host/composerState.ts";
import { step } from "../../steps.ts";
import { objectRows } from "../design.ts";
import { vcsStatus } from "../gitWorld.ts";
import { chooseCommand } from "../threadUi.ts";
import type { ThreadWorld } from "../threadWorld.ts";
import { findObject, pressKey, settle, type World } from "../world.ts";

interface DiffWorld extends ThreadWorld {
  scrollBefore?: number;
  rowsBefore?: string[];
}

const CWD = "/workspace/project-one";
const select = (ctx: World) => ctx.host!.state.get("select") as TuiSelectState;
const diff = (ctx: World) =>
  ctx.host!.state.get("diff") as {
    open: boolean;
    title: string;
    status: string;
    files: Array<{ path: string; body: string }>;
  };
const scrollY = (ctx: World) => Number(findObject(ctx, "diffScroll").get("contentY"));

const fileDiff = (path: string, hunk: string) =>
  [`diff --git a/${path} b/${path}`, `--- a/${path}`, `+++ b/${path}`, hunk].join("\n");

const REAL = fileDiff(
  "src/cart.ts",
  "@@ -1,3 +1,3 @@\n export function total(items) {\n-  return sum(items);\n+  return round(sum(items));\n }",
);
// Re-indented only: every changed line differs in spacing alone.
const SPACING = fileDiff(
  "src/format.ts",
  "@@ -1,2 +1,2 @@\n-export const pad = (text) =>   text;\n+export const pad = (text) => text;\n export default pad;",
);

function serveRefs(ctx: World) {
  ctx.fake!.override(
    "listRefs",
    async () =>
      ({
        refs: [
          { name: "main", current: false, isDefault: true, worktreePath: null },
          { name: "feature/tax", current: true, isDefault: false, worktreePath: null },
          { name: "release", current: false, isDefault: false, worktreePath: null },
        ],
        isRepo: true,
        hasPrimaryRemote: true,
        nextCursor: null,
        totalCount: 3,
      }) as never,
  );
}

async function pick(ctx: World, label: string) {
  const index = select(ctx).options.findIndex((option) => option.label === label);
  expect(index, `no "${label}" in the picker`).toBeGreaterThanOrEqual(0);
  const moves = index - select(ctx).index;
  for (let i = 0; i < Math.abs(moves); i += 1) await pressKey(ctx, moves > 0 ? "Down" : "Up");
  await pressKey(ctx, "Enter");
  await settle(ctx);
}

async function reviewAgainst(
  ctx: World,
  base: string,
  whitespace: "Every change" | "Ignore whitespace",
) {
  serveRefs(ctx);
  // The thread works in a repository, on a feature branch.
  ctx.fake!.setVcsStatus(vcsStatus());
  await settle(ctx);
  await chooseCommand(ctx, "Review changes against a base…");
  await settle(ctx);
  // Every branch but the one checked out; the default branch is offered first.
  expect(select(ctx).options.map((option) => option.label)).toEqual(["main", "release"]);
  expect(select(ctx).index).toBe(0);
  await pick(ctx, base);
  await pick(ctx, whitespace);
}

// --- Base ref and whitespace --------------------------------------------------------------

step(
  "the user reviews the thread's changes against {string} ignoring whitespace",
  async (ctx: DiffWorld, base: string) => {
    ctx.fake!.server.reviewDiffs.set(`${base}:all`, `${REAL}\n${SPACING}`);
    ctx.fake!.server.reviewDiffs.set(`${base}:no-whitespace`, REAL);
    await reviewAgainst(ctx, base, "Ignore whitespace");
  },
);

step(
  "the diff shows only non-whitespace changes since {string}",
  async (ctx: DiffWorld, base: string) => {
    // The server makes the diff: the client asks for the base and for whitespace to be left out.
    expect(
      ctx.fake!.calls.filter((call) => call.method === "reviewDiff").map((call) => call.args),
    ).toEqual([[CWD, base, true]]);
    expect(ctx.host!.state.get("mode")).toBe("diff");
    expect(diff(ctx)).toMatchObject({
      open: true,
      status: "ready",
      title: `diff · ${base}…feature/tax · no whitespace`,
    });
    expect(diff(ctx).files.map((file) => file.path)).toEqual(["src/cart.ts"]);
    const rows = (await objectRows(ctx, "diffViewer")).join("\n");
    expect(rows).toContain(`${base}…feature/tax · no whitespace`);
    expect(rows).toContain("return round(sum(items));");
    expect(rows).not.toContain("src/format.ts");
    // With whitespace counted the re-indented file is there too.
    await pressKey(ctx, "Esc");
    await reviewAgainst(ctx, base, "Every change");
    expect(diff(ctx).files.map((file) => file.path)).toEqual(["src/cart.ts", "src/format.ts"]);
  },
);

// --- Keeping the place -----------------------------------------------------------------------

const largeDiff = (extra = "") =>
  Array.from({ length: 6 }, (_, file) =>
    fileDiff(
      `src/module-${file + 1}.ts`,
      `@@ -1,40 +1,40 @@\n${Array.from(
        { length: 40 },
        (_, line) => `-old ${file + 1}.${line + 1}\n+new ${file + 1}.${line + 1}`,
      ).join("\n")}`,
    ),
  ).join("\n") + extra;

step("the user scrolled halfway through a large diff", async (ctx: DiffWorld) => {
  ctx.fake!.server.reviewDiffs.set("main:all", largeDiff());
  await reviewAgainst(ctx, "main", "Every change");
  expect(diff(ctx).files).toHaveLength(6);
  for (let page = 0; page < 12; page += 1) await pressKey(ctx, "PgDn");
  await settle(ctx);
  ctx.scrollBefore = scrollY(ctx);
  ctx.rowsBefore = await objectRows(ctx, "diffScroll");
  expect(ctx.scrollBefore).toBeGreaterThan(100);
  // In the middle of the change, not at either end.
  expect(ctx.rowsBefore.join("\n")).not.toContain("module-1.ts");
  expect(ctx.rowsBefore.join("\n")).not.toContain("new 6.40");
});

step("the diff refreshes", async (ctx: DiffWorld) => {
  // The agent changed one more file meanwhile; "r" loads the same scope again.
  ctx.fake!.server.reviewDiffs.set(
    "main:all",
    largeDiff(`\n${fileDiff("src/module-7.ts", "@@ -1 +1 @@\n-old 7.1\n+new 7.1")}`),
  );
  await pressKey(ctx, "r");
  await settle(ctx);
  expect(ctx.fake!.calls.filter((call) => call.method === "reviewDiff")).toHaveLength(2);
  expect(diff(ctx).files).toHaveLength(7);
});

step("the user is at the same file and line", async (ctx: DiffWorld) => {
  expect(scrollY(ctx)).toBe(ctx.scrollBefore!);
  expect(await objectRows(ctx, "diffScroll")).toEqual(ctx.rowsBefore!);
});
