// Steps for the Settings scenarios of mc/platform/openshell.feature (@shared):
// the Review sandboxes page over an MC whose `server.getOpenShellStatus`,
// `server.runOpenShellOperation` and openShell shape these steps fake from what
// the scenario says about its machine.
import type { OpenShellOperationState, ServerOpenShellOperation } from "@hal-c2/contracts";
import { expect } from "bun:test";

import { step } from "../../steps.ts";
import { pressKey, settle } from "../world.ts";
import { runPaletteCommand } from "./controls.steps.ts";
import { chooseRow, connected, mc, pageText, paneWords, sectionState } from "../settingsWorld.ts";
import type { World } from "../world.ts";

const PINNED = "0.1.7";
const INTEL_MAC =
  "OpenShell supports Apple Silicon Macs only. This MC runs as x86_64: an Intel Mac, or an MC running under Rosetta.";
const NOT_INSTALLED = "Press Install to install it.";
const FAILURE = "OpenShell's status did not answer within 20 seconds. Refresh to try again.";
const INSTALL_STEPS = [
  "Checking this machine",
  "Checking the gateway's configuration",
  "Starting the gateway",
];
const INSTALLED = `OpenShell installed, ${PINNED}, listening on https://127.0.0.1:17670.`;
const REMOVED = "OpenShell removed.";
const MANAGE_REASON =
  "Installing and managing OpenShell needs a session that can manage this machine and use its terminal (access:write, terminal:operate). Pair this device with a link that grants them.";

interface Machine {
  intelMac: boolean;
  gateway: boolean;
  pointed: boolean;
  failing: boolean;
  /** A gateway this MC installed and runs. */
  managed: boolean;
  /** This MC's review sandboxes on the gateway. */
  reviews: number;
  /** The device was paired without access:write and terminal:operate. */
  cannotManage: boolean;
}

const machines = new WeakMap<World, Machine>();

const action = (operation: ServerOpenShellOperation, label: string) => ({ operation, label });

/** The scenario's machine, whose status and operations the fake MC answers with. */
function machine(ctx: World): Machine {
  let found = machines.get(ctx);
  if (found) return found;
  found = {
    intelMac: false,
    gateway: false,
    pointed: false,
    failing: false,
    managed: false,
    reviews: 0,
    cannotManage: false,
  };
  const state = found;
  machines.set(ctx, state);
  mc(ctx).on("server.getOpenShellStatus", () => {
    if (state.failing) throw new Error(FAILURE);
    const external = !state.intelMac && state.gateway && state.pointed;
    const ready = state.managed || external;
    return {
      supported: !state.intelMac,
      ready,
      mode: state.managed ? "managed" : external ? "external" : null,
      version: ready ? PINNED : null,
      pinnedVersion: PINNED,
      problems: state.intelMac
        ? [{ code: "intel-mac", message: INTEL_MAC }]
        : ready
          ? []
          : [{ code: "not-installed", message: NOT_INSTALLED }],
      actions: state.intelMac
        ? []
        : state.managed
          ? [
              action("check", "Check"),
              action("rotate", "Rotate certificates"),
              action("uninstall", "Uninstall"),
            ]
          : external
            ? [action("check", "Check"), action("uninstall", "Stop using it")]
            : [action("install", "Install")],
      canManage: !state.cannotManage,
      manageReason: state.cannotManage ? MANAGE_REASON : null,
    };
  });
  // Like the MC, the reply is the operation running; its steps and outcome go to
  // whoever follows the openShell shape.
  mc(ctx).on(
    "server.runOpenShellOperation",
    (payload: { operation: ServerOpenShellOperation; drain?: boolean }) => {
      if (state.cannotManage) throw new Error("This session may not access:write.");
      const fake = mc(ctx);
      const emit = (next: OpenShellOperationState) => {
        fake.openShellOperation = next;
        fake.emitOpenShellOperation();
      };
      const running: OpenShellOperationState = {
        operation: payload.operation,
        running: true,
        steps: [],
        result: null,
      };
      queueMicrotask(() => {
        emit(running);
        const finish = (steps: ReadonlyArray<string>, result: OpenShellOperationState["result"]) =>
          emit({ ...running, running: false, steps: [...steps], result });
        if (payload.operation === "install") {
          for (let at = 1; at <= INSTALL_STEPS.length; at += 1) {
            emit({ ...running, steps: INSTALL_STEPS.slice(0, at) });
          }
          state.managed = true;
          finish(INSTALL_STEPS, { ok: true, code: null, message: INSTALLED, sandboxes: null });
        } else if (payload.operation === "uninstall" && state.reviews > 0 && !payload.drain) {
          finish([], {
            ok: false,
            code: "sandboxes-running",
            message: `${state.reviews} of this MC's review sandboxes are on the gateway. Going ahead deletes them, which stops their reviews; or let them finish first.`,
            sandboxes: state.reviews,
          });
        } else if (payload.operation === "uninstall") {
          state.reviews = 0;
          state.managed = false;
          finish(["Removing the gateway"], {
            ok: true,
            code: null,
            message: REMOVED,
            sandboxes: null,
          });
        } else {
          finish([], {
            ok: true,
            code: null,
            message: "OpenShell passed its checks.",
            sandboxes: null,
          });
        }
      });
      return running;
    },
  );
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

step(
  "an OpenShell gateway this MC runs, with a sandbox of this MC's and one of someone else's",
  (ctx: World) => {
    const state = machine(ctx);
    state.managed = true;
    // Someone else's sandbox is the MC's to leave alone; only this MC's are counted.
    state.reviews = 1;
  },
);
step("the user's device was paired without the right to manage the MC's machine", (ctx: World) => {
  machine(ctx).cannotManage = true;
});

step("they press {string} in the sandbox settings", async (ctx: World, label: string) => {
  await chooseRow(ctx, label);
});

step("the sandbox settings show the install's steps", async (ctx: World) => {
  await reads(ctx, INSTALL_STEPS);
});

step("they read that OpenShell was installed", async (ctx: World) => {
  await reads(ctx, [
    INSTALLED,
    "Review sandboxes can run here.",
    `OpenShell ${PINNED}, run by this MC.`,
  ]);
});

step("the sandbox settings offer to uninstall it", async (ctx: World) => {
  await reads(ctx, ["Uninstall", "Check", "Rotate certificates"]);
  // Install is offered again only once it is uninstalled.
  expect(pageText(ctx)).not.toMatch(/(^|\s)Install(\s|$)/m);
});

step("the sandbox settings offer to install it", async (ctx: World) => {
  await reads(ctx, ["Install", NOT_INSTALLED]);
  expect(pageText(ctx)).not.toContain("Uninstall");
});

step(/^they are asked whether to stop (\d+) reviews?$/, async (ctx: World, spelled: string) => {
  const count = Number(spelled);
  const question = sectionState(ctx).confirm?.lines.join(" ") ?? "";
  expect(words(question)).toContain(`Stop ${count} review${count === 1 ? "" : "s"} and go ahead?`);
  // Nothing was stopped yet: the first uninstall asked without draining.
  const runs = mc(ctx).callsTo("server.runOpenShellOperation");
  expect(runs.map((call) => call.payload)).toEqual([{ operation: "uninstall" }]);
});

step("they agree to stop it", async (ctx: World) => {
  await pressKey(ctx, "y");
  await settle(ctx);
});

step("they read that OpenShell was removed, its review stopped first", async (ctx: World) => {
  await reads(ctx, [REMOVED]);
  const runs = mc(ctx).callsTo("server.runOpenShellOperation");
  expect(runs.at(-1)?.payload).toEqual({ operation: "uninstall", drain: true });
});

step(
  "the sandbox settings' actions are off, and say which access the device lacks",
  async (ctx: World) => {
    await reads(ctx, [MANAGE_REASON]);
    await chooseRow(ctx, "Install");
    expect(mc(ctx).callsTo("server.runOpenShellOperation")).toEqual([]);
  },
);
