// Steps for settings/background-service.feature (@shared): the client tells
// the MC what the user is looking at, and the background activity page sets
// custom intervals.
import { expect } from "bun:test";

import { step } from "../../steps.ts";
import { CLIENT_ACTIVITY_TTL_MS } from "../../../src/host/clientActivity.ts";
import { effectivePolicy, readActivity } from "../../../src/host/sections/backgroundActivity.ts";
import { runPaletteCommand } from "./controls.steps.ts";
import {
  chooseRow,
  connected,
  documentOf,
  fillField,
  fixture,
  mc,
  pageText,
  paneWords,
  sectionState,
  type SettingsWorld,
} from "../settingsWorld.ts";
import { settle } from "../world.ts";

const words = (text: string) => text.replace(/\s+/g, " ");
const reports = (ctx: SettingsWorld) => mc(ctx).callsTo("server.reportClientActivity");

step("the user opens a thread in the client", async (ctx: SettingsWorld) => {
  mc(ctx).on("server.reportClientActivity", () => null);
  // The client starts on its one thread, "Thread one" in /workspace/project-one.
  await connected(ctx);
  expect((ctx.host!.state.get("page") as { kind: string; threadId?: string }).threadId).toBe("t1");
});

step(
  "the client tells the MC it is watching that thread's git status",
  async (ctx: SettingsWorld) => {
    await settle(ctx);
    expect(reports(ctx)).toHaveLength(1);
    const report = reports(ctx)[0]!.payload as Record<string, any>;
    expect(report.scopes).toEqual([
      { type: "thread", threadId: "t1" },
      { type: "vcs-status", cwd: "/workspace/project-one" },
    ]);
    expect(report).toMatchObject({ visible: true, focused: true, ttlMs: CLIENT_ACTIVITY_TTL_MS });
    expect(typeof report.clientId).toBe("string");
    // The report lapses on the MC unless renewed: the renewal sends it again.
    ctx.host!.dispatch("clientActivity.renew");
    await settle(ctx);
    expect(reports(ctx)).toHaveLength(2);
    expect((reports(ctx)[1]!.payload as Record<string, any>).clientId).toBe(report.clientId);
  },
);

step(
  "the user chooses advanced background activity for the environment",
  async (ctx: SettingsWorld) => {
    fixture(ctx);
    await connected(ctx);
    await runPaletteCommand(ctx, "Background activity");
    expect(sectionState(ctx).id).toBe("backgroundActivity");
    expect(words(pageText(ctx))).toContain("Profile Balanced");
    // The profile's values cannot be set until Custom is chosen.
    expect(words(pageText(ctx))).toContain("Fetch git every 30 sec");
    await chooseRow(ctx, "Profile");
    await chooseRow(ctx, "Custom");
    expect(words(pageText(ctx))).toContain("Profile Custom (advanced), from Balanced");
  },
);

step(
  "the user sets git fetch to every 2 minutes and turns off pausing when locked",
  async (ctx: SettingsWorld) => {
    await chooseRow(ctx, "Fetch git");
    await fillField(ctx, "2m");
    await chooseRow(ctx, "Pause when the host is locked");
    const screen = await paneWords(ctx);
    expect(screen).toContain("Fetch git every 2 min");
    expect(screen).toContain("Pause when the host is locked off");
  },
);

step("the MC fetches git every 2 minutes, even when locked", (ctx: SettingsWorld) => {
  // What the MC was given to keep: the custom profile over the one it replaced.
  const stored = documentOf(ctx).settings.backgroundActivity;
  expect(stored).toEqual({
    schemaVersion: 1,
    profile: "custom",
    baseProfile: "balanced",
    overrides: { automaticGitFetchInterval: 120_000, pauseWhenHostLocked: false },
  });
  // And what that comes to, by the MC's rule (the preset with the overrides over it).
  const policy = effectivePolicy(readActivity(documentOf(ctx).settings));
  expect(policy.automaticGitFetchInterval).toBe(120_000);
  expect(policy.pauseWhenHostLocked).toBe(false);
  // The rest of the profile is as it was.
  expect(policy.providerHealthRefreshInterval).toBe(300_000);
  expect(policy.pauseWhenHostLowPower).toBe(true);
});
