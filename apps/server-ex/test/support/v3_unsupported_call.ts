// Calls one RPC through the protocol 3 client adapter (makeV3Session) against a
// running node, recording every frame the adapter sends while the call runs.
// Usage: bun v3_unsupported_call.ts <ws url> <environment id> <method>
// Prints {"error": <message>, "sent": [<frames sent during the call>]} as JSON.
import { ClusterSocket } from "../../../../packages/client-runtime/src/v3/clusterSocket.ts";
import { makeV3Session } from "../../../../packages/client-runtime/src/v3/session.ts";

// effect resolves from the client runtime, so it is the instance the adapter uses.
const runtime = new URL("../../../../packages/client-runtime/src/", import.meta.url).pathname;
const Effect = await import(Bun.resolveSync("effect/Effect", runtime));

const [url, environmentId, method] = process.argv.slice(2);
const sent: Array<unknown> = [];
let recording = false;

const socket = new ClusterSocket({
  url: url!,
  reconnect: false,
  createSocket: (target) => {
    const ws = new WebSocket(target);
    const send = ws.send.bind(ws);
    ws.send = (data) => {
      if (recording) sent.push(JSON.parse(String(data)));
      send(data);
    };
    return ws;
  },
});

const session = await Effect.runPromise(makeV3Session({ socket, environmentId: environmentId! }));
const call = (session.client as unknown as Record<string, (input: unknown) => unknown>)[method!]!;

recording = true;
const error: Error = await Effect.runPromise(Effect.flip(call({})));
recording = false;

const reason = (error as { reason?: { message?: string } }).reason;
console.log(JSON.stringify({ error: reason?.message ?? error.message, sent }));
socket.close();
process.exit(0);
