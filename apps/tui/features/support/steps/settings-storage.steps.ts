// Steps for settings/storage.feature (@shared, "Storage settings"): the storage
// page over one machine or all of them. Other machines are environments the MC
// is linked to, each with its own settings document.
import { expect } from "bun:test";

import { step } from "../../steps.ts";
import { ruleValue, STORAGE_RULES } from "../../../src/host/sections/storage.ts";
import { runPaletteCommand } from "./controls.steps.ts";
import {
  chooseRow,
  connected,
  documentOf,
  fixture,
  linkMachine,
  mc,
  pageText,
  paneWords,
  sectionState,
  type SettingsWorld,
} from "../settingsWorld.ts";

const words = (text: string) => text.replace(/\s+/g, " ");

async function openStorage(ctx: SettingsWorld): Promise<void> {
  fixture(ctx);
  await connected(ctx);
  await runPaletteCommand(ctx, "Storage settings");
  expect(sectionState(ctx).id).toBe("storage");
}

step(
  "{string} deletes inactive worktrees and {string} does not",
  (ctx: SettingsWorld, deleting: string, keeping: string) => {
    documentOf(ctx, linkMachine(ctx, deleting).id).settings = {
      storageCleanup: { worktreeAfterDays: 8 },
    };
    documentOf(ctx, linkMachine(ctx, keeping).id).settings = {
      storageCleanup: { worktreeAfterDays: null },
    };
  },
);

step("the user views storage settings for both machines", async (ctx: SettingsWorld) => {
  await openStorage(ctx);
  // The page opens on this machine, where the rule is off.
  expect(words(pageText(ctx))).toContain("Applies to This machine");
  expect(words(pageText(ctx))).toContain("Delete inactive worktrees off");
  for (
    let turn = 0;
    turn < 4 && !words(pageText(ctx)).includes("Applies to All machines");
    turn += 1
  ) {
    await chooseRow(ctx, "Applies to");
  }
  expect(words(pageText(ctx))).toContain("Applies to All machines");
});

step("that rule shows as mixed", async (ctx: SettingsWorld) => {
  expect(words(pageText(ctx))).toContain("Delete inactive worktrees mixed");
  expect(await paneWords(ctx)).toContain("Delete inactive worktrees mixed");
  // Rules the machines agree on are not mixed.
  expect(words(pageText(ctx))).toContain("Delete merged worktrees off");
  expect(pageText(ctx).match(/mixed/g)).toHaveLength(1);
  const documents = [...fixture(ctx).documents.values()].map((document) => ({
    settings: document.settings,
    version: document.version,
  }));
  expect(documents).toHaveLength(3);
  const rule = STORAGE_RULES.find((candidate) => candidate.key === "worktreeAfterDays")!;
  expect(ruleValue(rule, documents).mixed).toBe(true);
});

step("the selected machine does not support storage cleanup", (ctx: SettingsWorld) => {
  fixture(ctx).local.capabilities = {};
});

step("the user opens storage settings", openStorage);

step("the user is asked to update that machine first", async (ctx: SettingsWorld) => {
  const notice =
    "Update the selected environments to use storage cleanup, or choose a machine that supports it.";
  expect(words(pageText(ctx))).toContain(notice);
  expect(await paneWords(ctx)).toContain(notice);
  // No rule is offered, and its settings were not read.
  for (const rule of STORAGE_RULES) expect(pageText(ctx)).not.toContain(rule.label);
  expect(mc(ctx).callsTo("hal-c2.readSettings")).toEqual([]);
});
