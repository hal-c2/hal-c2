// terminal/io.feature: the output window against the real MC (support/realMc.ts). The
// drawer's model runs on the real client; a gate on its acks plays a client that stopped
// handling output, and a second socket that does not acknowledge says what the shell printed.
// Waits end on the next frame that makes them true; the runner's timeout fails what never comes.
import { expect } from "bun:test";
import type { TerminalAttachStreamEvent, ThreadId } from "@hal-c2/contracts";
import { remoteHttpClientLayer } from "@hal-c2/client-runtime/rpc";
import { fetchRemoteEnvironmentDescriptor } from "@hal-c2/client-runtime/environment";
import * as Effect from "effect/Effect";
import * as NodePath from "node:path";

import { buildTuiRuntime, makeTuiClient, type TuiClient } from "../../../src/connection.ts";
import {
  createTerminalController,
  type TerminalController,
} from "../../../src/host/terminalState.ts";
import { makeHttpSocketTicketMinter } from "../../../src/socketTicket.ts";
import type { Store } from "../../../src/store.ts";
import { startRealMc, type RealMc } from "../realMc.ts";
import { step, type StepContext } from "../../steps.ts";

/** `HalC2.Terminal.OutputWindow.limit/0`. */
const LIMIT = 64 * 1024;
const THREAD_ID = "window-thread";

interface Received {
  readonly type: string;
  readonly bytes: number;
}

interface WindowWorld extends StepContext {
  mc: RealMc;
  client: TuiClient;
  controller: TerminalController;
  /** What the client's terminal received, by terminal. */
  received: Map<string, Received[]>;
  /** The terminal the scenario started, and its shell. */
  terminalId: string;
  shellPid: number;
  /** Bytes the shell has printed, as a client that always keeps up heard it. */
  printed: number;
  stalled: boolean;
  held: (() => void) | null;
  /** Frames seen so far, and the waits for the next one. */
  frames: number;
  waiting: Set<() => void>;
  /** The client's own sockets, to drop its connection. */
  sockets: WebSocket[];
  /** Set by "stops acknowledging": where that began. */
  stalledAt: number;
  printedAt: number;
}

const received = (ctx: WindowWorld) => ctx.received.get(ctx.terminalId) ?? [];
const outputBytes = (events: ReadonlyArray<Received>) =>
  events.filter((event) => event.type === "output").reduce((sum, event) => sum + event.bytes, 0);

function frameSeen(ctx: WindowWorld) {
  ctx.frames++;
  for (const resolve of ctx.waiting) resolve();
  ctx.waiting.clear();
}

/** Resolves on the first frame after which `done` holds. */
async function until(ctx: WindowWorld, done: () => boolean): Promise<void> {
  while (!done()) await new Promise<void>((resolve) => ctx.waiting.add(resolve));
}

/** The emulator parses after a frame arrives, so this looks again once it has. */
async function untilScreenShows(ctx: WindowWorld, text: string): Promise<void> {
  for (;;) {
    const seen = ctx.frames;
    await ctx.controller.settled();
    if (ctx.controller.viewportText()?.includes(text)) return;
    await until(ctx, () => ctx.frames > seen);
  }
}

const onCleanup = (ctx: WindowWorld, cleanup: () => unknown) => {
  ctx.cleanups = [...(ctx.cleanups as Array<() => unknown>), cleanup];
};

function gatedClient(ctx: WindowWorld, client: TuiClient): TuiClient {
  return {
    ...client,
    subscribeTerminal: (input, onEvent) =>
      client.subscribeTerminal(input, (event, ack) => {
        record(ctx, input.terminalId, event);
        onEvent(event, (sequence) => {
          if (ctx.stalled) ctx.held = () => ack?.(sequence);
          else ack?.(sequence);
        });
        frameSeen(ctx);
      }),
  };
}

function record(ctx: WindowWorld, terminalId: string, event: TerminalAttachStreamEvent) {
  const events = ctx.received.get(terminalId) ?? [];
  const bytes =
    event.type === "output"
      ? event.data.length
      : event.type === "snapshot" || event.type === "restarted"
        ? event.snapshot.history.length
        : 0;
  events.push({ type: event.type, bytes });
  ctx.received.set(terminalId, events);
  if (event.type === "snapshot" || event.type === "restarted") {
    ctx.shellPid = event.snapshot.pid ?? ctx.shellPid;
  }
}

const RealWebSocket = globalThis.WebSocket;

/** Counts what the shell prints on a socket of its own, which never acknowledges. */
async function listenToShell(ctx: WindowWorld, mint: () => Promise<string>) {
  const socket = new RealWebSocket(await mint());
  onCleanup(ctx, () => socket.close());
  await new Promise<void>((resolve) => {
    socket.onmessage = (message) => {
      const frame = JSON.parse(String(message.data));
      if (frame.t === "hello") {
        const input = { threadId: THREAD_ID, terminalId: ctx.terminalId };
        const shape = { type: "terminal", mc: frame.mc, input };
        socket.send(JSON.stringify({ t: "sub", id: 1, shape, offset: null }));
      } else if (frame.t === "terminal") {
        if (frame.event.type === "output") ctx.printed += frame.event.data.length;
        frameSeen(ctx);
        resolve();
      }
    };
  });
}

/** Sends every socket the client opens through `sockets`, for a scenario that drops them. */
function trackSockets(ctx: WindowWorld) {
  ctx.sockets = [];
  globalThis.WebSocket = class extends RealWebSocket {
    constructor(url: string | URL, protocols?: string | string[]) {
      super(url, protocols);
      ctx.sockets.push(this);
    }
  } as typeof WebSocket;
  return () => {
    globalThis.WebSocket = RealWebSocket;
  };
}

step("a running terminal whose shell prints continuously", async (ctx: WindowWorld) => {
  const mc = await startRealMc();
  ctx.mc = mc;
  onCleanup(ctx, () => mc.stop());
  onCleanup(ctx, trackSockets(ctx));
  Object.assign(ctx, {
    received: new Map(),
    printed: 0,
    stalled: false,
    held: null,
    frames: 0,
    waiting: new Set(),
  });

  const descriptor = await Effect.runPromise(
    fetchRemoteEnvironmentDescriptor({ httpBaseUrl: mc.origin }).pipe(
      Effect.provide(remoteHttpClientLayer(globalThis.fetch)),
    ),
  );
  const mintSocketUrl = makeHttpSocketTicketMinter({
    origin: mc.origin,
    bearerToken: mc.accessToken,
  });
  const real = makeTuiClient(
    buildTuiRuntime({
      origin: mc.origin,
      bearerToken: mc.accessToken,
      mintSocketUrl,
      logPath: NodePath.join(mc.home, "client.log"),
      reconnectDelay: "10 millis",
      environmentId: descriptor.environmentId,
      orchestrationProtocolVersion: descriptor.orchestrationProtocolVersion,
    }),
    mc.origin,
  );
  onCleanup(ctx, () => real.dispose());
  ctx.client = real;

  let focused = false;
  const thread = { threadId: THREAD_ID, title: "Window", cwd: mc.home, worktreePath: null };
  ctx.controller = createTerminalController({
    client: gatedClient(ctx, real),
    store: { setStatus: () => {} } as unknown as Store,
    thread: () => thread,
    width: () => 100,
    rows: () => 24,
    layoutChanged: () => {},
    isFocused: () => focused,
    setFocused: (next) => {
      focused = next;
    },
    copyToClipboard: () => false,
    publish: () => {},
  });
  onCleanup(ctx, async () => {
    for (const id of ctx.received.keys()) {
      await real.terminalClose(THREAD_ID as ThreadId, id).catch(() => {});
    }
  });
  onCleanup(ctx, () => ctx.controller.dispose());
  ctx.controller.open();
  await until(ctx, () => ctx.received.size > 0);
  ctx.terminalId = [...ctx.received.keys()][0]!;
  await listenToShell(ctx, mintSocketUrl);

  // Lines wide enough that the MC's history, capped in lines, outgrows the window.
  ctx.controller.input("while :; do seq -f %040g 1 500; sleep 0.05; done\n");
  // Past the window many times over, so this client's acks are what let it through.
  await until(ctx, () => outputBytes(received(ctx)) >= 4 * LIMIT);
});

step("a client stops acknowledging the output it has received", (ctx: WindowWorld) => {
  ctx.stalled = true;
  ctx.stalledAt = received(ctx).length;
});

step(
  "only a small amount of output waits unacknowledged for that client",
  async (ctx: WindowWorld) => {
    const from = ctx.printed;
    await until(ctx, () => ctx.printed >= from + 3 * LIMIT);
    const sizes = received(ctx)
      .slice(ctx.stalledAt)
      .filter((event) => event.type === "output")
      .map((event) => event.bytes);
    // It was let through until the limit, the event that crossed it included.
    expect(sizes.reduce((sum, size) => sum + size, 0) - (sizes.at(-1) ?? 0)).toBeLessThan(LIMIT);
  },
);

step("the MC stops sending output to that client until it catches up", async (ctx: WindowWorld) => {
  const count = received(ctx).length;
  const from = ctx.printed;
  await until(ctx, () => ctx.printed >= from + 2 * LIMIT);
  expect(received(ctx).slice(count)).toEqual([]);

  ctx.stalled = false;
  ctx.held?.();
  await until(ctx, () =>
    received(ctx)
      .slice(count)
      .some((event) => event.type === "snapshot"),
  );
  // Caught up from a history larger than the window, and on the live output again.
  const snapshot = received(ctx)
    .slice(count)
    .find((event) => event.type === "snapshot")!;
  expect(snapshot.bytes).toBeGreaterThan(LIMIT);
  await until(ctx, () => outputBytes(received(ctx).slice(count)) >= 2 * LIMIT);
});

step("the shell itself keeps running", async (ctx: WindowWorld) => {
  expect(process.kill(ctx.shellPid, 0)).toBe(true);
  const from = ctx.printed;
  await until(ctx, () => ctx.printed > from);
  await ctx.controller.settled();
  expect(ctx.controller.viewportText()).toMatch(/\d/);
});

// --- a terminal off screen -------------------------------------------------------------------

step("the terminal drawer is closed", async (ctx: WindowWorld) => {
  ctx.controller.toggle();
  ctx.stalledAt = received(ctx).length;
});

step("the shell goes on printing with nothing reaching the client", async (ctx: WindowWorld) => {
  const from = ctx.printed;
  await until(ctx, () => ctx.printed >= from + 3 * LIMIT);
  // At most what was on its way when the drawer closed.
  expect(outputBytes(received(ctx).slice(ctx.stalledAt))).toBeLessThan(LIMIT);
  ctx.stalledAt = received(ctx).length;
});

step("the terminal drawer opens again", (ctx: WindowWorld) => {
  ctx.controller.open();
});

step(
  "the client catches up from a snapshot and follows the shell again",
  async (ctx: WindowWorld) => {
    await until(ctx, () =>
      received(ctx)
        .slice(ctx.stalledAt)
        .some((e) => e.type === "snapshot"),
    );
    await until(ctx, () => outputBytes(received(ctx).slice(ctx.stalledAt)) >= 2 * LIMIT);
    await ctx.controller.settled();
    expect(ctx.controller.viewportText()).toMatch(/\d/);
  },
);

step("another terminal opens in front of it", (ctx: WindowWorld) => {
  ctx.stalledAt = received(ctx).length;
  ctx.controller.newTab();
});

step("the terminal behind it goes on taking the shell's output", async (ctx: WindowWorld) => {
  await until(ctx, () => outputBytes(received(ctx).slice(ctx.stalledAt)) >= 4 * LIMIT);
});

// --- a restart and a dropped connection ------------------------------------------------------

step("the terminal is restarted", (ctx: WindowWorld) => {
  ctx.stalledAt = received(ctx).length;
  ctx.controller.restart();
});

step("the held back client shows the new shell", async (ctx: WindowWorld) => {
  await until(ctx, () =>
    received(ctx)
      .slice(ctx.stalledAt)
      .some((e) => e.type === "restarted"),
  );
  ctx.controller.input("echo fresh-$((40 + 2))\n");
  // The answer, not the line typed: the shell works it out.
  await untilScreenShows(ctx, "fresh-42");
});

step("the client's connection drops and it stops being held back", (ctx: WindowWorld) => {
  ctx.stalledAt = received(ctx).length;
  ctx.stalled = false;
  // What it could not say on the old connection is gone with it.
  ctx.held = null;
  for (const socket of ctx.sockets) socket.close();
});
