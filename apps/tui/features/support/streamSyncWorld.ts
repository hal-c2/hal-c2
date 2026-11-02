// The open thread kept in sync by the real client, for the catch-up scenarios of
// timeline/streaming.feature. `synced` builds the thread as it stands (the turn
// fixture of turnWorld.ts), serves it from a fake MC (fakeThreadMc.ts) and
// subscribes to it with `makeTuiClient`, the client the terminal runs; what the
// client makes of the thread is pushed into the booted shell, so the timeline
// shows what the real resume, resync and apply-once logic produced. In a cluster
// the thread lives on another member, reached through `makeClusterClient`.
import * as NodeOs from "node:os";
import * as NodePath from "node:path";

import {
  OrchestrationV2ThreadProjection,
  type ClusterStatus,
  type OrchestrationThread,
} from "@hal-c2/contracts";
import * as Schema from "effect/Schema";

import { makeClusterClient } from "../../src/clusterClient.ts";
import {
  buildTuiRuntime,
  makeTuiClient,
  type OrchestrationShellSnapshot,
  type TuiClient,
  type TuiThreadPage,
} from "../../src/connection.ts";
import type { Patch } from "../../../../packages/client-runtime/src/v3/patch.ts";
import { startFakeThreadMc, type FakeThreadMc, type ThreadRow } from "./fakeThreadMc.ts";
import { timelineText } from "./threadWorld.ts";
import { addItem, NOW_MS, projection, startRun, turns, type TurnWorld } from "./turnWorld.ts";
import { settle } from "./world.ts";

const HOME_ENVIRONMENT = "env-home";
const MEMBER_ENVIRONMENT = "env-workshop";
const MEMBER_LABEL = "workshop";
const WAIT_MS = 10_000;

export interface Synced {
  readonly mc: FakeThreadMc;
  /** The cluster's member holding the thread joins (true) or leaves (false) it. */
  readonly setMemberConnected: ((connected: boolean) => Promise<void>) | null;
  page: TuiThreadPage | null;
  /** Timeline lines once the client first showed the thread. */
  shownBefore: string[];
  /** Where the client was when the connection dropped: its stream's offset, and the subs so far. */
  offsetBefore?: number;
  subsBefore?: number;
  /** Lines of the reply when it is whole. */
  replyLines: number;
  /** Resolves once `check` holds, re-checked whenever the client shows the thread again. */
  until(check: () => boolean, what: string): Promise<void>;
}

export interface SyncWorld extends TurnWorld {
  synced?: Synced;
}

const encodeProjection = Schema.encodeSync(Schema.toCodecJson(OrchestrationV2ThreadProjection));

/** The thread as entity rows, as the MC's snapshot carries them. */
function threadRows(ctx: SyncWorld): ThreadRow[] {
  const fixture = ctx.turns!;
  // Agent messages as the MC keeps them: the turn fixture leaves who made them out.
  fixture.messages = fixture.messages.map((entry) => ({
    createdBy: "agent",
    creationSource: "provider",
    ...entry,
  }));
  const encoded = encodeProjection(projection(ctx)) as unknown as Record<string, unknown>;
  const thread = encoded.thread as Record<string, unknown>;
  const rows: ThreadRow[] = [["thread", String(thread.id), thread]];
  const kinds = { runs: "run", messages: "message", turnItems: "turn-item" } as const;
  for (const [field, kind] of Object.entries(kinds)) {
    for (const entity of encoded[field] as Array<Record<string, unknown>>) {
      rows.push([kind, String(entity.id), entity]);
    }
  }
  return rows;
}

/** Reply text of `count` paragraphs, numbered from `from`. */
export const replyText = (count: number, from = 1) =>
  Array.from({ length: count }, (_, index) => `Reply line ${from + index}.`).join("\n\n");

const iso = (ms: number) => new Date(ms).toISOString();

/**
 * The client in charge of the open thread, started on first use: the current
 * fixture (which needs a run) is served by a fake MC and followed by the real client.
 */
export async function synced(
  ctx: SyncWorld,
  options: { readonly cluster?: boolean } = {},
): Promise<Synced> {
  if (ctx.synced) return ctx.synced;
  const cluster = options.cluster === true;
  const threadId = ctx.thread!.id;
  const mc = startFakeThreadMc({
    threadId,
    rows: threadRows(ctx),
    environmentId: cluster ? MEMBER_ENVIRONMENT : HOME_ENVIRONMENT,
    mc: cluster ? "workshop@fake" : "home@fake",
  });
  const waiters = new Set<() => void>();
  const connect = (environmentId: string) =>
    makeTuiClient(
      buildTuiRuntime({
        origin: mc.origin,
        bearerToken: "fake-bearer",
        mintSocketUrl: () => mc.mintSocketUrl(),
        logPath: NodePath.join(
          process.env.TMPDIR ?? NodeOs.tmpdir(),
          `tui-stream-sync-${process.pid}.log`,
        ),
        reconnectDelay: "20 millis",
        environmentId,
        orchestrationProtocolVersion: 3,
      }),
      mc.origin,
    );

  let client: TuiClient;
  let setMemberConnected: Synced["setMemberConnected"] = null;
  if (cluster) {
    let connected = true;
    const status = (): ClusterStatus => ({
      clustered: true,
      id: HOME_ENVIRONMENT,
      label: "home",
      mc: "home@fake",
      addresses: [],
      members: [{ id: MEMBER_ENVIRONMENT, label: MEMBER_LABEL, addresses: [], connected }],
    });
    const none = { projects: [], threads: [] } as unknown as OrchestrationShellSnapshot;
    const home = {
      subscribeShell: (onSnapshot: (snapshot: OrchestrationShellSnapshot) => void) => {
        onSnapshot(none);
        return () => {};
      },
      subscribeConnection: () => () => {},
      clusterStatus: async () => status(),
      dispose: async () => {},
    } as unknown as TuiClient;
    // The member's own shell has no rows here; the cluster client is told it holds the
    // thread, while the member's shell subscription still hears the MC come and go.
    const member = connect(MEMBER_ENVIRONMENT);
    const listing = {
      projects: [],
      threads: [{ id: threadId }],
    } as unknown as OrchestrationShellSnapshot;
    client = makeClusterClient(home, () => ({
      ...member,
      subscribeShell: (onSnapshot) => {
        const stop = member.subscribeShell(() => {});
        onSnapshot(listing);
        return stop;
      },
    }));
    client.subscribeShell(() => {});
    await client.clusterStatus();
    setMemberConnected = async (next) => {
      connected = next;
      mc.setOnline(next);
      // What the host does when the MC says a machine came or went (`subscribeCluster`).
      await client.clusterStatus();
    };
  } else {
    client = connect(HOME_ENVIRONMENT);
  }

  const state: Synced = {
    mc,
    setMemberConnected,
    page: null,
    shownBefore: [],
    replyLines: 10,
    until: (check, what) =>
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
  };
  ctx.synced = state;
  const stop = client.subscribeThread(threadId, (thread: OrchestrationThread, page) => {
    ctx.thread = thread;
    ctx.page = page;
    state.page = page;
    ctx.fake!.emitThread(thread, page);
    for (const waiter of waiters) waiter();
  });
  ctx.cleanups.push(async () => {
    stop();
    await client.dispose();
    mc.stop();
  });
  await state.until(() => mc.subs.length > 0 && state.page !== null, "the thread from the MC");
  await settle(ctx);
  state.shownBefore = timelineText(ctx);
  return state;
}

/** The text of the reply message `r1` as the client shows it. */
export const reply = (ctx: SyncWorld) => ctx.thread?.messages.find((entry) => entry.id === "r1");

/** Patches that write `lines` more of the reply and finish it, with its run. */
export function finishReply(
  ctx: SyncWorld,
  lines: number,
): Array<readonly [string, string, Patch]> {
  const synced = ctx.synced!;
  const more = `\n\n${replyText(lines, synced.replyLines + 1)}`;
  synced.replyLines += lines;
  const done = iso(NOW_MS);
  const run = String(ctx.turns!.runs.at(-1)!.id);
  return [
    ["message", "r1", { a: { text: more } }],
    ["turn-item", "r1", { a: { text: more } }],
    ["turn-item", "r1", { s: { streaming: false, status: "completed", completedAt: done } }],
    ["message", "r1", { s: { streaming: false, updatedAt: done } }],
    ["run", run, { s: { status: "completed", completedAt: done } }],
  ];
}

/** Every line `before` showed is still shown, in the same order. */
export function keepsRows(before: ReadonlyArray<string>, now: ReadonlyArray<string>): string[] {
  const missing: string[] = [];
  let at = 0;
  for (const line of before) {
    const found = now.indexOf(line, at);
    if (found < 0) missing.push(line);
    else at = found + 1;
  }
  return missing;
}

/** The agent writing its reply (`r1`, ten lines), as the MC serves it to the client. */
export async function writingReply(ctx: SyncWorld): Promise<Synced> {
  const fixture = await turns(ctx);
  if (fixture.runs.length === 0) {
    await startRun(ctx, 30);
    await addItem(ctx, "assistant_message", {
      id: "r1",
      text: replyText(10),
      streaming: true,
      status: "running",
    });
  }
  return synced(ctx);
}

/** The open thread's MC closes the client's socket and lets it back only when told (`reconnect`). */
export async function dropThreadConnection(ctx: SyncWorld): Promise<void> {
  const state = await writingReply(ctx);
  state.offsetBefore = state.mc.head;
  state.subsBefore = state.mc.subs.length;
  state.mc.drop(true);
}
