// @effect-diagnostics nodeBuiltinImport:off globalTimers:off - process launcher, deliberately Effect-free.
/**
 * Desktop host for the Qt shell.
 *
 * Spawned by hal-c2-qt (see src/BackendProcess.cpp). Serves the built web app
 * from a loopback port (webBundle.ts), starts the desktop app's own Elixir node
 * (elixirNode.ts), and announces a `/pair` URL that pairs the app with that node
 * and opens it. With `--attach=<url>` it starts no node: a node pairing link
 * opens the app paired with that node, any other URL is announced unchanged.
 *
 * Arguments: `--base-dir=<HAL-C2 home>` (the node's home and the app's port key),
 * `--attach=<url>`.
 *
 * Protocol (stdout, newline-delimited JSON):
 *   {"type":"ready","url":"http://..."}   load this URL
 *   {"type":"error","message":"..."}       fatal, the host is exiting
 *   {"type":"exit","code":n}               the node ended on its own
 * stdin closing means the shell is gone: stop the node and exit.
 */
import * as NodeCrypto from "node:crypto";
import * as NodePath from "node:path";
import * as NodeURL from "node:url";

import {
  fetchDescriptor,
  nodePort,
  resolveNodeLaunch,
  startNode,
  waitForNode,
  type RunningNode,
} from "./elixirNode.ts";
import { HostError } from "./hostError.ts";
import { appPairingUrl, readPairingLink } from "./pairingUrl.ts";
import { resolveWebBundle, serveWebBundle, webPort, type WebServer } from "./webBundle.ts";

type HostMessage =
  | { readonly type: "ready"; readonly url: string }
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
let web: WebServer | undefined;
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
  await web?.close();
  process.exit(code);
}

async function serveApp(home: string | undefined): Promise<WebServer> {
  const root = resolveWebBundle(hostDir, process.env);
  web = await serveWebBundle({ root, port: webPort(process.env, home) });
  return web;
}

async function standalone(home: string | undefined): Promise<string> {
  const app = await serveApp(home);
  const port = await nodePort(process.env);
  const launch = resolveNodeLaunch(hostDir, process.env);
  // Exchangeable for a day with admin scopes (HalC2.Auth); a new one each start
  // replaces the previous desktop session, and the app upserts the environment
  // by id, so a relaunch pairs the same environment again.
  const token = NodeCrypto.randomBytes(32).toString("base64url");
  const started = startNode({ launch, port, home, token, env: process.env });
  node = started;
  await waitForNode(started, NODE_START_TIMEOUT_MS);
  void started.exited.then(({ code, signal }) => {
    if (stopping) return;
    emit({ type: "exit", code, signal });
    process.exit(code ?? 1);
  });
  return appPairingUrl(app.origin, started.origin, token);
}

async function attach(url: string, home: string | undefined): Promise<string> {
  const link = readPairingLink(url);
  if (link === undefined) return url;
  const descriptor = await fetchDescriptor(link.origin).catch((error: unknown) => {
    const reason = error instanceof Error && error.cause instanceof Error ? error.cause : error;
    throw new HostError(
      `Cannot reach the node at ${link.origin}: ${reason instanceof Error ? reason.message : String(reason)}`,
    );
  });
  // Anything that is not a protocol-3 node (a web dev server, a legacy
  // server that serves its own app) is loaded as it is.
  if (descriptor === undefined) return url;
  const app = await serveApp(home);
  return link.token === undefined
    ? `${app.origin}/`
    : appPairingUrl(app.origin, link.origin, link.token);
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
  const url =
    args.attach === undefined
      ? await standalone(args.baseDir)
      : await attach(args.attach, args.baseDir);
  if (!stopping) emit({ type: "ready", url });
} catch (error) {
  if (!stopping) {
    emit({
      type: "error",
      message: error instanceof HostError ? error.message : `Desktop host failed: ${String(error)}`,
    });
    await stop(1);
  }
}
