// tui/composer-controls.feature: the provider's state in the composer, a
// model change a started thread cannot make, and the model's options.
import { expect } from "bun:test";

import type { ServerProvider } from "@hal-c2/contracts";

import type { TuiComposerState, TuiSelectState } from "../../../src/host/composerState.ts";
import { flattenModelOptions } from "../../../src/models.ts";
import { THEME } from "../../../src/theme.ts";
import { step } from "../../steps.ts";
import { expectColour, objectRows, rectOf, textWithin } from "../design.ts";
import { PROVIDERS } from "../fakeClient.ts";
import { chooseCommand, clickText } from "../threadUi.ts";
import { message, updateThread, type ThreadWorld } from "../threadWorld.ts";
import { findObject, geometry, pressKey, resize, settle, typeText, type World } from "../world.ts";
import { chooseInPicker } from "./controls.steps.ts";

const composer = (ctx: World) => ctx.host!.state.get("composer") as TuiComposerState;
const select = (ctx: World) => ctx.host!.state.get("select") as TuiSelectState;
const status = (ctx: World) => ctx.host!.state.get("status") as { text: string; kind: string };
const sent = (ctx: World) => ctx.fake!.calls.filter((call) => call.method === "sendReply");

/** The fixture's providers as the server reports them, each changed by `change`. */
function providers(change: (provider: ServerProvider) => Partial<ServerProvider> = () => ({})) {
  return PROVIDERS.map(
    (provider) =>
      ({
        ...provider,
        installed: true,
        version: "1.0.0",
        status: "ready",
        auth: { status: "authenticated" },
        checkedAt: "2026-07-13T00:00:00.000Z",
        ...change(provider),
      }) as ServerProvider,
  );
}

/** The server's provider state changed; the client learns of it on a refresh. */
async function serverReports(ctx: World, next: ServerProvider[]) {
  ctx.fake!.server.providers = next;
  ctx.fake!.override(
    "getServerConfig",
    async () =>
      ({
        settings: ctx.fake!.server.settings,
        providers: ctx.fake!.server.providers,
      }) as never,
  );
  ctx.fake!.override("listModels", async () => flattenModelOptions(ctx.fake!.server.providers));
  await chooseCommand(ctx, "Refresh providers");
  await settle(ctx);
}

// --- A signed-out provider ---------------------------------------------------------

step("the thread's provider is signed out", async (ctx: World) => {
  expect(composer(ctx).notice).toBeNull();
  await serverReports(
    ctx,
    providers((provider) =>
      provider.instanceId === "codex"
        ? {
            status: "error",
            auth: { status: "unauthenticated" },
            message: "run `codex login` in a terminal" as never,
          }
        : {},
    ),
  );
});

step("the composer says the provider needs sign-in and how to fix it", async (ctx: World) => {
  const notice =
    "Codex needs sign-in: run `codex login` in a terminal, then ^K → Refresh providers.";
  expect(composer(ctx).notice).toBe(notice);
  const frame = rectOf(ctx, "composer");
  // Wrapped to the composer, nothing cut off.
  const rows = (await objectRows(ctx, "composerNotice")).map((row) => row.trim());
  expect(rows.length).toBeGreaterThan(1);
  expect(rows.join(" ")).toBe(`⚠ ${notice}`);
  expectColour((await textWithin(ctx, frame, "Codex needs sign-in")).span.fg, THEME.warning);
  // The notice has its own row: the editor and the footer still fit under it.
  expect(geometry(findObject(ctx, "composerInput")).visible).toBe(true);
  expect(geometry(findObject(ctx, "composerPrimaryAction")).visible).toBe(true);
  // Signing in and refreshing clears it.
  await serverReports(ctx, providers());
  expect(composer(ctx).notice).toBeNull();
});

// --- A model the thread cannot change to -----------------------------------------------

step(
  "the user picks a model from a provider the thread cannot switch to",
  async (ctx: ThreadWorld) => {
    // A conversation is under way, and Claude keeps the model it started with.
    await updateThread(ctx, () => ({
      messages: [message("m-1", "user", "Add caching", 1), message("m-2", "assistant", "Done.", 2)],
    }));
    await serverReports(
      ctx,
      providers((provider) =>
        provider.instanceId === "claude" ? { requiresNewThreadForModelChange: true } : {},
      ),
    );
    await pressKey(ctx, "Ctrl+Shift+M");
    await chooseInPicker(ctx, "Opus");
  },
);

step("the client explains that a new thread is needed", async (ctx: World) => {
  expect(status(ctx)).toEqual({
    kind: "error",
    text: "Start a new thread (^N) to use Opus: Claude cannot change models once a conversation has started.",
  });
  // The thread keeps its model: the next reply goes to it.
  expect(composer(ctx).selectedModel).toBe("gpt-5");
  await typeText(ctx, "Carry on");
  await pressKey(ctx, "Enter");
  await settle(ctx);
  expect(sent(ctx)).toHaveLength(1);
  expect((sent(ctx)[0]!.args[3] as { model: string } | undefined)?.model ?? "gpt-5").toBe("gpt-5");
  // A new thread can use it.
  await pressKey(ctx, "Ctrl+N");
  await pressKey(ctx, "Ctrl+Shift+M");
  await chooseInPicker(ctx, "Opus");
  expect(composer(ctx).selectedModel).toBe("opus");
});

// --- Traits -----------------------------------------------------------------------------

const traitLabels = (ctx: World) => select(ctx).options.map((option) => option.label);

step("the model has a select trait and a boolean trait", (ctx: World) => {
  expect(composer(ctx).options.map(({ id, type, value }) => ({ id, type, value }))).toEqual([
    { id: "reasoningEffort", type: "select", value: "medium" },
    { id: "fastMode", type: "boolean", value: null },
  ]);
});

step("the user changes both", async (ctx: World) => {
  await chooseCommand(ctx, "Change model options");
  expect(traitLabels(ctx)).toEqual(["Reasoning: Medium", "Fast mode: off"]);
  await chooseInPicker(ctx, "Reasoning: Medium");
  expect(select(ctx).title).toBe("reasoning");
  await chooseInPicker(ctx, "High");
  await chooseCommand(ctx, "Change model options");
  await chooseInPicker(ctx, "Fast mode: off");
  expect(status(ctx)).toEqual({ kind: "success", text: "Fast mode → on (next turn)" });
  await chooseCommand(ctx, "Change model options");
  expect(traitLabels(ctx)).toEqual(["Reasoning: High", "Fast mode: on"]);
  await pressKey(ctx, "Esc");
});

step("the next reply is sent with those trait values", async (ctx: World) => {
  await typeText(ctx, "Carry on");
  await pressKey(ctx, "Enter");
  await settle(ctx);
  expect(sent(ctx)).toHaveLength(1);
  expect((sent(ctx)[0]!.args[3] as { options: unknown }).options).toEqual(
    expect.arrayContaining([
      { id: "reasoningEffort", value: "high" },
      { id: "fastMode", value: true },
    ]),
  );
});

step("the terminal is narrow", async (ctx: World) => {
  await resize(ctx, 60);
  await settle(ctx);
  expect(composer(ctx).compact).toBe(true);
});

step("provider traits are reachable from one compact menu", async (ctx: World) => {
  // The footer has no room for the effort control; "^K options" stands for the rest.
  expect(geometry(findObject(ctx, "composerEffort")).visible).toBe(false);
  expect(geometry(findObject(ctx, "composerOptions")).visible).toBe(true);
  // A click on it, or the effort chord, opens every trait in one list.
  await clickText(ctx, "^K options");
  await settle(ctx);
  expect(select(ctx)).toMatchObject({ open: true, title: "options" });
  expect(traitLabels(ctx)).toEqual(["Reasoning: Medium", "Fast mode: off"]);
  expect((await objectRows(ctx, "selectOverlay")).join("\n")).toContain("Fast mode: off");
  await pressKey(ctx, "Esc");
  await pressKey(ctx, "Ctrl+Shift+E");
  await settle(ctx);
  expect(select(ctx)).toMatchObject({ open: true, title: "options" });
  // And each trait changes from it.
  await chooseInPicker(ctx, "Fast mode: off");
  expect(composer(ctx).options.find((option) => option.id === "fastMode")?.value).toBe(true);
});
