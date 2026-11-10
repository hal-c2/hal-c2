// The model picker (composer/model-and-mode.feature): every saved custom model
// is offered (upstream #14961), and a draft's pick gives way to a change made
// on another client once the thread has taken it (upstream #20886), and a
// provider's older models wait behind a "Show more" row (upstream #28076).
import { expect } from "bun:test";

import type { OrchestrationThread, ServerProvider } from "@hal-c2/contracts";

import { step } from "../../steps.ts";
import { PROVIDERS, shell, thread } from "../fakeClient.ts";
import { shownText } from "../threadWorld.ts";
import { findObject, pressKey, resize, settle, type World } from "../world.ts";
import { composer, updateThread } from "./composer.steps.ts";
import { chooseInPicker, restartClient, select, type ControlsWorld } from "./controls.steps.ts";

// --- Custom models (upstream #14961) -------------------------------------------

const customModels = (count: number) =>
  Array.from({ length: count }, (_, at) => ({
    slug: `custom-model-${at + 1}`,
    name: `Custom Model ${at + 1}`,
    isCustom: true,
    capabilities: null,
  }));

step(
  "the user has saved {int} custom models for Codex",
  async (ctx: ControlsWorld, count: number) => {
    const providers = PROVIDERS.map((provider) =>
      provider.instanceId === "codex"
        ? { ...provider, models: [...provider.models, ...customModels(count)] }
        : provider,
    ) as unknown as ReadonlyArray<ServerProvider>;
    await restartClient(ctx, { providers });
  },
);

step("all {int} custom models are offered", (ctx: World, count: number) => {
  const labels = select(ctx).options.map((option) => option.label);
  for (const model of customModels(count)) expect(labels).toContain(model.name);
});

step(
  /^a thread set to the (\d+)(?:st|nd|rd|th) custom model shows that model as chosen$/,
  async (ctx: World, nth: string) => {
    await pressKey(ctx, "Esc");
    await settle(ctx);
    const model = `custom-model-${nth}`;
    await updateThread(ctx, (detail) => ({
      ...detail,
      modelSelection: { instanceId: "codex", model } as never,
    }));
    expect(composer(ctx).selectedModel).toBe(model);
    expect(shownText(findObject(ctx, "composerModel").get("text"))).toBe(
      `model Custom Model ${nth} ▾`,
    );
  },
);

// --- A draft follows a change made elsewhere (upstream #20886) -----------------

/** The models the scenario names, as the fake MC lists them. */
const MODELS: Record<string, { instanceId: string; model: string; label: string }> = {
  "gpt-5": { instanceId: "codex", model: "gpt-5", label: "GPT-5" },
  "gpt-5-codex": { instanceId: "codex", model: "gpt-5-codex", label: "GPT-5 Codex" },
  "claude-opus": { instanceId: "claude", model: "opus", label: "Opus" },
};

const row = (id: string, title: string, updatedAt: string) => ({
  id,
  projectId: "p1",
  title,
  updatedAt,
  session: { status: "idle" },
  latestTurn: null,
});

/** Thread two sits below thread one; Alt+Down and Alt+Up move between them. */
async function switchTo(ctx: World, id: "t1" | "t2"): Promise<void> {
  await pressKey(ctx, id === "t2" ? "Alt+Down" : "Alt+Up");
  await settle(ctx);
  expect(composer(ctx).target).toBe(`thread:${id}`);
}

async function pickModel(ctx: World, name: string): Promise<void> {
  await pressKey(ctx, "Ctrl+Shift+M");
  await settle(ctx);
  expect(select(ctx)).toMatchObject({ open: true, kind: "model", status: "ready" });
  await chooseInPicker(ctx, MODELS[name]!.label);
  expect(composer(ctx).selectedModel).toBe(MODELS[name]!.model);
}

/** The thread's own row now runs `name`, as when a turn ran on it or another client changed it. */
function runThreadOn(ctx: World, id: string, name: string): void {
  const { instanceId, model } = MODELS[name]!;
  const current = ctx.fake!.currentThread(id)!;
  ctx.fake!.emitThread({
    ...current,
    modelSelection: { instanceId, model },
  } as unknown as OrchestrationThread);
}

step(
  "the user picked {string} in the draft of a thread on this client",
  async (ctx: ControlsWorld, name: string) => {
    await restartClient(ctx);
    ctx.fake!.emitShell(
      shell([
        row("t1", "Thread one", "2026-07-13T00:00:02.000Z"),
        row("t2", "Thread two", "2026-07-13T00:00:01.000Z"),
      ] as never),
    );
    ctx.fake!.emitThread({ ...thread(), id: "t2", title: "Thread two" } as never);
    await settle(ctx);
    // Thread two holds a pick its thread has not taken.
    await switchTo(ctx, "t2");
    await pickModel(ctx, "gpt-5-codex");
    await switchTo(ctx, "t1");
    // Here, each pick is taken by the thread in turn.
    await pickModel(ctx, "gpt-5-codex");
    runThreadOn(ctx, "t1", "gpt-5-codex");
    await settle(ctx);
    await pickModel(ctx, name);
    runThreadOn(ctx, "t1", name);
    await settle(ctx);
  },
);

step("then changed the thread to {string} on another client", async (ctx: World, name: string) => {
  // The user is in thread two when the change comes.
  await switchTo(ctx, "t2");
  runThreadOn(ctx, "t1", name);
  await settle(ctx);
});

step("the user returns to the thread here", async (ctx: World) => {
  await switchTo(ctx, "t1");
});

step("the draft is on {string}", (ctx: World, name: string) => {
  const { instanceId, model } = MODELS[name]!;
  expect(composer(ctx)).toMatchObject({ selectedInstanceId: instanceId, selectedModel: model });
});

step("an unsent pick in another thread's draft is kept", async (ctx: World) => {
  await switchTo(ctx, "t2");
  expect(composer(ctx).selectedModel).toBe("gpt-5-codex");
});

// --- Older models (upstream #28076) --------------------------------------------

const codexModel = (slug: string, name: string, isLegacy = false) => ({
  slug,
  name,
  isCustom: false,
  capabilities: null,
  ...(isLegacy ? { isLegacy: true } : {}),
});

const CURRENT = ["GPT-6", "GPT-6 Mini"];
const OLDER = ["GPT-4.1", "GPT-4o", "o3"];

const labels = (ctx: World) => select(ctx).options.map((option) => option.label);

/** A short terminal, so the picker cannot hold the five models and the two other rows. */
const SHORT_ROWS = 12;

step("Codex lists two current models and three it calls legacy", async (ctx: ControlsWorld) => {
  const providers = PROVIDERS.map((provider) =>
    provider.instanceId === "codex"
      ? {
          ...provider,
          models: [
            codexModel("gpt-6", "GPT-6"),
            codexModel("gpt-6-mini", "GPT-6 Mini"),
            codexModel("gpt-4.1", "GPT-4.1", true),
            codexModel("gpt-4o", "GPT-4o", true),
            codexModel("o3", "o3", true),
          ],
        }
      : provider,
  ) as unknown as ReadonlyArray<ServerProvider>;
  await restartClient(ctx, {
    providers,
    detail: { ...thread(), modelSelection: { instanceId: "codex", model: "gpt-6" } } as never,
  });
  await resize(ctx, ctx.columns ?? 100, SHORT_ROWS);
  await settle(ctx);
});

step(
  "the user chooses {string} at the end of Codex's models",
  async (ctx: World, label: string) => {
    await pressKey(ctx, "Ctrl+Shift+M");
    await settle(ctx);
    expect(select(ctx)).toMatchObject({ open: true, kind: "model", status: "ready" });
    // The older models are folded behind the row that ends Codex's models.
    expect(labels(ctx)).toEqual([...CURRENT, label, "Opus"]);
    expect(select(ctx).options[CURRENT.length]!.description).toContain("Codex");
    await chooseInPicker(ctx, label);
  },
);

step(
  "the three older models are listed in place and the row reads {string}",
  (ctx: World, label: string) => {
    const picker = select(ctx);
    expect(picker).toMatchObject({ open: true, kind: "model" });
    expect(labels(ctx)).toEqual([...CURRENT, ...OLDER, label, "Opus"]);
    // The highlight stays on the row the user chose.
    expect(picker.options[picker.index]!.label).toBe(label);
  },
);

step("the list scrolls inside the picker", async (ctx: World) => {
  const shown = () => select(ctx).rows.map((row) => row.index);
  // Not every row fits: the window follows the highlight.
  expect(shown().length).toBeLessThan(select(ctx).options.length);
  expect(shown()).toContain(select(ctx).index);
  while (select(ctx).index > 0) {
    await pressKey(ctx, "Up");
    await settle(ctx);
  }
  expect(shown()).toContain(0);
  expect(shown()).not.toContain(select(ctx).options.length - 1);
});
