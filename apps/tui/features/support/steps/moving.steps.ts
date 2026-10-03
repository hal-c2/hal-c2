// Steps for threads/moving-between-machines.feature (@shared): a cluster of
// machines in the environment (environment.ts), whose fake MC moves a thread
// as HalC2.ThreadMove does. Where the feature says "the phone", this client
// plays the client that only watches.
import { expect } from "bun:test";

import type { OrchestrationThread, TuiConnectionPhase } from "../../../src/connection.ts";
import type { TuiSelectState } from "../../../src/host/composerState.ts";
import { MOVE_THREAD_LABEL } from "../../../src/threadMenu.logic.ts";
import { step } from "../../steps.ts";
import {
  addProject,
  addThread,
  arrive,
  change,
  env,
  flush,
  startMoving,
  threadNamed,
  ui,
} from "../environment.ts";
import { thread } from "../fakeClient.ts";
import { message } from "../threadWorld.ts";
import {
  chooseCommand,
  chooseMenuItem,
  click,
  clickText,
  contextMenu,
  findOnScreen,
  fromMenu,
  listedRow,
  rowLineYs,
  selectThread,
  sidebar,
  statusText,
  threadRows,
} from "../threadUi.ts";
import { pressKey, settle, snapshot, typeText, type World } from "../world.ts";

interface MovingWorld extends World {
  /** What the agent wrote on the machine the thread is moved back from. */
  work?: string;
  /** What the user wrote while the thread was moving. */
  written?: string;
  /** Connection phases since this client started watching. */
  phases?: TuiConnectionPhase[];
}

const MOVE_COMMAND = "Move thread to another machine";

const picker = (ctx: World) => ctx.host!.state.get("select") as TuiSelectState;
const callsTo = (ctx: World, method: string) =>
  ctx.fake!.calls.filter((call) => call.method === method);
const moves = (ctx: World) =>
  callsTo(ctx, "moveThread").map((call) => call.args[0] as { threadId: string; machine: string });

/** Choose in the open picker as the user does: arrow to the option, Enter. */
async function choose(ctx: World, label: string): Promise<void> {
  await settle(ctx);
  const { options } = picker(ctx);
  const index = options.findIndex((option) => option.label === label);
  expect(index, `no "${label}" among ${options.map((option) => option.label)}`).not.toBe(-1);
  for (let i = 0; i < options.length && picker(ctx).index !== index; i += 1) {
    await pressKey(ctx, "Down");
  }
  expect(picker(ctx).index).toBe(index);
  await pressKey(ctx, "Enter");
  await settle(ctx);
}

async function askWhereToMove(ctx: World, title: string): Promise<void> {
  await fromMenu(ctx, title, MOVE_THREAD_LABEL);
  await settle(ctx);
  expect(picker(ctx)).toMatchObject({ open: true, title: `Move "${title}" to` });
}

/** Open the thread with a conversation behind it, so the prompt can send. */
async function open(ctx: World, title: string, messages: unknown[] = []): Promise<void> {
  await selectThread(ctx, title);
  const { id, projectId } = threadNamed(ctx, title);
  ctx.fake!.emitThread({ ...thread(), id, projectId, title, messages } as never);
  await settle(ctx);
}

/** The thread's one row is on `machine`, and the list says so. */
async function expectListedUnder(ctx: World, title: string, machine: string): Promise<void> {
  const frame = (await settle(ctx)).split("\n");
  const rows = threadRows(ctx).filter((row) => row.thread.title === title);
  expect(rows.map((row) => row.thread.machine)).toEqual([machine]);
  expect(
    rowLineYs(ctx, title)
      .map((y) => frame[y])
      .join("\n"),
  ).toContain(machine);
}

async function expectLookingAt(ctx: World, title: string, machine?: string): Promise<void> {
  await settle(ctx);
  expect(sidebar(ctx).activeThreadKey).toBe(listedRow(ctx, title)!.key);
  expect(ctx.host!.state.get("page")).toMatchObject({
    kind: "thread",
    threadId: threadNamed(ctx, title).id,
  });
  if (machine !== undefined) await expectListedUnder(ctx, title, machine);
}

/** Another client moved the thread: this one only sees the list change. */
async function movedElsewhere(ctx: World, title: string, machine: string): Promise<void> {
  startMoving(ctx, title, machine);
  arrive(ctx, title, machine);
  await flush(ctx);
}

// --- The cluster ---------------------------------------------------------------

step(
  "a cluster of the machines {string} and {string}",
  (ctx: World, here: string, other: string) => {
    env(ctx).machines = [here, other].map((label) => ({ id: `env-${label}`, label, online: true }));
  },
);

step("the cluster also has the machine {string}, which is offline", (ctx: World, label: string) => {
  env(ctx).machines.push({ id: `env-${label}`, label, online: false });
});

step(
  "the project {string} on each machine is a checkout of the same repository",
  (ctx: World, title: string) => {
    for (const machine of env(ctx).machines) addProject(ctx, title, machine.label);
  },
);

step(
  "the thread {string} lives on {string} in {string}",
  (ctx: World, title: string, machine: string, project: string) => {
    addThread(ctx, title, { projectId: addProject(ctx, project, machine).id, machine });
  },
);

// On its own a machine has no cluster to name: its projects and threads are just its own.
step("{string} is not in a cluster", (ctx: World, machine: string) => {
  const environment = env(ctx);
  environment.machines = [];
  for (const project of [...environment.projects]) {
    if (project.machine !== machine) {
      environment.projects.splice(environment.projects.indexOf(project), 1);
    }
    delete project.machine;
  }
  for (const item of environment.threads) delete item.machine;
});

step(
  /^"([^"]*)" runs on an agent whose provider (can|cannot) carry its session$/,
  (ctx: World, _title: string, can: string) => {
    env(ctx).sessionCarried = can === "can";
  },
);

// --- Moving --------------------------------------------------------------------

step("the user chooses where to move {string}", askWhereToMove);

step("the user moves {string} to {string}", async (ctx: World, title: string, machine: string) => {
  await askWhereToMove(ctx, title);
  await choose(ctx, machine);
});

step(
  "the user moves {string} to {string} and chooses to stop it first",
  async (ctx: World, title: string, machine: string) => {
    await askWhereToMove(ctx, title);
    await choose(ctx, machine);
    expect(picker(ctx)).toMatchObject({
      open: true,
      title: `Stop "${title}" and move it to ${machine}?`,
    });
    await choose(ctx, "Stop and move");
  },
);

step("{string} is shown as offline and cannot be chosen", async (ctx: World, machine: string) => {
  const label = `${machine} (offline)`;
  const index = picker(ctx).options.findIndex((option) => option.label === label);
  expect(picker(ctx).options[index]).toMatchObject({ label, disabled: true });
  // The arrows step over it, and clicking it chooses nothing.
  for (const _ of picker(ctx).options) {
    await pressKey(ctx, "Down");
    expect(picker(ctx).index).not.toBe(index);
  }
  const at = await findOnScreen(ctx, label);
  expect(at, `"${label}" is not on screen`).not.toBeNull();
  await click(ctx, { x: at!.x + 1, y: at!.y });
  await settle(ctx);
  expect(picker(ctx).open).toBe(true);
  expect(moves(ctx)).toEqual([]);
});

step("{string} is listed under {string}", expectListedUnder);

step("{string} is no longer listed under {string}", async (ctx: World, title: string, machine) => {
  await settle(ctx);
  const rows = threadRows(ctx).filter((row) => row.thread.title === title);
  expect(rows).toHaveLength(1);
  expect(rows[0]!.thread.machine).not.toBe(machine);
});

step("the user is looking at {string}", (ctx: World, title: string) => open(ctx, title));
step("the user is looking at {string} on {string}", expectLookingAt);
step("{string} opens on {string}", expectLookingAt);

step("the running turn of {string} is interrupted", (ctx: World, title: string) => {
  expect(callsTo(ctx, "interrupt").map((call) => call.args[0])).toEqual([
    threadNamed(ctx, title).id,
  ]);
});

step("{string} moves to {string}", async (ctx: World, title: string, machine: string) => {
  expect(moves(ctx)).toEqual([{ threadId: threadNamed(ctx, title).id, machine }]);
  await expectListedUnder(ctx, title, machine);
});

// --- Moving back ---------------------------------------------------------------

step(
  "{string} was moved from {string} to {string}",
  (ctx: World, title: string, _from: string, machine: string) => arrive(ctx, title, machine),
);

step(
  "the user worked in {string} on {string}",
  async (ctx: MovingWorld, title: string, machine) => {
    ctx.work = `Tidied the cart on ${machine}`;
    await open(ctx, title, [
      message("m-ask", "user", "Tidy the cart", 1),
      message("m-work", "assistant", ctx.work, 2),
    ]);
  },
);

step(
  "{string} is listed under {string} with the work done on {string}",
  async (ctx: MovingWorld, title: string, machine: string, _from: string) => {
    await expectLookingAt(ctx, title, machine);
    expect(await snapshot(ctx)).toContain(ctx.work!);
  },
);

// What a terminal shows of a carried session is what the MC says about it.
step(
  "the agent on {string} continues the session as it was on {string}",
  (ctx: World, machine: string, _from: string) => {
    expect(moves(ctx).map((move) => move.machine)).toEqual([machine]);
    expect(statusText(ctx)).toMatch(
      new RegExp(` moved to ${machine}\\. The agent continues its own session there\\.$`),
    );
  },
);

// --- Finding a thread that moved -----------------------------------------------

step(
  "the user was notified that {string} finished while it lived on {string}",
  async (ctx: World, title: string, machine: string) => {
    // Alerts are for threads the user is not looking at.
    const other = addThread(ctx, "Beta", {
      projectId: threadNamed(ctx, title).projectId,
      machine,
    });
    await selectThread(ctx, other.title);
    change(ctx, () => {
      Object.assign(threadNamed(ctx, title), {
        latestTurn: { turnId: "turn-1", state: "completed" },
      });
    });
    expect(await settle(ctx)).toContain(`Thread completed · ${title}`);
  },
);

step("{string} has since moved to {string}", movedElsewhere);

step("the user opens the notification", async (ctx: World) => {
  await clickText(ctx, "[Open]");
  await settle(ctx);
});

// --- Other clients -------------------------------------------------------------

step("a phone and the desktop app both follow the cluster's threads", async (ctx: MovingWorld) => {
  await ui(ctx);
  const phases: TuiConnectionPhase[] = [];
  ctx.cleanups.push(ctx.fake!.client.subscribeConnection((phase) => phases.push(phase)));
  // Subscribing reports where the connection stands; what counts is what follows.
  phases.length = 0;
  ctx.phases = phases;
});

step("the user moves {string} to {string} from the desktop app", movedElsewhere);
step("{string} is moved to {string} from another client", movedElsewhere);

step(
  "the phone lists {string} under {string} and no longer under {string}",
  async (ctx: World, title: string, machine: string, _from: string) => {
    await expectListedUnder(ctx, title, machine);
  },
);

step("the phone did not have to reconnect", (ctx: MovingWorld) => {
  expect(ctx.phases).toEqual([]);
});

step("the phone is showing {string}", (ctx: World, title: string) => open(ctx, title));

step("the phone keeps showing {string}", (ctx: World, title: string) =>
  expectLookingAt(ctx, title),
);

step(
  "a message sent from the phone reaches {string} on {string}",
  async (ctx: World, title: string, machine: string) => {
    await typeText(ctx, "Carry on");
    await pressKey(ctx, "Enter");
    await settle(ctx);
    const sent = callsTo(ctx, "sendReply").map((call) => [
      (call.args[0] as OrchestrationThread).id,
      call.args[1],
    ]);
    expect(sent).toEqual([[threadNamed(ctx, title).id, "Carry on"]]);
    expect(threadNamed(ctx, title).machine).toBe(machine);
  },
);

step("the phone lists {string}", async (ctx: World, title: string) => {
  await ui(ctx);
  expect(listedRow(ctx, title)).toBeDefined();
});

step("{string} starts moving to {string}", async (ctx: World, title: string, machine: string) => {
  startMoving(ctx, title, machine);
  await flush(ctx);
});

step(
  "the phone shows {string} as moving to {string} until it arrives",
  async (ctx: World, title: string, machine: string) => {
    const label = `Moving to ${machine}`;
    const rowText = async () => {
      const frame = (await settle(ctx)).split("\n");
      return rowLineYs(ctx, title)
        .map((y) => frame[y])
        .join("\n");
    };
    expect(await rowText()).toContain(label);
    expect(listedRow(ctx, title)!.thread.statusLabel).toBe(label);
    arrive(ctx, title, machine);
    expect(await rowText()).not.toContain(label);
    await expectListedUnder(ctx, title, machine);
  },
);

// --- While a thread is moving --------------------------------------------------

step("{string} is moving to {string}", (ctx: World, title: string, machine: string) =>
  startMoving(ctx, title, machine),
);

step("the user writes a message in {string}", async (ctx: MovingWorld, title: string) => {
  ctx.subject = title;
  ctx.written = "Carry on from here";
  await open(ctx, title);
  await typeText(ctx, ctx.written);
  await pressKey(ctx, "Enter");
  await settle(ctx);
});

step("the message is kept as a draft", async (ctx: MovingWorld) => {
  const title = ctx.subject as string;
  expect(callsTo(ctx, "sendReply")).toEqual([]);
  expect((ctx.host!.state.get("composer") as { text: string }).text).toBe(ctx.written!);
  expect(statusText(ctx)).toBe(
    `${title} is moving to ${threadNamed(ctx, title).moving!.label}. Send the message once it has arrived.`,
  );
});

step(
  "it can be sent once {string} has arrived on {string}",
  async (ctx: MovingWorld, title: string, machine: string) => {
    arrive(ctx, title, machine);
    await settle(ctx);
    await pressKey(ctx, "Enter");
    await settle(ctx);
    expect(callsTo(ctx, "sendReply").map((call) => call.args[1])).toEqual([ctx.written]);
    expect((ctx.host!.state.get("composer") as { text: string }).text).toBe("");
  },
);

// --- From the list -------------------------------------------------------------

step(
  /^moving to another machine is (offered|not offered)$/,
  async (ctx: World, offered: string) => {
    const labels = contextMenu(ctx)!.items.map((item) => item.label);
    const frame = await snapshot(ctx);
    if (offered === "offered") {
      expect(labels).toContain(MOVE_THREAD_LABEL);
      expect(frame).toContain(MOVE_THREAD_LABEL);
      // And it leads somewhere: choosing it asks which machine.
      await chooseMenuItem(ctx, MOVE_THREAD_LABEL);
      await settle(ctx);
      expect(picker(ctx).open).toBe(true);
    } else {
      expect(labels).not.toContain(MOVE_THREAD_LABEL);
      expect(frame).not.toContain(MOVE_THREAD_LABEL);
    }
  },
);

step("the user asks the command palette to move the thread to another machine", (ctx: World) =>
  chooseCommand(ctx, MOVE_COMMAND),
);

step("the user is asked which machine to move {string} to", async (ctx: World, title: string) => {
  const frame = await settle(ctx);
  const heading = `Move "${title}" to`;
  expect(picker(ctx)).toMatchObject({ open: true, title: heading });
  expect(frame).toContain(heading);
  const here = threadNamed(ctx, title).machine;
  expect(picker(ctx).options.map((option) => option.label)).toEqual(
    env(ctx)
      .machines.filter((machine) => machine.label !== here)
      .map((machine) => machine.label),
  );
});
