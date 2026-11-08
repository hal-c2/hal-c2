// What the composer's footer names (composer/model-and-mode.feature): the
// permissions only when they differ from the default (upstream #25869), and
// the model as the user would say it (upstream #24205).
import { expect } from "bun:test";

import { DEFAULT_SERVER_SETTINGS, type RuntimeMode, type ServerProvider } from "@hal-c2/contracts";

import { step } from "../../steps.ts";
import { RUNTIME_MODE_META } from "../../../src/controls.ts";
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
import { chooseInPicker, restartClient, select, type ControlsWorld } from "./controls.steps.ts";

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

step("the composer does not name the permissions", async (ctx: World) => {
  expect(geometry(access(ctx)).visible).toBe(false);
  expect(await snapshot(ctx)).not.toContain(composer(ctx).runtimeModeLabel);
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
