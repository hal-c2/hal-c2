// What the composer's footer names (composer/model-and-mode.feature): a
// started thread's permissions always (HAL-C2 departs from upstream
// #25869's differ-from-the-default rule here), the model as the user would
// say it (upstream #24205), and its effort as a word or rising bars, as the
// user chose (upstream #25869).
import { expect } from "bun:test";

import { DEFAULT_SERVER_SETTINGS, type RuntimeMode, type ServerProvider } from "@hal-c2/contracts";

import { step } from "../../steps.ts";
import { RUNTIME_MODE_META } from "../../../src/controls.ts";
import { THEME } from "../../../src/theme.ts";
import { cellAt, expectColour, textAt } from "../design.ts";
import { thread } from "../fakeClient.ts";
import { shownText } from "../threadWorld.ts";
import {
  clickObject,
  findObject,
  geometry,
  pressKey,
  settle,
  snapshot,
  type World,
} from "../world.ts";
import { composer, updateThread } from "./composer.steps.ts";
import {
  chooseInPicker,
  restartClient,
  runPaletteCommand,
  select,
  type ControlsWorld,
} from "./controls.steps.ts";

const PERMISSIONS = "Supervised|Full access";

const runtimeModeLabelled = (label: string) =>
  (Object.keys(RUNTIME_MODE_META) as RuntimeMode[]).find(
    (mode) => RUNTIME_MODE_META[mode].label === label,
  )!;

const access = (ctx: World) => findObject(ctx, "composerAccess");

step(
  new RegExp(`^the default permissions are (${PERMISSIONS})$`),
  async (ctx: ControlsWorld, label: string) => {
    await restartClient(ctx, {
      getServerConfig: async () =>
        ({
          settings: { ...DEFAULT_SERVER_SETTINGS, defaultRuntimeMode: runtimeModeLabelled(label) },
        }) as never,
    });
  },
);

step(
  new RegExp(`^the open thread runs in (${PERMISSIONS})$`),
  async (ctx: World, label: string) => {
    await updateThread(ctx, (detail) => ({ ...detail, runtimeMode: runtimeModeLabelled(label) }));
    expect(composer(ctx).runtimeModeLabel).toBe(label);
  },
);

step("the user looks at the composer", async (ctx: World) => {
  await settle(ctx);
  await snapshot(ctx);
});

// The terminal's effort picker holds only the efforts; the permissions key
// (^O) is the TUI's way to the permissions, as the effort menu is the desktop's.
step(
  new RegExp(`^the user sets the thread's permissions to (${PERMISSIONS}) from the effort menu$`),
  async (ctx: World, label: string) => {
    await pressKey(ctx, "Ctrl+O");
    await settle(ctx);
    expect(select(ctx).kind).toBe("runtime");
    await chooseInPicker(ctx, label);
    expect(ctx.fake!.currentThread("t1")?.runtimeMode).toBe(runtimeModeLabelled(label));
  },
);

step("the composer names {string} beside the model", async (ctx: World, label: string) => {
  await settle(ctx);
  await snapshot(ctx);
  const model = geometry(findObject(ctx, "composerModel"));
  const named = geometry(access(ctx));
  expect(named.visible).toBe(true);
  expect(named.y).toBe(model.y);
  expect(named.x).toBeGreaterThan(model.x);
  expect(shownText(access(ctx).get("text"))).toContain(label);
});

step("the draft says it will run in {string}", async (ctx: World, label: string) => {
  await settle(ctx);
  await snapshot(ctx);
  expect(composer(ctx).runtimeModeLabel).toBe(label);
  expect(geometry(access(ctx)).visible).toBe(true);
  expect(shownText(access(ctx).get("text"))).toContain(label);
});

step("the user chooses the permissions it names", async (ctx: World) => {
  await clickObject(ctx, "composerAccess");
  await settle(ctx);
});

step("the user can pick other permissions for the thread", (ctx: World) => {
  const picker = select(ctx);
  expect(picker).toMatchObject({ open: true, kind: "runtime" });
  expect(picker.options.map((option) => option.label)).toEqual(
    expect.arrayContaining(["Supervised", "Full access"]),
  );
});

// --- The model's names (upstream #24205) --------------------------------------

type NamingWorld = ControlsWorld & { shortNames?: Record<string, string> };

/** One model per provider, named as its catalog names it. */
const namedProviders = (shortNames: Record<string, string> = {}) =>
  (
    [
      ["claude", "claudeAgent", "Claude", "claude-opus-5-5", "Claude Opus 5.5"],
      ["codex", "codex", "Codex", "gpt-5.5", "GPT-5.5"],
      ["opencode", "opencode", "OpenCode", "nvidia/nemotron-3-super", "NVIDIA: Nemotron 3 Super"],
    ] as const
  ).map(([instanceId, driver, displayName, slug, name]) => ({
    instanceId,
    driver,
    displayName,
    enabled: true,
    models: [
      {
        slug,
        name,
        ...(shortNames[name] ? { shortName: shortNames[name] } : {}),
        isCustom: false,
        capabilities: null,
      },
    ],
  })) as unknown as ReadonlyArray<ServerProvider>;

async function chooseNamedModel(ctx: NamingWorld, name: string): Promise<void> {
  await restartClient(ctx, { providers: namedProviders(ctx.shortNames) });
  await pressKey(ctx, "Ctrl+Shift+M");
  await settle(ctx);
  expect(select(ctx)).toMatchObject({ open: true, kind: "model", status: "ready" });
  await chooseInPicker(ctx, name);
}

step(
  "the model manifest names {string} {string} for short",
  (ctx: NamingWorld, name: string, short: string) => {
    ctx.shortNames = { ...ctx.shortNames, [name]: short };
  },
);

step(
  /^the user chooses the (?:Claude|Codex|OpenCode) model "([^"]+)"$/,
  (ctx: NamingWorld, name: string) => chooseNamedModel(ctx, name),
);

step(/^the user chooses "(Claude [^"]+)"$/, (ctx: NamingWorld, name: string) =>
  chooseNamedModel(ctx, name),
);

step("the model button reads {string}", async (ctx: World, short: string) => {
  await settle(ctx);
  expect(shownText(findObject(ctx, "composerModel").get("text"))).toBe(`model ${short} ▾`);
});

step(
  "the full name {string} is shown in its tooltip and in the model picker",
  async (ctx: World, full: string) => {
    await pressKey(ctx, "Ctrl+Shift+M");
    await settle(ctx);
    expect(select(ctx).options.map((option) => option.label)).toContain(full);
    await pressKey(ctx, "Esc");
    throw new Error(
      "The terminal client has no tooltips; the model picker, which the model control opens, lists the full name.",
    );
  },
);

// --- The effort as a word or bars (upstream #25869) ---------------------------

/** Opus 5.5's efforts, as Claude lists them: four levels, then Max, then Ultrathink. */
const OPUS_EFFORTS = [
  ["low", "Low"],
  ["medium", "Medium"],
  ["high", "High"],
  ["xhigh", "Extra High"],
  ["max", "Max"],
  ["ultrathink", "Ultrathink"],
] as const;

const opusProviders = [
  {
    instanceId: "claude",
    driver: "claudeAgent",
    displayName: "Claude",
    enabled: true,
    models: [
      {
        slug: "claude-opus-5-5",
        name: "Claude Opus 5.5",
        isCustom: false,
        capabilities: {
          optionDescriptors: [
            {
              id: "effort",
              label: "Effort",
              type: "select",
              options: OPUS_EFFORTS.map(([id, label]) => ({
                id,
                label,
                ...(id === "medium" ? { isDefault: true } : {}),
              })),
              promptInjectedValues: ["ultrathink"],
            },
          ],
        },
      },
    ],
  },
] as unknown as ReadonlyArray<ServerProvider>;

const BAR_COUNTS: Record<string, number> = { one: 1, two: 2, three: 3, four: 4 };

step(
  /^the thread runs on "Opus 5\.5" with (Low|Medium|High|Extra High|Max) effort$/,
  async (ctx: ControlsWorld, label: string) => {
    const id = OPUS_EFFORTS.find(([, name]) => name === label)![0];
    await restartClient(ctx, {
      providers: opusProviders,
      detail: {
        ...thread(),
        modelSelection: {
          instanceId: "claude",
          model: "claude-opus-5-5",
          options: [{ id: "effort", value: id }],
        },
      } as never,
    });
    expect(composer(ctx).effort).toBe(id);
  },
);

step("the effort display is set to {string}", async (ctx: World, display: string) => {
  await runPaletteCommand(ctx, "Change effort display…");
  expect(select(ctx).title).toBe("effort display");
  await chooseInPicker(ctx, display);
});

step(
  /^the model reads "([^"]+)" followed by (?:"([^"]+)"|(one|two|three|four) bars?)$/,
  async (ctx: World, model: string, word: string | undefined, bars: string | undefined) => {
    await settle(ctx);
    await snapshot(ctx);
    expect(shownText(findObject(ctx, "composerModel").get("text"))).toBe(`model ${model} ▾`);
    const modelBox = geometry(findObject(ctx, "composerModel"));
    const effortBox = geometry(findObject(ctx, "composerEffort"));
    expect(effortBox.y).toBe(modelBox.y);
    expect(effortBox.x).toBeGreaterThan(modelBox.x);
    const effort = shownText(findObject(ctx, "composerEffort").get("text"));
    if (word !== undefined) {
      expect(composer(ctx).effortBars).toBeNull();
      expect(effort).toBe(`effort ${word} ▾`);
      return;
    }
    // Opus 5.5 has four levels below Max; the lowest `filled` are lit.
    const filled = BAR_COUNTS[bars!]!;
    expect(composer(ctx).effortBars).toEqual({ count: 4, filled });
    const glyphs = "▂▄▆█";
    expect(effort).toBe(`effort ${glyphs} ▾`);
    const at = await textAt(ctx, glyphs);
    for (let bar = 0; bar < glyphs.length; bar += 1) {
      const cell = await cellAt(ctx, at.x + bar, at.y);
      expectColour(cell.span.fg, bar < filled ? THEME.text : THEME.dim);
    }
  },
);
