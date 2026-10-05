// mc/platform/websocket-protocol.feature, the client's side: an MC whose protocol this
// client cannot speak is refused from its descriptor, before anything is opened, and an
// entity kind the client does not know is skipped by the decoder the socket feeds
// (`ThreadShapeFold`), so the events after it still reach the screen.
import { expect } from "bun:test";
import * as NodeFS from "node:fs";
import * as NodeOS from "node:os";
import * as NodePath from "node:path";
import {
  OrchestrationV2AppThread,
  OrchestrationV2TurnItem,
  ThreadId,
  type OrchestrationV2ThreadProjection,
} from "@hal-c2/contracts";
import * as Schema from "effect/Schema";

import { applyOrchestrationV2ProjectionEvent } from "../../../../../packages/client-runtime/src/state/orchestrationV2Projection.ts";
import { v2Projection } from "../../../../../packages/client-runtime/src/state/orchestrationV2TestFixtures.ts";
import {
  ThreadShapeFold,
  type ShapeEvent,
} from "../../../../../packages/client-runtime/src/v3/threadShape.ts";
import { connectRemoteMc, LaunchError } from "../../../src/mcDiscovery.ts";
import { presentTuiThread } from "../../../src/orchestrationV2Adapter.ts";
import { step } from "../../steps.ts";
import { hostState, openThread, settle, type ThreadWorld } from "../threadWorld.ts";
import { linesOf, shownItems } from "../turnWorld.ts";
import { snapshot } from "../world.ts";

interface ProtocolWorld extends ThreadWorld {
  /** Where this terminal client keeps the sessions it paired. */
  credentialsPath?: string;
  /** Every request the client made to the environment, in order. */
  requested?: string[];
  fetch?: typeof globalThis.fetch;
  refusal?: unknown;
  fold?: ThreadShapeFold;
  projection?: OrchestrationV2ThreadProjection;
  /** What the fold made of the frame with the unknown kind. */
  folded?: ReturnType<ThreadShapeFold["events"]>;
}

const ORIGIN = "http://workstation.test:3773";

// The terminal client holds a session with the environment from an earlier pairing.
step("a paired client", (ctx: ProtocolWorld) => {
  const dir = NodeFS.mkdtempSync(NodePath.join(NodeOS.tmpdir(), "hal-c2-tui-paired-"));
  ctx.cleanups.push(() => NodeFS.rmSync(dir, { recursive: true, force: true }));
  ctx.credentialsPath = NodePath.join(dir, "sessions.json");
  NodeFS.writeFileSync(
    ctx.credentialsPath,
    JSON.stringify({
      version: 1,
      sessions: { [ORIGIN]: { bearerToken: "paired-bearer", pairedAt: "2026-09-01T00:00:00Z" } },
    }),
  );
});

// --- An unknown protocol ---------------------------------------------------------------------

step("an environment whose descriptor declares an unsupported protocol", (ctx: ProtocolWorld) => {
  const requested: string[] = (ctx.requested = []);
  ctx.fetch = (async (input: Parameters<typeof globalThis.fetch>[0]) => {
    const url = new URL(
      typeof input === "string" ? input : input instanceof URL ? input.href : input.url,
    );
    requested.push(url.pathname);
    if (url.pathname === "/.well-known/hal-c2/environment") {
      return Response.json({
        environmentId: "env-workstation",
        label: "workstation",
        platform: { os: "linux", arch: "x64" },
        serverVersion: "9.0.0",
        // Newer than anything this client speaks.
        orchestrationProtocolVersion: 99,
        capabilities: {},
      });
    }
    // The session check a paired client would make next.
    return Response.json({ authenticated: true });
  }) as typeof globalThis.fetch;
});

step("a client tries to connect", async (ctx: ProtocolWorld) => {
  ctx.refusal = await connectRemoteMc({
    url: ORIGIN,
    credentialsPath: ctx.credentialsPath!,
    fetch: ctx.fetch!,
  }).then(
    (target) => ({ connected: target }),
    (error: unknown) => error,
  );
});

step("it is blocked before opening a socket", (ctx: ProtocolWorld) => {
  expect(ctx.refusal).toBeInstanceOf(LaunchError);
  // The descriptor is all it read: no session check, no socket ticket, no socket.
  expect(ctx.requested).toEqual(["/.well-known/hal-c2/environment"]);
  // Its pairing is untouched, for when one side is updated.
  expect(
    JSON.parse(NodeFS.readFileSync(ctx.credentialsPath!, "utf8")).sessions[ORIGIN],
  ).toMatchObject({
    bearerToken: "paired-bearer",
  });
});

step("it says which side to update", (ctx: ProtocolWorld) => {
  expect((ctx.refusal as Error).message).toBe(
    "This client is not supported by this server. Update your app or use a compatible release to connect to workstation.",
  );
});

// --- An unknown event type ---------------------------------------------------------------------

const THREAD_ID = ThreadId.make("t1");
const encodeThread = Schema.encodeSync(Schema.toCodecJson(OrchestrationV2AppThread));
const encodeItem = Schema.encodeSync(Schema.toCodecJson(OrchestrationV2TurnItem));

const answer = (text: string) =>
  encodeItem({
    id: "item-1",
    threadId: THREAD_ID,
    runId: null,
    nodeId: null,
    providerThreadId: null,
    providerTurnId: null,
    nativeItemRef: null,
    parentItemId: null,
    ordinal: 1,
    status: "running",
    title: null,
    startedAt: v2Projection.updatedAt,
    completedAt: null,
    updatedAt: v2Projection.updatedAt,
    type: "assistant_message",
    messageId: "message-1",
    text,
    streaming: true,
  } as unknown as OrchestrationV2TurnItem) as Record<string, unknown>;

const messageRow = (text: string) => ({
  id: "message-1",
  threadId: THREAD_ID,
  runId: null,
  nodeId: null,
  role: "assistant",
  text,
  attachments: [],
  streaming: true,
  createdAt: "2026-06-20T00:00:00.000Z",
  updatedAt: "2026-06-20T00:00:00.000Z",
  createdBy: "agent",
  creationSource: "provider",
});

/** Show what the client holds for the thread, as its subscription would deliver it. */
async function show(ctx: ProtocolWorld) {
  ctx.fake!.emitThread(presentTuiThread(ctx.projection!));
  await settle();
}

const shown = (ctx: ProtocolWorld) => shownItems(ctx).flatMap(linesOf).join("\n");

// The thread stream as the MC sends it: a snapshot of entities, then patches by kind.
step(
  "a connected client does not recognize an event type the MC publishes",
  async (ctx: ProtocolWorld) => {
    await openThread(ctx);
    ctx.fold = new ThreadShapeFold(THREAD_ID);
    const [first] = ctx.fold.snapshot({
      rows: [
        [
          "thread",
          THREAD_ID,
          encodeThread({
            ...v2Projection.thread,
            id: THREAD_ID,
            title: "Thread one",
          } as never) as Record<string, unknown>,
        ],
        ["turn-item", "item-1", answer("Adding the tax")],
        ["message", "message-1", messageRow("Adding the tax")],
      ],
      part: 0,
      done: true,
      offset: 1,
      at: Date.parse("2026-06-20T00:00:00Z"),
    });
    if (first?.kind !== "snapshot") throw new Error("the snapshot did not fold");
    ctx.projection = first.projection;
    await show(ctx);
    expect(shown(ctx)).toContain("Adding the tax");
    expect(hostState(ctx, "connection").state).toBe("connected");
  },
);

const apply = (ctx: ProtocolWorld, events: ReadonlyArray<ShapeEvent>) => {
  const items = ctx.fold!.events(events);
  for (const item of items) {
    if (item.kind === "event") {
      ctx.projection = applyOrchestrationV2ProjectionEvent(ctx.projection!, item.event)!;
    }
  }
  return items;
};

// A kind from a newer MC, in one frame with nothing else.
step("the MC publishes an event of that type", (ctx: ProtocolWorld) => {
  ctx.folded = apply(ctx, [
    [
      2,
      "hologram",
      "hologram-1",
      { s: { id: "hologram-1", depth: 3 } },
      Date.parse("2026-06-20T00:00:01Z"),
    ],
  ]);
});

step("the client skips the event", async (ctx: ProtocolWorld) => {
  // Nothing came of it, and nothing broke: the thread is as it was.
  expect(ctx.folded).toEqual([]);
  await show(ctx);
  expect(shown(ctx)).toContain("Adding the tax");
  expect(ctx.projection!.turnItems.map((item) => item.id as string)).toEqual(["item-1"]);
});

step(
  "it keeps its connection and processes the later events it knows",
  async (ctx: ProtocolWorld) => {
    // The same stream goes on: the message's next words, after another unknown kind.
    const items = apply(ctx, [
      [3, "hologram", "hologram-1", { s: { depth: 4 } }, Date.parse("2026-06-20T00:00:02Z")],
      [4, "turn-item", "item-1", { a: { text: " line now" } }, Date.parse("2026-06-20T00:00:03Z")],
      [5, "message", "message-1", { a: { text: " line now" } }, Date.parse("2026-06-20T00:00:03Z")],
    ]);
    expect(items.map((item) => (item.kind === "event" ? item.sequence : item.kind))).toEqual([
      4, 5,
    ]);
    await show(ctx);
    expect(shown(ctx)).toContain("Adding the tax line now");
    expect(await snapshot(ctx)).toContain("Adding the tax line now");
    expect(hostState(ctx, "connection").state).toBe("connected");
    expect(ctx.logs!.filter((entry) => /hologram|unknown/i.test(entry))).toEqual([]);
  },
);
