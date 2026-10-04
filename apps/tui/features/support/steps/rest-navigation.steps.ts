// navigation/command-palette.feature: how the terminal palette ranks what the user typed.
import { expect } from "bun:test";

import { step } from "../../steps.ts";
import { project, shell } from "../fakeClient.ts";
import { palette } from "../threadUi.ts";
import { pressKey, settle, snapshot, typeText, type World } from "../world.ts";

const titles = (ctx: World) => palette(ctx).commands.map((command) => command.title);

// The terminal's own entries: "New thread", the project's first script "Renew token"
// (listed as "Run Renew token") and the terminal toggle ("Show terminal"). Two more
// fill the other tiers for "new": a second script the script menu's entry names in
// its keywords, and a project whose title only has the letters in order.
step(
  "the palette commands {string}, {string} and {string}",
  async (ctx: World, first: string, script: string, _toggle: string) => {
    const current = ctx.fake!.latestShell();
    const scripts = [script, "Newsletter"].map((name, index) => ({
      id: `script-${index}`,
      name,
      command: "bin/run",
      icon: "play",
    }));
    ctx.fake!.emitShell(
      shell(current.threads, [
        { ...project, title: current.projects[0]!.title, scripts },
        { ...project, id: "p2", title: "nextflow", workspaceRoot: "/workspace/nextflow" },
      ] as never),
    );
    await settle(ctx);
    await pressKey(ctx, "Ctrl+K");
    await settle(ctx);
    expect(titles(ctx)).toEqual(
      expect.arrayContaining([
        first,
        `Run ${script}`,
        "Show terminal",
        KEYWORD_MATCH,
        "Show project nextflow",
      ]),
    );
    await pressKey(ctx, "Esc");
    await settle(ctx);
  },
);

/** Its keywords are the scripts' names. */
const KEYWORD_MATCH = "Run a project script…";

step("the user types {string} into the palette", async (ctx: World, query: string) => {
  await pressKey(ctx, "Ctrl+K");
  await typeText(ctx, query);
  await settle(ctx);
  expect(palette(ctx)).toMatchObject({ open: true, query });
});

step("{string} is listed before {string}", async (ctx: World, first: string, second: string) => {
  const listed = titles(ctx);
  const at = listed.indexOf(first);
  const then = listed.findIndex((title) => title.includes(second));
  // A title that starts with the query is the first entry, highlighted.
  expect(at).toBe(0);
  expect(then).toBeGreaterThan(at);
  expect(listed).not.toContain("Show terminal");
  const screen = await snapshot(ctx);
  expect(screen).toContain(`▸ ${first}`);
  expect(screen.indexOf(first)).toBeLessThan(screen.indexOf(second));
});

step("commands that only match by subsequence are listed last", (ctx: World) => {
  const query = palette(ctx).query;
  const tier = (title: string) => {
    const text = title.toLowerCase();
    if (text.startsWith(query)) return 0;
    if (text.includes(query)) return 1;
    return title === KEYWORD_MATCH ? 2 : 3;
  };
  const listed = titles(ctx);
  const tiers = listed.map(tier);
  expect(tiers).toEqual(tiers.toSorted((a, b) => a - b));
  expect(new Set(tiers)).toEqual(new Set([0, 1, 2, 3]));
  expect(listed.at(-1)).toBe("Show project nextflow");
});
