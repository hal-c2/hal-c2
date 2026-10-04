// Steps for settings/load-balancing.feature (@tui): the user turns balancing
// on and sets preferences from the palette, which writes the fake MC's
// settings document, then starts a thread from a draft. The fake MC
// (environment.ts) chooses under the rules of HalC2.LoadBalancing; these steps
// check what the client asked it and where the thread was then created. The
// cluster and its projects come from moving.steps.ts.
import { expect } from "bun:test";

import type { TuiSettingsState } from "../../../src/host/settingsState.ts";
import { projectKey } from "../../../src/host/sidebarState.ts";
import { step } from "../../steps.ts";
import { addProject, change, env, flush, IDLE, ui, type EnvProject } from "../environment.ts";
import { palette, statusText, threadRows } from "../threadUi.ts";
import { pressKey, settle, typeText, type World } from "../world.ts";
import { chooseInPicker, newThread, runPaletteCommand } from "./controls.steps.ts";

interface BalancingWorld extends World {
  /** The checkout the user started the new thread in. */
  picked?: EnvProject;
  /** The user chose the draft's branch, so the MC is not asked where it starts. */
  tied?: boolean;
}

const MESSAGE = "Fix the login redirect";

const callsTo = (ctx: World, method: string) =>
  ctx.fake!.calls.filter((call) => call.method === method);
const machineNamed = (ctx: World, label: string) => {
  const machine = env(ctx).machines.find((candidate) => candidate.label === label);
  if (!machine) throw new Error(`no machine "${label}" in the cluster`);
  return machine;
};
const weights = (ctx: World) =>
  (env(ctx).settings.loadBalancingWeights ?? {}) as Record<string, number>;

/** The "Load balancing" group of the settings overview, by row label; null when not offered. */
async function settingsShown(ctx: World): Promise<Record<string, string> | null> {
  await runPaletteCommand(ctx, "Settings");
  const screen = await settle(ctx);
  const group = (ctx.host!.state.get("settings") as TuiSettingsState).groups.find(
    (candidate) => candidate.title === "Load balancing",
  );
  expect(screen.includes("Load balancing")).toBe(group !== undefined);
  ctx.host!.dispatch("settings.close");
  await settle(ctx);
  return group ? Object.fromEntries(group.rows.map((row) => [row.label, row.value])) : null;
}

async function setPreference(ctx: World, machine: string, preference: string): Promise<void> {
  await runPaletteCommand(ctx, `Load balancing preference for ${machine}…`);
  await chooseInPicker(ctx, preference);
  expect(statusText(ctx)).toBe(`${machine} → ${preference}`);
}

/** Open a draft in a machine's checkout: scope the list to it, then Ctrl+N. */
async function openDraft(ctx: BalancingWorld, project: string, machine: string): Promise<void> {
  await ui(ctx);
  ctx.picked = addProject(ctx, project, machine);
  await runPaletteCommand(ctx, `Show project ${project} · ${machine}`);
  await pressKey(ctx, "Ctrl+N");
  await flush(ctx);
  expect(newThread(ctx)?.projectKey).toBe(projectKey(ctx.picked.id));
}

async function send(ctx: World): Promise<void> {
  await typeText(ctx, MESSAGE);
  await pressKey(ctx, "Enter");
  await settle(ctx);
}

async function expectStartedOn(ctx: BalancingWorld, machine: string, project?: string) {
  await settle(ctx);
  const picked = ctx.picked!;
  const target = env(ctx).projects.find(
    (candidate) => candidate.title === (project ?? picked.title) && candidate.machine === machine,
  )!;
  expect(callsTo(ctx, "createThread").map((call) => call.args[0])).toMatchObject([
    { projectId: target.id, projectCwd: target.workspaceRoot, firstMessage: MESSAGE },
  ]);
  // The MC was asked about the user's own pick and the agent the thread runs on,
  // unless the draft was tied to its machine.
  expect(callsTo(ctx, "placeThread").map((call) => call.args[0])).toEqual(
    ctx.tied
      ? []
      : [
          {
            environmentId: machineNamed(ctx, picked.machine!).id,
            projectId: picked.id,
            instanceId: picked.defaultModelSelection.instanceId,
          },
        ],
  );
  expect(
    threadRows(ctx)
      .filter((row) => row.thread.title === MESSAGE)
      .map((row) => row.thread.machine),
  ).toEqual([machine]);
  expect(newThread(ctx)).toBeNull();
  expect(statusText(ctx)).toBe(
    machine === picked.machine ? "Thread created." : `Thread created on ${machine}.`,
  );
}

// --- Settings --------------------------------------------------------------------

step("load balancing is on", async (ctx: World) => {
  const environment = env(ctx);
  if (environment.machines.length === 0) {
    // A scenario that names no cluster: one where a thread started on "laptop"
    // would go to "server".
    environment.machines = ["laptop", "server"].map((label) => ({
      id: `env-${label}`,
      label,
      online: true,
    }));
    for (const machine of environment.machines) addProject(ctx, "api", machine.label);
    environment.loads.laptop = { cpu: 0.9, free: 0.2 };
  }
  await ui(ctx);
  expect(await settingsShown(ctx)).toMatchObject({ "balance load": "Off" });
  await runPaletteCommand(ctx, "Turn on load balancing");
  expect(environment.settings.loadBalancingEnabled).toBe(true);
  expect(await settingsShown(ctx)).toMatchObject({
    "balance load": "On",
    ...Object.fromEntries(environment.machines.map((machine) => [machine.label, "Normal"])),
  });
});

step("{string} is set to manual only", async (ctx: World, machine: string) => {
  await setPreference(ctx, machine, "Manual only");
  expect(weights(ctx)).toEqual({ [machineNamed(ctx, machine).id]: 0 });
});

step(
  "the user prefers {string} and sets {string} to less often",
  async (ctx: World, preferred: string, lessOften: string) => {
    await setPreference(ctx, preferred, "Prefer");
    await setPreference(ctx, lessOften, "Less often");
    expect(weights(ctx)).toEqual({
      [machineNamed(ctx, preferred).id]: 100,
      [machineNamed(ctx, lessOften).id]: 25,
    });
    expect(await settingsShown(ctx)).toMatchObject({
      "balance load": "On",
      [preferred]: "Prefer",
      [lessOften]: "Less often",
    });
  },
);

step("only one machine is connected", (ctx: World) => {
  expect(env(ctx).machines).toEqual([]);
  addProject(ctx, "api");
});

step("the user opens connection settings", async (ctx: World) => {
  await ui(ctx);
  await runPaletteCommand(ctx, "Settings");
  expect(ctx.host!.state.get("mode")).toBe("settings");
});

step("load balancing is not offered", async (ctx: World) => {
  const screen = await settle(ctx);
  const { groups } = ctx.host!.state.get("settings") as TuiSettingsState;
  expect(groups.map((group) => group.title)).toContain("Cluster");
  expect(groups.map((group) => group.title)).not.toContain("Load balancing");
  expect(screen).not.toContain("Load balancing");
  // Nor among the palette's commands, which is where it is turned on.
  await pressKey(ctx, "Esc");
  await pressKey(ctx, "Ctrl+K");
  await typeText(ctx, "load balancing");
  await settle(ctx);
  expect(palette(ctx).open).toBe(true);
  expect(palette(ctx).commands.filter((command) => /load balancing/i.test(command.title))).toEqual(
    [],
  );
});

step("a second machine joins the cluster", (ctx: World) => {
  change(ctx, (environment) => {
    environment.machines = ["laptop", "server"].map((label) => ({
      id: `env-${label}`,
      label,
      online: true,
    }));
  });
});

step("load balancing is offered and off without opening settings again", async (ctx: World) => {
  await settle(ctx);
  expect(ctx.host!.state.get("mode")).toBe("settings");
  const group = (ctx.host!.state.get("settings") as TuiSettingsState).groups.find(
    (candidate) => candidate.title === "Load balancing",
  );
  expect(
    Object.fromEntries((group?.rows ?? []).map((row) => [row.label, row.value])),
  ).toMatchObject({ "balance load": "Off", laptop: "Normal", server: "Normal" });
});

// --- How the machines are doing (what the fake MC weighs) ---------------------------

step("{string} is busy and {string} is idle", (ctx: World, busy: string, idle: string) => {
  env(ctx).loads[busy] = { cpu: 0.9, free: 0.2 };
  env(ctx).loads[idle] = { ...IDLE };
});

step("both machines are equally idle", (ctx: World) => {
  for (const machine of env(ctx).machines) env(ctx).loads[machine.label] = { ...IDLE };
});

step("{string} is somewhat busier than {string}", (ctx: World, busier: string, other: string) => {
  env(ctx).loads[busier] = { cpu: 0.5, free: 0.9 };
  env(ctx).loads[other] = { cpu: 0.2, free: 0.9 };
});

step("{string} does not answer in time", (ctx: World, machine: string) => {
  env(ctx).loads[machine] = { ...IDLE, silent: true };
});

step("{string} is offline", (ctx: World, machine: string) => {
  change(ctx, () => {
    machineNamed(ctx, machine).online = false;
  });
});

step("{string} is at 95% CPU", (ctx: World, machine: string) => {
  env(ctx).loads[machine] = { cpu: 0.95, free: 0.9 };
});

step("{string} has 5% of memory free", (ctx: World, machine: string) => {
  env(ctx).loads[machine] = { cpu: 0.1, free: 0.05 };
});

step("{string} does not have the chosen provider signed in", (ctx: World, machine: string) => {
  env(ctx).loads[machine] = { ...IDLE, signedOut: true };
});

step("{string} instead has no checkout of the repository", (ctx: World, machine: string) => {
  change(ctx, (environment) => {
    const kept = environment.projects.filter((project) => project.machine !== machine);
    environment.projects.splice(0, environment.projects.length, ...kept);
  });
});

// --- Starting the thread -----------------------------------------------------------

step(
  "the user starts a new thread in {string} on {string}",
  async (ctx: BalancingWorld, project: string, machine: string) => {
    await openDraft(ctx, project, machine);
    await send(ctx);
  },
);

step(
  "the user chose a branch for the new thread on {string}",
  async (ctx: BalancingWorld, machine: string) => {
    env(ctx).refs.push({
      name: "develop",
      current: false,
      isDefault: false,
      worktreePath: null,
    } as never);
    await openDraft(ctx, "api", machine);
    await runPaletteCommand(ctx, "Change branch");
    await chooseInPicker(ctx, "develop");
    expect(newThread(ctx)?.branch).toBe("develop");
    ctx.tied = true;
  },
);

step("the user sends the first message", send);

step("the thread starts on {string}", (ctx: BalancingWorld, machine: string) =>
  expectStartedOn(ctx, machine),
);

step(
  "the thread starts on {string} in its checkout of {string}",
  (ctx: BalancingWorld, machine: string, project: string) => expectStartedOn(ctx, machine, project),
);
