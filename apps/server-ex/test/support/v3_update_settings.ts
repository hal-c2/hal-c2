// Changes one setting through the protocol 3 client adapter (makeV3Session) against a
// running MC.
// Usage: bun v3_update_settings.ts <ws url> <environment id> <settings patch as JSON>
import { ClusterSocket } from "../../../../packages/client-runtime/src/v3/clusterSocket.ts";
import { makeV3Session } from "../../../../packages/client-runtime/src/v3/session.ts";

// effect resolves from the client runtime, so it is the instance the adapter uses.
const runtime = new URL("../../../../packages/client-runtime/src/", import.meta.url).pathname;
const Effect = await import(Bun.resolveSync("effect/Effect", runtime));

const [url, environmentId, patch] = process.argv.slice(2);
const socket = new ClusterSocket({ url: url!, reconnect: false });
const session = await Effect.runPromise(makeV3Session({ socket, environmentId: environmentId! }));
const update = (session.client as unknown as Record<string, (input: unknown) => unknown>)[
  "server.updateSettings"
]!;
await Effect.runPromise(update({ patch: JSON.parse(patch!) }));
socket.close();
process.exit(0);
