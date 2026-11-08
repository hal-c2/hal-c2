// A provider account that cannot run gives way to another of its driver
// (composer/model-and-mode.feature, upstream #23957, #27859, #29789). The
// accounts are the MC's provider config, which the TUI reads at start and on
// "Refresh providers"; turning one off is the config changing, then a refresh.
import { expect } from "bun:test";

import {
  DEFAULT_SERVER_SETTINGS,
  type ModelSelection,
  type OrchestrationThread,
  type ServerProvider,
} from "@hal-c2/contracts";

import { step } from "../../steps.ts";
import { flattenModelOptions } from "../../../src/models.ts";
import { PROVIDERS, project, shell, thread } from "../fakeClient.ts";
import { pressKey, settle, type World } from "../world.ts";
import { callsTo, composer, typeIntoPrompt } from "./composer.steps.ts";
import { restartClient, runPaletteCommand, select, type ControlsWorld } from "./controls.steps.ts";

interface FallbackWorld extends ControlsWorld {
  /** The MC's provider accounts, as its config says now. */
  accounts?: ServerProvider[];
  /** The project's model for new threads. */
  defaultModel?: ModelSelection;
  /** The open thread, as the MC saved it. */
  saved?: OrchestrationThread;
}

const effortChoices = {
  id: "reasoningEffort",
  label: "Effort",
  type: "select",
  options: [
    { id: "low", label: "Low", isDefault: true },
    { id: "high", label: "High" },
    { id: "xhigh", label: "Extra High" },
  ],
};

const accountModel = (slug: string, name: string, extra: Record<string, unknown> = {}) => ({
  slug,
  name,
  isCustom: false,
  capabilities: { optionDescriptors: [effortChoices] },
  ...extra,
});

const accountId = (name: string) => name.toLowerCase().replace(/ /g, "_");

const account = (name: string, driver: string, models: ReadonlyArray<unknown>) =>
  ({
    instanceId: accountId(name),
    driver,
    displayName: name,
    enabled: true,
    installed: true,
    status: "ready",
    models,
  }) as unknown as ServerProvider;

/** The client, serving the world's accounts as the MC's config. */
async function connect(ctx: FallbackWorld, detail?: OrchestrationThread): Promise<void> {
  await restartClient(ctx, {
    ...(detail ? { detail } : {}),
    // The project's own default for new threads (a carried model gives way to it).
    ...(ctx.defaultModel
      ? {
          shellSnapshot: shell(undefined, [
            { ...project, defaultModelSelection: ctx.defaultModel },
          ] as never),
        }
      : {}),
    listModels: async () => flattenModelOptions(ctx.accounts ?? []),
    getServerConfig: async () =>
      ({
        settings: {
          ...DEFAULT_SERVER_SETTINGS,
          // The settings name each account, on or off, as the MC's do.
          providerInstances: Object.fromEntries(
            (ctx.accounts ?? []).map((entry) => [
              entry.instanceId,
              { driver: entry.driver, enabled: entry.enabled !== false },
            ]),
          ),
        },
        providers: ctx.accounts ?? [],
      }) as never,
  });
}

function turnOff(ctx: FallbackWorld, instanceId: string): void {
  ctx.accounts = ctx.accounts!.map((entry) =>
    entry.instanceId === instanceId ? ({ ...entry, enabled: false } as ServerProvider) : entry,
  );
}

const refreshProviders = (ctx: World) => runPaletteCommand(ctx, "Refresh providers");

const effortOf = (ctx: World) =>
  composer(ctx).options.find((option) => option.id === "reasoningEffort")?.value ?? null;

/** Choose `label` on `provider` in the model picker, which lists every account's models. */
async function pickModel(ctx: World, label: string, provider: string): Promise<void> {
  await pressKey(ctx, "Ctrl+Shift+M");
  await settle(ctx);
  expect(select(ctx)).toMatchObject({ open: true, kind: "model", status: "ready" });
  const target = select(ctx).options.findIndex(
    (option) => option.label === label && option.description === provider,
  );
  expect(target).toBeGreaterThanOrEqual(0);
  while (select(ctx).index !== target) {
    await pressKey(ctx, select(ctx).index < target ? "Down" : "Up");
    await settle(ctx);
  }
  await pressKey(ctx, "Enter");
  await settle(ctx);
  expect(composer(ctx)).toMatchObject({
    selectedInstanceId: accountId(provider),
    selectedModel: expect.any(String),
  });
}

async function pickEffort(ctx: World, label: string): Promise<void> {
  await pressKey(ctx, "Ctrl+Shift+E");
  await settle(ctx);
  const target = select(ctx).options.findIndex((option) => option.label === label);
  expect(target).toBeGreaterThanOrEqual(0);
  while (select(ctx).index !== target) {
    await pressKey(ctx, select(ctx).index < target ? "Down" : "Up");
    await settle(ctx);
  }
  await pressKey(ctx, "Enter");
  await settle(ctx);
}

// --- A new thread's default on an account that is off (upstream #23957) ------

step(
  "new threads default to Claude Opus at extra high effort on the account {string}",
  async (ctx: FallbackWorld, name: string) => {
    ctx.accounts = [
      ...(PROVIDERS as ServerProvider[]),
      account(name, "claudeAgent", [accountModel("opus", "Claude Opus")]),
      account("Claude Team", "claudeAgent", [accountModel("opus", "Claude Opus")]),
    ];
    ctx.defaultModel = {
      instanceId: accountId(name),
      model: "opus",
      options: [{ id: "reasoningEffort", value: "xhigh" }],
    } as unknown as ModelSelection;
    await connect(ctx);
  },
);

step(
  "{string} is turned off and the account {string} is ready",
  async (ctx: FallbackWorld, off: string, ready: string) => {
    expect(ctx.accounts!.some((entry) => entry.instanceId === accountId(ready))).toBe(true);
    turnOff(ctx, accountId(off));
    await refreshProviders(ctx);
  },
);

step(
  "{string} is turned off and {string}, with high effort of its own is ready",
  async (ctx: FallbackWorld, off: string, ready: string) => {
    // The fallback account's own effort for the model, from when the user used it.
    await pickModel(ctx, "Claude Opus", ready);
    await pickEffort(ctx, "High");
    expect(effortOf(ctx)).toBe("high");
    turnOff(ctx, accountId(off));
    await refreshProviders(ctx);
  },
);

step(
  "{string} is turned off and only a Codex account is ready",
  async (ctx: FallbackWorld, off: string) => {
    for (const id of [accountId(off), "claude_team", "claude"]) turnOff(ctx, id);
    await refreshProviders(ctx);
    expect(
      ctx.accounts!.filter((entry) => entry.enabled !== false).map((entry) => entry.driver),
    ).toEqual(["codex"] as never);
  },
);

step(
  "the composer shows Claude Opus at extra high effort on {string}",
  async (ctx: World, name: string) => {
    await settle(ctx);
    expect(composer(ctx).routeKind).toBe("draft");
    expect(composer(ctx)).toMatchObject({
      selectedInstanceId: accountId(name),
      selectedModel: "opus",
    });
    expect(effortOf(ctx)).toBe("xhigh");
  },
);

step("the first turn is sent at extra high effort", async (ctx: World) => {
  await typeIntoPrompt(ctx, "first turn");
  await pressKey(ctx, "Enter");
  await settle(ctx);
  const created = callsTo(ctx, "createThread").at(-1)?.args[0] as
    | { modelSelection: ModelSelection }
    | undefined;
  expect(created?.modelSelection).toMatchObject({
    instanceId: "claude_team",
    model: "opus",
    options: expect.arrayContaining([{ id: "reasoningEffort", value: "xhigh" }]),
  });
});

step("the composer shows {string} at its own high effort", async (ctx: World, name: string) => {
  await settle(ctx);
  expect(composer(ctx).routeKind).toBe("draft");
  expect(composer(ctx).selectedInstanceId).toBe(accountId(name));
  expect(effortOf(ctx)).toBe("high");
});

step("the composer shows the Codex model at its default effort", async (ctx: World) => {
  await settle(ctx);
  expect(composer(ctx)).toMatchObject({
    routeKind: "draft",
    selectedInstanceId: "codex",
    selectedModel: "gpt-5",
  });
  // Codex's effort defaults to medium in this catalogue.
  expect(effortOf(ctx)).toBe("medium");
});

// --- A thread saved under an alias (upstream #27859) -------------------------

step(
  "a thread saved on the account {string} with the model {string} at high effort",
  async (ctx: FallbackWorld, name: string, model: string) => {
    const builtIn = accountModel("gpt-5.4", "GPT-5.4", { aliases: ["5.4"] });
    const custom = accountModel("my-5.4", "5.4", { isCustom: true });
    ctx.accounts = [
      account(name, "codex", [builtIn, custom]),
      account("Codex Work", "codex", [builtIn]),
    ];
    ctx.saved = {
      ...thread(),
      modelSelection: {
        instanceId: accountId(name),
        model,
        options: [{ id: "reasoningEffort", value: "high" }],
      },
    } as unknown as OrchestrationThread;
    await connect(ctx, ctx.saved);
  },
);

/** "the user opens the thread": the saved one, on the accounts the config has now. */
export async function openSavedThread(ctx: World): Promise<void> {
  const world = ctx as FallbackWorld;
  if (!world.saved) throw new Error("No thread was saved to open.");
  await connect(world, world.saved);
}

step(
  "the composer shows {string} on {string} at high effort",
  async (ctx: World, model: string, name: string) => {
    await settle(ctx);
    expect(composer(ctx)).toMatchObject({
      routeKind: "server",
      selectedInstanceId: accountId(name),
      selectedModel: model,
    });
    expect(effortOf(ctx)).toBe("high");
  },
);

step(
  "a custom model named {string} on {string} is not taken for {string}",
  (ctx: World, _name: string, _account: string, model: string) => {
    expect(composer(ctx).selectedModel).toBe(model);
    expect(composer(ctx).selectedModel).not.toBe("my-5.4");
  },
);

// --- A custom model named like a built-in's alias (upstream #29789) ----------

step(
  "the Codex account {string} has the custom model {string}",
  async (ctx: FallbackWorld, name: string, slug: string) => {
    // The built-in Codex account lists "GPT-5 Codex", whose slug is "gpt-5-codex" too.
    ctx.accounts = [
      ...(PROVIDERS as ServerProvider[]),
      account(name, "codex", [accountModel(slug, slug, { isCustom: true })]),
    ];
    await connect(ctx);
  },
);

step(
  "the user picks {string} on {string} at high effort and sends a message",
  async (ctx: World, slug: string, name: string) => {
    await pickModel(ctx, slug, name);
    await pickEffort(ctx, "High");
    expect(effortOf(ctx)).toBe("high");
    await typeIntoPrompt(ctx, "through the proxy");
    await pressKey(ctx, "Enter");
    await settle(ctx);
  },
);

step(
  "the turn runs on the custom model {string}, not on a built-in model it is an alias of",
  (ctx: World, slug: string) => {
    const sent = callsTo(ctx, "sendReply").at(-1)?.args[3] as ModelSelection | undefined;
    expect(sent).toMatchObject({
      instanceId: "codex_proxy",
      model: slug,
      options: [{ id: "reasoningEffort", value: "high" }],
    });
  },
);

step("picking {string} again offers high effort", async (ctx: World, slug: string) => {
  await pickModel(ctx, "GPT-5", "Codex");
  expect(composer(ctx).selectedModel).toBe("gpt-5");
  await pickModel(ctx, slug, "Codex Proxy");
  expect(composer(ctx)).toMatchObject({ selectedInstanceId: "codex_proxy", selectedModel: slug });
  expect(effortOf(ctx)).toBe("high");
});
