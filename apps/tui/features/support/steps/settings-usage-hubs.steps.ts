// Steps for settings/usage-limit-sources.feature (@shared): adding CLIProxyAPI
// hubs on the usage hubs page. A hub is one entry of the machine's
// `settings.usageLimitSources`; the limits its accounts add are the usage page's.
import { expect } from "bun:test";

import { step } from "../../steps.ts";
import { hubIdFromUrl } from "../../../src/host/sections/usageHubs.ts";
import { runPaletteCommand } from "./controls.steps.ts";
import {
  chooseRow,
  connected,
  documentOf,
  fillField,
  fixture,
  linkMachine,
  pageText,
  paneWords,
  sectionState,
  type SettingsWorld,
} from "../settingsWorld.ts";

const HUB_URL = "https://hub.example.ts.net:8318";
const words = (text: string) => text.replace(/\s+/g, " ");

async function openHubs(ctx: SettingsWorld): Promise<void> {
  fixture(ctx);
  await connected(ctx);
  await runPaletteCommand(ctx, "Usage hubs");
  expect(sectionState(ctx).id).toBe("usageHubs");
}

async function openForm(ctx: SettingsWorld): Promise<void> {
  await openHubs(ctx);
  await chooseRow(ctx, "+ Add a CLIProxyAPI hub");
  expect(sectionState(ctx).title).toBe("usage hubs · add a hub");
}

async function setField(ctx: SettingsWorld, label: string, value: string): Promise<void> {
  await chooseRow(ctx, label);
  await fillField(ctx, value);
}

step("an MC the user administers", (ctx: SettingsWorld) => {
  fixture(ctx);
});

step(
  "the user adds a hub with a URL and management key but no label",
  async (ctx: SettingsWorld) => {
    await openForm(ctx);
    await setField(ctx, "URL", HUB_URL);
    await setField(ctx, "Management key", "hub-key");
    // The key is not echoed back once typed.
    expect(words(pageText(ctx))).toContain("Management key ••••••");
    expect(pageText(ctx)).not.toContain("hub-key");
    await chooseRow(ctx, "Add hub");
  },
);

step("the hub is listed under the hub's host name", async (ctx: SettingsWorld) => {
  const id = "cliproxy-hub.example.ts.net-8318";
  expect(hubIdFromUrl(HUB_URL)).toBe(id);
  // The MC was given the hub and its key once, to keep in its secret store.
  expect(documentOf(ctx).writes).toHaveLength(1);
  expect(documentOf(ctx).settings.usageLimitSources).toEqual({
    [id]: { kind: "cliproxy", url: HUB_URL, managementKey: "hub-key", enabled: true },
  });
  expect(sectionState(ctx).title).toBe("usage hubs");
  const screen = await paneWords(ctx);
  expect(screen).toContain(`hub.example.ts.net:8318 ${HUB_URL}`);
  expect(screen).not.toContain("hub-key");
});

step("the user fills in a URL but no management key", async (ctx: SettingsWorld) => {
  await openForm(ctx);
  await setField(ctx, "URL", "https://hub.example");
  await chooseRow(ctx, "Add hub");
});

step("the user cannot add the hub", async (ctx: SettingsWorld) => {
  expect(documentOf(ctx).writes).toEqual([]);
  // The form stays open and says what is missing.
  expect(sectionState(ctx).title).toBe("usage hubs · add a hub");
  expect(await paneWords(ctx)).toContain("Enter the hub's URL and its management key.");
});

step("the user is connected with read-only access", (ctx: SettingsWorld) => {
  // "Build box" was paired for reading only.
  const link = linkMachine(ctx, "Build box");
  link.scopes = ["orchestration:read"];
  documentOf(ctx, link.id).settings = { usageLimitSources: {} };
});

step("the user opens usage providers", async (ctx: SettingsWorld) => {
  await openHubs(ctx);
  // This machine's hubs can be changed; Build box's are the next machine along.
  expect(pageText(ctx)).toContain("+ Add a CLIProxyAPI hub");
  await chooseRow(ctx, "Machine");
  expect(words(pageText(ctx))).toContain("Machine Build box");
});

step("the user cannot add a hub", async (ctx: SettingsWorld) => {
  expect(await paneWords(ctx)).toContain(
    "This session can view Build box's hubs but can't change them.",
  );
  expect(pageText(ctx)).not.toContain("+ Add a CLIProxyAPI hub");
  // The only row is the machine: nothing on the page writes to Build box.
  expect(
    sectionState(ctx)
      .rows.filter((row) => row.selectable)
      .map((row) => row.id),
  ).toEqual(["machine"]);
  expect(documentOf(ctx, "env-Build box").writes).toEqual([]);
});
