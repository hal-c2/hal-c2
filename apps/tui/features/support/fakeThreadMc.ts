// A fake protocol-3 MC serving one thread stream, for the streaming catch-up
// scenarios (timeline/streaming.feature): the real client (`makeTuiClient`)
// connects to it, so its resume, resync and apply-once logic is what runs.
//
// The thread is a list of entity rows plus an event log. A `sub` without an
// offset gets a snapshot of the rows with every event applied; one with an
// offset gets the events after it. Steps append events, drop the sockets, keep
// the MC unreachable (no socket URL is minted), hold events back, cut a
// catch-up after its first frame, send a `resync`, and take the thread's MC out
// of the cluster and back. It records each stream `sub` so steps can check what
// the client asked for and what it was sent. The real MC is covered by
// `mix features` (mc/streams/*.feature).
import type { Server, ServerWebSocket } from "bun";

import { applyPatch, type Patch } from "../../../../packages/client-runtime/src/v3/patch.ts";

type Entity = Record<string, unknown>;
export type ThreadRow = readonly [kind: string, id: string, entity: Entity];
export type ThreadEvent = readonly [
  seq: number,
  kind: string,
  id: string,
  patch: Patch,
  at: number,
];

const HANDLE = "fake-log-1";

/** The smallest config a protocol-3 client decodes. */
const config = (environmentId: string) => ({
  auth: {
    policy: "loopback-browser",
    bootstrapMethods: ["one-time-token"],
    sessionMethods: ["bearer-access-token"],
    sessionCookieName: "hal_c2_session",
  },
  availableEditors: [],
  cwd: "/srv/fake-mc",
  environment: {
    environmentId,
    label: environmentId,
    platform: { os: "linux", arch: "x64" },
    serverVersion: "0.0.0",
    orchestrationProtocolVersion: 3,
    capabilities: {},
  },
  issues: [],
  keybindingRules: [],
  keybindings: [],
  keybindingsConfigPath: "/srv/fake-mc/keybindings.json",
  observability: {
    localTracingEnabled: false,
    logsDirectoryPath: "/srv/fake-mc/logs",
    otlpLogsEnabled: false,
    otlpMetricsEnabled: false,
    otlpTracesEnabled: false,
  },
  providers: [],
  settings: {},
});

/** A stream `sub` the client sent, and how the MC answered it. */
export interface StreamSub {
  readonly offset: number | null;
  readonly handle: string | undefined;
  /** "snapshot": the whole thread; "events": what came after the offset; "refused". */
  answer: "snapshot" | "events" | "refused";
  /** The events this sub was sent, by sequence. */
  readonly sent: number[];
}

interface Live {
  readonly ws: ServerWebSocket<SocketData>;
  readonly id: number;
  readonly sub: StreamSub;
  /** The newest sequence this subscription was sent. */
  at: number;
}

interface SocketData {
  readonly shells: number[];
}

export interface FakeThreadMcOptions {
  readonly threadId: string;
  readonly rows: ReadonlyArray<ThreadRow>;
  /** The MC the thread lives on, as `config` names it for `environmentId`. */
  readonly environmentId: string;
  readonly mc: string;
}

export interface FakeThreadMc {
  readonly origin: string;
  readonly environmentId: string;
  readonly subs: StreamSub[];
  /** The newest sequence in the log. */
  readonly head: number;
  /** A socket URL, or a failure while the MC cannot be reached. */
  mintSocketUrl(): Promise<string>;
  /**
   * Log events (`[kind, id, patch]`) and send them to the subscriptions that are
   * live, unless `withhold`: then they are only logged, as a client too slow to read them.
   */
  append(events: ReadonlyArray<readonly [string, string, Patch]>, withhold?: boolean): void;
  /** Close every socket; `unreachable` keeps the client from connecting again. */
  drop(unreachable?: boolean): void;
  reachable(): void;
  /** The next resumed sub is sent its first event, and nothing more until the sockets drop. */
  cutNextCatchUp(): void;
  /** Tell each live stream subscription to resync from what it was sent. */
  resync(): void;
  /** The thread's MC leaves the cluster (false) or rejoins it (true). */
  setOnline(online: boolean): void;
  until(check: () => boolean, what: string): Promise<void>;
  stop(): void;
}

const UNTIL_TIMEOUT_MS = 10_000;

export function startFakeThreadMc(options: FakeThreadMcOptions): FakeThreadMc {
  const log: ThreadEvent[] = [];
  const subs: StreamSub[] = [];
  const live = new Set<Live>();
  const sockets = new Set<ServerWebSocket<SocketData>>();
  let unreachable = false;
  let online = true;
  let cutNext = false;
  let ticket = 0;
  const waiters = new Set<() => void>();
  const changed = () => {
    for (const waiter of waiters) waiter();
  };
  // A real MC's log is long past its start by the time a client opens the thread.
  const head = () => log.at(-1)?.[0] ?? 100;
  const send = (ws: ServerWebSocket<SocketData>, frame: unknown) => ws.send(JSON.stringify(frame));

  const snapshotRows = (): ThreadRow[] => {
    const entities = new Map<string, ThreadRow>();
    for (const row of options.rows) entities.set(`${row[0]}\u0000${row[1]}`, row);
    for (const [, kind, id, patch] of log) {
      const key = `${kind}\u0000${id}`;
      const next = applyPatch(entities.get(key)?.[2], patch);
      if (next === null) entities.delete(key);
      else entities.set(key, [kind, id, next]);
    }
    return [...entities.values()];
  };

  const sendEvents = (entry: Live, events: ReadonlyArray<ThreadEvent>) => {
    if (events.length === 0) return;
    entry.at = events.at(-1)![0];
    entry.sub.sent.push(...events.map(([seq]) => seq));
    send(entry.ws, { t: "events", id: entry.id, offset: entry.at, events });
  };

  const subscribeStream = (ws: ServerWebSocket<SocketData>, id: number, frame: Entity) => {
    const offset = typeof frame.offset === "number" ? frame.offset : null;
    const handle = typeof frame.handle === "string" ? frame.handle : undefined;
    const resumes = offset !== null && handle === HANDLE && offset <= head();
    const sub: StreamSub = { offset, handle, answer: resumes ? "events" : "snapshot", sent: [] };
    subs.push(sub);
    for (const entry of live) if (entry.ws === ws && entry.id === id) live.delete(entry);
    if (!online) {
      sub.answer = "refused";
      send(ws, { t: "error", id, reason: "unknown MC" });
      return;
    }
    const entry: Live = { ws, id, sub, at: resumes ? offset : head() };
    if (!resumes) {
      send(ws, {
        t: "snapshot",
        id,
        rows: snapshotRows(),
        part: 0,
        done: true,
        offset: head(),
        at: Date.now(),
        floor: null,
        handle: HANDLE,
      });
    }
    const missing = log.filter(([seq]) => seq > entry.at);
    if (resumes && cutNext) {
      // Part of the catch-up reaches the client, then nothing until the sockets drop.
      cutNext = false;
      sendEvents(entry, missing.slice(0, 1));
      return;
    }
    sendEvents(entry, missing);
    send(ws, { t: "live", id, offset: entry.at });
    live.add(entry);
  };

  const server = Bun.serve<SocketData>({
    hostname: "127.0.0.1",
    port: 0,
    idleTimeout: 0,
    fetch: (request, bun) => {
      const url = new URL(request.url);
      if (url.pathname === "/ws" && bun.upgrade(request, { data: { shells: [] } })) {
        return undefined;
      }
      return new Response("not found", { status: 404 });
    },
    websocket: {
      open: (ws) => {
        sockets.add(ws);
        send(ws, { t: "hello", mc: "home@fake", protocol: 3 });
        changed();
      },
      close: (ws) => {
        sockets.delete(ws);
        for (const entry of live) if (entry.ws === ws) live.delete(entry);
        changed();
      },
      message: (ws, raw) => {
        const frame = JSON.parse(String(raw)) as Entity & { t: string; id?: number };
        if (frame.t === "ping") send(ws, { t: "pong" });
        if (frame.t === "rpc") send(ws, { t: "rpc.error", id: frame.id, error: "unsupported" });
        if (frame.t === "unsub") {
          for (const entry of live)
            if (entry.ws === ws && entry.id === frame.id) live.delete(entry);
        }
        if (frame.t !== "sub" || typeof frame.id !== "number") return;
        const shape = frame.shape as Entity;
        if (shape.type === "config") {
          const environment = String(shape.environment ?? options.environmentId);
          const mc = environment === options.environmentId ? options.mc : "home@fake";
          send(ws, { t: "config", id: frame.id, mc, config: config(environment) });
        } else if (shape.type === "shell") {
          ws.data.shells.push(frame.id);
          send(ws, { t: "shell", id: frame.id, rows: [], mcs: [] });
        } else if (shape.type === "stream" && shape.stream === options.threadId) {
          subscribeStream(ws, frame.id, frame);
        }
        changed();
      },
    },
  });
  const origin = `http://127.0.0.1:${server.port}`;

  return {
    origin,
    environmentId: options.environmentId,
    subs,
    get head() {
      return head();
    },
    mintSocketUrl: async () => {
      if (unreachable) throw new Error("the MC cannot be reached");
      return `ws://127.0.0.1:${server.port}/ws?wsTicket=fake-${++ticket}`;
    },
    append: (events, withhold = false) => {
      const at = Date.now();
      const logged = events.map(([kind, id, patch], index): ThreadEvent => {
        return [head() + index + 1, kind, id, patch, at];
      });
      log.push(...logged);
      if (withhold) return;
      for (const entry of live) sendEvents(entry, logged);
    },
    drop: (keepAway = false) => {
      unreachable = keepAway;
      for (const ws of sockets) ws.close(1012, "MC restarting");
    },
    reachable: () => {
      unreachable = false;
    },
    cutNextCatchUp: () => {
      cutNext = true;
    },
    resync: () => {
      for (const entry of [...live]) {
        live.delete(entry);
        send(entry.ws, { t: "resync", id: entry.id, offset: entry.at });
      }
    },
    setOnline: (next) => {
      online = next;
      if (!next) {
        for (const entry of [...live]) {
          live.delete(entry);
          send(entry.ws, { t: "error", id: entry.id, reason: "unknown MC" });
        }
      }
      for (const ws of sockets) {
        for (const id of ws.data.shells) {
          send(ws, { t: "shell.mc", id, mc: options.mc, online: next });
        }
      }
    },
    until: (check, what) =>
      new Promise<void>((resolve, reject) => {
        const timer = setTimeout(() => {
          waiters.delete(waiter);
          reject(new Error(`the fake MC timed out waiting for ${what}`));
        }, UNTIL_TIMEOUT_MS);
        const waiter = () => {
          if (!check()) return;
          clearTimeout(timer);
          waiters.delete(waiter);
          resolve();
        };
        waiters.add(waiter);
        waiter();
      }),
    stop: () => server.stop(true),
  };
}
