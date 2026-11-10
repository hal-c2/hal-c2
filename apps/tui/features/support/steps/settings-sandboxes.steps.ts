// Steps for the Settings scenarios of mc/platform/openshell.feature (@shared):
// the Review sandboxes page over an MC whose `server.getOpenShellStatus` these
// steps fake from what the scenario says about its machine.
import { expect } from "bun:test";

import { step } from "../../steps.ts";
import { runPaletteCommand } from "./controls.steps.ts";
import { chooseRow, connected, mc, pageText, paneWords, sectionState } from "../settingsWorld.ts";
import type { World } from "../world.ts";

const PINNED = "0.1.7";
const INTEL_MAC =
  "OpenShell supports Apple Silicon Macs only. This MC runs as x86_64: an Intel Mac, or an MC running under Rosetta.";
const NOT_INSTALLED = "Run `hal-c2-service openshell install` to install it.";
const FAILURE =
  "OpenShell's status did not answer within 20 seconds. Try again, or run `hal-c2-service openshell status` on the MC's machine.";

interface Machine {
  intelMac: boolean;
  gateway: boolean;
  pointed: boolean;
  failing: boolean;
}

const machines = new WeakMap<World, Machine>();

/** The scenario's machine, whose status the fake MC answers with. */
function machine(ctx: World): Machine {
  let found = machines.get(ctx);
  if (found) return found;
  found = { intelMac: false, gateway: false, pointed: false, failing: false };
  const state = found;
  machines.set(ctx, state);
  mc(ctx).on("server.getOpenShellStatus", () => {
    if (state.failing) throw new Error(FAILURE);
    const ready = !state.intelMac && state.gateway && state.pointed;
    return {
      supported: !state.intelMac,
      ready,
      mode: ready ? "external" : null,
      version: ready ? PINNED : null,
      pinnedVersion: PINNED,
      problems: state.intelMac
        ? [{ code: "intel-mac", message: INTEL_MAC }]
        : ready
          ? []
          : [{ code: "not-installed", message: NOT_INSTALLED }],
    };
  });
  return state;
}

const words = (text: string) => text.replace(/\s+/g, " ");

async function reads(ctx: World, lines: ReadonlyArray<string>): Promise<void> {
  const drawn = await paneWords(ctx);
  for (const line of lines) {
    expect(words(pageText(ctx))).toContain(line);
    expect(drawn).toContain(line);
  }
}

step("a Linux machine with rootless Podman", (ctx: World) => {
  machine(ctx);
});
step("a machine that is an Intel Mac", (ctx: World) => {
  machine(ctx).intelMac = true;
});
step("a gateway the user runs, with its CA and a client certificate", (ctx: World) => {
  machine(ctx).gateway = true;
});
step("the user points the MC at it", (ctx: World) => {
  machine(ctx).pointed = true;
});
step("the MC cannot say whether review sandboxes can run", (ctx: World) => {
  machine(ctx).failing = true;
});

step("the user opens the sandbox settings", async (ctx: World) => {
  machine(ctx);
  await connected(ctx);
  await runPaletteCommand(ctx, "Review sandboxes");
  expect(sectionState(ctx).id).toBe("sandboxes");
});

step("the MC can say again and the user refreshes the sandbox settings", async (ctx: World) => {
  machine(ctx).failing = false;
  await chooseRow(ctx, "Refresh");
});

step("they read that OpenShell does not run on an Intel Mac", async (ctx: World) => {
  await reads(ctx, ["Review sandboxes can't run on this machine.", INTEL_MAC]);
});

step("they read that OpenShell is not installed, and how to install it", async (ctx: World) => {
  await reads(ctx, [
    "Review sandboxes can't run here yet.",
    `OpenShell ${PINNED} is the version this MC pins.`,
    NOT_INSTALLED,
  ]);
});

step("they read that review sandboxes can run here", async (ctx: World) => {
  await reads(ctx, ["Review sandboxes can run here.", `OpenShell ${PINNED}, a gateway you run.`]);
  expect(pageText(ctx)).not.toContain(NOT_INSTALLED);
});

step("they read that the sandbox status could not be read", async (ctx: World) => {
  await reads(ctx, ["Could not read whether review sandboxes can run here.", FAILURE]);
  // The user can ask again.
  expect(pageText(ctx)).toContain("Refresh");
});
