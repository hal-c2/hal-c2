// @effect-diagnostics nodeBuiltinImport:off globalTimers:off globalFetch:off globalDate:off - process launcher, deliberately Effect-free.
/**
 * Starts the desktop app's own Elixir node the way the Electron app does
 * (apps/desktop/src/backend/DesktopBackendConfiguration.ts): a release
 * `bin/hal_c2 start`, or `mix hal_c2.server` in a checkout, with
 * `HAL_C2_BOOTSTRAP_STDIN=1` and one JSON bootstrap line on stdin (port, host,
 * `halC2Home`, `desktopBootstrapToken`; read by apps/server-ex/lib/hal_c2/desktop.ex).
 * The token never appears in argv or the environment.
 */
import * as NodeChildProcess from "node:child_process";
import * as NodeFS from "node:fs";
import * as NodeNet from "node:net";
import * as NodeOS from "node:os";
import * as NodePath from "node:path";

import { HAL_C2_APP_DIR, HAL_C2_DEV_APP_DIR, resolveHalC2Dirs } from "@hal-c2/shared/xdgDirs";

import { HostError } from "./hostError.ts";

/** The node's own default (apps/server-ex/config/config.exs); scanned upward when taken. */
const DEFAULT_NODE_PORT = 3780;
const PORT_SCAN = 100;
const NODE_HOST = "127.0.0.1";

export interface NodeLaunch {
  readonly command: string;
  readonly args: ReadonlyArray<string>;
  readonly cwd?: string;
}

/**
 * Which node to run: `HAL_C2_NODE_RELEASE` (a release directory or its
 * `bin/hal_c2`), the release bundled next to the host in a package, else the
 * checkout's apps/server-ex from source.
 */
export function resolveNodeLaunch(
  hostDir: string,
  env: NodeJS.ProcessEnv,
  exists: (path: string) => boolean = NodeFS.existsSync,
): NodeLaunch {
  const configured = env.HAL_C2_NODE_RELEASE?.trim();
  if (configured) {
    const release = NodePath.resolve(configured);
    const bin = NodePath.join(release, "bin", "hal_c2");
    return { command: exists(bin) ? bin : release, args: ["start"] };
  }
  const bundled = NodePath.resolve(hostDir, "../hal-c2-node/bin/hal_c2");
  if (exists(bundled)) {
    return { command: bundled, args: ["start"] };
  }
  const source = NodePath.resolve(hostDir, "../../server-ex");
  if (exists(NodePath.join(source, "mix.exs"))) {
    return { command: "mix", args: ["hal_c2.server"], cwd: source };
  }
  throw new HostError(
    "No node to start: set HAL_C2_NODE_RELEASE to a node release, or run from a checkout with apps/server-ex.",
  );
}

function portIsFree(port: number, host: string): Promise<boolean> {
  return new Promise((resolve) => {
    const probe = NodeNet.createServer();
    probe.once("error", () => resolve(false));
    probe.listen(port, host, () => probe.close(() => resolve(true)));
  });
}

/** `HAL_C2_NODE_PORT` exactly, else the first free port from the node's default. */
export async function nodePort(env: NodeJS.ProcessEnv): Promise<number> {
  const configured = env.HAL_C2_NODE_PORT?.trim();
  if (configured) {
    const port = Number(configured);
    if (!Number.isInteger(port) || port < 1 || port > 65_535) {
      throw new HostError(`HAL_C2_NODE_PORT is not a port: ${configured}`);
    }
    if (!(await portIsFree(port, NODE_HOST))) {
      throw new HostError(
        `Port ${port} for the node is in use by another program. Set HAL_C2_NODE_PORT to a free port.`,
      );
    }
    return port;
  }
  for (let port = DEFAULT_NODE_PORT; port < DEFAULT_NODE_PORT + PORT_SCAN; port += 1) {
    if (await portIsFree(port, NODE_HOST)) {
      return port;
    }
  }
  throw new HostError(
    `No free port for the node in ${DEFAULT_NODE_PORT}-${DEFAULT_NODE_PORT + PORT_SCAN - 1}. Set HAL_C2_NODE_PORT.`,
  );
}

/**
 * The node's data directory, resolved the way `HalC2.Paths` resolves it for this
 * launch: the desktop's HAL-C2 home, `HAL_C2_NODE_HOME`, a checkout's own
 * `.hal-c2` (config/config.exs), else HAL-C2's XDG data directory.
 */
export function nodeDataDir(input: {
  readonly launch: NodeLaunch;
  readonly home: string | undefined;
  readonly env: NodeJS.ProcessEnv;
  readonly homeDir?: string;
}): string {
  if (input.home !== undefined) return NodePath.join(input.home, "data", "elixir");
  const nodeHome = input.env.HAL_C2_NODE_HOME?.trim();
  if (nodeHome) return NodePath.join(nodeHome, "data");
  if (input.launch.cwd !== undefined) {
    return NodePath.resolve(input.launch.cwd, "../..", ".hal-c2", "data", "elixir");
  }
  const dirs = resolveHalC2Dirs({
    env: input.env,
    homeDir: input.homeDir ?? NodeOS.homedir(),
    platform: process.platform,
  });
  return NodePath.join(dirs.data, "elixir");
}

/**
 * The node's own access token (`HalC2.Web.token/0`, written at boot), which the
 * shell's native client puts on its socket. Undefined when the file is not there.
 */
export function readAccessToken(dataDir: string): string | undefined {
  try {
    const token = NodeFS.readFileSync(NodePath.join(dataDir, "access-token"), "utf8").trim();
    return token === "" ? undefined : token;
  } catch {
    return undefined;
  }
}

/**
 * The access token of the node at `origin` when it runs on this machine: the
 * first node directory whose runtime record (`<state>/server-runtime.json`,
 * apps/server-ex/lib/hal_c2/runtime_record.ex) names that origin and a live pid.
 * Looks where apps/tui/src/nodeDiscovery.ts looks: `HAL_C2_NODE_HOME`, the
 * desktop's HAL-C2 home, then the `hal-c2-dev` and release XDG directories.
 * Only reads.
 */
export function findLocalNodeToken(input: {
  readonly origin: string;
  readonly home: string | undefined;
  readonly env: NodeJS.ProcessEnv;
  readonly homeDir?: string;
  readonly isAlive?: (pid: number) => boolean;
}): string | undefined {
  const candidates: Array<{ state: string; data: string }> = [];
  const nodeHome = input.env.HAL_C2_NODE_HOME?.trim();
  if (nodeHome) {
    candidates.push({
      state: NodePath.join(nodeHome, "state"),
      data: NodePath.join(nodeHome, "data"),
    });
  }
  if (input.home !== undefined) {
    candidates.push({
      state: NodePath.join(input.home, "state", "elixir"),
      data: NodePath.join(input.home, "data", "elixir"),
    });
  }
  // HAL_C2_HOME is the desktop's own home, already a candidate above.
  const env = { ...input.env, HAL_C2_HOME: undefined };
  for (const profile of [HAL_C2_DEV_APP_DIR, HAL_C2_APP_DIR] as const) {
    const dirs = resolveHalC2Dirs({
      env,
      homeDir: input.homeDir ?? NodeOS.homedir(),
      platform: process.platform,
      profile,
    });
    candidates.push({
      state: NodePath.join(dirs.state, "elixir"),
      data: NodePath.join(dirs.data, "elixir"),
    });
  }
  const isAlive = input.isAlive ?? processIsAlive;
  for (const dirs of candidates) {
    const record = readRuntimeRecord(NodePath.join(dirs.state, "server-runtime.json"));
    if (record === undefined || !sameOrigin(record.origin, input.origin) || !isAlive(record.pid)) {
      continue;
    }
    return readAccessToken(dirs.data);
  }
  return undefined;
}

function readRuntimeRecord(path: string): { pid: number; origin: string } | undefined {
  try {
    const record = JSON.parse(NodeFS.readFileSync(path, "utf8")) as {
      pid?: unknown;
      origin?: unknown;
    };
    return typeof record.pid === "number" && typeof record.origin === "string"
      ? { pid: record.pid, origin: record.origin }
      : undefined;
  } catch {
    // Missing, torn or foreign: no record.
    return undefined;
  }
}

function sameOrigin(a: string, b: string): boolean {
  try {
    return new URL(a).origin === new URL(b).origin;
  } catch {
    return false;
  }
}

/** `kill(pid, 0)`: EPERM still means the process exists. */
function processIsAlive(pid: number): boolean {
  try {
    process.kill(pid, 0);
    return true;
  } catch (error) {
    return (error as NodeJS.ErrnoException).code === "EPERM";
  }
}

export interface NodeExit {
  readonly code: number | null;
  readonly signal: NodeJS.Signals | null;
  /** Set when the command could not be run at all. */
  readonly error?: string;
}

export interface RunningNode {
  readonly origin: string;
  readonly exited: Promise<NodeExit>;
  /** The last lines the node wrote, for error messages. */
  output(): string;
  /** SIGTERM to the node's process group (mix, erl, and anything they spawned). */
  stop(): void;
}

/** Spawns the node and hands it the bootstrap line; output goes to the host's stderr. */
export function startNode(input: {
  readonly launch: NodeLaunch;
  readonly port: number;
  readonly home: string | undefined;
  readonly token: string;
  readonly env: NodeJS.ProcessEnv;
}): RunningNode {
  const child = NodeChildProcess.spawn(input.launch.command, [...input.launch.args], {
    cwd: input.launch.cwd,
    env: {
      ...input.env,
      HAL_C2_BOOTSTRAP_STDIN: "1",
      // JavaScript sidecars run on the Node that runs this host.
      HAL_C2_NODE_COMMAND: process.execPath,
    },
    stdio: ["pipe", "pipe", "pipe"],
    // Its own process group, so stop() reaches the BEAM behind mix or the release script.
    detached: process.platform !== "win32",
  });

  let tail = "";
  const record = (chunk: Buffer) => {
    process.stderr.write(chunk);
    tail = (tail + chunk.toString("utf8")).slice(-4_000);
  };
  child.stdout.on("data", record);
  child.stderr.on("data", record);

  const exited = new Promise<NodeExit>((resolve) => {
    child.once("exit", (code, signal) => resolve({ code, signal }));
    child.once("error", (error) => resolve({ code: null, signal: null, error: error.message }));
  });

  const bootstrap = {
    port: input.port,
    host: NODE_HOST,
    desktopBootstrapToken: input.token,
    ...(input.home === undefined ? {} : { halC2Home: input.home }),
  };
  child.stdin.on("error", () => {});
  child.stdin.end(`${JSON.stringify(bootstrap)}\n`);

  let stopped = false;
  return {
    origin: `http://${NODE_HOST}:${input.port}`,
    exited,
    output: () => tail.trim(),
    stop: () => {
      if (stopped || child.pid === undefined || child.exitCode !== null) return;
      stopped = true;
      try {
        if (process.platform === "win32") child.kill("SIGTERM");
        else process.kill(-child.pid, "SIGTERM");
      } catch {
        // Already gone.
      }
    },
  };
}

export interface NodeDescriptor {
  readonly environmentId: string;
  readonly label?: string;
  readonly orchestrationProtocolVersion: number;
}

/** A protocol-3 node's descriptor at `origin`, undefined for anything else that answers. */
export async function fetchDescriptor(
  origin: string,
  timeoutMs = 2_000,
): Promise<NodeDescriptor | undefined> {
  const response = await fetch(new URL("/.well-known/hal-c2/environment", origin), {
    signal: AbortSignal.timeout(timeoutMs),
  });
  if (!response.ok) return undefined;
  const body = (await response.json().catch(() => undefined)) as
    | Partial<NodeDescriptor>
    | undefined;
  return typeof body?.environmentId === "string" &&
    typeof body.orchestrationProtocolVersion === "number" &&
    body.orchestrationProtocolVersion >= 3
    ? (body as NodeDescriptor)
    : undefined;
}

/**
 * Waits until the node answers its descriptor. Fails when the node exits first
 * or does not answer within `timeoutMs` (a checkout may compile first).
 */
export async function waitForNode(node: RunningNode, timeoutMs: number): Promise<NodeDescriptor> {
  let exit: NodeExit | undefined;
  void node.exited.then((value) => {
    exit = value;
  });
  const deadline = Date.now() + timeoutMs;
  while (Date.now() < deadline) {
    if (exit !== undefined) {
      const how =
        exit.error !== undefined
          ? exit.error
          : exit.code !== null
            ? `exit code ${exit.code}`
            : `signal ${exit.signal ?? "unknown"}`;
      const output = node.output();
      throw new HostError(
        `The node failed to start (${how}) before it answered.${output ? `\n${output}` : ""}`,
      );
    }
    const descriptor = await fetchDescriptor(node.origin, 1_000).catch(() => undefined);
    if (descriptor !== undefined) return descriptor;
    await new Promise((resolve) => setTimeout(resolve, 200));
  }
  throw new HostError(`The node did not answer at ${node.origin} within ${timeoutMs / 1000} s.`);
}
