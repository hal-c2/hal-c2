// Steps for tui/settings.feature and settings/search-and-navigation.feature:
// the read-only settings overview in place of the conversation.
import { expect } from "bun:test";

import { step } from "../../steps.ts";
import type { TuiSettingsState } from "../../../src/host/settingsState.ts";
import { KEYBINDING_GROUPS } from "../../../src/keymap.ts";
import { changes, ready, scm, setCheckout, settle, vcsStatus } from "../gitWorld.ts";
import { findObject, geometry, type World } from "../world.ts";

const settingsState = (ctx: World) => ctx.host!.state.get("settings") as TuiSettingsState;
const rowValue = (ctx: World, group: string, label: string) =>
  settingsState(ctx)
    .groups.find((entry) => entry.title === group)
    ?.rows.find((row) => row.label === label)?.value;

/** Open settings as the palette's "Settings" command does. */
async function openSettings(ctx: World): Promise<void> {
  await ready(ctx);
  ctx.host!.dispatch("settings.open");
  await settle(ctx);
  expect(ctx.host!.state.get("mode")).toBe("settings");
}

/** The screen shows `label` followed (on the same row) by `value`. */
function expectRow(screen: string, label: string, value: string): void {
  const row = screen.split("\n").find((line) => line.includes(` ${label} `));
  expect(row, `no "${label}" row on screen`).toBeDefined();
  expect(row!.slice(row!.indexOf(label) + label.length)).toContain(value);
}

step("the settings overlay is open", openSettings);
step("the settings overview is open in the terminal client", openSettings);
step("the user opens settings in the terminal client", openSettings);

step("the user has opened settings", (ctx: World) => {
  scm(ctx);
  setCheckout(
    ctx,
    vcsStatus({
      ...changes("src/cart.ts"),
      pr: {
        number: 42,
        title: "Add tax to the cart",
        url: "https://github.com/acme/shop/pull/42",
        baseRef: "main",
        headRef: "feature/tax",
        state: "open",
      },
    } as Parameters<typeof vcsStatus>[0]),
  );
});

step("the overlay shows providers, source control and keybindings", async (ctx: World) => {
  const screen = await settle(ctx);
  expect(settingsState(ctx).active).toBe(true);
  expect(geometry(findObject(ctx, "settingsPage")).visible).toBe(true);
  expect(geometry(findObject(ctx, "conversation")).visible).toBe(false);
  for (const title of ["Providers", "Source control", KEYBINDING_GROUPS[0]!.title]) {
    expect(screen).toContain(title);
  }
});

step("the overlay scrolls down", async (ctx: World) => {
  await settle(ctx);
  expect(Number(findObject(ctx, "settingsBody").get("contentY"))).toBeGreaterThan(0);
  expect(await settle(ctx)).not.toContain(" model ");
});

step("the conversation is shown again", async (ctx: World) => {
  await settle(ctx);
  expect(ctx.host!.state.get("mode")).toBe("compose");
  expect(settingsState(ctx).active).toBe(false);
  expect(() => findObject(ctx, "settingsPage")).toThrow();
  expect(geometry(findObject(ctx, "conversation")).visible).toBe(true);
});

step("the current model, reasoning, mode and runtime access are shown", async (ctx: World) => {
  const screen = await settle(ctx);
  for (const label of ["model", "reasoning", "mode", "runtime access"]) {
    const value = rowValue(ctx, "Providers", label);
    expect(value).toBeTruthy();
    expectRow(screen, label, value!);
  }
  expect(rowValue(ctx, "Providers", "model")).toBe("gpt-5");
});

step("the branch, pull request and working tree state are shown", async (ctx: World) => {
  const screen = await settle(ctx);
  expectRow(screen, "branch", "feature/tax");
  expectRow(screen, "pull request", "#42 open");
  expectRow(screen, "working tree", "uncommitted changes");
});

step("the keybinding reference is listed by context", async (ctx: World) => {
  await settle(ctx);
  const groups = settingsState(ctx).groups.filter((group) => group.rows.every((row) => row.keys));
  expect(groups.map((group) => group.title)).toEqual(KEYBINDING_GROUPS.map((group) => group.title));
  for (const [index, group] of groups.entries()) {
    expect(group.rows.map((row) => row.label)).toEqual(
      KEYBINDING_GROUPS[index]!.bindings.map((binding) => binding.keys),
    );
  }
});
