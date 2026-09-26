// A thread open in the terminal client, for the timeline, approval and
// question scenarios. `openThread` boots the shell on thread "t1"; Given
// steps then change `ctx.thread` with `updateThread`, which pushes it through
// the fake client like a live server event. Client calls answer through
// `ctx.respond`, so a scenario can make one fail after boot.
import type { OrchestrationThread } from "@hal-c2/contracts";

import type { TuiClient, TuiThreadPage } from "../../src/connection.ts";
import type { Environment } from "./environment.ts";
import { project, shell, thread as baseThread } from "./fakeClient.ts";
import { boot, snapshot, useClient, type World } from "./world.ts";

type Activity = OrchestrationThread["activities"][number];
type Message = OrchestrationThread["messages"][number];
type Checkpoint = OrchestrationThread["checkpoints"][number];
type Plan = OrchestrationThread["proposedPlans"][number];

export interface ClientResponses {
  approve?: TuiClient["approve"];
  respondUserInput?: TuiClient["respondUserInput"];
  implementPlan?: TuiClient["implementPlan"];
  revertCheckpoint?: TuiClient["revertCheckpoint"];
  getTurnDiff?: TuiClient["getTurnDiff"];
  getFullThreadDiff?: TuiClient["getFullThreadDiff"];
}

export interface ThreadWorld extends World {
  thread?: OrchestrationThread;
  page?: TuiThreadPage;
  respond?: ClientResponses;
  /** Title of the thread's project (Background "a connected environment with the project …"). */
  projectTitle?: string;
}

/** Ten minutes ago: fixtures are relative to the host's real clock. */
const BASE_MS = Date.now() - 10 * 60_000;

/** An ISO time `seconds` after the fixture base. */
export const at = (seconds: number): string => new Date(BASE_MS + seconds * 1000).toISOString();

export function message(
  id: string,
  role: "user" | "assistant",
  text: string,
  seconds: number,
  extra: Partial<Message> & { turnId?: string } = {},
): Message {
  return {
    id,
    role,
    text,
    createdAt: at(seconds),
    updatedAt: at(seconds),
    streaming: false,
    turnId: null,
    ...extra,
  } as unknown as Message;
}

export interface ToolOptions {
  readonly kind?: string;
  readonly tone?: string;
  readonly summary?: string;
  readonly itemType?: string;
  readonly requestKind?: string;
  readonly detail?: string;
  readonly status?: string;
  readonly data?: Record<string, unknown>;
  readonly turnId?: string | null;
  readonly payload?: Record<string, unknown>;
}

let sequence = 0;

export function activity(id: string, seconds: number, options: ToolOptions = {}): Activity {
  sequence += 1;
  return {
    id,
    tone: options.tone ?? "tool",
    kind: options.kind ?? "tool.completed",
    summary: options.summary ?? "Ran command",
    payload: options.payload ?? {
      ...(options.itemType !== undefined && { itemType: options.itemType }),
      ...(options.requestKind !== undefined && { requestKind: options.requestKind }),
      ...(options.detail !== undefined && { detail: options.detail }),
      ...(options.status !== undefined && { status: options.status }),
      ...(options.data !== undefined && { data: options.data }),
    },
    turnId: options.turnId ?? null,
    sequence,
    createdAt: at(seconds),
  } as unknown as Activity;
}

/** A finished shell command. */
export const command = (id: string, seconds: number, cmd: string, turnId: string | null = null) =>
  activity(id, seconds, {
    itemType: "command_execution",
    detail: cmd,
    summary: "Ran command",
    turnId,
  });

export function approvalRequest(
  requestId: string,
  detail: string,
  seconds: number,
  requestKind = "command",
): Activity {
  return activity(`act-${requestId}`, seconds, {
    tone: "approval",
    kind: "approval.requested",
    summary: "Approval requested",
    payload: { requestId, requestKind, detail },
  });
}

export function approvalResolved(requestId: string, seconds: number): Activity {
  return activity(`act-${requestId}-resolved`, seconds, {
    tone: "approval",
    kind: "approval.resolved",
    summary: "Approval resolved",
    payload: { requestId },
  });
}

export interface QuestionFixture {
  readonly id: string;
  readonly header?: string;
  readonly question: string;
  readonly options: ReadonlyArray<string>;
  readonly multiSelect?: boolean;
}

export function questionRequest(
  requestId: string,
  questions: ReadonlyArray<QuestionFixture>,
  seconds: number,
): Activity {
  return activity(`act-${requestId}`, seconds, {
    tone: "info",
    kind: "user-input.requested",
    summary: "User input requested",
    payload: {
      requestId,
      questions: questions.map((entry) => ({
        id: entry.id,
        header: entry.header ?? "Question",
        question: entry.question,
        multiSelect: entry.multiSelect ?? false,
        options: entry.options.map((label) => ({ label, description: "" })),
      })),
    },
  });
}

export function checkpoint(
  turnCount: number,
  files: ReadonlyArray<string | { path: string; additions: number; deletions: number }>,
  seconds: number,
  assistantMessageId: string | null,
): Checkpoint {
  return {
    turnId: `turn-${turnCount}`,
    checkpointTurnCount: turnCount,
    checkpointRef: `refs/hal-c2/checkpoints/${turnCount}`,
    status: "ready",
    files: files.map((file) =>
      typeof file === "string"
        ? { path: file, kind: "modified", additions: 3, deletions: 1 }
        : { kind: "modified", ...file },
    ),
    assistantMessageId,
    completedAt: at(seconds),
  } as unknown as Checkpoint;
}

export function plan(
  id: string,
  planMarkdown: string,
  seconds: number,
  extra: Partial<Plan> & { turnId?: string | null } = {},
): Plan {
  return {
    id,
    turnId: null,
    planMarkdown,
    implementedAt: null,
    implementationThreadId: null,
    createdAt: at(seconds),
    updatedAt: at(seconds),
    ...extra,
  } as unknown as Plan;
}

/** The latest turn, running unless a completion time is given. */
export function latestTurn(
  turnId: string,
  startedSeconds: number,
  completedSeconds: number | null = null,
  assistantMessageId: string | null = null,
): OrchestrationThread["latestTurn"] {
  return {
    turnId,
    state: completedSeconds === null ? "running" : "completed",
    requestedAt: at(startedSeconds),
    startedAt: at(startedSeconds),
    completedAt: completedSeconds === null ? null : at(completedSeconds),
    assistantMessageId,
  } as unknown as OrchestrationThread["latestTurn"];
}

/** Wait for queued client promises and the renders they cause. */
export const settle = () => new Promise<void>((resolve) => setImmediate(resolve));

/** Boot the shell with thread "t1" selected and its detail streamed in. */
export async function openThread(
  ctx: ThreadWorld,
  detail: OrchestrationThread = baseThread(),
  options: Parameters<typeof useClient>[1] = {},
): Promise<void> {
  const respond: ClientResponses = (ctx.respond ??= {});
  ctx.thread = detail;
  // The Background's project (T1's environment.ts) names the thread's project.
  const projectTitle = ctx.projectTitle ?? (ctx as { env?: Environment }).env?.projects[0]?.title;
  // Thread fixtures are timed against the real clock (`at`), not the environment's pinned one.
  delete ctx.nowMs;
  useClient(ctx, {
    ...options,
    detail,
    ...(projectTitle !== undefined && {
      shellSnapshot: shell(undefined, [{ ...project, title: projectTitle }] as never),
    }),
    approve: (...args) => (respond.approve ?? (async () => {}))(...args),
    respondUserInput: (...args) => (respond.respondUserInput ?? (async () => {}))(...args),
    implementPlan: (...args) => (respond.implementPlan ?? (async () => {}))(...args),
    revertCheckpoint: (...args) => (respond.revertCheckpoint ?? (async () => {}))(...args),
    getTurnDiff: (...args) => (respond.getTurnDiff ?? (async () => ""))(...args),
    getFullThreadDiff: (...args) => (respond.getFullThreadDiff ?? (async () => ""))(...args),
  });
  await boot(ctx);
  ctx.fake!.connect();
  ctx.fake!.emitThread(detail, ctx.page);
  await settle();
  // The first frame lays the timeline out beside a scrollbar that turns out
  // not to be needed; the next one gives the column its full width back.
  await snapshot(ctx);
  await snapshot(ctx);
}

/** Apply a change to the open thread and stream it in. */
export async function updateThread(
  ctx: ThreadWorld,
  change: (detail: OrchestrationThread) => Partial<OrchestrationThread>,
): Promise<OrchestrationThread> {
  if (!ctx.thread) throw new Error("updateThread: no thread is open");
  const next = { ...ctx.thread, ...change(ctx.thread) } as OrchestrationThread;
  ctx.thread = next;
  ctx.fake!.emitThread(next, ctx.page);
  await settle();
  return next;
}

/** A published `Shell.state` key. */
export const hostState = (ctx: World, key: string): any => ctx.host!.state.get(key);

/** What the fake client was asked through `method`, as plain argument lists. */
export const recorded = (ctx: World, method: string): unknown[][] =>
  ctx.fake!.calls.filter((call) => call.method === method).map((call) => [...call.args]);

/** The plain text of a styled `{chunks}` value. */
export const plain = (
  text: { chunks: ReadonlyArray<{ text: string }> } | null | undefined,
): string => (text ? text.chunks.map((part) => part.text).join("") : "");

/** An object's `text` as plain text, whether a string or StyledText. */
export const shownText = (value: unknown): string =>
  typeof value === "string" ? value : plain(value as Parameters<typeof plain>[0]);

/** Every timeline line as plain text, in order (right parts after a tab). */
export function timelineText(ctx: World): string[] {
  const timeline = hostState(ctx, "timeline");
  const lines: string[] = [];
  for (const item of timeline.items) {
    for (const entry of item.lines) {
      lines.push(
        entry.right ? `${plain(entry.text)}\t${plain(entry.right.text)}` : plain(entry.text),
      );
    }
  }
  return lines;
}

/** Click the first place the rendered screen shows `text`. */
export async function clickText(ctx: World, text: string): Promise<void> {
  const screen = (await snapshot(ctx)).split("\n");
  const row = screen.findIndex((line) => line.includes(text));
  if (row < 0) throw new Error(`clickText: "${text}" is not on screen\n${screen.join("\n")}`);
  const column = Bun.stringWidth(screen[row]!.slice(0, screen[row]!.indexOf(text)));
  await ctx.app!.click(column, row);
  await settle();
}

/** A promise the scenario resolves or rejects later. */
export function deferred<T = void>() {
  let resolve!: (value: T) => void;
  let reject!: (error: unknown) => void;
  const promise = new Promise<T>((res, rej) => {
    resolve = res;
    reject = rej;
  });
  return { promise, resolve, reject };
}
