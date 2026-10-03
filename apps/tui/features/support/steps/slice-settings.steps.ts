// tui/settings.feature: what the terminal changes on the server (new-thread
// defaults, provider instances and their keys, refresh, update) and the
// server's diagnostics, each from the palette with the result in settings.
import { expect } from "bun:test";

import { DEFAULT_SERVER_SETTINGS, type ServerProvider } from "@hal-c2/contracts";

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
  expect(
    palette(ctx)
      .commands.map((command) => command.title)
      .filter((title) => title.startsWith("Update ")),
  ).toEqual(["Update Codex to 1.5.0"]);
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

// --- Diagnostics (the settings page, sections/diagnostics.ts) ---

const none = { _id: "Option", _tag: "None" };
const diagnosticsProcess = (pid: number, command: string, elapsed: string) => ({
  pid,
  ppid: 1,
  pgid: pid,
  status: "S",
  cpuPercent: 1.5,
  rssBytes: 200 * 1024 * 1024,
  elapsed,
  startTimeMs: 1_767_225_600_000 + pid,
  command,
  depth: 0,
  childPids: [],
});

step("the user opens diagnostics", async (ctx: ServerWorld) => {
  await openOnServer(ctx);
  const mc = ctx.fake!.settings;
  mc.on("server.getProcessDiagnostics", () => ({
    serverPid: 4100,
    readAt: "2026-07-15T12:00:00.000Z",
    processCount: 2,
    totalRssBytes: 400 * 1024 * 1024,
    totalCpuPercent: 3,
    processes: [
      diagnosticsProcess(4100, "beam.smp hal-c2-mc", "3-04:12:55"),
      diagnosticsProcess(4180, "codex app-server", "00:41:07"),
    ],
    error: none,
  }));
  mc.on("server.getTraceDiagnostics", () => ({
    recordCount: 120,
    failureCount: 2,
    slowSpanCount: 0,
    parseErrorCount: 0,
    latestFailures: [
      { name: "vcs.pull", cause: "remote rejected: non-fast-forward" },
      { name: "provider.codex", cause: "app-server exited with status 1" },
    ],
    error: none,
  }));
  await chooseCommand(ctx, "Diagnostics");
  await settle(ctx);
});

step("the server's version, uptime and recent errors are shown", async (ctx: World) => {
  const section = ctx.host!.state.get("settingsSection") as { id: string; lines: string[] };
  expect(section.id).toBe("diagnostics");
  const page = section.lines.join("\n");
  // The version the MC reports and how long its own process has run.
  expect(page).toContain("version 0.42.1 · up 3-04:12:55");
  // The latest failures it recorded, newest first, with why.
  expect(page).toContain("2 failures");
  expect(page).toContain("vcs.pull");
  expect(page).toContain("remote rejected: non-fast-forward");
  expect(page).toContain("app-server exited with status 1");
  const screen = (await settle(ctx)).replace(/\s+/g, " ");
  for (const text of ["version 0.42.1 · up 3-04:12:55", "remote rejected: non-fast-forward"]) {
    expect(screen).toContain(text);
  }
});
