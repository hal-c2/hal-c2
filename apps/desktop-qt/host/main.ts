// @effect-diagnostics nodeBuiltinImport:off globalTimers:off - process launcher, deliberately Effect-free.
/**
 * Desktop host for the Qt shell.
 *
 * Spawned by hal-c2-qt (see src/BackendProcess.cpp). Starts the desktop app's
 * own Elixir node (elixirNode.ts) and announces where the shell's client
 * connects. With `--attach=<url>` it starts no node and pairs the shell with the
 * node a pairing link names instead.
 *
 * Arguments: `--base-dir=<HAL-C2 home>` (the node's home), `--attach=<url>`.
 *
 * Protocol (stdout, newline-delimited JSON):
 *   {"type":"ready","node":{"origin","token"}}  where the shell's own client
 *                                               connects, and its bearer
 *   {"type":"error","message":"..."}            fatal, the host is exiting
 *   {"type":"exit","code":n}                    the node ended on its own
 * stdin closing means the shell is gone: stop the node and exit.
 */
import * as NodePath from "node:path";
import * as NodeURL from "node:url";

import {
  exchangePairingToken,
  fetchDescriptor,
  findLocalNodeToken,
  nodeDataDir,
  nodePort,
  readAccessToken,
  resolveNodeLaunch,
  startNode,
  waitForNode,
  type RunningNode,
} from "./elixirNode.ts";
import { HostError } from "./hostError.ts";
import { readPairingLink } from "./pairingUrl.ts";

interface NodeAccess {
  readonly origin: string;
  readonly token: string;
}

type HostMessage =
  | { readonly type: "ready"; readonly node: NodeAccess }
  | { readonly type: "error"; readonly message: string }
  | { readonly type: "exit"; readonly code: number | null; readonly signal: string | null };

/** A checkout's first start may compile the node. */
const NODE_START_TIMEOUT_MS = 10 * 60_000;
/** How long quitting waits for the node before the host exits anyway. */
const NODE_STOP_GRACE_MS = 1_500;

function emit(message: HostMessage): void {
  process.stdout.write(`${JSON.stringify(message)}\n`);
}

interface HostArgs {
  readonly baseDir: string | undefined;
  readonly attach: string | undefined;
}

function parseArgs(argv: ReadonlyArray<string>): HostArgs {
  const values = new Map<string, string>();
  for (let index = 0; index < argv.length; index += 1) {
    const arg = argv[index] ?? "";
    const match = /^--(base-dir|attach)(?:=(.*))?$/.exec(arg);
    if (match === null) {
      throw new HostError(`Unknown desktop host argument: ${arg}`);
    }
    const value = match[2] ?? argv[(index += 1)];
    if (!value) {
      throw new HostError(`--${match[1]} needs a value.`);
    }
    values.set(match[1] ?? "", value);
  }
  const baseDir = values.get("base-dir");
  return {
    baseDir: baseDir === undefined ? undefined : NodePath.resolve(baseDir),
    attach: values.get("attach"),
  };
}

const hostDir = NodePath.dirname(NodeURL.fileURLToPath(import.meta.url));
let node: RunningNode | undefined;
let stopping = false;

async function stop(code: number): Promise<never> {
  stopping = true;
  const running = node;
  if (running !== undefined) {
    running.stop();
    await Promise.race([
      running.exited,
      new Promise((resolve) => setTimeout(resolve, NODE_STOP_GRACE_MS)),
    ]);
  }
  process.exit(code);
}

async function standalone(home: string | undefined): Promise<NodeAccess> {
  const port = await nodePort(process.env);
  const launch = resolveNodeLaunch(hostDir, process.env);
  const started = startNode({ launch, port, home, env: process.env });
  node = started;
  await waitForNode(started, NODE_START_TIMEOUT_MS);
  void started.exited.then(({ code, signal }) => {
    if (stopping) return;
    emit({ type: "exit", code, signal });
    process.exit(code ?? 1);
  });
  const token = readAccessToken(nodeDataDir({ launch, home, env: process.env }));
  if (token === undefined) {
    throw new HostError("The node started but wrote no access token for the desktop app.");
  }
  return { origin: started.origin, token };
}

function notANode(address: string): HostError {
  return new HostError(
    `${address} is not a HAL-C2 node. Start the desktop app with a node's pairing link to attach to it.`,
  );
}

async function attach(url: string, home: string | undefined): Promise<NodeAccess> {
  const link = readPairingLink(url);
  if (link === undefined) throw notANode(url);
  const descriptor = await fetchDescriptor(link.origin).catch((error: unknown) => {
    const reason = error instanceof Error && error.cause instanceof Error ? error.cause : error;
    throw new HostError(
      `Cannot reach the node at ${link.origin}: ${reason instanceof Error ? reason.message : String(reason)}`,
    );
  });
  if (descriptor === undefined) throw notANode(link.origin);
  // A node on this machine lets the shell in with its own access token.
  const local = findLocalNodeToken({ origin: link.origin, home, env: process.env });
  if (local !== undefined) return { origin: link.origin, token: local };
  // Any other node pairs the shell with the link's token, which is single use.
  if (link.token === undefined) {
    throw new HostError(
      `The link to ${link.origin} has no pairing token, and no node on this machine records that origin.`,
    );
  }
  const token = await exchangePairingToken(link.origin, link.token).catch(() => undefined);
  if (token === undefined) {
    throw new HostError(`The pairing link for ${link.origin} is invalid or expired.`);
  }
  return { origin: link.origin, token };
}

for (const signal of ["SIGINT", "SIGTERM", "SIGHUP"] as const) {
  process.on(signal, () => void stop(0));
}
// The shell holds our stdin open; EOF means it exited (cleanly or not).
process.stdin.on("end", () => void stop(0));
process.stdin.on("error", () => void stop(0));
process.stdin.resume();

try {
  const args = parseArgs(process.argv.slice(2));
  const access =
    args.attach === undefined
      ? await standalone(args.baseDir)
      : await attach(args.attach, args.baseDir);
  if (!stopping) emit({ type: "ready", node: access });
} catch (error) {
  if (!stopping) {
    emit({
      type: "error",
      message: error instanceof HostError ? error.message : `Desktop host failed: ${String(error)}`,
    });
    await stop(1);
  }
}
