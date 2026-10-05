// The open thread as the MC sends it (features/timeline/*): runs, turn items,
// runtime requests, plans and checkpoints of the orchestration V2 projection,
// shown through the client's own adapter (`presentTuiThread`). Steps build a
// turn with `startRun`, `addItem` and `settleRun`; each change is streamed in
// like a live update. The clock is pinned at 10:00 on 23 September 2026, local
// time, so durations and message stamps read the same everywhere.
import type { OrchestrationThread, OrchestrationV2ThreadProjection } from "@hal-c2/contracts";
import * as DateTime from "effect/DateTime";

import { presentTuiThread } from "../../src/orchestrationV2Adapter.ts";
import { hostState, openThread, plain, settle, type ThreadWorld } from "./threadWorld.ts";

export const NOW_MS = new Date(2026, 8, 23, 10, 0, 0).getTime();

type Fields = Record<string, unknown>;

interface Fixture {
  readonly runs: Fields[];
  readonly items: Fields[];
  readonly messages: Fields[];
  readonly plans: Fields[];
  readonly requests: Fields[];
  readonly checkpoints: Fields[];
  readonly subagents: Fields[];
  /** The provider's own threads: the context they used, the work they still run. */
  providerThreads?: Fields[];
  /** Fields of the thread itself (interaction mode, model). */
  thread: Fields;
  created: number;
}

export interface TurnWorld extends ThreadWorld {
  turns?: Fixture;
}

const time = (ms: number) => DateTime.makeUnsafe(new Date(ms));

/** The fixture of the open thread, opening it on first use. */
export async function turns(ctx: TurnWorld): Promise<Fixture> {
  if (!ctx.app) await openThread(ctx);
  ctx.nowMs = NOW_MS;
  ctx.turns ??= {
    runs: [],
    items: [],
    messages: [],
    plans: [],
    requests: [],
    checkpoints: [],
    subagents: [],
    thread: {},
    created: 0,
  };
  return ctx.turns;
}

const latestRun = (fixture: Fixture): Fields => {
  const run = fixture.runs.at(-1);
  if (!run) throw new Error("no run has started");
  return run;
};

/** The id of the run the scenario is in. */
export const currentRun = (ctx: TurnWorld): string => String(latestRun(ctx.turns!).id);

function projection(ctx: TurnWorld): OrchestrationV2ThreadProjection {
  const fixture = ctx.turns!;
  const base = ctx.thread!;
  const created = time(NOW_MS - 60 * 60_000);
  return {
    thread: {
      id: base.id,
      projectId: base.projectId,
      title: base.title,
      providerInstanceId: base.modelSelection.instanceId,
      modelSelection: base.modelSelection,
      runtimeMode: base.runtimeMode,
      interactionMode: base.interactionMode,
      branch: base.branch,
      worktreePath: base.worktreePath,
      activeProviderThreadId: null,
      lineage: { rootThreadId: base.id, parentThreadId: null, relationshipToParent: null },
      forkedFrom: null,
      createdBy: "user",
      creationSource: "web",
      createdAt: created,
      updatedAt: time(NOW_MS),
      archivedAt: null,
      settledOverride: null,
      settledAt: null,
      lastVisitedAt: null,
      deletedAt: null,
      ...fixture.thread,
    },
    runs: fixture.runs,
    attempts: [],
    nodes: [],
    subagents: fixture.subagents,
    providerSessions: [],
    providerThreads: fixture.providerThreads ?? [],
    providerTurns: [],
    runtimeRequests: fixture.requests,
    messages: fixture.messages,
    plans: fixture.plans,
    turnItems: fixture.items,
    checkpointScopes: [],
    checkpoints: fixture.checkpoints,
    contextHandoffs: [],
    contextTransfers: [],
    visibleTurnItems: fixture.items.map((item, position) => ({
      position,
      visibility: "local",
      sourceThreadId: base.id,
      sourceItemId: item.id,
      item,
    })),
    updatedAt: time(NOW_MS),
  } as unknown as OrchestrationV2ThreadProjection;
}

/** What the client makes of the thread as it stands (without sending it). */
export const presented = (ctx: TurnWorld): OrchestrationThread => presentTuiThread(projection(ctx));

/** Stream the thread as it stands now. */
export async function sync(ctx: TurnWorld): Promise<void> {
  const next = presented(ctx);
  ctx.thread = next;
  ctx.fake!.emitThread(next, ctx.page);
  await settle();
}

/** Change the thread's own fields (interaction mode, …) and stream it. */
export async function setThread(ctx: TurnWorld, fields: Fields): Promise<void> {
  const fixture = await turns(ctx);
  fixture.thread = { ...fixture.thread, ...fields };
  await sync(ctx);
}

/**
 * The user sends a message and its run starts `secondsAgo` (a run that is
 * "starting" has not begun: it has no start time). Returns the run's id.
 */
export async function startRun(
  ctx: TurnWorld,
  secondsAgo = 0,
  status = "running",
  startMs = NOW_MS - secondsAgo * 1000,
): Promise<string> {
  const fixture = await turns(ctx);
  const ordinal = fixture.runs.length + 1;
  const id = `run-${ordinal}`;
  const at = time(startMs);
  const started = status === "starting" || status === "queued" ? null : at;
  fixture.runs.push({
    id,
    threadId: ctx.thread!.id,
    ordinal,
    providerInstanceId: ctx.thread!.modelSelection.instanceId,
    modelSelection: ctx.thread!.modelSelection,
    providerThreadId: null,
    userMessageId: `message:${id}`,
    rootNodeId: null,
    activeAttemptId: null,
    status,
    requestedAt: at,
    startedAt: started,
    completedAt: null,
    checkpointId: null,
    contextHandoffId: null,
  });
  fixture.messages.push({
    id: `message:${id}`,
    threadId: ctx.thread!.id,
    runId: id,
    nodeId: null,
    role: "user",
    text: "Add tax to the cart",
    attachments: [],
    streaming: false,
    createdAt: at,
    updatedAt: at,
    createdBy: "user",
    creationSource: "web",
  });
  await sync(ctx);
  return id;
}

/** A turn item of the current run, a tenth of a second after the one before. */
export async function addItem(ctx: TurnWorld, type: string, fields: Fields = {}): Promise<string> {
  const fixture = await turns(ctx);
  const run = latestRun(fixture);
  fixture.created += 1;
  const id = String(fields.id ?? `item-${fixture.created}`);
  const runStart = DateTime.toEpochMillis(run.requestedAt as DateTime.Utc);
  const at = time(runStart + fixture.created * 100);
  const status = String(fields.status ?? "completed");
  const item: Fields = {
    id,
    threadId: ctx.thread!.id,
    runId: run.id,
    nodeId: null,
    providerThreadId: null,
    providerTurnId: null,
    nativeItemRef: null,
    parentItemId: null,
    ordinal: fixture.items.length,
    status,
    title: null,
    startedAt: at,
    completedAt: status === "completed" ? at : null,
    updatedAt: at,
    type,
    ...fields,
  };
  if (type === "assistant_message") {
    item.messageId = id;
    item.streaming ??= false;
    fixture.messages.push({
      id,
      threadId: ctx.thread!.id,
      runId: run.id,
      nodeId: null,
      role: "assistant",
      text: item.text ?? "",
      attachments: [],
      streaming: item.streaming,
      createdAt: at,
      updatedAt: at,
    });
  }
  if (type === "proposed_plan") {
    item.planId ??= `plan-${fixture.created}`;
    item.streaming ??= false;
    fixture.plans.push({
      id: item.planId,
      kind: "proposed_plan",
      threadId: ctx.thread!.id,
      runId: run.id,
      nodeId: null,
      status: "active",
      markdown: item.markdown ?? "",
    });
  }
  if (type === "checkpoint") {
    fixture.checkpoints.push({
      id: `checkpoint-${run.ordinal}`,
      threadId: ctx.thread!.id,
      scopeId: "scope-1",
      runId: run.id,
      nodeId: "node-1",
      parentCheckpointId: null,
      ordinalWithinScope: Number(run.ordinal),
      appRunOrdinal: run.ordinal,
      ref: `refs/hal-c2/checkpoints/${run.ordinal}`,
      status: "ready",
      files: item.files ?? [],
      capturedAt: at,
    });
  }
  if (
    (type === "approval_request" || type === "user_input_request") &&
    !fixture.requests.some((request) => request.id === item.requestId)
  ) {
    fixture.requests.push({
      id: item.requestId,
      nodeId: "node-1",
      providerTurnId: null,
      nativeRequestRef: null,
      kind: type === "approval_request" ? (item.requestKind ?? "command") : "user_input",
      status: "pending",
      responseCapability: { type: "live", providerSessionId: "session-1" },
      createdAt: at,
      resolvedAt: null,
    });
  }
  fixture.items.push(item);
  await sync(ctx);
  return id;
}

/** The nth command of the turn: `bun test cart-<n>`. */
export const addCommand = (ctx: TurnWorld, n: number, status = "completed") =>
  addItem(ctx, "command_execution", {
    id: `call-${n}`,
    status,
    input: `bun test cart-${n}`,
    output: status === "completed" ? "ok" : "",
    ...(status === "completed" ? { exitCode: 0 } : {}),
  });

/** Change an item (and its message, when it is one) and stream the thread. */
export async function setItem(ctx: TurnWorld, id: string, fields: Fields): Promise<void> {
  const fixture = await turns(ctx);
  const replace = (list: Fields[]) => {
    const index = list.findIndex((entry) => entry.id === id);
    if (index >= 0) list[index] = { ...list[index], ...fields };
    return index >= 0;
  };
  if (!replace(fixture.items)) throw new Error(`no turn item "${id}"`);
  const { text, streaming } = fields;
  const message = fixture.messages.findIndex((entry) => entry.id === id);
  if (message >= 0) {
    fixture.messages[message] = {
      ...fixture.messages[message],
      ...(text !== undefined && { text }),
      ...(streaming !== undefined && { streaming }),
    };
  }
  await sync(ctx);
}

/** Change a runtime request (its status, decision or whether it can be answered). */
export async function setRequest(ctx: TurnWorld, id: string, fields: Fields): Promise<void> {
  const fixture = await turns(ctx);
  const index = fixture.requests.findIndex((request) => request.id === id);
  if (index < 0) throw new Error(`no runtime request "${id}"`);
  fixture.requests[index] = { ...fixture.requests[index], ...fields };
  await sync(ctx);
}

/** The current run ends as `status`, `afterSeconds` after it began. */
export async function settleRun(ctx: TurnWorld, status: string, afterSeconds: number) {
  const fixture = await turns(ctx);
  const run = latestRun(fixture);
  const began = DateTime.toEpochMillis((run.startedAt ?? run.requestedAt) as DateTime.Utc);
  run.status = status;
  run.completedAt = time(began + afterSeconds * 1000);
  // Items still open end with their run.
  fixture.items.forEach((item, index) => {
    if (item.runId !== run.id) return;
    if (item.status === "running" || item.status === "pending" || item.status === "waiting") {
      fixture.items[index] = { ...item, status: status === "completed" ? "completed" : status };
    }
  });
  await sync(ctx);
}

// --- what the timeline shows ---------------------------------------------------------

export interface ShownLine {
  readonly text: { readonly chunks: ReadonlyArray<ShownChunk> };
  readonly action: string | null;
  readonly payload: unknown;
  readonly right: { readonly text: ShownLine["text"]; readonly action: string } | null;
}
export interface ShownChunk {
  readonly text: string;
  readonly attributes?: number;
  readonly fg?: unknown;
  readonly link?: { readonly url: string };
}
export interface ShownItem {
  readonly key: string;
  readonly kind: string;
  readonly align: string;
  readonly boxed: boolean;
  readonly lines: ReadonlyArray<ShownLine>;
}

export const shownItems = (ctx: ThreadWorld): ShownItem[] => hostState(ctx, "timeline").items;
export const itemsOf = (ctx: ThreadWorld, kind: string) =>
  shownItems(ctx).filter((item) => item.kind === kind);
export const linesOf = (item: ShownItem): string[] => item.lines.map((line) => plain(line.text));

/** The last item of a kind; fails with what is shown when there is none. */
export function lastOf(ctx: ThreadWorld, kind: string): ShownItem {
  const item = itemsOf(ctx, kind).at(-1);
  if (!item) {
    const shown = shownItems(ctx)
      .map((entry) => `${entry.kind}: ${linesOf(entry).join(" / ")}`)
      .join("\n");
    throw new Error(`the timeline shows no ${kind} row:\n${shown}`);
  }
  return item;
}

/** The item showing a message. */
export function messageItem(ctx: ThreadWorld, id: string): ShownItem {
  const item = shownItems(ctx).find((entry) => entry.kind === "message" && entry.key === id);
  if (!item) throw new Error(`the timeline does not show the message "${id}"`);
  return item;
}
