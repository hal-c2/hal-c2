// Moving a thread to another machine of the cluster
// (threads/moving-between-machines.feature), as far as one machine's client
// sees it: where a thread can go, asking the MC to move it, and what the MC
// says. The fake MC answers `hal-c2.moveDestinations` and `hal-c2.moveThread`
// as `HalC2.ThreadMove` does.
import { expect } from "bun:test";

import { step } from "../../steps.ts";
import { addProject, addThread, change, env, flush, threadNamed, ui } from "../environment.ts";
import { chooseCommand, chooseMenuItem, contextMenu, openMenu, selectThread } from "../threadUi.ts";
import { settle, snapshot, type World } from "../world.ts";

interface MoveWorld extends World {
  /** This machine's label, and the others in its cluster. */
  machines?: { local: string; others: Array<{ label: string; online: boolean }> };
  /** Whether the thread's provider can carry its session to another machine. */
  carriesSession?: boolean;
}

const mcCalls = (ctx: World, method: string) =>
  ctx.fake!.settings.callsTo(method).map((call) => call.payload as Record<string, any>);
const menuLabels = (ctx: World) =>
  (contextMenu(ctx)?.rows ?? []).flatMap((row) => (row.kind === "item" ? [row] : []));

/** This machine's MC knows its cluster and moves threads; installed on the client before it starts. */
function install(ctx: MoveWorld): void {
  const fake = ctx.fake!;
  const machines = ctx.machines!;
  fake.cluster.members = machines.others.map((machine) => ({
    id: `env-${machine.label}`,
    label: machine.label,
    addresses: [`${machine.label}:47730`],
    connected: machine.online,
  }));
  fake.settings.on("hal-c2.moveDestinations", () =>
    machines.others.map((machine) => ({
      machine: machine.label,
      environmentId: `env-${machine.label}`,
      online: machine.online,
      projects: machine.online
        ? [{ id: "p-shop", title: "shop", workspaceRoot: "/work/shop", sameRepository: true }]
        : [],
    })),
  );
  fake.settings.on("hal-c2.moveThread", (payload) => {
    const thread = threadNamedById(ctx, payload.threadId);
    if (thread.session?.status === "running") {
      throw new Error(
        `${thread.title} is running. Stop it or wait for it to finish before moving it.`,
      );
    }
    const carried = ctx.carriesSession ?? true;
    return {
      status: "moved",
      threadId: thread.id,
      machine: payload.machine,
      environmentId: `env-${payload.machine}`,
      projectId: "p-shop",
      sessionCarried: carried,
      message: `${thread.title} moved to ${payload.machine}. ${
        carried
          ? "The agent continues its own session there."
          : "The agent there will get a summary of the conversation."
      }`,
      notes: [],
    };
  });
  // Interrupting ends the turn; the thread's row says so.
  fake.override("interrupt", async (threadId) => {
    change(ctx, () => {
      threadNamedById(ctx, threadId).session = { status: "interrupted" };
    });
  });
}

const threadNamedById = (ctx: World, id: unknown) =>
  env(ctx).threads.find((candidate) => candidate.id === id)!;

async function start(ctx: MoveWorld): Promise<void> {
  await ui(ctx);
  await settle(ctx);
}

/** Open the thread's menu, ask to move it, and wait for the machines. */
async function chooseDestination(ctx: MoveWorld, title: string): Promise<void> {
  await start(ctx);
  await openMenu(ctx, title);
  await chooseMenuItem(ctx, "Move to another machine…");
  await settle(ctx);
  expect(contextMenu(ctx)?.items[0]).toMatchObject({ header: true, label: `Move ${title} to` });
}

// --- The cluster ------------------------------------------------------------------

step("a cluster of the machines {string} and {string}", (ctx: MoveWorld, local: string, other) => {
  ctx.machines = { local, others: [{ label: other, online: true }] };
  // The connection comes up with the client, which then reads the cluster it reaches.
  ctx.connectOnBoot = true;
  const previous = ctx.prepare;
  ctx.prepare = () => {
    previous?.();
    install(ctx);
  };
});

step(
  "the project {string} on each machine is a checkout of the same repository",
  (ctx: MoveWorld, project: string) => {
    addProject(ctx, project);
  },
);

step(
  "the thread {string} lives on {string} in {string}",
  (ctx: MoveWorld, title: string, machine: string, project: string) => {
    expect(machine).toBe(ctx.machines!.local);
    addThread(ctx, title, { project });
  },
);

step("the cluster also has the machine {string}, which is offline", (ctx: MoveWorld, label) => {
  ctx.machines!.others.push({ label, online: false });
});

// --- Choosing where to ----------------------------------------------------------------

step("the user chooses where to move {string}", chooseDestination);

step(
  "{string} is shown as offline and cannot be chosen",
  async (ctx: MoveWorld, machine: string) => {
    const item = menuLabels(ctx).find((row) => row.id === machine);
    expect(item).toMatchObject({ label: `${machine} (offline)`, disabled: true });
    expect(await snapshot(ctx)).toContain(`${machine} (offline)`);
    // Choosing it anyway moves nothing.
    const menu = contextMenu(ctx)!;
    ctx.host!.dispatch("contextMenu.select", { requestId: menu.requestId, id: machine });
    await settle(ctx);
    expect(mcCalls(ctx, "hal-c2.moveThread")).toEqual([]);
    expect(contextMenu(ctx)?.requestId).toBe(menu.requestId);
  },
);

step("moving to another machine is offered", async (ctx: MoveWorld) => {
  const item = menuLabels(ctx).find((row) => row.id === "move");
  expect(item).toMatchObject({ label: "Move to another machine…", disabled: false });
  expect(await snapshot(ctx)).toContain("Move to another machine…");
});

step("the user is looking at {string}", async (ctx: MoveWorld, title: string) => {
  await start(ctx);
  await selectThread(ctx, title);
});

step(
  "the user asks the command palette to move the thread to another machine",
  async (ctx: MoveWorld) => {
    await chooseCommand(ctx, "Move thread to another machine…");
    await settle(ctx);
  },
);

step("the user is asked which machine to move {string} to", async (ctx: MoveWorld, title) => {
  const screen = await settle(ctx);
  expect(mcCalls(ctx, "hal-c2.moveDestinations")).toEqual([
    { threadId: threadNamed(ctx, title).id },
  ]);
  expect(ctx.host!.state.get("mode")).toBe("contextMenu");
  expect(contextMenu(ctx)?.items.map((item) => item.label)).toEqual([
    `Move ${title} to`,
    "desktop",
  ]);
  expect(screen).toContain(`Move ${title} to`);
  // Nothing moves until a machine is chosen.
  expect(mcCalls(ctx, "hal-c2.moveThread")).toEqual([]);
});

// --- Moving -------------------------------------------------------------------------------

step(
  /^"([^"]*)" runs on an agent whose provider (can|cannot) carry its session$/,
  (ctx: MoveWorld, _title: string, can: string) => {
    ctx.carriesSession = can === "can";
  },
);

step("the user moves {string} to {string}", async (ctx: MoveWorld, title: string, machine) => {
  await chooseDestination(ctx, title);
  await chooseMenuItem(ctx, machine);
  await settle(ctx);
  expect(mcCalls(ctx, "hal-c2.moveThread")).toEqual([
    { threadId: threadNamed(ctx, title).id, machine },
  ]);
});

step(
  "the user moves {string} to {string} and chooses to stop it first",
  async (ctx: MoveWorld, title: string, machine: string) => {
    await chooseDestination(ctx, title);
    await chooseMenuItem(ctx, machine);
    await flush(ctx);
    // It is running: nothing was asked of the MC yet, and stopping first is offered.
    expect(mcCalls(ctx, "hal-c2.moveThread")).toEqual([]);
    expect(contextMenu(ctx)?.items[0]).toMatchObject({
      header: true,
      label: `${title} is running`,
    });
    await chooseMenuItem(ctx, `Stop it and move to ${machine}`);
    await settle(ctx);
  },
);

step("the running turn of {string} is interrupted", (ctx: MoveWorld, title: string) => {
  const thread = threadNamed(ctx, title);
  expect(
    ctx.fake!.calls.filter((call) => call.method === "interrupt").map((call) => call.args),
  ).toEqual([[thread.id]]);
  expect(thread.session?.status).toBe("interrupted");
});

step("{string} moves to {string}", async (ctx: MoveWorld, title: string, machine: string) => {
  await settle(ctx);
  // Asked once, after the turn had stopped (the MC refuses a running thread).
  expect(mcCalls(ctx, "hal-c2.moveThread")).toEqual([
    { threadId: threadNamed(ctx, title).id, machine },
  ]);
  expect(ctx.host!.state.get("status")).toEqual({
    kind: "success",
    text: `${title} moved to ${machine}. The agent continues its own session there.`,
  });
});
