// Connection health from the terminal (features/connections/connection-health.feature):
// a protocol mismatch blocks the launch with advice; a cluster is one connection whose
// streams and thread list resume where they stopped; a slow MC is waited for, not asked
// again. The cluster and slow-MC clients are the terminal's own (`connectTui`) against
// a fake cluster MC (fakeClusterMc.ts).
import * as NodeOS from "node:os";
import * as NodePath from "node:path";

import { expect } from "bun:test";
import type { OrchestrationThread } from "@hal-c2/contracts";

import { HELLO_TIMEOUT_MS } from "../../../../../packages/client-runtime/src/v3/session.ts";
import { PING_INTERVAL_MS } from "../../../../../packages/client-runtime/src/v3/clusterSocket.ts";
import { connectTui } from "../../../src/clusterClient.ts";
import type { OrchestrationShellSnapshot, TuiClient } from "../../../src/connection.ts";
import { step } from "../../steps.ts";
import { startFakeClusterMc, type FakeClusterMc, type FakeMember } from "../fakeClusterMc.ts";
import { runClient, runningMc, type LaunchWorld } from "../launchWorld.ts";
import { connected } from "../settingsWorld.ts";
import { settle } from "../world.ts";

interface Following {
  readonly mc: FakeClusterMc;
  readonly client: TuiClient;
  shell: OrchestrationShellSnapshot | null;
  /** Shell snapshots the client delivered. */
  shells: number;
  readonly threads: Map<string, OrchestrationThread>;
  /** Re-checks what `until` waits on; the client delivered something. */
  wake(): void;
  /** Resolves once `check` holds, re-checked whenever the client delivers something. */
  until(check: () => boolean, what: string): Promise<void>;
}

interface HealthWorld extends LaunchWorld {
  connectBy?: () => Promise<void>;
  following?: Following;
  /** Subs the MC had been sent when the connection dropped. */
  subsBefore?: number;
  shellsBefore?: number;
}

const WAIT_MS = 10_000;

// --- A protocol mismatch --------------------------------------------------------

/** The client speaks protocols 2 and 3; these are one past either end. */
const PROTOCOLS = {
  "a newer protocol than the client": 4,
  "an older protocol than the client": 1,
} as const;

step(
  /^an environment whose MC speaks (a newer protocol than the client|an older protocol than the client)$/,
  (ctx: HealthWorld, protocol: string) => {
    runningMc(ctx, { protocol: PROTOCOLS[protocol as keyof typeof PROTOCOLS] });
    // The real client, launched against that MC; it exits instead of drawing when blocked.
    ctx.connectBy = async () => {
      await runClient(ctx, {});
    };
  },
);

step("the connection is blocked", (ctx: HealthWorld) => {
  const run = ctx.client!;
  expect(run.drew).toBe(false);
  expect(run.code).not.toBe(0);
  // Blocked on the descriptor: no socket ticket, no socket.
  expect(ctx.mc!.ticketRequests).toHaveLength(0);
  expect(ctx.mc!.sockets).toHaveLength(0);
});

step(
  /^the client says (update HAL-C2 on (?:this device|that environment))$/,
  (ctx: HealthWorld, advice: string) => {
    expect(ctx.client!.stderr.toLowerCase()).toContain(advice.toLowerCase());
  },
);

// --- The client against a fake cluster ------------------------------------------

const member = (name: string, threads: FakeMember["threads"]): FakeMember => ({
  environmentId: `env-${name}`,
  mc: `${name}@fake`,
  label: name,
  threads,
});

/** The terminal's client on `members` (the first is the MC it connects to), with a fast keepalive. */
function follow(ctx: HealthWorld, members: ReadonlyArray<FakeMember>): Following {
  const mc = startFakeClusterMc(members);
  const client = connectTui({
    origin: mc.origin,
    bearerToken: "fake-bearer",
    mintSocketUrl: () => mc.mintSocketUrl(),
    logPath: NodePath.join(process.env.TMPDIR ?? NodeOS.tmpdir(), `tui-health-${process.pid}.log`),
    reconnectDelay: "20 millis",
    environmentId: members[0]!.environmentId,
    orchestrationProtocolVersion: 3,
    // Pings every few milliseconds, so a held answer spans many of them.
    pingIntervalMs: 5,
  });
  const waiters = new Set<() => void>();
  const wake = () => {
    for (const waiter of waiters) waiter();
  };
  const state: Following = {
    mc,
    client,
    shell: null,
    shells: 0,
    threads: new Map(),
    wake,
    until: (check, what) =>
      Promise.race([
        mc.until(check, what),
        new Promise<void>((resolve, reject) => {
          const timer = setTimeout(() => {
            waiters.delete(waiter);
            reject(new Error(`timed out waiting for ${what}`));
          }, WAIT_MS);
          const waiter = () => {
            if (!check()) return;
            clearTimeout(timer);
            waiters.delete(waiter);
            resolve();
          };
          waiters.add(waiter);
          waiter();
        }),
      ]),
  };
  const stopShell = client.subscribeShell((snapshot) => {
    state.shell = snapshot;
    state.shells++;
    wake();
  });
  ctx.following = state;
  ctx.cleanups.push(async () => {
    stopShell();
    await client.dispose();
    mc.stop();
  });
  return state;
}

const listed = (state: Following, threadId: string) =>
  state.shell?.threads.some((thread) => thread.id === threadId) === true;

/** Opens `threadId` in the client; resolves once its stream was asked for. */
async function open(state: Following, threadId: string, ctx: HealthWorld): Promise<void> {
  const before = streamSubs(state.mc, threadId).length;
  const stop = state.client.subscribeThread(threadId as never, (thread: OrchestrationThread) => {
    state.threads.set(threadId, thread);
    state.wake();
  });
  ctx.cleanups.push(stop);
  await state.until(() => streamSubs(state.mc, threadId).length > before, `${threadId}'s stream`);
}

const streamSubs = (mc: FakeClusterMc, threadId: string) =>
  mc.subs.filter((sub) => sub.shape.type === "stream" && sub.shape.stream === threadId);
const shellSubs = (mc: FakeClusterMc) => mc.subs.filter((sub) => sub.shape.type === "shell");

const allThreads = (members: ReadonlyArray<FakeMember>) =>
  members.flatMap((entry) => entry.threads.map((thread) => thread.id));

/** Waits until every thread of `members` is in the client's list. */
async function listsAll(state: Following, members: ReadonlyArray<FakeMember>): Promise<void> {
  const ids = allThreads(members);
  await state.until(() => ids.every((id) => listed(state, id)), "every MC's threads in the list");
}

// --- One connection for a cluster -----------------------------------------------

const THREE_MCS = [
  member("home", [{ id: "thread-home", title: "Home thread" }]),
  member("workshop", [{ id: "thread-workshop", title: "Workshop thread" }]),
  member("studio", [{ id: "thread-studio", title: "Studio thread" }]),
];

step("a client connected to a cluster of three MCs", async (ctx: HealthWorld) => {
  const state = follow(ctx, THREE_MCS);
  await listsAll(state, THREE_MCS);
});

step("the client keeps one connection for the cluster", (ctx: HealthWorld) => {
  const { mc } = ctx.following!;
  expect(mc.minted()).toBe(1);
  expect(mc.sockets()).toBe(1);
  expect(mc.open()).toBe(1);
});

step("streams from every MC arrive over it", async (ctx: HealthWorld) => {
  const state = ctx.following!;
  for (const id of allThreads(THREE_MCS)) await open(state, id, ctx);
  await state.until(
    () => allThreads(THREE_MCS).every((id) => state.threads.has(id)),
    "every MC's thread",
  );
  for (const entry of THREE_MCS) {
    const [thread] = entry.threads;
    expect(state.threads.get(thread!.id)?.title).toBe(thread!.title);
    const subs = streamSubs(state.mc, thread!.id);
    expect(subs.map((sub) => [sub.socket, sub.shape.mc])).toEqual([[1, entry.mc]]);
  }
  // The shell and every member's config came over it too.
  expect(new Set(state.mc.subs.map((sub) => sub.socket))).toEqual(new Set([1]));
  expect(state.mc.sockets()).toBe(1);
});

// --- Resuming a cluster connection ----------------------------------------------

const FOLLOWED = THREE_MCS.slice(1).map((entry) => entry.threads[0]!.id);

step("a client following threads on two cluster members", async (ctx: HealthWorld) => {
  const state = follow(ctx, THREE_MCS);
  await listsAll(state, THREE_MCS);
  for (const id of FOLLOWED) await open(state, id, ctx);
  await state.until(() => FOLLOWED.every((id) => state.threads.has(id)), "both threads");
});

step("the cluster connection drops and returns", async (ctx: HealthWorld) => {
  const state = ctx.following!;
  ctx.subsBefore = state.mc.subs.length;
  ctx.shellsBefore = state.shells;
  state.mc.drop();
  const again = () => state.mc.subs.slice(ctx.subsBefore);
  await state.until(
    () =>
      state.mc.sockets() === 2 &&
      FOLLOWED.every((id) =>
        again().some((sub) => sub.shape.type === "stream" && sub.shape.stream === id),
      ) &&
      state.shells > ctx.shellsBefore!,
    "the client back on a new connection",
  );
});

step("each thread stream resumes from its last offset", (ctx: HealthWorld) => {
  const state = ctx.following!;
  for (const id of FOLLOWED) {
    const subs = streamSubs(state.mc, id);
    // The first asked from nothing; the one on the new connection from where it stopped.
    expect(subs.map((sub) => [sub.socket, sub.offset])).toEqual([
      [1, null],
      [2, 100],
    ]);
    expect(subs[1]!.handle).toBe("fake-cluster-log");
    expect(state.threads.get(id)?.title).toBeDefined();
  }
  expect(state.mc.open()).toBe(1);
});

step("the thread list asks only for the rows changed since", (ctx: HealthWorld) => {
  const state = ctx.following!;
  const resumed = shellSubs(state.mc).filter((sub) => sub.socket === 2);
  expect(resumed.length).toBeGreaterThan(0);
  const have = Object.fromEntries(THREE_MCS.map((entry) => [entry.mc, [`epoch-${entry.mc}`, 1]]));
  for (const sub of resumed) {
    expect(sub.have).toEqual(have);
    // Nothing changed while the client was away, so the MC sent no rows.
    expect(sub.answeredRows).toBe(0);
  }
  // And the list still holds every MC's threads.
  for (const id of allThreads(THREE_MCS)) expect(listed(state, id)).toBe(true);
});

// --- A slow MC ------------------------------------------------------------------
//
// The MC holds its answer while the client pings it many times (every 5 ms here,
// every 25 seconds for real), which stands in for the 12 seconds. A held answer is
// waited for: nothing in the client asks again while it waits. Its only deadline on
// a connection is the MC's `hello`, answered before the list is asked for; that and
// the keepalive are both longer than 12 seconds anyway.

const SLOW = [member("home", [{ id: "thread-slow", title: "Slow thread" }])];
/** Pings the client sends while the MC holds an answer. */
const HELD_PINGS = 5;

async function holdThroughPings(state: Following): Promise<void> {
  const from = state.mc.pings();
  await state.until(() => state.mc.pings() >= from + HELD_PINGS, "the client to keep pinging");
  state.mc.release();
}

function realDeadlinesOutlastTheMc(): void {
  const twelveSeconds = 12_000;
  expect(HELLO_TIMEOUT_MS).toBeGreaterThan(twelveSeconds);
  expect(PING_INTERVAL_MS).toBeGreaterThan(twelveSeconds);
}

step("the MC takes 12 seconds to build the thread list", (ctx: HealthWorld) => {
  ctx.connectBy = async () => {
    const state = follow(ctx, SLOW);
    state.mc.holdShell();
    await state.until(() => shellSubs(state.mc).length > 0, "the thread list asked for");
    await holdThroughPings(state);
  };
});

step("the thread list shows once the MC answers", async (ctx: HealthWorld) => {
  const state = ctx.following!;
  await state.until(() => listed(state, "thread-slow"), "the thread list");
  // What the terminal draws from it.
  await connected(ctx);
  ctx.fake!.emitShell(state.shell!);
  expect(await settle(ctx)).toContain("Slow thread");
});

step("the MC builds the thread list once", (ctx: HealthWorld) => {
  const { mc } = ctx.following!;
  expect(shellSubs(mc)).toHaveLength(1);
  expect(mc.sockets()).toBe(1);
  realDeadlinesOutlastTheMc();
});

step("the MC takes 12 seconds to load a thread", async (ctx: HealthWorld) => {
  const state = follow(ctx, SLOW);
  state.mc.holdThread("thread-slow");
  await state.until(() => listed(state, "thread-slow"), "the thread list");
});

step("the user opens the thread", async (ctx: HealthWorld) => {
  const state = ctx.following!;
  await open(state, "thread-slow", ctx);
  await holdThroughPings(state);
});

step("the thread shows once the MC answers", async (ctx: HealthWorld) => {
  const state = ctx.following!;
  await state.until(() => state.threads.has("thread-slow"), "the thread");
  expect(state.threads.get("thread-slow")?.title).toBe("Slow thread");
});

step("the MC loads the thread once", (ctx: HealthWorld) => {
  const { mc } = ctx.following!;
  expect(streamSubs(mc, "thread-slow")).toHaveLength(1);
  expect(mc.sockets()).toBe(1);
  realDeadlinesOutlastTheMc();
});
