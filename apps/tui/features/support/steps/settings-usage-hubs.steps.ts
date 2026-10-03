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
import { pressKey, settle } from "../world.ts";

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

// --- Hub accounts in limits -----------------------------------------------------------------
// The limits page pools this machine's provider accounts with its hubs' (the MC
// publishes both with its config). The clock is the scenario's own.

const NOW_MS = Date.parse("2026-09-23T10:00:00.000Z");
const iso = (ms: number) => new Date(ms).toISOString();
const HUB_ID = "team-hub";

const limitsWindow = (usedPercent: number, resetsInMs: number) => ({
  id: "primary",
  kind: "session",
  label: "5-hour",
  usedPercent,
  resetsAt: iso(NOW_MS + resetsInMs),
  windowDurationMins: 300,
});

/** Codex signed in on this machine, with its limits. */
const codexHere = (email: string, limits: Record<string, unknown>) => ({
  instanceId: "codex",
  driver: "codex",
  displayName: "Codex",
  enabled: true,
  installed: true,
  status: "ready",
  auth: { status: "authenticated", email },
  models: [],
  usageLimits: limits,
});

/** The hub's one Codex account: `codex-ops.json`, half used, resetting in two hours. */
const hubAccount = (email: string | null, credit: boolean) => ({
  id: "codex-ops.json",
  driver: "codex",
  ...(email === null ? {} : { email }),
  usageLimits: {
    checkedAt: iso(NOW_MS),
    windows: [limitsWindow(50, 2 * 3_600_000)],
    ...(credit ? { resetCredits: { availableCount: 1, nextCreditId: "credit-1" } } : {}),
  },
});

function setHub(
  ctx: SettingsWorld,
  label: string,
  accounts: ReadonlyArray<unknown>,
  error?: string,
): void {
  const server = (ctx.fake ?? (fixture(ctx), ctx.fake!)).settings;
  server.usageLimits = {
    ...server.usageLimits,
    sources: [
      {
        id: HUB_ID,
        kind: "cliproxy",
        label,
        checkedAt: iso(NOW_MS),
        accounts,
        ...(error === undefined ? {} : { error }),
      },
    ] as never,
  };
  server.emitUsageLimits();
}

function setProviders(ctx: SettingsWorld, providers: ReadonlyArray<unknown>): void {
  const server = (ctx.fake ?? (fixture(ctx), ctx.fake!)).settings;
  server.usageLimits = { ...server.usageLimits, providers: providers as never };
  server.emitUsageLimits();
}

/** The limits page's lines under the Codex heading. */
function codexLines(ctx: SettingsWorld): string[] {
  const lines = sectionState(ctx).lines;
  const from = lines.findIndex((line) => line.startsWith("Codex · "));
  if (from < 0) return [];
  const rest = lines.slice(from);
  const end = rest.findIndex((line) => line.trim() === "");
  return end < 0 ? rest : rest.slice(0, end);
}

async function openLimits(ctx: SettingsWorld): Promise<void> {
  fixture(ctx);
  ctx.nowMs = NOW_MS;
  await connected(ctx);
  await runPaletteCommand(ctx, "Usage limits");
  expect(sectionState(ctx).id).toBe("usageLimits");
  // Limits are followed while the page is open.
  expect(ctx.fake!.settings.usageLimitWatchers()).toBe(1);
}

step("the hub {string} reports a Codex account", (ctx: SettingsWorld, label: string) => {
  setHub(ctx, label, [hubAccount(null, false)]);
});

step(
  /^the hub "([^"]*)" reports the Codex account "([^"]*)"( with a banked reset credit)?$/,
  (ctx: SettingsWorld, label: string, email: string, credit: string | undefined) => {
    setHub(ctx, label, [hubAccount(email, credit !== undefined)]);
  },
);

step(
  "the hub {string} cannot be read: {string}",
  (ctx: SettingsWorld, label: string, error: string) => {
    setHub(ctx, label, [], error);
  },
);

step("Codex is signed in here as {string}", (ctx: SettingsWorld, email: string) => {
  setProviders(ctx, [
    codexHere(email, {
      checkedAt: iso(NOW_MS - 60_000),
      windows: [limitsWindow(40, 3_600_000)],
    }),
  ]);
});

step("Codex has a reset credit banked", (ctx: SettingsWorld) => {
  setProviders(ctx, [
    codexHere("sam@example.com", {
      checkedAt: iso(NOW_MS),
      windows: [limitsWindow(90, 3_600_000)],
      resetCredits: { availableCount: 1, nextExpiresAt: iso(NOW_MS + 27 * 86_400_000) },
    }),
  ]);
});

step("the user views limits", openLimits);

step(
  "Codex limits include the account {string} of the hub",
  async (ctx: SettingsWorld, account: string) => {
    const codex = codexLines(ctx).map((line) => line.trim());
    expect(codex[0]).toBe("Codex · 1 account");
    expect(codex).toContain("5-hour: 50% left · under pace");
    expect(codex).toContain(`${account} · Team hub · 50% left · resets in 2h 0m`);
    expect(await paneWords(ctx)).toContain(`${account} · Team hub · 50% left · resets in 2h 0m`);
  },
);

step("Codex limits count one account", async (ctx: SettingsWorld) => {
  const codex = codexLines(ctx).map((line) => line.trim());
  expect(codex[0]).toBe("Codex · 1 account");
  // The account is named once, as this machine signs it in; the hub adds no second line.
  expect(codex.filter((line) => line.includes("% left · resets"))).toHaveLength(1);
  expect(pageText(ctx)).not.toContain("codex-ops");
  expect(await paneWords(ctx)).toContain("Codex · 1 account");
});

step("usage says {string}", async (ctx: SettingsWorld, notice: string) => {
  expect(sectionState(ctx).lines.map((line) => line.trim())).toContain(notice);
  expect(await paneWords(ctx)).toContain(notice);
});

step("the user uses the reset credit and confirms", async (ctx: SettingsWorld) => {
  ctx.fake ?? fixture(ctx);
  ctx.fake!.settings.on("provider.consumeResetCredit", () => ({ outcome: "reset" }));
  await openLimits(ctx);
  await chooseRow(ctx, "Use a reset credit for Codex");
  // Spending a credit asks first.
  expect(sectionState(ctx).confirm?.lines.join(" ")).toContain("Use a reset credit for Codex?");
  expect(ctx.fake!.settings.callsTo("provider.consumeResetCredit")).toEqual([]);
  await pressKey(ctx, "y");
  await settle(ctx);
});

step("the credit is spent through the hub", (ctx: SettingsWorld) => {
  // The hub's credit, not this machine's: only that clears the hub's own cooldown.
  expect(
    ctx.fake!.settings.callsTo("provider.consumeResetCredit").map((call) => call.payload),
  ).toEqual([{ sourceId: HUB_ID, accountId: "codex-ops.json", creditId: "credit-1" }]);
  expect((ctx.host!.state.get("status") as { text: string }).text).toBe("Limits reset.");
});

// A hub the user added: its entry in the settings, its key sealed on the MC, its account in limits.
interface HubWorld extends SettingsWorld {
  hubSecrets?: Map<string, string>;
}

step("a hub {string}", (ctx: HubWorld, label: string) => {
  const document = documentOf(ctx);
  document.settings = {
    usageLimitSources: {
      [HUB_ID]: {
        kind: "cliproxy",
        label,
        url: "https://hub.example",
        managementKey: "••••••",
        enabled: true,
      },
    },
  };
  const secrets = new Map([[`hub/${HUB_ID}`, "hub-key"]]);
  ctx.hubSecrets = secrets;
  setHub(ctx, label, [hubAccount(null, false)]);
  // As the MC does when a hub leaves its settings: its key goes, and so do its accounts.
  const server = ctx.fake!.settings;
  server.on("hal-c2.writeSettings", (payload) => {
    document.settings = payload.settings;
    document.version += 1;
    document.writes.push(payload.settings);
    if (!(HUB_ID in (payload.settings.usageLimitSources ?? {}))) {
      secrets.delete(`hub/${HUB_ID}`);
      server.usageLimits = { ...server.usageLimits, sources: [] };
      server.emitUsageLimits();
    }
    return { version: document.version };
  });
});

step("the user removes {string} and confirms", async (ctx: HubWorld, label: string) => {
  // Its account is in limits to begin with.
  await openLimits(ctx);
  expect(pageText(ctx)).toContain("codex-ops · Team hub");
  await runPaletteCommand(ctx, "Usage hubs");
  expect(sectionState(ctx).id).toBe("usageHubs");
  await chooseRow(ctx, label);
  expect(sectionState(ctx).confirm?.lines.join(" ")).toContain(`Remove the hub "${label}"?`);
  expect(documentOf(ctx).writes).toEqual([]);
  await pressKey(ctx, "y");
  await settle(ctx);
});

step("its key is deleted from the MC", async (ctx: HubWorld) => {
  expect(documentOf(ctx).settings.usageLimitSources).toEqual({});
  expect(ctx.hubSecrets!.has(`hub/${HUB_ID}`)).toBe(false);
  expect(await paneWords(ctx)).not.toContain("Team hub https://hub.example");
});

step("its accounts leave limits", async (ctx: HubWorld) => {
  await runPaletteCommand(ctx, "Usage limits");
  expect(sectionState(ctx).id).toBe("usageLimits");
  expect(pageText(ctx)).not.toContain("codex-ops");
  expect(codexLines(ctx)).toEqual([]);
  expect(await paneWords(ctx)).toContain("No limits to show.");
});

step("the hub itself is untouched", (ctx: HubWorld) => {
  // The MC saved its settings once; nothing else was asked of it or of the hub.
  expect(documentOf(ctx).writes).toHaveLength(1);
  expect(
    ctx
      .fake!.settings.calls.map((call) => call.method)
      .filter(
        (method) => !method.startsWith("hal-c2.") && method !== "server.reportClientActivity",
      ),
  ).toEqual([]);
});
