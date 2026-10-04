// providers/usage-limits.feature and providers/usage.feature: "/usage-limits" answered
// above the prompt from what the MC knows, and the Usage page's totals per provider.
import { expect } from "bun:test";
import { DEFAULT_SERVER_SETTINGS, type OrchestrationThread } from "@hal-c2/contracts";

import type { TuiSelectState } from "../../../src/host/composerState.ts";
import { step } from "../../steps.ts";
import { objectRows } from "../design.ts";
import { PROVIDERS, thread } from "../fakeClient.ts";
import { openSection, pageText, paneWords, type SettingsWorld } from "../settingsWorld.ts";
import {
  findObject,
  geometry,
  pressKey,
  settle,
  typeText,
  useClient,
  type World,
} from "../world.ts";
import { callsTo, composer, openOnThread, type ComposerWorld } from "./composer.steps.ts";

const NOW_MS = Date.parse("2026-09-23T10:00:00.000Z");
const iso = (ms: number) => new Date(ms).toISOString();
const select = (ctx: World) => ctx.host!.state.get("select") as TuiSelectState;

// --- Subscription limits --------------------------------------------------------------------

const limits = (session: number, weekly: number) => ({
  checkedAt: iso(NOW_MS),
  windows: [
    {
      id: "primary",
      kind: "session",
      label: "5-hour",
      usedPercent: session,
      resetsAt: iso(NOW_MS + 2 * 3_600_000),
      windowDurationMins: 300,
    },
    {
      id: "secondary",
      kind: "weekly",
      label: "Weekly",
      usedPercent: weekly,
      resetsAt: iso(NOW_MS + 3 * 86_400_000),
      windowDurationMins: 10_080,
    },
  ],
});

const signedIn = (index: number, email: string, usage: unknown) => ({
  ...PROVIDERS[index]!,
  installed: true,
  status: "ready",
  auth: { status: "authenticated", email },
  slashCommands: [],
  usageLimits: usage,
});

/** Antigravity reports no limits; it has a command of its own. */
const ANTIGRAVITY = {
  instanceId: "antigravity",
  driver: "antigravity",
  displayName: "Antigravity",
  enabled: true,
  installed: true,
  status: "ready",
  auth: { status: "authenticated" },
  models: [{ slug: "gemini-pro", name: "Gemini Pro", isCustom: false, capabilities: null }],
  slashCommands: [{ name: "memory", description: "Show what the agent remembers" }],
};

interface LimitsWorld extends ComposerWorld {
  limitProviders?: unknown[];
}

step(
  "a connected environment with Codex and Claude signed in with subscriptions",
  (ctx: LimitsWorld) => {
    ctx.nowMs = NOW_MS;
    ctx.limitProviders = [
      signedIn(0, "sam@example.com", limits(40, 10)),
      signedIn(1, "sam@example.com", limits(5, 20)),
      ANTIGRAVITY,
    ];
  },
);

/** Open the client on a thread of `instanceId`, with the MC's providers as the Background set them. */
async function openThreadOn(ctx: LimitsWorld, instanceId: string, model: string) {
  const providers = ctx.limitProviders as never;
  await openOnThread(
    ctx,
    { ...thread(), modelSelection: { instanceId, model } } as unknown as OrchestrationThread,
    {
      providers,
      getServerConfig: async () =>
        ({ settings: DEFAULT_SERVER_SETTINGS, providers, usageLimitSources: [] }) as never,
    },
  );
  // What following the limits delivers: the same accounts, as the MC's config stream has them.
  ctx.fake!.settings.usageLimits = { providers, sources: [] };
  expect(composer(ctx).selectedModel).toBe(model);
}

step("a Codex thread", (ctx: LimitsWorld) => openThreadOn(ctx, "codex", "gpt-5"));
step("an Antigravity thread", (ctx: LimitsWorld) => openThreadOn(ctx, "antigravity", "gemini-pro"));

const LIMIT_ROWS = [
  "Codex 5-hour: 60% left · resets in 2h 0m",
  "Codex Weekly: 90% left · resets in 3d 0h",
];

step(
  "Codex's windows are shown above the composer without running the agent",
  async (ctx: World) => {
    expect(composer(ctx).limitLines).toEqual(LIMIT_ROWS);
    expect(geometry(findObject(ctx, "composerLimits")).visible).toBe(true);
    const rows = (await objectRows(ctx, "composerLimits")).map((row) => row.trim());
    expect(rows).toEqual(LIMIT_ROWS);
    // Above the prompt, which is clear again; only Codex's accounts, not Claude's.
    expect(composer(ctx).text).toBe("");
    expect(rows.join("\n")).not.toContain("Claude");
    // Answered by the client: nothing went to the agent.
    expect(callsTo(ctx, "sendReply")).toEqual([]);
    expect(composer(ctx).isRunning).toBe(false);
    expect(ctx.fake!.settings.usageLimitWatchers()).toBe(1);
  },
);

step("they close when the user sends the next message", async (ctx: World) => {
  await typeText(ctx, "Carry on with the tax line");
  await pressKey(ctx, "Enter");
  await settle(ctx);
  expect(callsTo(ctx, "sendReply").map((call) => call.args[1])).toEqual([
    "Carry on with the tax line",
  ]);
  expect(composer(ctx).limitLines).toEqual([]);
  expect(geometry(findObject(ctx, "composerLimits")).visible).toBe(false);
  expect(ctx.fake!.settings.usageLimitWatchers()).toBe(0);
});

step("the user opens the composer's command menu", async (ctx: World) => {
  await typeText(ctx, "/");
  await settle(ctx);
  // The provider's own commands are there, so the menu opens.
  expect(select(ctx)).toMatchObject({ open: true, title: "commands" });
  expect(select(ctx).options.map((option) => option.label)).toEqual(["/memory"]);
});

// --- Usage totals -----------------------------------------------------------------------------

const bucket = (
  provider: string,
  model: string,
  day: string,
  tokens: [input: number, cached: number, output: number],
  costUsd: number,
) => ({
  day,
  provider,
  model,
  totals: {
    uncachedInputTokens: tokens[0],
    cachedInputTokens: tokens[1],
    cacheCreationTokens: 0,
    outputTokens: tokens[2],
    reasoningTokens: 0,
  },
  costUsd,
  cacheSavingsUsd: 0,
  costSource: "modelPriced",
  records: 10,
  unpricedRecords: 0,
  sessions: 2,
});

step("a connected environment with Codex, Claude and Grok history", (ctx: SettingsWorld) => {
  ctx.nowMs = NOW_MS;
  const fake = ctx.fake ?? useClient(ctx);
  fake.settings.on("server.getUsageSummary", (payload) => {
    const input = payload as { sinceDay: string; untilDay: string; timeZone: string };
    return {
      contractVersion: 5,
      readAt: iso(NOW_MS),
      ...input,
      buckets: [
        bucket("codex", "gpt-5", input.untilDay, [900_000, 300_000, 50_000], 4.2),
        bucket("codex", "gpt-5-codex", input.sinceDay, [200_000, 0, 50_000], 1.3),
        bucket("claude", "claude-opus", input.untilDay, [2_000_000, 500_000, 100_000], 31.75),
        bucket("grok", "grok-code", input.untilDay, [10_000, 0, 2_500], 0.04),
      ],
      sources: [],
      pricing: { status: "fresh", source: "litellm", fetchedAt: iso(NOW_MS), knownModels: 3 },
      scanDurationMs: 12,
    };
  });
});

step("the user opens Usage in the TUI", async (ctx: SettingsWorld) => {
  await openSection(ctx, "usage");
});

step("tokens and estimated cost per provider are shown", async (ctx: SettingsWorld) => {
  // One read, of the last seven days in the user's own time zone.
  const [call] = ctx.fake!.settings.callsTo("server.getUsageSummary");
  const asked = call!.payload as { sinceDay: string; untilDay: string; timeZone: string };
  expect(asked.timeZone).toBe(Intl.DateTimeFormat().resolvedOptions().timeZone);
  expect(Date.parse(asked.untilDay) - Date.parse(asked.sinceDay)).toBe(6 * 86_400_000);
  const text = pageText(ctx);
  // The costliest provider first; a provider's models are added up.
  expect(text.indexOf("Claude")).toBeLessThan(text.indexOf("Codex"));
  expect(text.indexOf("Codex")).toBeLessThan(text.indexOf("Grok"));
  expect(text).toContain("2.60M tokens · 2.50M in · 100K out");
  expect(text).toContain("$31.75 estimated");
  expect(text).toContain("1.50M tokens · 1.40M in · 100K out");
  expect(text).toContain("$5.50 estimated");
  expect(text).toContain("12.5K tokens · 10K in · 2.50K out");
  expect(text).toContain("$0.04 estimated");
  expect(text).toContain("Total $37.29 estimated");
  const pane = await paneWords(ctx);
  expect(pane).toContain("Claude");
  expect(pane).toContain("$31.75 estimated");
  expect(pane).toContain("Total $37.29 estimated");
});
