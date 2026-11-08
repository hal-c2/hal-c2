// Stepping the effort from the keyboard (composer/model-and-mode.feature, upstream
// #19928): composer.increaseEffort / decreaseEffort, bound here as a user's
// keymap.json would bind them, since they ship unbound.
import { expect } from "bun:test";

import { DEFAULT_SERVER_SETTINGS, type ServerProvider } from "@hal-c2/contracts";

import { step } from "../../steps.ts";
import { PROVIDERS, thread } from "../fakeClient.ts";
import { approvalRequest, questionRequest, shownText } from "../threadWorld.ts";
import { findObject, holdKey, pressKey, settle, type World } from "../world.ts";
import { callsTo, composer, typeIntoPrompt } from "./composer.steps.ts";
import { restartClient, type ControlsWorld } from "./controls.steps.ts";

// `applyKeymapOverrides` is not exported from opentui-qml's entry; reach the module directly.
const keymapModule = new URL("./components/keymap.ts", import.meta.resolve("opentui-qml"));
const { applyKeymapOverrides } = (await import(keymapModule.href)) as {
  applyKeymapOverrides: (engine: unknown, overrides: Record<string, unknown>) => void;
};

const STEP_KEYS = { up: "alt+]", down: "alt+[" } as const;

interface EffortWorld extends ControlsWorld {
  /** The prompt's text and caret before the step. */
  promptBefore?: { text: string; caret: number };
  /** The effort the outcome compares against. */
  effortBefore?: string | null;
  /** The step key is held down rather than pressed. */
  holdStep?: boolean;
  /** The effort option's value, which a read-out the prompt sets can hide. */
  chosenBefore?: string | boolean | null;
  /** Every effort the picker listed and stepping reached. */
  effortsOffered?: string[];
  /** The effort read-out when the prompt was sent. */
  effortWhenSent?: string;
}

const effortSelect = (defaultId: string, ids = ["low", "medium", "high"], extra = {}) => ({
  id: "effort",
  label: "Effort",
  type: "select",
  options: ids.map((id) => ({
    id,
    label: id[0]!.toUpperCase() + id.slice(1),
    ...(id === defaultId ? { isDefault: true } : {}),
  })),
  ...extra,
});

/** Claude at medium or high, with Ultrathink above them, a level only the prompt reaches. */
const CLAUDE = [
  {
    instanceId: "claude",
    driver: "claudeAgent",
    displayName: "Claude",
    enabled: true,
    models: [
      {
        slug: "opus",
        name: "Opus",
        isCustom: false,
        capabilities: {
          optionDescriptors: [
            effortSelect("medium", ["medium", "high", "ultrathink"], {
              promptInjectedValues: ["ultrathink"],
            }),
          ],
        },
      },
    ],
  },
] as unknown as ReadonlyArray<ServerProvider>;

/** The prompt's text and caret, as the TextArea holds them. */
function prompt(ctx: World): { text: string; caret: number } {
  const { renderable } = findObject(ctx, "composerInput") as unknown as {
    renderable: { plainText: string; cursorOffset: number };
  };
  return { text: renderable.plainText, caret: renderable.cursorOffset };
}

/** The value the selection holds for the effort, under any read-out. */
const chosenEffort = (ctx: World) =>
  composer(ctx).options.find((option) => option.id === "effort" || option.id === "reasoningEffort")
    ?.value ?? null;

async function setEffort(ctx: World, effort: string): Promise<void> {
  await pressKey(ctx, "Ctrl+Shift+E");
  await settle(ctx);
  const label = effort[0]!.toUpperCase() + effort.slice(1);
  const picker = ctx.host!.state.get("select") as {
    options: ReadonlyArray<{ label: string }>;
    index: number;
  };
  const target = picker.options.findIndex((option) => option.label === label);
  expect(target).toBeGreaterThanOrEqual(0);
  for (let at = picker.index; at !== target; at += at < target ? 1 : -1) {
    await pressKey(ctx, at < target ? "Down" : "Up");
  }
  await pressKey(ctx, "Enter");
  await settle(ctx);
  expect(composer(ctx).effort).toBe(effort);
}

step(
  "the thread runs on a model whose efforts are low, medium and high",
  async (ctx: EffortWorld) => {
    await restartClient(ctx);
    expect(composer(ctx).effort).toBe("medium");
  },
);

step(
  /^the effort is (low|medium|high) and the user is typing a draft$/,
  async (ctx: EffortWorld, effort: string) => {
    if (composer(ctx).effort !== effort) await setEffort(ctx, effort);
    await typeIntoPrompt(ctx, "tidy the cache");
    // The caret sits mid-draft, before "cache".
    for (let i = 0; i < "cache".length; i += 1) await pressKey(ctx, "Left");
    await settle(ctx);
    ctx.promptBefore = prompt(ctx);
    expect(ctx.promptBefore).toEqual({ text: "tidy the cache", caret: "tidy the ".length });
  },
);

step("the thread runs on Claude", async (ctx: EffortWorld) => {
  await restartClient(ctx, {
    providers: CLAUDE,
    detail: { ...thread(), modelSelection: { instanceId: "claude", model: "opus" } } as never,
  });
  expect(composer(ctx).effort).toBe("medium");
});

/** Bind the step commands as a user's keymap.json would. */
function bindStepKeys(ctx: World): void {
  applyKeymapOverrides(ctx.app!.engine, {
    [STEP_KEYS.up]: "composer.increaseEffort",
    [STEP_KEYS.down]: "composer.decreaseEffort",
  });
}

step("the user opens the effort choices or steps the effort", async (ctx: EffortWorld) => {
  await pressKey(ctx, "Ctrl+Shift+E");
  await settle(ctx);
  const picker = ctx.host!.state.get("select") as {
    open: boolean;
    options: ReadonlyArray<{ label: string }>;
  };
  expect(picker.open).toBe(true);
  const offered = picker.options.map((option) => option.label);
  await pressKey(ctx, "Esc");
  await settle(ctx);
  // Once round every level and one more, each way.
  bindStepKeys(ctx);
  const levels = offered.length;
  for (const key of ["]", "["]) {
    for (let i = 0; i <= levels; i += 1) {
      await pressKey(ctx, `Alt+${key}`);
      await settle(ctx);
      offered.push(String(composer(ctx).effort));
    }
  }
  ctx.effortsOffered = offered;
});

step("Ultrathink is not offered", (ctx: EffortWorld) => {
  expect(ctx.effortsOffered!.length).toBeGreaterThan(0);
  expect(ctx.effortsOffered!.some((effort) => /ultrathink/i.test(effort))).toBe(false);
});

step("the user types {string} and sends it", async (ctx: EffortWorld, text: string) => {
  await typeIntoPrompt(ctx, text);
  ctx.effortWhenSent = shownText(findObject(ctx, "composerEffort").get("text"));
  await pressKey(ctx, "Enter");
  await settle(ctx);
});

step(
  "the effort reads {string} and the turn runs at Ultrathink",
  (ctx: EffortWorld, label: string) => {
    expect(ctx.effortWhenSent).toMatch(new RegExp(label, "i"));
    // The prompt carries the level to the agent.
    const sent = callsTo(ctx, "sendReply");
    expect(sent.map((call) => call.args[1])).toEqual(["Ultrathink: design the cache"]);
  },
);

step(
  "the draft reads {string} without {string}",
  async (ctx: EffortWorld, text: string, gone: string) => {
    await settle(ctx);
    expect(composer(ctx).text).toBe(text);
    expect(prompt(ctx).text).toBe(text);
    expect(composer(ctx).text).not.toContain(gone);
  },
);

step("the provider reports an effort the model does not list", async (ctx: EffortWorld) => {
  // OpenCode reports "default", a level its models do not offer.
  const providers = PROVIDERS.map((provider) => ({
    ...provider,
    models: provider.models.map((model) => ({
      ...model,
      capabilities: model.capabilities && {
        optionDescriptors: model.capabilities.optionDescriptors?.map((descriptor) =>
          descriptor.type === "select" ? { ...descriptor, currentValue: "default" } : descriptor,
        ),
      },
    })),
  })) as unknown as ReadonlyArray<ServerProvider>;
  await restartClient(ctx, { providers });
  expect(composer(ctx).effort).toBe("default");
});

step(/^the model's default effort is (low|medium|high)$/, (_ctx: World, effort: string) => {
  // The thread's model, GPT-5, defaults to medium.
  const descriptor = PROVIDERS[0]!.models[0]!.capabilities?.optionDescriptors?.[0];
  expect(descriptor?.type === "select" && descriptor.options.find((o) => o.isDefault)?.id).toBe(
    effort,
  );
});

step("an approval is waiting for the user", async (ctx: EffortWorld) => {
  await restartClient(ctx, {
    detail: thread([approvalRequest("approval-1", "rm -rf build", 1)]),
  });
});

step("the agent's question is waiting for an answer", async (ctx: EffortWorld) => {
  await restartClient(ctx, {
    detail: thread([
      questionRequest("question-1", [{ id: "q", question: "Which cache?", options: ["A"] }], 1),
    ]),
  });
});

step("the user is editing a queued message", () => {
  throw new Error(
    "The terminal client cannot edit a queued message, so it cannot be editing one when the user steps the effort.",
  );
});

step("no provider is available", async (ctx: EffortWorld) => {
  // The models are listed, but the provider's last check failed.
  await restartClient(ctx, {
    getServerConfig: async () =>
      ({
        settings: DEFAULT_SERVER_SETTINGS,
        providers: PROVIDERS.map((provider) =>
          provider.instanceId === "codex" ? { ...provider, status: "error" } : provider,
        ),
      }) as never,
  });
  expect(composer(ctx).effort).toBe("medium");
});

step("the user is holding the step key down after one step", async (ctx: EffortWorld) => {
  await restartClient(ctx);
  ctx.holdStep = true;
});

step(
  /^the user steps the effort (up|down)$/,
  async (ctx: EffortWorld, direction: "up" | "down") => {
    bindStepKeys(ctx);
    const key = STEP_KEYS[direction].split("+")[1]!;
    if (ctx.holdStep) {
      // The press steps once from medium; the repeats that follow must not.
      expect(composer(ctx).effort).toBe("medium");
      ctx.effortBefore = direction === "up" ? "high" : "low";
      // Two repeats: were they steps, three steps round three levels would hide them.
      await holdKey(ctx, key, 2, { meta: true });
      await settle(ctx);
      return;
    }
    ctx.effortBefore = composer(ctx).effort;
    ctx.chosenBefore = chosenEffort(ctx);
    await pressKey(ctx, `Alt+${key}`);
    await settle(ctx);
  },
);

step(/^the effort is (low|medium|high)$/, (ctx: EffortWorld, effort: string) => {
  expect(composer(ctx).effort).toBe(effort);
  expect(ctx.fake!.calls.some((call) => call.method === "sendReply")).toBe(false);
});

step("the draft and where the user was typing are unchanged", async (ctx: EffortWorld) => {
  await settle(ctx);
  expect(prompt(ctx)).toEqual(ctx.promptBefore!);
  expect(composer(ctx).text).toBe(ctx.promptBefore!.text);
});

step("the effort picker stays closed", (ctx: World) => {
  expect((ctx.host!.state.get("select") as { open: boolean }).open).toBe(false);
});

step("the effort still reads {string}", async (ctx: EffortWorld, label: string) => {
  await settle(ctx);
  // The words lock it: the level under the read-out did not move either.
  expect(chosenEffort(ctx)).toBe(ctx.chosenBefore!);
  expect(composer(ctx).effort?.toLowerCase()).toBe(label.toLowerCase());
  expect(shownText(findObject(ctx, "composerEffort").get("text"))).toMatch(new RegExp(label, "i"));
});

step("the effort is unchanged", (ctx: EffortWorld) => {
  expect(composer(ctx).effort).toBe(ctx.effortBefore!);
});
