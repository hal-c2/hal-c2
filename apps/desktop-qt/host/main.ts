// @effect-diagnostics nodeBuiltinImport:off globalTimers:off - process launcher, deliberately Effect-free.
/**
 * Desktop host for the Qt shell.
 *
 * Spawned by hal-c2-qt (see src/BackendProcess.cpp). Starts the desktop app's
 * own Elixir MC (elixirMc.ts) and announces where the shell's client
 * connects. With `--attach=<url>` it starts no MC and pairs the shell with the
 * MC a pairing link names instead.
 *
 * Arguments: `--base-dir=<HAL-C2 home>` (the MC's home), `--attach=<url>`.
 *
 * Protocol (stdout, newline-delimited JSON):
 *   {"type":"ready","MC":{"origin","token"}}  where the shell's own client
 *                                               connects, and its bearer
 *   {"type":"error","message":"..."}            fatal, the host is exiting
 *   {"type":"exit","code":n}                    the MC ended on its own
 * stdin closing means the shell is gone: stop the MC and exit.
 */
import * as NodePath from "node:path";
import * as NodeURL from "node:url";

import {
  exchangePairingToken,
  fetchDescriptor,
  findLocalMcToken,
  mcDataDir,
  mcPort,
  readAccessToken,
  resolveMcLaunch,
  startMc,
  waitForMc,
  type RunningMc,
} from "./elixirMc.ts";
import { HostError } from "./hostError.ts";
import { readPairingLink } from "./pairingUrl.ts";

interface McAccess {
  readonly origin: string;
  readonly token: string;
}

type HostMessage =
  | { readonly type: "ready"; readonly mc: McAccess }
  | { readonly type: "error"; readonly message: string }
  | { readonly type: "exit"; readonly code: number | null; readonly signal: string | null };

/** A checkout's first start may compile the MC. */
const MC_START_TIMEOUT_MS = 10 * 60_000;
/** How long quitting waits for the MC before the host exits anyway. */
const MC_STOP_GRACE_MS = 1_500;

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
let mc: RunningMc | undefined;
let stopping = false;

async function stop(code: number): Promise<never> {
  stopping = true;
  const running = mc;
  if (running !== undefined) {
    running.stop();
    await Promise.race([
      running.exited,
      new Promise((resolve) => setTimeout(resolve, MC_STOP_GRACE_MS)),
    ]);
  }
  process.exit(code);
}

async function standalone(home: string | undefined): Promise<McAccess> {
  const port = await mcPort(process.env);
  const launch = resolveMcLaunch(hostDir, process.env);
  const started = startMc({ launch, port, home, env: process.env });
  mc = started;
  await waitForMc(started, MC_START_TIMEOUT_MS);
  void started.exited.then(({ code, signal }) => {
    if (stopping) return;
    emit({ type: "exit", code, signal });
    process.exit(code ?? 1);
  });
  const token = readAccessToken(mcDataDir({ launch, home, env: process.env }));
  if (token === undefined) {
    throw new HostError("The MC started but wrote no access token for the desktop app.");
  }
  return { origin: started.origin, token };
}

function notAnMc(address: string): HostError {
  return new HostError(
    `${address} is not a HAL-C2 MC. Start the desktop app with an MC's pairing link to attach to it.`,
  );
}

async function attach(url: string, home: string | undefined): Promise<McAccess> {
  const link = readPairingLink(url);
  if (link === undefined) throw notAnMc(url);
  const descriptor = await fetchDescriptor(link.origin).catch((error: unknown) => {
    const reason = error instanceof Error && error.cause instanceof Error ? error.cause : error;
    throw new HostError(
      `Cannot reach the MC at ${link.origin}: ${reason instanceof Error ? reason.message : String(reason)}`,
    );
  });
  if (descriptor === undefined) throw notAnMc(link.origin);
  // An MC on this machine lets the shell in with its own access token.
  const local = findLocalMcToken({ origin: link.origin, home, env: process.env });
  if (local !== undefined) return { origin: link.origin, token: local };
  // Any other MC pairs the shell with the link's token, which is single use.
  if (link.token === undefined) {
    throw new HostError(
      `The link to ${link.origin} has no pairing token, and no MC on this machine records that origin.`,
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
  if (!stopping) emit({ type: "ready", mc: access });
} catch (error) {
  if (!stopping) {
    emit({
      type: "error",
      message: error instanceof HostError ? error.message : `Desktop host failed: ${String(error)}`,
    });
    await stop(1);
  }
}
