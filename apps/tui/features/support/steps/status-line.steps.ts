// Steps for tui/status-line.feature: an error stays on the status line until the user
// dismisses it, and the history lists the recent ones.
import { expect } from "bun:test";

import type { TuiSelectState } from "../../../src/host/composerState.ts";
import { step } from "../../steps.ts";
import { changes, ready, runAction, setCheckout, settle, vcsStatus } from "../gitWorld.ts";
import { chooseCommand, clickText, palette } from "../threadUi.ts";
import { pressKey, typeText, type World } from "../world.ts";

/** The screen's last non-blank row: the status line. */
async function statusLine(ctx: World): Promise<string> {
  const screen = (await settle(ctx)).split("\n");
  return screen.findLast((line) => line.trim() !== "") ?? "";
}

step("pulling will fail with {string}", (ctx: World, reason: string) => {
  ctx.fake!.override("runGitPull", () => Promise.reject(new Error(reason)));
});

step("pulling will succeed", (ctx: World) => {
  ctx.fake!.override("runGitPull", () => Promise.resolve());
});

step("the user pulls the branch", async (ctx: World) => {
  await ready(ctx);
  // What the panel's Pull row and the palette's command both fire.
  ctx.host!.dispatch("git.pull");
  await settle(ctx);
});

step("the user submits an empty commit message", async (ctx: World) => {
  setCheckout(ctx, vcsStatus(changes("src/tax.ts")));
  await runAction(ctx, "Commit");
  ctx.host!.dispatch("git.commit", { message: "" });
  await settle(ctx);
});

step("the status line shows {string}", async (ctx: World, text: string) => {
  expect(await statusLine(ctx)).toContain(text);
});

step(
  "the status line shows {string} before {string}",
  async (ctx: World, first: string, second: string) => {
    const line = await statusLine(ctx);
    expect(line).toContain(first);
    expect(line).toContain(second);
    expect(line.indexOf(first)).toBeLessThan(line.indexOf(second));
  },
);

step("the status line no longer shows {string}", async (ctx: World, text: string) => {
  expect(await statusLine(ctx)).not.toContain(text);
});

step("the user clicks {string} on the status line", async (ctx: World, text: string) => {
  await clickText(ctx, text);
});

step("the user runs the palette command {string}", async (ctx: World, name: string) => {
  await chooseCommand(ctx, name);
});

step("the palette does not offer {string}", async (ctx: World, name: string) => {
  await pressKey(ctx, "Ctrl+K");
  await typeText(ctx, name);
  expect(palette(ctx).commands.map((command) => command.title)).not.toContain(name);
  await pressKey(ctx, "Esc");
});

step(
  "the picker {string} lists {string} then {string}",
  async (ctx: World, title: string, first: string, second: string) => {
    await settle(ctx);
    const select = ctx.host!.state.get("select") as TuiSelectState;
    expect(select.open).toBe(true);
    expect(select.title).toBe(title);
    expect(select.options.map((option) => option.label)).toEqual([first, second]);
  },
);

step("{string} is on the clipboard", (ctx: World, text: string) => {
  expect(ctx.clipboard).toEqual([text]);
});
