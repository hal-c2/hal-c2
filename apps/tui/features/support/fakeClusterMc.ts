// A fake protocol-3 MC fronting a cluster, for connections/connection-health.feature:
// the real client (`makeTuiClient`, joined by `makeClusterClient` as the terminal
// does) connects to it, so its one-socket cluster, its stream resumes and its shell
// `have` are what run. Each member is an MC with one project and its threads; the
// shell answers a `have` as the MC does (`HalC2.Shell.subscribe`): only what the
// client lacks, every row of an MC it marks `reset`. The fake records every socket
// and every `sub`, and can hold the shell or a thread's snapshot back to play a slow
// MC. The real MC is covered by `mix features`.
import type { ServerWebSocket } from "bun";

import {
  OrchestrationProjectShell,
  OrchestrationV2AppThread,
  OrchestrationV2ThreadShell,
} from "@hal-c2/contracts";
import * as Schema from "effect/Schema";

import {
  v2Project,
  v2Projection,
  v2ThreadShell,
} from "../../../../packages/client-runtime/src/state/orchestrationV2TestFixtures.ts";

type Entity = Record<string, unknown>;

const encodeProject = Schema.encodeSync(Schema.toCodecJson(OrchestrationProjectShell));
const encodeThreadShell = Schema.encodeSync(Schema.toCodecJson(OrchestrationV2ThreadShell));
const encodeThread = Schema.encodeSync(Schema.toCodecJson(OrchestrationV2AppThread));

const HANDLE = "fake-cluster-log";
/** Where every thread's log stands; a real one is long past its start. */
const HEAD = 100;

export interface FakeMember {
  readonly environmentId: string;
  readonly mc: string;
  readonly label: string;
  /** Thread ids and titles, all in the member's one project. */
  readonly threads: ReadonlyArray<{ readonly id: string; readonly title: string }>;
}

/** A `sub` the client sent: on which socket (1-based), for what, from where. */
export interface ClusterSub {
  readonly socket: number;
  readonly shape: Entity;
  readonly offset: number | null;
  readonly handle: string | undefined;
  readonly have: Entity | undefined;
  /** For the shell: the rows its answer carried. */
  answeredRows?: number;
}

export interface FakeClusterMc {
  readonly origin: string;
  /** The first member is the MC the client connects to. */
  readonly members: ReadonlyArray<FakeMember>;
  readonly subs: ClusterSub[];
  /** Sockets opened, and socket URLs minted. */
  readonly sockets: () => number;
  readonly minted: () => number;
  mintSocketUrl(): Promise<string>;
  /** The sockets open now, and the pings the client sent. */
  readonly open: () => number;
  readonly pings: () => number;
  /** Hold every shell answer, or a thread's snapshot, back until `release()`. */
  holdShell(): void;
  holdThread(threadId: string): void;
  release(): void;
  /** Close every socket; the client may connect again. */
  drop(): void;
  until(check: () => boolean, what: string): Promise<void>;
  stop(): void;
}

const UNTIL_TIMEOUT_MS = 10_000;

/** The smallest config a protocol-3 client decodes. */
const config = (environmentId: string, label: string) => ({
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
    label,
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

const projectId = (member: FakeMember) => `project-${member.environmentId}`;

function shellRows(member: FakeMember): Array<readonly [string, string, string, Entity]> {
  const project = encodeProject({ ...v2Project, id: projectId(member) as never }) as Entity;
  return [
    [member.mc, String(project.id), "project", project],
    ...member.threads.map(({ id, title }): readonly [string, string, string, Entity] => [
      member.mc,
      id,
      "thread",
      encodeThreadShell({
        ...v2ThreadShell,
        id: id as never,
        projectId: projectId(member) as never,
        title,
      }) as Entity,
    ]),
  ];
}

function threadRow(
  member: FakeMember,
  id: string,
  title: string,
): readonly [string, string, Entity] {
  const thread = encodeThread({
    ...v2Projection.thread,
    id: id as never,
    projectId: projectId(member) as never,
    title,
  }) as Entity;
  return ["thread", id, thread];
}

interface SocketData {
  readonly number: number;
}

export function startFakeClusterMc(members: ReadonlyArray<FakeMember>): FakeClusterMc {
  const home = members[0]!;
  const subs: ClusterSub[] = [];
  const sockets = new Set<ServerWebSocket<SocketData>>();
  let opened = 0;
  let minted = 0;
  let pings = 0;
  let holdShell = false;
  const heldThreads = new Set<string>();
  const held: Array<() => void> = [];
  const waiters = new Set<() => void>();
  const changed = () => {
    for (const waiter of waiters) waiter();
  };
  const send = (ws: ServerWebSocket<SocketData>, frame: unknown) => ws.send(JSON.stringify(frame));
  // Every MC's rows stand at one revision of one epoch: nothing changes while the client is away.
  const at = (member: FakeMember) => [`epoch-${member.mc}`, 1] as const;

  const answerShell = (ws: ServerWebSocket<SocketData>, id: number, sub: ClusterSub) => {
    const have = (sub.have ?? {}) as Record<string, unknown>;
    const mcs = members.map((member) => {
      const [epoch, rev] = at(member);
      const held = have[member.mc];
      const current = Array.isArray(held) && held[0] === epoch && held[1] === rev;
      return {
        member,
        entry: {
          mc: member.mc,
          online: true,
          environment: member.environmentId,
          epoch,
          rev,
          reset: !current,
        },
      };
    });
    const rows = mcs.flatMap(({ member, entry }) => (entry.reset ? shellRows(member) : []));
    sub.answeredRows = rows.length;
    send(ws, { t: "shell", id, mcs: mcs.map(({ entry }) => entry), rows });
  };

  const answerStream = (ws: ServerWebSocket<SocketData>, id: number, sub: ClusterSub) => {
    const member = members.find((entry) => entry.mc === sub.shape.mc);
    const thread = member?.threads.find((entry) => entry.id === sub.shape.stream);
    if (member === undefined || thread === undefined) {
      send(ws, { t: "error", id, reason: "unknown stream" });
      return;
    }
    if (sub.offset !== null && sub.handle === HANDLE) {
      // Nothing happened while the client was away: it is caught up at once.
      send(ws, { t: "live", id, offset: sub.offset, handle: HANDLE });
      return;
    }
    send(ws, {
      t: "snapshot",
      id,
      rows: [threadRow(member, thread.id, thread.title)],
      part: 0,
      done: true,
      offset: HEAD,
      at: Date.now(),
      floor: null,
      handle: HANDLE,
    });
    send(ws, { t: "live", id, offset: HEAD, handle: HANDLE });
  };

  const clusterStatus = () => ({
    clustered: true,
    id: home.environmentId,
    label: home.label,
    mc: home.mc,
    addresses: [],
    members: members.slice(1).map(({ environmentId, label }) => ({
      id: environmentId,
      label,
      addresses: [],
      connected: true,
    })),
  });

  const server = Bun.serve<SocketData>({
    hostname: "127.0.0.1",
    port: 0,
    idleTimeout: 0,
    fetch: (request, bun) => {
      const url = new URL(request.url);
      if (url.pathname === "/ws" && bun.upgrade(request, { data: { number: ++opened } })) {
        return undefined;
      }
      return new Response("not found", { status: 404 });
    },
    websocket: {
      open: (ws) => {
        sockets.add(ws);
        send(ws, { t: "hello", mc: home.mc, protocol: 3, environment: home.environmentId });
        changed();
      },
      close: (ws) => {
        sockets.delete(ws);
        changed();
      },
      message: (ws, raw) => {
        const frame = JSON.parse(String(raw)) as Entity & { t: string; id?: number };
        if (frame.t === "ping") {
          pings++;
          send(ws, { t: "pong" });
          changed();
        }
        if (frame.t === "rpc") {
          if (frame.method === "cluster.status") {
            send(ws, { t: "rpc.result", id: frame.id, result: clusterStatus() });
          } else {
            send(ws, { t: "rpc.error", id: frame.id, error: "unsupported" });
          }
        }
        if (frame.t !== "sub" || typeof frame.id !== "number") return;
        const id = frame.id;
        const shape = frame.shape as Entity;
        const sub: ClusterSub = {
          socket: ws.data.number,
          shape,
          offset: typeof frame.offset === "number" ? frame.offset : null,
          handle: typeof frame.handle === "string" ? frame.handle : undefined,
          have: frame.have as Entity | undefined,
        };
        subs.push(sub);
        if (shape.type === "config") {
          const member = members.find((entry) => entry.environmentId === shape.environment);
          if (member === undefined) send(ws, { t: "error", id, reason: "unknown environment" });
          else
            send(ws, {
              t: "config",
              id,
              mc: member.mc,
              config: config(member.environmentId, member.label),
            });
        } else if (shape.type === "shell") {
          const answer = () => answerShell(ws, id, sub);
          if (holdShell) held.push(answer);
          else answer();
        } else if (shape.type === "stream") {
          const answer = () => answerStream(ws, id, sub);
          if (heldThreads.has(String(shape.stream))) held.push(answer);
          else answer();
        }
        changed();
      },
    },
  });

  return {
    origin: `http://127.0.0.1:${server.port}`,
    members,
    subs,
    sockets: () => opened,
    minted: () => minted,
    open: () => sockets.size,
    pings: () => pings,
    mintSocketUrl: async () => `ws://127.0.0.1:${server.port}/ws?wsTicket=fake-${++minted}`,
    holdShell: () => {
      holdShell = true;
    },
    holdThread: (threadId) => {
      heldThreads.add(threadId);
    },
    release: () => {
      holdShell = false;
      heldThreads.clear();
      for (const answer of held.splice(0)) answer();
    },
    drop: () => {
      for (const ws of sockets) ws.close(1012, "MC restarting");
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
