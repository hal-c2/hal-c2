// Steps for settings/subagents.feature (@tui): the Subagents page sets which
// subagents agents use on the MC.
import { expect } from "bun:test";

import { step } from "../../steps.ts";
import { runPaletteCommand } from "./controls.steps.ts";
import {
  chooseRow,
  connected,
  documentOf,
  fixture,
  pageText,
  sectionState,
  type SettingsWorld,
} from "../settingsWorld.ts";

const words = (text: string) => text.replace(/\s+/g, " ");

step("the user opens the subagents settings", async (ctx: SettingsWorld) => {
  fixture(ctx);
  await connected(ctx);
  await runPaletteCommand(ctx, "Subagents");
  expect(sectionState(ctx).id).toBe("subagents");
});

step("the subagents setting reads {string}", (ctx: SettingsWorld, value: string) => {
  expect(words(pageText(ctx))).toContain(`Subagents ${value}`);
});

step("the user chooses HAL-C2 workers", async (ctx: SettingsWorld) => {
  await chooseRow(ctx, "Subagents");
  expect(words(pageText(ctx))).toContain("Subagents HAL-C2 workers");
});

step("the MC keeps HAL-C2 workers as the subagents setting", (ctx: SettingsWorld) => {
  expect(documentOf(ctx).settings.nativeSubagents).toBe("hal-c2");
});
