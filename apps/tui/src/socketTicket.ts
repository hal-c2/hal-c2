import { resolveRemoteWebSocketConnectionUrl } from "@hal-c2/client-runtime/authorization";
import { remoteHttpClientLayer } from "@hal-c2/client-runtime/rpc";
import * as Effect from "effect/Effect";

/**
 * Websocket URLs come from the `hal-c2 tui` launcher over the Node IPC channel: the
 * client sends `{ type: "mintSocketUrl", id }` and the launcher answers
 * `{ type: "socketUrl", id, url }` with a freshly ticketed URL. The entry wires
 * `receive` to `process.on("message")` and `disconnect` to
 * `process.on("disconnect")`, so a silent or vanished launcher never leaves the
 * reconnect loop waiting forever.
 */
export const SOCKET_TICKET_TIMEOUT_MS = 10_000;

interface SocketUrlReply {
  readonly type: "socketUrl";
  readonly id: number;
  readonly url: string | null;
  readonly error?: string;
}

export interface SocketTicketTimers {
  readonly set: (run: () => void, ms: number) => unknown;
  readonly clear: (handle: unknown) => void;
}

const DEFAULT_TIMERS: SocketTicketTimers = {
  set: (run, ms) => {
    const timer = setTimeout(run, ms);
    timer.unref?.();
    return timer;
  },
  clear: (handle) => clearTimeout(handle as ReturnType<typeof setTimeout>),
};

export function makeSocketTicketMinter(input: {
  /** `process.send`; undefined when there is no launcher on the other end. */
  readonly send: ((message: unknown) => boolean) | undefined;
  readonly timers?: SocketTicketTimers;
}) {
  const timers = input.timers ?? DEFAULT_TIMERS;
  let nextRequestId = 1;
  const pending = new Map<number, { resolve: (url: string) => void; reject: (e: Error) => void }>();

  const mint = (): Promise<string> =>
    new Promise<string>((resolve, reject) => {
      const send = input.send;
      if (!send) {
        reject(new Error("no IPC channel to the hal-c2 parent process"));
        return;
      }
      const id = nextRequestId++;
      const timer = timers.set(() => {
        if (pending.delete(id)) reject(new Error("timed out minting a websocket url"));
      }, SOCKET_TICKET_TIMEOUT_MS);
      pending.set(id, {
        resolve: (url) => {
          timers.clear(timer);
          resolve(url);
        },
        reject: (error) => {
          timers.clear(timer);
          reject(error);
        },
      });
      try {
        send({ type: "mintSocketUrl", id });
      } catch (error) {
        if (pending.delete(id)) {
          timers.clear(timer);
          reject(error instanceof Error ? error : new Error(String(error)));
        }
      }
    });

  return {
    mint,
    /** A message from the launcher; anything but a `socketUrl` reply is ignored. */
    receive: (raw: unknown): void => {
      if (typeof raw !== "object" || raw === null) return;
      const message = raw as Partial<SocketUrlReply>;
      if (message.type !== "socketUrl" || typeof message.id !== "number") return;
      const entry = pending.get(message.id);
      if (!entry) return;
      pending.delete(message.id);
      if (typeof message.url === "string") entry.resolve(message.url);
      else entry.reject(new Error(message.error ?? "failed to mint socket url"));
    },
    /** The launcher went away: settle every outstanding request now. */
    disconnect: (): void => {
      for (const entry of pending.values()) {
        entry.reject(new Error("hal-c2 parent IPC channel closed"));
      }
      pending.clear();
    },
  };
}

/**
 * Without a launcher the client buys each websocket ticket itself:
 * `POST /api/auth/websocket-ticket` with its bearer, answered with a
 * `ws(s)://…/ws?wsTicket=…` URL that carries nothing else.
 */
export function makeHttpSocketTicketMinter(input: {
  readonly origin: string;
  readonly bearerToken: string;
  readonly fetch?: typeof globalThis.fetch;
}): () => Promise<string> {
  const wsBaseUrl = new URL(input.origin);
  wsBaseUrl.protocol = wsBaseUrl.protocol === "https:" ? "wss:" : "ws:";
  return () =>
    Effect.runPromise(
      resolveRemoteWebSocketConnectionUrl({
        wsBaseUrl: wsBaseUrl.toString(),
        httpBaseUrl: input.origin,
        bearerToken: input.bearerToken,
      }).pipe(Effect.provide(remoteHttpClientLayer(input.fetch ?? globalThis.fetch))),
    );
}
