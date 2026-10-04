// composer/drafting-and-sending.feature and composer/model-and-mode.feature: sending
// without a connection, and what a new thread starts with (model, permissions).
import { expect } from "bun:test";
import { DEFAULT_SERVER_SETTINGS, type OrchestrationThread } from "@hal-c2/contracts";

import { step } from "../../steps.ts";
import { PROVIDERS, project, shell, thread } from "../fakeClient.ts";
import { findObject, pressKey, settle, snapshot, type World } from "../world.ts";
import { callsTo, composer, typeIntoPrompt } from "./composer.steps.ts";
import { chooseInPicker, newThread, restartClient, select } from "./controls.steps.ts";

const status = (ctx: World) => ctx.host!.state.get("status") as { text: string; kind: string };

// --- Sending while disconnected -------------------------------------------------------

// The connection was up and is lost.
step("the environment is disconnected", async (ctx: World) => {
  ctx.fake!.emitConnection("reconnecting");
  await settle(ctx);
  expect((ctx.host!.state.get("connection") as { state: string }).state).toBe("reconnecting");
});

step("the user tries to send it", async (ctx: World) => {
  await pressKey(ctx, "Enter");
  await settle(ctx);
});

step(
  "the user is told the message was not sent because they are not connected",
  async (ctx: World) => {
    expect(status(ctx)).toEqual({ kind: "error", text: "Not sent: not connected." });
    // The composer says it in full, above the draft it kept.
    expect(composer(ctx).notice).toBe("Not sent: not connected to the environment");
    const screen = await snapshot(ctx);
    expect(screen).toContain("⚠ Not sent: not connected to the environment");
    expect(screen).toContain("✗ Not sent: not connected.");
    expect(callsTo(ctx, "sendReply")).toEqual([]);
  },
);

step("the draft still reads {string}", async (ctx: World, text: string) => {
  expect(composer(ctx).text).toBe(text);
  const field = findObject(ctx, "composerInput");
  expect(field.get("plainText") ?? field.get("text")).toBe(text);
});

// --- What a new thread starts with -------------------------------------------------------

const NO_DEFAULT = { ...project, defaultModelSelection: null };
const codexThread = (model: string) =>
  ({ ...thread(), modelSelection: { instanceId: "codex", model } }) as OrchestrationThread;

async function openDraft(ctx: World) {
  await pressKey(ctx, "Ctrl+N");
  await settle(ctx);
  expect(newThread(ctx)).not.toBeNull();
}

// The thread was started on GPT-5 Codex elsewhere; here the user switched it to
// `slug` and sent a turn with it. The project names no model of its own.
step("the user last used {string} with Codex", async (ctx: World, slug: string) => {
  await restartClient(ctx, {
    detail: codexThread("gpt-5-codex"),
    providers: PROVIDERS,
    shellSnapshot: shell(undefined, [NO_DEFAULT] as never),
  });
  expect(composer(ctx).selectedModel).toBe("gpt-5-codex");
  await pressKey(ctx, "Ctrl+Shift+M");
  await settle(ctx);
  expect(select(ctx).kind).toBe("model");
  await chooseInPicker(ctx, "GPT-5");
  await typeIntoPrompt(ctx, "Next step");
  await pressKey(ctx, "Enter");
  await settle(ctx);
  expect(callsTo(ctx, "sendReply").at(-1)!.args[3]).toMatchObject({
    instanceId: "codex",
    model: slug,
  });
  // The MC still holds the model the thread was created with.
  expect(ctx.fake!.currentThread("t1")!.modelSelection.model).toBe("gpt-5-codex");
});

step("the user starts a new thread on Codex", openDraft);

step("{string} is chosen", async (ctx: World, slug: string) => {
  expect(newThread(ctx)!.projectKey).not.toBeNull();
  expect(composer(ctx).selectedModel).toBe(slug);
  expect(await snapshot(ctx)).toContain(`model ${slug} `);
});

step("a model set for the project takes precedence", async (ctx: World) => {
  await pressKey(ctx, "Esc");
  await settle(ctx);
  expect(newThread(ctx)).toBeNull();
  ctx.fake!.emitShell(
    shell(undefined, [
      { ...project, defaultModelSelection: { instanceId: "codex", model: "gpt-5-codex" } },
    ] as never),
  );
  await openDraft(ctx);
  expect(composer(ctx).selectedModel).toBe("gpt-5-codex");
});

type PermissionsWorld = World & { overrides?: Record<string, unknown> };

const serveSettings = (ctx: PermissionsWorld) => ({
  providers: PROVIDERS,
  getServerConfig: async () =>
    ({
      settings: {
        ...DEFAULT_SERVER_SETTINGS,
        defaultRuntimeMode: "approval-required",
        projectSettingsOverrides: ctx.overrides ?? {},
      },
    }) as never,
});

// The open thread itself runs with full access: the default is not copied from it.
step("the default permissions for new threads are Supervised", async (ctx: PermissionsWorld) => {
  await restartClient(ctx, serveSettings(ctx));
  expect(composer(ctx).runtimeModeLabel).toBe("Full access");
});

step("the thread runs in Supervised", async (ctx: World) => {
  expect(newThread(ctx)).not.toBeNull();
  expect(composer(ctx)).toMatchObject({
    runtimeMode: "approval-required",
    runtimeModeLabel: "Supervised",
  });
  expect(await snapshot(ctx)).toContain("Supervised");
  await typeIntoPrompt(ctx, "Start here");
  await pressKey(ctx, "Enter");
  await settle(ctx);
  expect(callsTo(ctx, "createThread").map((call) => call.args[0])).toMatchObject([
    { projectId: "p1", runtimeMode: "approval-required" },
  ]);
});

step(
  "a project that overrides the default uses its own permissions",
  async (ctx: PermissionsWorld) => {
    ctx.overrides = { p1: { defaultRuntimeMode: "auto-accept-edits" } };
    await restartClient(ctx, serveSettings(ctx));
    await openDraft(ctx);
    expect(composer(ctx).runtimeMode).toBe("auto-accept-edits");
  },
);
