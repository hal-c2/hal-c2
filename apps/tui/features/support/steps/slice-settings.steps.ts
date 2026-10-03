// tui/settings.feature: what the terminal changes on the server (new-thread
// defaults, provider instances and their keys, refresh, update) and the
// server's diagnostics, each from the palette with the result in settings.
import { expect } from "bun:test";

import {
  DEFAULT_SERVER_SETTINGS,
  type ServerProcessDiagnosticsResult,
  type ServerProvider,
  type ServerTraceDiagnosticsResult,
} from "@hal-c2/contracts";
import * as DateTime from "effect/DateTime";
import * as Option from "effect/Option";

import type { TuiSelectState } from "../../../src/host/composerState.ts";
import type { TuiSettingsState } from "../../../src/host/settingsState.ts";
import { flattenModelOptions } from "../../../src/models.ts";
import { step } from "../../steps.ts";
import { PROVIDERS } from "../fakeClient.ts";
import { chooseCommand, palette } from "../threadUi.ts";
import { deferred } from "../threadWorld.ts";
import { pressKey, settle, typeText, type World } from "../world.ts";
import { openOnThread, type ComposerWorld } from "./composer.steps.ts";
import { chooseInPicker } from "./controls.steps.ts";

interface ServerWorld extends ComposerWorld {
  /** Holds the provider update open so its progress can be read. */
  updateHold?: ReturnType<typeof deferred>;
  modelsBefore?: string[];
}

const select = (ctx: World) => ctx.host!.state.get("select") as TuiSelectState;
const status = (ctx: World) => ctx.host!.state.get("status") as { text: string; kind: string };
const settings = (ctx: World) => ctx.host!.state.get("settings") as TuiSettingsState;
const calls = (ctx: World, method: string) =>
  ctx.fake!.calls.filter((call) => call.method === method);
/** A settings group as label and value pairs (a value wrapped over rows is one value). */
function group(ctx: World, title: string): Array<[string, string]> {
  const rows: Array<[string, string]> = [];
  for (const row of settings(ctx).groups.find((entry) => entry.title === title)?.rows ?? []) {
    if (row.label === "" && rows.length > 0) rows.at(-1)![1] += row.value;
    else rows.push([row.label, row.value]);
  }
  return rows;
}

const provider = (base: (typeof PROVIDERS)[number], extra: Partial<ServerProvider> = {}) =>
  ({
    ...base,
    installed: true,
    version: "1.4.2",
    status: "ready",
    auth: { status: "authenticated" },
    checkedAt: "2026-07-13T00:00:00.000Z",
    ...extra,
  }) as ServerProvider;

/** Open on a thread of a server whose config is read from `ctx.fake.server`. */
async function openOnServer(ctx: ServerWorld, providers = PROVIDERS.map((base) => provider(base))) {
  if (ctx.app) return;
  await openOnThread(ctx, undefined, {
    getServerConfig: async () =>
      ({
        settings: ctx.fake!.server.settings,
        providers: ctx.fake!.server.providers,
        environment: { serverVersion: "0.42.1", capabilities: {} },
      }) as never,
    listModels: async () => flattenModelOptions(ctx.fake!.server.providers),
  });
  ctx.fake!.server.providers = providers;
  ctx.fake!.server.settings = DEFAULT_SERVER_SETTINGS;
  // The client read the config while it started; read it again now that the server has data.
  ctx.host!.dispatch("composer.providers.reload");
  await chooseCommand(ctx, "Refresh providers");
  await settle(ctx);
  ctx.fake!.calls.length = 0;
}

// --- Defaults -----------------------------------------------------------------------

step(
  "the user changes the default new-thread workspace to a new worktree",
  async (ctx: ServerWorld) => {
    await openOnServer(ctx);
    expect(group(ctx, "Defaults")).toEqual([["new threads", "Current checkout"]]);
    await chooseCommand(ctx, "Default workspace for new threads…");
    await chooseInPicker(ctx, "New worktree");
  },
);

step("the next new-thread draft preselects a new worktree", async (ctx: World) => {
  expect(calls(ctx, "updateSettings").map((call) => call.args[0])).toEqual([
    { defaultThreadEnvMode: "worktree" },
  ]);
  expect(status(ctx)).toEqual({ kind: "success", text: "New threads start in a new worktree." });
  expect(group(ctx, "Defaults")).toEqual([["new threads", "New worktree"]]);
  await pressKey(ctx, "Ctrl+N");
  await settle(ctx);
  expect(ctx.host!.state.get("newThread")).toMatchObject({
    workspaceMode: "new-worktree",
    workspaceLabel: "New worktree",
  });
});

// --- Provider instances ----------------------------------------------------------------

const API_KEY = "sk-test-0123456789";

step("the user adds a provider instance with an API key", async (ctx: ServerWorld) => {
  await openOnServer(ctx);
  await chooseCommand(ctx, "Add a provider instance…");
  expect(select(ctx).options.map((option) => option.label)).toEqual(["codex", "claude"]);
  await chooseInPicker(ctx, "codex");
  expect(ctx.host!.state.get("ask")).toMatchObject({ label: "instance name" });
  await typeText(ctx, "Codex work");
  await pressKey(ctx, "Enter");
  await settle(ctx);
  expect(ctx.host!.state.get("ask")).toMatchObject({ label: "OPENAI_API_KEY" });
  await typeText(ctx, API_KEY);
  await pressKey(ctx, "Enter");
  await settle(ctx);
});

step("the provider is listed and the key is stored as a secret", async (ctx: World) => {
  // One request: the instance with its key marked sensitive, for the server's secret store.
  expect(ctx.fake!.server.instanceMutations as unknown[]).toEqual([
    {
      operation: "create",
      instanceId: "codex-codex-work",
      instance: {
        driver: "codex",
        displayName: "Codex work",
        environment: [{ name: "OPENAI_API_KEY", value: API_KEY, sensitive: true }],
        enabled: true,
      },
    },
  ]);
  expect(status(ctx)).toEqual({
    kind: "success",
    text: "Added Codex work; its key is stored as a secret.",
  });
  // Settings list it, and never show the key.
  const rows = group(ctx, "Provider instances");
  expect(rows).toContainEqual(["Codex work", "codex · not started yet"]);
  expect(rows).toContainEqual(["  OPENAI_API_KEY", "•••••••• (secret)"]);
  ctx.host!.dispatch("settings.open");
  const screen = await settle(ctx);
  expect(screen).toContain("Codex work");
  expect(screen).toContain("(secret)");
  expect(screen).not.toContain(API_KEY);
  expect(JSON.stringify(settings(ctx))).not.toContain(API_KEY);
});

// --- Refresh ------------------------------------------------------------------------------

step("the user refreshes providers", async (ctx: ServerWorld) => {
  await openOnServer(ctx);
  await pressKey(ctx, "Ctrl+Shift+M");
  await settle(ctx);
  ctx.modelsBefore = select(ctx).options.map((option) => option.label);
  await pressKey(ctx, "Esc");
  // Since the last probe: Claude was signed out and Codex gained a model.
  ctx.fake!.server.afterRefresh = PROVIDERS.map((base) =>
    base.instanceId === "claude"
      ? provider(base, { status: "error", auth: { status: "unauthenticated" } })
      : provider(base, {
          models: [
            ...base.models,
            { slug: "gpt-6", name: "GPT-6", isCustom: false, capabilities: null },
          ],
        } as never),
  );
  await chooseCommand(ctx, "Refresh providers");
  await settle(ctx);
});

step("provider status and models are fetched again", async (ctx: ServerWorld) => {
  expect(calls(ctx, "refreshProviders")).toHaveLength(1);
  expect(status(ctx)).toEqual({ kind: "success", text: "2 providers refreshed · 1 signed out." });
  // Status: settings show what the probe found.
  expect(group(ctx, "Provider instances")).toEqual([
    ["Codex", "ready · signed in · 1.4.2 · 3 models"],
    ["Claude", "error · signed out · 1.4.2 · 1 model"],
  ]);
  // Models: the picker offers the new one, and no longer the signed-out provider's.
  expect(ctx.modelsBefore).toEqual(["GPT-5", "GPT-5 Codex", "Opus"]);
  await pressKey(ctx, "Ctrl+Shift+M");
  await settle(ctx);
  expect(select(ctx).options.map((option) => option.label)).toEqual([
    "GPT-5",
    "GPT-5 Codex",
    "GPT-6",
    "Opus",
  ]);
});

// --- Update -----------------------------------------------------------------------------------

const BEHIND = {
  status: "behind_latest",
  currentVersion: "1.4.2",
  latestVersion: "1.5.0",
  updateCommand: "npm i -g @openai/codex",
  canUpdate: true,
  checkedAt: null,
  message: null,
} as const;

step("a provider has an update available", async (ctx: ServerWorld) => {
  await openOnServer(
    ctx,
    PROVIDERS.map((base) =>
      provider(base, base.instanceId === "codex" ? { versionAdvisory: BEHIND as never } : {}),
    ),
  );
  expect(group(ctx, "Provider instances")[0]).toEqual([
    "Codex",
    "ready · signed in · 1.4.2 (1.5.0 available) · 2 models",
  ]);
  // Only the provider that is behind offers an update.
  await pressKey(ctx, "Ctrl+K");
  await typeText(ctx, "update");
  expect(palette(ctx).commands.map((command) => command.title)).toEqual(["Update Codex to 1.5.0"]);
  await pressKey(ctx, "Esc");
});

step("the user runs the provider update", async (ctx: ServerWorld) => {
  const hold = (ctx.updateHold = deferred());
  ctx.held = (ctx.held ?? 0) + 1;
  const updated = PROVIDERS.map((base) =>
    provider(
      base,
      base.instanceId === "codex"
        ? {
            version: "1.5.0" as never,
            updateState: {
              status: "succeeded",
              startedAt: null,
              finishedAt: null,
              message: null,
              output: null,
            },
          }
        : {},
    ),
  );
  // The server takes a while: the request stays open until the scenario lets it finish.
  ctx.fake!.override("updateProvider", async () => {
    await hold.promise;
    ctx.fake!.server.providers = updated;
    return updated;
  });
  await chooseCommand(ctx, "Update Codex to 1.5.0");
});

step("the update progress and result are shown", async (ctx: ServerWorld) => {
  // While the server runs the updater.
  expect(status(ctx)).toEqual({ kind: "busy", text: "Updating Codex to 1.5.0…" });
  expect(await settle(ctx)).toContain("Updating Codex to 1.5.0");
  ctx.held = (ctx.held ?? 1) - 1;
  ctx.updateHold!.resolve(undefined);
  await settle(ctx);
  expect(calls(ctx, "updateProvider").map((call) => call.args[0])).toEqual([
    { provider: "codex", instanceId: "codex", targetVersion: "1.5.0" },
  ]);
  expect(status(ctx)).toEqual({ kind: "success", text: "Codex updated to 1.5.0." });
  expect(group(ctx, "Provider instances")[0]).toEqual([
    "Codex",
    "ready · signed in · 1.5.0 · 2 models",
  ]);
  // Nothing left to update.
  await pressKey(ctx, "Ctrl+K");
  await typeText(ctx, "update codex");
  expect(palette(ctx).commands.map((command) => command.title)).not.toContain(
    "Update Codex to 1.5.0",
  );
});

// --- Diagnostics --------------------------------------------------------------------------------

const READ_AT = DateTime.makeUnsafe("2026-07-15T12:00:00.000Z");
const PROCESSES: ServerProcessDiagnosticsResult = {
  serverPid: 4100 as never,
  readAt: READ_AT,
  processCount: 2 as never,
  totalRssBytes: (310 * 1024 * 1024) as never,
  totalCpuPercent: 3.5,
  processes: [
    {
      pid: 4100 as never,
      startTimeMs: 0 as never,
      ppid: 1 as never,
      pgid: Option.none(),
      status: "S" as never,
      cpuPercent: 1.5,
      rssBytes: (200 * 1024 * 1024) as never,
      elapsed: "3-04:12:55" as never,
      command: "beam.smp hal-c2-mc" as never,
      depth: 0 as never,
      childPids: [4180 as never],
    },
    {
      pid: 4180 as never,
      startTimeMs: 0 as never,
      ppid: 4100 as never,
      pgid: Option.none(),
      status: "S" as never,
      cpuPercent: 2,
      rssBytes: (110 * 1024 * 1024) as never,
      elapsed: "00:41:07" as never,
      command: "codex app-server" as never,
      depth: 1 as never,
      childPids: [],
    },
  ],
  error: Option.none(),
};
const TRACES = {
  traceFilePath: "/var/log/hal-c2/trace.ndjson",
  scannedFilePaths: [],
  readAt: READ_AT,
  recordCount: 120,
  parseErrorCount: 0,
  firstSpanAt: Option.none(),
  lastSpanAt: Option.none(),
  failureCount: 1,
  interruptionCount: 0,
  slowSpanThresholdMs: 1000,
  slowSpanCount: 0,
  logLevelCounts: {},
  topSpansByCount: [],
  slowestSpans: [],
  commonFailures: [],
  latestFailures: [
    {
      name: "vcs.pull",
      cause: "remote rejected: non-fast-forward",
      durationMs: 412,
      endedAt: READ_AT,
      traceId: "t1",
      spanId: "s1",
    },
  ],
  latestWarningAndErrorLogs: [
    {
      spanName: "provider.codex",
      level: "Error",
      message: "app-server exited with status 1",
      seenAt: READ_AT,
      traceId: "t2",
      spanId: "s2",
    },
  ],
  partialFailure: Option.none(),
  error: Option.none(),
} as unknown as ServerTraceDiagnosticsResult;

step("the user opens diagnostics", async (ctx: ServerWorld) => {
  await openOnServer(ctx);
  ctx.fake!.server.processDiagnostics = PROCESSES;
  ctx.fake!.server.traceDiagnostics = TRACES;
  await chooseCommand(ctx, "Diagnostics");
  await settle(ctx);
});

step("the server's version, uptime and recent errors are shown", async (ctx: World) => {
  expect(calls(ctx, "getProcessDiagnostics")).toHaveLength(1);
  expect(calls(ctx, "getTraceDiagnostics")).toHaveLength(1);
  expect(group(ctx, "Diagnostics")).toEqual([
    ["version", "0.42.1"],
    ["uptime", "3-04:12:55"],
    ["processes", "2 · 310 MB"],
    ["recent errors", "2"],
    ["vcs.pull", "remote rejected: non-fast-forward"],
    ["Error provider.codex", "app-server exited with status 1"],
  ]);
  // Settings opened on them; they sit below the keys' fold, so scroll to them.
  expect(ctx.host!.state.get("mode")).toBe("settings");
  let screen = await settle(ctx);
  for (let page = 0; page < 6 && !screen.includes("Diagnostics"); page += 1) {
    await pressKey(ctx, "PgDn");
    screen = await settle(ctx);
  }
  for (const text of ["0.42.1", "3-04:12:55", "remote rejected: non-fast-forward"]) {
    expect(screen).toContain(text);
  }
});
