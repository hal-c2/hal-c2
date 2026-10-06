// @effect-diagnostics nodeBuiltinImport:off globalTimers:off globalFetch:off globalDate:off - process launcher, deliberately Effect-free.
/**
 * Starts the desktop app's own Elixir MC the way the Electron app does
 * (apps/desktop/src/backend/DesktopBackendConfiguration.ts): a release
 * `bin/hal_c2 start`, or `mix hal_c2.server` in a checkout, with
 * `HAL_C2_BOOTSTRAP_STDIN=1` and one JSON bootstrap line on stdin (port, host,
 * `halC2Home`; read by apps/server-ex/lib/hal_c2/desktop.ex).
 */
import * as NodeChildProcess from "node:child_process";
import * as NodeFS from "node:fs";
import * as NodeNet from "node:net";
import * as NodeOS from "node:os";
import * as NodePath from "node:path";

import {
  absoluteEnvPath,
  isLegacyHome,
  HAL_C2_APP_DIR,
  HAL_C2_DEV_APP_DIR,
  LEGACY_HOME_DIR_NAMES,
  resolveHalC2Dirs,
} from "@hal-c2/shared/xdgDirs";

import { HostError } from "./hostError.ts";

// oxlint-disable-next-line hal-c2/no-global-process-runtime -- The host is a plain Node process with no Effect runtime.
const hostPlatform = process.platform;

/** The MC's own default (apps/server-ex/config/config.exs); scanned upward when taken. */
const DEFAULT_MC_PORT = 3780;
const PORT_SCAN = 100;
const MC_HOST = "127.0.0.1";

export interface McLaunch {
  readonly command: string;
  readonly args: ReadonlyArray<string>;
  readonly cwd?: string;
}

/**
 * Which MC to run: `HAL_C2_MC_RELEASE` (a release directory or its
 * `bin/hal_c2`), the release bundled next to the host in a package, else the
 * checkout's apps/server-ex from source.
 */
export function resolveMcLaunch(
  hostDir: string,
  env: NodeJS.ProcessEnv,
  exists: (path: string) => boolean = NodeFS.existsSync,
): McLaunch {
  const configured = env.HAL_C2_MC_RELEASE?.trim();
  if (configured) {
    const release = NodePath.resolve(configured);
    const bin = NodePath.join(release, "bin", "hal_c2");
    return { command: exists(bin) ? bin : release, args: ["start"] };
  }
  const bundled = NodePath.resolve(hostDir, "../hal-c2-mc/bin/hal_c2");
  if (exists(bundled)) {
    return { command: bundled, args: ["start"] };
  }
  const source = NodePath.resolve(hostDir, "../../server-ex");
  if (exists(NodePath.join(source, "mix.exs"))) {
    return { command: "mix", args: ["hal_c2.server"], cwd: source };
  }
  throw new HostError(
    "No MC to start: set HAL_C2_MC_RELEASE to an MC release, or run from a checkout with apps/server-ex.",
  );
}

function portIsFree(port: number, host: string): Promise<boolean> {
  return new Promise((resolve) => {
    const probe = NodeNet.createServer();
    probe.once("error", () => resolve(false));
    probe.listen(port, host, () => probe.close(() => resolve(true)));
  });
}

/** `HAL_C2_MC_PORT` exactly, else the first free port from the MC's default. */
export async function mcPort(env: NodeJS.ProcessEnv): Promise<number> {
  const configured = env.HAL_C2_MC_PORT?.trim();
  if (configured) {
    const port = Number(configured);
    if (!Number.isInteger(port) || port < 1 || port > 65_535) {
      throw new HostError(`HAL_C2_MC_PORT is not a port: ${configured}`);
    }
    if (!(await portIsFree(port, MC_HOST))) {
      throw new HostError(
        `Port ${port} for the MC is in use by another program. Set HAL_C2_MC_PORT to a free port.`,
      );
    }
    return port;
  }
  for (let port = DEFAULT_MC_PORT; port < DEFAULT_MC_PORT + PORT_SCAN; port += 1) {
    if (await portIsFree(port, MC_HOST)) {
      return port;
    }
  }
  throw new HostError(
    `No free port for the MC in ${DEFAULT_MC_PORT}-${DEFAULT_MC_PORT + PORT_SCAN - 1}. Set HAL_C2_MC_PORT.`,
  );
}

/**
 * The MC's data directory, resolved the way `HalC2.Paths` resolves it for this
 * launch: the desktop's HAL-C2 home, `HAL_C2_MC_HOME`, else HAL-C2's XDG data
 * directory, in the `hal-c2-dev` profile for an MC run from a checkout
 * (config/config.exs), which does not read `HAL_C2_HOME` (config/runtime.exs).
 */
export function mcDataDir(input: {
  readonly launch: McLaunch;
  readonly home: string | undefined;
  readonly env: NodeJS.ProcessEnv;
  readonly homeDir?: string;
}): string {
  return mcDirs(input).data;
}

function mcDirs(input: {
  readonly launch: McLaunch;
  readonly home: string | undefined;
  readonly env: NodeJS.ProcessEnv;
  readonly homeDir?: string;
}): { readonly data: string; readonly state: string } {
  const homeDir = input.homeDir ?? NodeOS.homedir();
  if (input.home !== undefined) {
    // The MC ignores an old home as its home too (`HalC2.Desktop.apply_bootstrap/1`).
    if (isLegacyHome(input.home, { homeDir, platform: hostPlatform })) {
      throw new HostError(
        `The HAL-C2 home (${input.home}) must be a directory other than ~/.hal-c2 and ~/.t3.`,
      );
    }
    return {
      data: NodePath.join(input.home, "data", "elixir"),
      state: NodePath.join(input.home, "state", "elixir"),
    };
  }
  // Blank counts as set, as it does for the MC (config/runtime.exs).
  const mcHome = input.env.HAL_C2_MC_HOME;
  if (mcHome) {
    // The MC ignores such a root and opens the installed app's files instead
    // (`HalC2.Paths.root?/4`), so the desktop app does not start it there.
    const root = absoluteEnvPath(mcHome, hostPlatform);
    const inOldHome = LEGACY_HOME_DIR_NAMES.some((name) => {
      const within = NodePath.relative(NodePath.join(homeDir, name), root ?? "");
      const outside = within === ".." || within.startsWith(`..${NodePath.sep}`);
      return !outside && !NodePath.isAbsolute(within);
    });
    if (root === undefined || inOldHome) {
      throw new HostError(
        `HAL_C2_MC_HOME (${mcHome}) must be an absolute path outside ~/.hal-c2 and ~/.t3.`,
      );
    }
    return { data: NodePath.join(root, "data"), state: NodePath.join(root, "state") };
  }
  const fromSource = input.launch.cwd !== undefined;
  const dirs = resolveHalC2Dirs({
    env: fromSource ? { ...input.env, HAL_C2_HOME: undefined } : input.env,
    homeDir,
    platform: hostPlatform,
    profile: fromSource ? HAL_C2_DEV_APP_DIR : HAL_C2_APP_DIR,
  });
  return {
    data: NodePath.join(dirs.data, "elixir"),
    state: NodePath.join(dirs.state, "elixir"),
  };
}

/**
 * The MC already running on the files this launch would use, such as the background
 * service: its address and access token, from its runtime record. Two MCs must not
 * share those files, so the desktop app uses this one instead of starting its own,
 * and fails when it cannot read that MC's token.
 */
export function findRunningMc(input: {
  readonly launch: McLaunch;
  readonly home: string | undefined;
  readonly env: NodeJS.ProcessEnv;
}): { readonly origin: string; readonly token: string } | undefined {
  const dirs = mcDirs(input);
  const record = readRuntimeRecord(NodePath.join(dirs.state, "server-runtime.json"));
  if (record === undefined || !processIsAlive(record.pid)) return undefined;
  const token = readAccessToken(dirs.data);
  if (token === undefined) {
    throw new HostError(
      `An MC is already running on ${dirs.data} (pid ${record.pid}), but its access token cannot be read.`,
    );
  }
  return { origin: record.origin, token };
}

/**
 * The MC's own access token (`HalC2.Web.token/0`, written at boot), which the
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
 * The access token of the MC at `origin` when it runs on this machine: the
 * first MC directory whose runtime record (`<state>/server-runtime.json`,
 * apps/server-ex/lib/hal_c2/runtime_record.ex) names that origin and a live pid.
 * Looks where apps/tui/src/mcDiscovery.ts looks: `HAL_C2_MC_HOME`, the
 * desktop's HAL-C2 home, then the `hal-c2-dev` and release XDG directories.
 * Only reads.
 */
export function findLocalMcToken(input: {
  readonly origin: string;
  readonly home: string | undefined;
  readonly env: NodeJS.ProcessEnv;
  readonly homeDir?: string;
  readonly isAlive?: (pid: number) => boolean;
}): string | undefined {
  const candidates: Array<{ state: string; data: string }> = [];
  const mcHome = input.env.HAL_C2_MC_HOME?.trim();
  if (mcHome) {
    candidates.push({
      state: NodePath.join(mcHome, "state"),
      data: NodePath.join(mcHome, "data"),
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
      platform: hostPlatform,
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

export interface McExit {
  readonly code: number | null;
  readonly signal: NodeJS.Signals | null;
  /** Set when the command could not be run at all. */
  readonly error?: string;
}

export interface RunningMc {
  readonly origin: string;
  readonly exited: Promise<McExit>;
  /** The last lines the MC wrote, for error messages. */
  output(): string;
  /** SIGTERM to the MC's process group (mix, erl, and anything they spawned). */
  stop(): void;
}

/** Spawns the MC and hands it the bootstrap line; output goes to the host's stderr. */
export function startMc(input: {
  readonly launch: McLaunch;
  readonly port: number;
  readonly home: string | undefined;
  readonly env: NodeJS.ProcessEnv;
}): RunningMc {
  const child = NodeChildProcess.spawn(input.launch.command, [...input.launch.args], {
    cwd: input.launch.cwd,
    env: {
      ...input.env,
      HAL_C2_BOOTSTRAP_STDIN: "1",
      // JavaScript sidecars run on the Node that runs this host.
      HAL_C2_NODE_COMMAND: process.execPath,
      // An MC run from source is the development one, whatever MIX_ENV the desktop
      // app inherited: any other environment keeps its files somewhere else.
      ...(input.launch.cwd === undefined ? {} : { MIX_ENV: "dev" }),
    },
    stdio: ["pipe", "pipe", "pipe"],
    // Its own process group, so stop() reaches the BEAM behind mix or the release script.
    detached: hostPlatform !== "win32",
  });

  let tail = "";
  const record = (chunk: Buffer) => {
    process.stderr.write(chunk);
    tail = (tail + chunk.toString("utf8")).slice(-4_000);
  };
  child.stdout.on("data", record);
  child.stderr.on("data", record);

  const exited = new Promise<McExit>((resolve) => {
    child.once("exit", (code, signal) => resolve({ code, signal }));
    child.once("error", (error) => resolve({ code: null, signal: null, error: error.message }));
  });

  const bootstrap = {
    port: input.port,
    host: MC_HOST,
    ...(input.home === undefined ? {} : { halC2Home: input.home }),
  };
  child.stdin.on("error", () => {});
  child.stdin.end(`${JSON.stringify(bootstrap)}\n`);

  let stopped = false;
  return {
    origin: `http://${MC_HOST}:${input.port}`,
    exited,
    output: () => tail.trim(),
    stop: () => {
      if (stopped || child.pid === undefined || child.exitCode !== null) return;
      stopped = true;
      try {
        if (hostPlatform === "win32") child.kill("SIGTERM");
        else process.kill(-child.pid, "SIGTERM");
      } catch {
        // Already gone.
      }
    },
  };
}

export interface McDescriptor {
  readonly environmentId: string;
  readonly label?: string;
  readonly orchestrationProtocolVersion: number;
}

/** A protocol-3 MC's descriptor at `origin`, undefined for anything else that answers. */
export async function fetchDescriptor(
  origin: string,
  timeoutMs = 2_000,
): Promise<McDescriptor | undefined> {
  const response = await fetch(new URL("/.well-known/hal-c2/environment", origin), {
    signal: AbortSignal.timeout(timeoutMs),
  });
  if (!response.ok) return undefined;
  const body = (await response.json().catch(() => undefined)) as Partial<McDescriptor> | undefined;
  return typeof body?.environmentId === "string" &&
    typeof body.orchestrationProtocolVersion === "number" &&
    body.orchestrationProtocolVersion >= 3
    ? (body as McDescriptor)
    : undefined;
}

/**
 * Exchanges an MC pairing token for a bearer at `/oauth/token`, as a desktop
 * client. Pairing tokens are single use, so the token is spent afterwards.
 * Undefined when the MC refuses it (invalid, expired or already used).
 */
export async function exchangePairingToken(
  origin: string,
  token: string,
  timeoutMs = 5_000,
): Promise<string | undefined> {
  const response = await fetch(new URL("/oauth/token", origin), {
    method: "POST",
    headers: { "content-type": "application/x-www-form-urlencoded" },
    body: new URLSearchParams({
      grant_type: "urn:ietf:params:oauth:grant-type:token-exchange",
      subject_token_type: "urn:hal-c2:params:oauth:token-type:environment-bootstrap",
      subject_token: token,
      client_label: "HAL-C2 desktop",
      client_device_type: "desktop",
    }),
    signal: AbortSignal.timeout(timeoutMs),
  });
  if (!response.ok) return undefined;
  const body = (await response.json().catch(() => undefined)) as
    | { readonly access_token?: unknown }
    | undefined;
  return typeof body?.access_token === "string" ? body.access_token : undefined;
}

/**
 * Waits until the MC answers its descriptor. Fails when the MC exits first
 * or does not answer within `timeoutMs` (a checkout may compile first).
 */
export async function waitForMc(mc: RunningMc, timeoutMs: number): Promise<McDescriptor> {
  let exit: McExit | undefined;
  void mc.exited.then((value) => {
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
      const output = mc.output();
      throw new HostError(
        `The MC failed to start (${how}) before it answered.${output ? `\n${output}` : ""}`,
      );
    }
    const descriptor = await fetchDescriptor(mc.origin, 1_000).catch(() => undefined);
    if (descriptor !== undefined) return descriptor;
    await new Promise((resolve) => setTimeout(resolve, 200));
  }
  throw new HostError(`The MC did not answer at ${mc.origin} within ${timeoutMs / 1000} s.`);
}
