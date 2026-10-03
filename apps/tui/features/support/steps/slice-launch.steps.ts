// tui/launch.feature: the relay client HAL-C2 Connect needs on the server,
// checked and installed from the terminal.
import { expect } from "bun:test";

import type { TuiSelectState } from "../../../src/host/composerState.ts";
import { step } from "../../steps.ts";
import { objectRows } from "../design.ts";
import { chooseCommand } from "../threadUi.ts";
import { pressKey, settle, type World } from "../world.ts";
import { openOnThread, type ComposerWorld } from "./composer.steps.ts";

const select = (ctx: World) => ctx.host!.state.get("select") as TuiSelectState;
const status = (ctx: World) => ctx.host!.state.get("status") as { text: string; kind: string };
const callsTo = (ctx: World, method: string) =>
  ctx.fake!.calls.filter((call) => call.method === method);

step("the relay client is not installed", async (ctx: ComposerWorld) => {
  await openOnThread(ctx);
  expect(ctx.fake!.server.relay).toEqual({ status: "missing", version: "2026.6.0" });
});

step("the user checks relay status from the terminal client", async (ctx: World) => {
  await chooseCommand(ctx, "Relay client");
  await settle(ctx);
});

step("the client says the relay is missing and offers to install it", async (ctx: World) => {
  expect(callsTo(ctx, "relayStatus")).toHaveLength(1);
  expect(status(ctx)).toEqual({ kind: "error", text: "The relay client is missing (2026.6.0)." });
  expect(select(ctx)).toMatchObject({ open: true, title: "relay client is missing" });
  expect(select(ctx).options).toEqual([
    {
      label: "Install the relay client 2026.6.0",
      description: "Downloads it on the server; remote access needs it.",
    },
    { label: "Not now", description: "Remote access stays unavailable." },
  ]);
  expect((await objectRows(ctx, "selectOverlay")).join("\n")).toContain(
    "Install the relay client 2026.6.0",
  );
  // Taking the offer installs it on the server, each stage named as it runs.
  const stages: string[] = [];
  const install = ctx.fake!.server;
  ctx.fake!.override("installRelay", async (onStage) => {
    for (const stage of ["downloading", "verifying", "installing", "activating"] as const) {
      onStage(stage);
      stages.push(status(ctx).text);
    }
    install.relay = {
      status: "available",
      executablePath: "/opt/hal-c2/relay/cloudflared",
      source: "managed",
      version: "2026.6.0",
    };
    return install.relay;
  });
  await pressKey(ctx, "Enter");
  await settle(ctx);
  expect(stages).toEqual([
    "Installing the relay client: downloading…",
    "Installing the relay client: verifying…",
    "Installing the relay client: installing…",
    "Installing the relay client: activating…",
  ]);
  expect(status(ctx)).toEqual({
    kind: "success",
    text: "The relay client 2026.6.0 is installed.",
  });
  // Checking again finds it; there is nothing left to offer.
  await chooseCommand(ctx, "Relay client");
  await settle(ctx);
  expect(select(ctx).open).toBe(false);
  expect(status(ctx).text).toBe("The relay client 2026.6.0 is installed.");
});
