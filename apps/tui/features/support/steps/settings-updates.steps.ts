// Steps for settings/updates.feature (@shared): the offer to update a server
// behind this app, the Updates page (one server, every machine, the copied
// command) and provider updates per machine. The fake MC answers
// `server.updateServer`, `server.refreshProviders` and `server.updateProvider`.
import { expect } from "bun:test";

import { step } from "../../steps.ts";
import { createHost } from "../../../src/host/host.ts";
import { memoryMutedThreads } from "../../../src/host/mutedThreads.ts";
import {
  manualUpdateCommand,
  providerOutcome,
  type TuiUpdateNotice,
} from "../../../src/host/sections/updates.ts";
import { runPaletteCommand } from "./controls.steps.ts";
import {
  chooseRow,
  connected,
  fixture,
  linkMachine,
  mc,
  pageText,
  paneWords,
  sectionState,
  type SettingsWorld,
} from "../settingsWorld.ts";
import { clickObject, pressKey, settle, snapshot } from "../world.ts";

const APP_VERSION = "1.4.0";
const OLD_VERSION = "1.3.0";

const words = (text: string) => text.replace(/\s+/g, " ");
const notice = (ctx: SettingsWorld) =>
  ctx.host!.state.get("updateNotice") as TuiUpdateNotice | null;
const updates = (ctx: SettingsWorld) => mc(ctx).callsTo("server.updateServer");

/** This app is 1.4.0; the dismissals it keeps outlive the client (a file on a real device). */
function app(ctx: SettingsWorld, version = APP_VERSION): void {
  ctx.hostOptions = {
    dismissedUpdates: memoryMutedThreads(),
    ...ctx.hostOptions,
    appVersion: version,
  };
}

/** The MC the terminal is connected to is `label`, one version behind, updating as a service. */
function serverBehind(ctx: SettingsWorld, label: string, selfUpdate: string | null): void {
  app(ctx);
  const local = fixture(ctx).local;
  local.label = label;
  local.serverVersion = OLD_VERSION;
  local.capabilities = selfUpdate === null ? {} : { serverSelfUpdate: selfUpdate };
}

/** A server takes the update and comes back on the version it was asked for. */
function serversUpdate(ctx: SettingsWorld, failing: ReadonlyArray<string> = []): void {
  mc(ctx).on("server.updateServer", (payload, environmentId) => {
    const link = fixture(ctx).links.find((known) => known.id === environmentId);
    if (link && failing.includes(link.label)) {
      throw new Error("The desktop app could not be reached.");
    }
    if (link) link.serverVersion = payload.targetVersion;
    else fixture(ctx).local.serverVersion = payload.targetVersion;
    return { targetVersion: payload.targetVersion, method: "boot-service" };
  });
}

async function openUpdates(ctx: SettingsWorld): Promise<void> {
  await connected(ctx);
  await runPaletteCommand(ctx, "Updates");
  expect(sectionState(ctx).id).toBe("updates");
}

step("the app is newer than the server on {string}", (ctx: SettingsWorld, label: string) => {
  serverBehind(ctx, label, "boot-service");
});

step("the user opens a thread on {string}", async (ctx: SettingsWorld, _label: string) => {
  await connected(ctx);
  expect((ctx.host!.state.get("page") as { kind: string }).kind).toBe("thread");
});

step("the user is offered to update {string}", async (ctx: SettingsWorld, label: string) => {
  await settle(ctx);
  expect(notice(ctx)).toMatchObject({
    label,
    serverVersion: OLD_VERSION,
    targetVersion: APP_VERSION,
  });
  // Over the conversation, where the user is.
  const text = `${label} is on ${OLD_VERSION}, behind this app (${APP_VERSION}).`;
  expect(words(await snapshot(ctx))).toContain(text);
  expect((ctx.host!.state.get("page") as { kind: string }).kind).toBe("thread");
  // The offer leads to the update itself.
  await clickObject(ctx, "updateNoticeAction");
  expect(sectionState(ctx).id).toBe("updates");
  expect(await paneWords(ctx)).toContain(
    `${label} ${OLD_VERSION} → ${APP_VERSION} · Update server`,
  );
});

step(
  "the user updates {string} and it reconnects on {string}",
  async (ctx: SettingsWorld, label: string, version: string) => {
    serverBehind(ctx, label, "boot-service");
    app(ctx, version);
    serversUpdate(ctx);
    await openUpdates(ctx);
    expect(notice(ctx)?.label).toBe(label);
    await chooseRow(ctx, label);
  },
);

step(
  "the user is told {string} was updated and reconnected on {string}",
  async (ctx: SettingsWorld, label: string, version: string) => {
    expect(updates(ctx).map((call) => call.payload)).toEqual([{ targetVersion: version }]);
    const text = `${label} was updated and reconnected on ${version}.`;
    expect((ctx.host!.state.get("status") as { kind: string; text: string }).text).toBe(text);
    expect(await paneWords(ctx)).toContain(text);
    // It is no longer behind: the page says so and the offer is gone.
    expect(words(pageText(ctx))).toContain(`${label} ${version} · up to date`);
    expect(notice(ctx)).toBeNull();
  },
);

step(
  "{string} is hosted by the desktop app and {string} is a service",
  (ctx: SettingsWorld, desktop: string, service: string) => {
    app(ctx);
    const hosted = linkMachine(ctx, desktop);
    hosted.serverVersion = OLD_VERSION;
    hosted.capabilities = { serverSelfUpdate: "desktop-managed", desktopAppUpdate: true };
    const served = linkMachine(ctx, service);
    served.serverVersion = OLD_VERSION;
    served.capabilities = { serverSelfUpdate: "boot-service" };
    // The desktop app does not come back; the service does.
    serversUpdate(ctx, [desktop]);
  },
);

step("the user updates all machines", async (ctx: SettingsWorld) => {
  await openUpdates(ctx);
  await chooseRow(ctx, "Update all machines");
});

step(
  "the user is asked to confirm that the desktop app on {string} will relaunch",
  async (ctx: SettingsWorld, label: string) => {
    const question = `Update the HAL-C2 desktop apps on ${label}? They will close and relaunch on those machines.`;
    expect(sectionState(ctx).confirm?.lines.join(" ")).toBe(question);
    expect(await paneWords(ctx)).toContain(question);
    // Nothing is updated before the user answers.
    expect(updates(ctx)).toEqual([]);
  },
);

step(
  "{string} updates independently of {string}",
  async (ctx: SettingsWorld, service: string, desktop: string) => {
    await pressKey(ctx, "y");
    await settle(ctx);
    expect(
      updates(ctx)
        .map((call) => call.environmentId)
        .toSorted(),
    ).toEqual([`env-${desktop}`, `env-${service}`].toSorted());
    // The desktop app's update failed; the service's went through all the same.
    const screen = await paneWords(ctx);
    expect(screen).toContain(`${service} was updated and reconnected on ${APP_VERSION}.`);
    expect(screen).toContain(`${desktop} update failed: The desktop app could not be reached.`);
    expect(words(pageText(ctx))).toContain(`${service} ${APP_VERSION} · up to date`);
  },
);

step(
  "the user copies the update command for {string}",
  async (ctx: SettingsWorld, label: string) => {
    // A server started by hand cannot update itself.
    serverBehind(ctx, label, null);
    await openUpdates(ctx);
    expect(words(pageText(ctx))).toContain(
      `${label} ${OLD_VERSION} → ${APP_VERSION} · Copy update command`,
    );
    await chooseRow(ctx, label);
  },
);

step("the command for the matching version is on the clipboard", (ctx: SettingsWorld) => {
  expect(ctx.clipboard?.at(-1)).toBe(manualUpdateCommand(APP_VERSION));
  expect(ctx.clipboard?.at(-1)).toBe(`npx hal-c2@${APP_VERSION}`);
  // Nothing was asked of the server.
  expect(updates(ctx)).toEqual([]);
});

step(
  "the user dismissed the update notice for {string}",
  async (ctx: SettingsWorld, version: string) => {
    serverBehind(ctx, "server", "boot-service");
    app(ctx, version);
    await connected(ctx);
    expect(notice(ctx)?.targetVersion).toBe(version);
    await runPaletteCommand(ctx, "Dismiss the update notice");
    expect(notice(ctx)).toBeNull();
  },
);

step("the user reconnects to the same server", async (ctx: SettingsWorld) => {
  ctx.fake!.emitConnection("reconnecting");
  await settle(ctx);
  ctx.fake!.emitConnection("connected");
  await settle(ctx);
});

step("the notice for {string} does not return", async (ctx: SettingsWorld, version: string) => {
  expect(notice(ctx)).toBeNull();
  expect(await snapshot(ctx)).not.toContain(`behind this app (${version})`);
});

step("a notice for {string} does appear", async (ctx: SettingsWorld, version: string) => {
  // The app was updated since: the same device and server, a newer client.
  const newer = createHost({
    client: ctx.fake!.client,
    size: { columns: 100, rows: 40 },
    log: () => {},
    appVersion: version,
    dismissedUpdates: ctx.hostOptions!.dismissedUpdates!,
  });
  try {
    await newer.settled();
    expect(newer.state.get("updateNotice")).toMatchObject({
      label: "server",
      serverVersion: OLD_VERSION,
      targetVersion: version,
    });
  } finally {
    newer.destroy();
  }
});

const WSL = "laptop (WSL)";

step(
  "Codex is behind on {string} and on its WSL environment",
  (ctx: SettingsWorld, label: string) => {
    app(ctx);
    linkMachine(ctx, label);
    linkMachine(ctx, WSL);
    const codex = (updateState?: { status: string; message: string | null }) => ({
      instanceId: "codex",
      driver: "codex",
      displayName: "Codex",
      versionAdvisory: {
        status: "behind_latest",
        currentVersion: "0.50.0",
        latestVersion: "0.51.0",
        canUpdate: true,
      },
      ...(updateState ? { updateState } : {}),
    });
    mc(ctx).on("server.refreshProviders", () => ({ providers: [codex()] }));
    // The update goes through on the laptop and fails in its WSL environment.
    mc(ctx).on("server.updateProvider", (_payload, environmentId) => ({
      providers: [
        codex(
          environmentId === `env-${label}`
            ? { status: "succeeded", message: null }
            : { status: "failed", message: "npm is not installed" },
        ),
      ],
    }));
  },
);

step("the user updates Codex on both", async (ctx: SettingsWorld) => {
  await openUpdates(ctx);
  const page = words(pageText(ctx));
  expect(page).toContain("Codex on laptop 0.50.0 → 0.51.0 · Update");
  expect(page).toContain(`Codex on ${WSL} 0.50.0 → 0.51.0 · Update`);
  await chooseRow(ctx, "Update Codex on 2 machines");
});

step(
  "each machine shows whether its update succeeded, was unchanged or failed",
  async (ctx: SettingsWorld) => {
    expect(
      mc(ctx)
        .callsTo("server.updateProvider")
        .map((call) => [call.environmentId, call.payload]),
    ).toEqual([
      ["env-laptop", { provider: "codex", instanceId: "codex" }],
      [`env-${WSL}`, { provider: "codex", instanceId: "codex" }],
    ]);
    const screen = await paneWords(ctx);
    expect(screen).toContain("Codex on laptop Updated");
    expect(screen).toContain(`Codex on ${WSL} Failed: npm is not installed`);
    // An update that found nothing newer reads as such.
    expect(
      providerOutcome({
        instanceId: "codex",
        driver: "codex",
        updateState: { status: "unchanged", message: null },
      }),
    ).toEqual({ text: "Already up to date", ok: true });
  },
);
