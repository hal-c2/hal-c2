// A fake protocol-3 MC for launch.feature: just enough of the MC's HTTP
// and socket surface for the client to find it, sign in and open its session.
//
// HTTP: the environment descriptor, `/oauth/token` (a pairing token for a bearer
// session), `/api/auth/session` and `/api/auth/websocket-ticket`, which accept the
// MC's access token or a session's bearer. Socket: `/ws?wsTicket=` (single use),
// a `hello`, a `config` frame for any config subscription, an empty `shell`, and
// `unsupported` for every RPC. It records what the client did so steps can check
// it, and can drop every socket. The real MC is covered by `mix features`
// (mc/platform/*.feature).
import type { Server, ServerWebSocket } from "bun";

export const FAKE_MC_ENVIRONMENT_ID = "fake-mc-environment";
const MC_NAME = "fake@mc";

const AUTH = {
  policy: "loopback-browser",
  bootstrapMethods: ["one-time-token"],
  sessionMethods: ["bearer-access-token"],
  sessionCookieName: "hal_c2_session",
};
const SCOPES = ["orchestration:read", "orchestration:operate", "terminal:operate"];

function descriptor(origin: string) {
  return {
    environmentId: FAKE_MC_ENVIRONMENT_ID,
    label: `Fake MC ${new URL(origin).port}`,
    platform: { os: "linux", arch: "x64" },
    serverVersion: "0.0.0",
    orchestrationProtocolVersion: 3,
    capabilities: {},
  };
}

/** The smallest config a protocol-3 client decodes (captured from a real MC, trimmed). */
function config(origin: string) {
  return {
    auth: AUTH,
    availableEditors: [],
    cwd: "/tmp/fake-mc",
    environment: descriptor(origin),
    issues: [],
    keybindingRules: [],
    keybindings: [],
    keybindingsConfigPath: "/tmp/fake-mc/keybindings.json",
    observability: {
      localTracingEnabled: false,
      logsDirectoryPath: "/tmp/fake-mc/logs",
      otlpLogsEnabled: false,
      otlpMetricsEnabled: false,
      otlpTracesEnabled: false,
    },
    providers: [],
    settings: {},
  };
}

export interface FakeSession {
  readonly label: string;
  readonly bearerToken: string;
  revoked: boolean;
}

/** A socket the client opened with a ticket, and the shapes it subscribed. */
export interface FakeSocket {
  readonly url: string;
  readonly ticket: string;
  readonly shapes: Array<Record<string, unknown>>;
}

export interface FakeMc {
  readonly origin: string;
  readonly accessToken: string;
  readonly sessions: FakeSession[];
  /** Bearers each ticket request carried, in order. */
  readonly ticketBearers: string[];
  readonly sockets: FakeSocket[];
  /** Pairing tokens the MC still accepts (each works once). */
  readonly pairingTokens: Set<string>;
  readonly tokenExchanges: number;
  /** Close every open socket, as an MC restart or network drop would. */
  dropConnections(): void;
  /** Resolves once `check` holds, re-checked whenever the client does something. */
  until(check: () => boolean, what: string): Promise<void>;
  stop(): void;
}

/** How long the client gets to do what a step waits for; failing past it is a bug. */
const UNTIL_TIMEOUT_MS = 10_000;

interface SocketData {
  readonly record: FakeSocket;
}

function bearer(request: Request): string | null {
  const header = request.headers.get("authorization") ?? "";
  return header.startsWith("Bearer ") ? header.slice("Bearer ".length).trim() : null;
}

async function formOrJson(request: Request): Promise<Record<string, string>> {
  const type = request.headers.get("content-type") ?? "";
  if (type.includes("application/json")) return (await request.json()) as Record<string, string>;
  return Object.fromEntries(new URLSearchParams(await request.text()));
}

export function startFakeMc(options: { accessToken?: string; pairingToken?: string } = {}): FakeMc {
  const accessToken = options.accessToken ?? "fake-mc-access-token";
  const sessions: FakeSession[] = [];
  const ticketBearers: string[] = [];
  const sockets: FakeSocket[] = [];
  const pairingTokens = new Set(options.pairingToken ? [options.pairingToken] : []);
  const tickets = new Set<string>();
  const open = new Set<ServerWebSocket<SocketData>>();
  let tokenExchanges = 0;
  let nextId = 1;
  const waiters = new Set<() => void>();
  const changed = () => {
    for (const waiter of waiters) waiter();
  };

  const authenticated = (token: string | null) =>
    token !== null &&
    (token === accessToken || sessions.some((s) => s.bearerToken === token && !s.revoked));

  const handle = async (
    request: Request,
    bun: Server<SocketData>,
  ): Promise<Response | undefined> => {
    const url = new URL(request.url);
    const origin = `http://127.0.0.1:${url.port}`;
    switch (url.pathname) {
      case "/.well-known/hal-c2/environment":
        return Response.json(descriptor(origin));
      case "/oauth/token": {
        tokenExchanges++;
        const body = await formOrJson(request);
        const token = body.subject_token ?? "";
        if (!pairingTokens.delete(token)) {
          return Response.json({ error: "invalid_grant" }, { status: 400 });
        }
        const session = {
          label: body.client_label ?? "",
          bearerToken: `fake-session-${nextId++}`,
          revoked: false,
        };
        sessions.push(session);
        return Response.json({
          access_token: session.bearerToken,
          issued_token_type: "urn:ietf:params:oauth:token-type:access_token",
          token_type: "Bearer",
          expires_in: 30 * 24 * 60 * 60,
          scope: SCOPES.join(" "),
        });
      }
      case "/api/auth/session":
        return Response.json(
          authenticated(bearer(request))
            ? {
                authenticated: true,
                auth: AUTH,
                scopes: SCOPES,
                sessionMethod: "bearer-access-token",
                expiresAt: "9999-12-31T23:59:59.999Z",
              }
            : { authenticated: false, auth: AUTH },
        );
      case "/api/auth/websocket-ticket": {
        const token = bearer(request);
        ticketBearers.push(token ?? "");
        if (!authenticated(token)) {
          return Response.json(
            { _tag: "EnvironmentAuthInvalidError", reason: "invalid_credential" },
            { status: 401 },
          );
        }
        const ticket = `fake-ticket-${nextId++}`;
        tickets.add(ticket);
        return Response.json({
          ticket,
          expiresAt: new Date(Date.now() + 5 * 60_000).toISOString(),
        });
      }
      case "/ws": {
        const ticket = url.searchParams.get("wsTicket") ?? "";
        if (!tickets.delete(ticket)) return new Response("unauthorized", { status: 401 });
        const record: FakeSocket = { url: request.url, ticket, shapes: [] };
        sockets.push(record);
        if (bun.upgrade(request, { data: { record } })) return undefined;
        return new Response("upgrade failed", { status: 400 });
      }
      default:
        return new Response("not found", { status: 404 });
    }
  };

  const server = Bun.serve<SocketData>({
    hostname: "127.0.0.1",
    port: 0,
    fetch: (request, bun) => handle(request, bun).finally(changed),
    websocket: {
      open: (ws) => {
        open.add(ws);
        changed();
        ws.send(JSON.stringify({ t: "hello", mc: MC_NAME, protocol: 3 }));
      },
      close: (ws) => {
        open.delete(ws);
      },
      message: (ws, raw) => {
        const frame = JSON.parse(String(raw)) as {
          t: string;
          id?: number;
          shape?: Record<string, unknown>;
        };
        const origin = `http://127.0.0.1:${server.port}`;
        if (frame.t === "ping") ws.send(JSON.stringify({ t: "pong" }));
        if (frame.t === "rpc") {
          ws.send(JSON.stringify({ t: "rpc.error", id: frame.id, error: "unsupported" }));
        }
        if (frame.t !== "sub" || !frame.shape) return;
        ws.data.record.shapes.push(frame.shape);
        changed();
        if (frame.shape.type === "config") {
          ws.send(
            JSON.stringify({ t: "config", id: frame.id, mc: MC_NAME, config: config(origin) }),
          );
        }
        if (frame.shape.type === "shell") {
          ws.send(JSON.stringify({ t: "shell", id: frame.id, rows: [], mcs: [] }));
        }
      },
    },
  });

  return {
    origin: `http://127.0.0.1:${server.port}`,
    accessToken,
    sessions,
    ticketBearers,
    sockets,
    pairingTokens,
    get tokenExchanges() {
      return tokenExchanges;
    },
    dropConnections: () => {
      for (const ws of open) ws.close(1012, "MC restarting");
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
