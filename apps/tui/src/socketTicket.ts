import { resolveRemoteWebSocketConnectionUrl } from "@hal-c2/client-runtime/authorization";
import { remoteHttpClientLayer } from "@hal-c2/client-runtime/rpc";
import * as Effect from "effect/Effect";

/**
 * The client buys each websocket ticket itself: `POST /api/auth/websocket-ticket`
 * with its bearer, answered with a `ws(s)://…/ws?wsTicket=…` URL that carries
 * nothing else. The supervisor calls it again on every reconnect.
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
