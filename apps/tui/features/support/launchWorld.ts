// Real processes for launch.feature, all on pipes (never a real terminal).
//
// The client finds a fake protocol-3 MC (fakeMc.ts) through the runtime record
// and access token under a temp `--base-dir`, or pairs with it from `--url`.
// Every process is killed by the pid captured at spawn.
import * as NodeFS from "node:fs";
import * as NodeOS from "node:os";
import * as NodePath from "node:path";

import { startFakeMc, type FakeMc } from "./fakeMc.ts";
import type { World } from "./world.ts";

const TUI_DIR = NodePath.resolve(import.meta.dir, "../..");
const CLIENT_ENTRY = NodePath.join(TUI_DIR, "src/index.ts");

/** How long a process gets to draw its first frame, or to exit once asked. */
const DRAW_TIMEOUT_MS = 12_000;
const EXIT_TIMEOUT_MS = 6_000;

export const ENTER_ALT_SCREEN = "\x1b[?1049h";
export const LEAVE_ALT_SCREEN = "\x1b[?1049l";
/** What a restored terminal gets back after the alternate screen: cursor, mouse, paste. */
export const RESTORE_SEQUENCES = ["\x1b[?25h", "\x1b[?1000l", "\x1b[?2004l"] as const;

/** The Givens of a launch: the terminal the client starts in. */
export interface LaunchSetup {
  /** The terminal's environment; `undefined` removes a key the test process has. */
  env: Record<string, string | undefined>;
}

export interface ProcessRun {
  readonly code: number | null;
  readonly stdout: string;
  readonly stderr: string;
  readonly drew: boolean;
}

export interface LaunchWorld extends World {
  launch?: LaunchSetup;
  launchHome?: string;
  /** A client that exited, or was left. */
  client?: ProcessRun;
  /** The MC the client finds or pairs with. */
  mc?: FakeMc;
  pairingLink?: string;
  /** A started client that drew and is still open. */
  direct?: DirectLaunch;
  /** Tickets the MC had issued when it dropped the connection. */
  ticketsBeforeDrop?: number;
}

export function launchSetup(ctx: LaunchWorld): LaunchSetup {
  return (ctx.launch ??= {
    env: { TERM: "xterm-256color", COLORTERM: undefined, TERM_PROGRAM: undefined },
  });
}

function home(ctx: LaunchWorld): string {
  if (!ctx.launchHome) {
    const dir = NodeFS.mkdtempSync(NodePath.join(NodeOS.tmpdir(), "hal-c2-tui-launch-"));
    ctx.cleanups.push(() => NodeFS.rmSync(dir, { recursive: true, force: true }));
    ctx.launchHome = dir;
  }
  return ctx.launchHome;
}

/** The test process's env minus anything that would point at real state or a real tmux. */
function cleanEnv(ctx: LaunchWorld): Record<string, string> {
  const env: Record<string, string> = {};
  for (const [key, value] of Object.entries(process.env)) {
    if (value === undefined) continue;
    if (key.startsWith("HAL_C2_TUI_") || key.startsWith("TMUX") || key.startsWith("SSH_")) continue;
    if (key === "HAL_C2_HOME" || key === "HAL_C2_MC_HOME" || key.startsWith("XDG_")) continue;
    if (key === "COLORTERM" || key === "TERM_PROGRAM") continue;
    env[key] = value;
  }
  const dir = home(ctx);
  env.HOME = dir;
  env.HAL_C2_TUI_LOG = NodePath.join(dir, "client.log");
  env.HAL_C2_TUI_SHELL_DIR = NodePath.join(dir, "shell");
  return env;
}

function withTerminal(env: Record<string, string>, terminal: LaunchSetup["env"]) {
  for (const [key, value] of Object.entries(terminal)) {
    if (value === undefined) delete env[key];
    else env[key] = value;
  }
  return env;
}

interface Spawned {
  readonly proc: ReturnType<typeof Bun.spawn<"pipe", "pipe", "pipe">>;
  readonly output: { stdout: string; stderr: string };
  /** True once the first frame is on screen, false if the process exits first. */
  readonly drawn: Promise<boolean>;
  readonly exited: Promise<number>;
}

function spawn(ctx: LaunchWorld, cmd: string[], env: Record<string, string>): Spawned {
  const proc = Bun.spawn(cmd, {
    cwd: TUI_DIR,
    env,
    stdin: "pipe",
    stdout: "pipe",
    stderr: "pipe",
  });
  ctx.cleanups.push(() => {
    if (proc.exitCode === null && proc.signalCode === null) proc.kill("SIGKILL");
  });
  const output = { stdout: "", stderr: "" };
  let markDrawn: (drew: boolean) => void = () => {};
  const drawn = new Promise<boolean>((resolve) => {
    markDrawn = resolve;
  });
  const decoder = new TextDecoder();
  const readOut = (async () => {
    for await (const chunk of proc.stdout) {
      output.stdout += decoder.decode(chunk, { stream: true });
      if (output.stdout.includes(ENTER_ALT_SCREEN)) markDrawn(true);
    }
  })();
  const readErr = (async () => {
    output.stderr += await new Response(proc.stderr).text();
  })();
  const exited = (async () => {
    const code = await proc.exited;
    await Promise.all([readOut, readErr]);
    markDrawn(false);
    return code;
  })();
  return { proc, output, drawn, exited };
}

async function within<T>(promise: Promise<T>, ms: number, what: string, spawned: Spawned) {
  let timer: ReturnType<typeof setTimeout> | undefined;
  const timeout = new Promise<never>((_, reject) => {
    timer = setTimeout(
      () => reject(new Error(`${what} timed out; stderr:\n${spawned.output.stderr}`)),
      ms,
    );
  });
  try {
    return await Promise.race([promise, timeout]);
  } finally {
    clearTimeout(timer);
  }
}

/** Ask a drawn client to leave (Ctrl+C on its input, or a signal) and wait for it. */
async function leave(spawned: Spawned, how: "ctrl+c" | "SIGINT" | "SIGTERM"): Promise<number> {
  if (how === "ctrl+c") {
    spawned.proc.stdin.write("\x03");
    spawned.proc.stdin.flush();
  } else {
    spawned.proc.kill(how);
  }
  return within(spawned.exited, EXIT_TIMEOUT_MS, `leaving with ${how}`, spawned);
}

function readText(path: string): string {
  try {
    return NodeFS.readFileSync(path, "utf8");
  } catch {
    return "";
  }
}

async function exitedPid(): Promise<number> {
  const proc = Bun.spawn(["true"]);
  await proc.exited;
  return proc.pid;
}

/** The client's own log (`[color-caps startup] …`). */
export function clientLog(ctx: LaunchWorld): string {
  return readText(NodePath.join(home(ctx), "client.log"));
}

/** A fake MC on this machine, recorded under the `--base-dir`; started once per scenario. */
export function runningMc(ctx: LaunchWorld): FakeMc {
  if (ctx.mc) return ctx.mc;
  const running = fakeMc(ctx);
  writeMcRecord(ctx, {
    pid: process.pid,
    origin: running.origin,
    accessToken: running.accessToken,
  });
  return running;
}

/**
 * Start the client against the MC on this machine and wait until it draws, then
 * leave it with `leaveWith` or wait for it to exit; `preload` runs a file first.
 */
export async function runClient(
  ctx: LaunchWorld,
  options: { preload?: string; leaveWith?: "ctrl+c" | "SIGINT" | "SIGTERM" },
): Promise<ProcessRun> {
  runningMc(ctx);
  const env = withTerminal(cleanEnv(ctx), launchSetup(ctx).env);
  const preload = options.preload ? ["--preload", options.preload] : [];
  const spawned = spawn(
    ctx,
    [process.execPath, ...preload, CLIENT_ENTRY, "--base-dir", home(ctx)],
    env,
  );
  const drew = await within(spawned.drawn, DRAW_TIMEOUT_MS, "the client", spawned);
  const code =
    drew && options.leaveWith
      ? await leave(spawned, options.leaveWith)
      : await within(spawned.exited, EXIT_TIMEOUT_MS, "the client", spawned);
  const run = { code, stdout: spawned.output.stdout, stderr: spawned.output.stderr, drew };
  ctx.client = run;
  return run;
}

/** A preload that makes the client fail after it took over the terminal. */
export function faultPreload(ctx: LaunchWorld): string {
  const path = NodePath.join(home(ctx), "fault.ts");
  // `process.once("SIGINT", …)` is the client's first call after the renderer
  // entered the alternate screen (the renderer itself uses addListener).
  NodeFS.writeFileSync(
    path,
    `const once = process.once.bind(process);
process.once = ((event, listener) => {
  if (event === "SIGINT") throw new Error("unrecoverable test fault");
  return once(event, listener);
});
`,
  );
  return path;
}

// --- the MC the client finds or pairs with ---

/** The temp root the client is given as `--base-dir`. */
export function baseDir(ctx: LaunchWorld): string {
  return home(ctx);
}

export function fakeMc(ctx: LaunchWorld, options: { pairingToken?: string } = {}): FakeMc {
  const mc = startFakeMc(options);
  ctx.cleanups.push(() => mc.stop());
  ctx.mc = mc;
  return mc;
}

/** What a running MC leaves under `<root>/{state,data}/elixir`. */
export function writeMcRecord(
  ctx: LaunchWorld,
  record: { pid: number; origin: string; accessToken?: string },
): void {
  const state = NodePath.join(home(ctx), "state/elixir");
  const data = NodePath.join(home(ctx), "data/elixir");
  NodeFS.mkdirSync(state, { recursive: true });
  NodeFS.mkdirSync(data, { recursive: true });
  const url = new URL(record.origin);
  NodeFS.writeFileSync(
    NodePath.join(state, "server-runtime.json"),
    JSON.stringify({
      version: 1,
      pid: record.pid,
      port: Number(url.port),
      origin: record.origin,
      startedAt: new Date().toISOString(),
    }),
  );
  if (record.accessToken)
    NodeFS.writeFileSync(NodePath.join(data, "access-token"), record.accessToken);
}

/** A pid that belonged to a process that has exited. */
export const deadPid = exitedPid;

/** An origin nothing listens on: a port that was free a moment ago. */
export function closedOrigin(): string {
  const server = Bun.serve({ hostname: "127.0.0.1", port: 0, fetch: () => new Response() });
  const origin = `http://127.0.0.1:${server.port}`;
  server.stop(true);
  return origin;
}

/** The paired sessions the client saved under its `--base-dir`. */
export function savedSessions(ctx: LaunchWorld): Record<string, unknown> {
  const text = readText(NodePath.join(home(ctx), "data/tui/credentials.json"));
  return text ? (JSON.parse(text) as { sessions: Record<string, unknown> }).sessions : {};
}

export interface DirectLaunch {
  readonly spawned: Spawned;
}

/**
 * Start the client's entry with `args`. A client that draws stays open in
 * `ctx.direct`; one that exits first is finished into `ctx.client`.
 */
export async function startDirect(ctx: LaunchWorld, args: ReadonlyArray<string>): Promise<void> {
  const env = withTerminal(cleanEnv(ctx), launchSetup(ctx).env);
  const spawned = spawn(ctx, [process.execPath, CLIENT_ENTRY, ...args], env);
  const drew = await within(spawned.drawn, DRAW_TIMEOUT_MS, "the client", spawned);
  if (drew) {
    ctx.direct = { spawned };
    return;
  }
  const code = await within(spawned.exited, EXIT_TIMEOUT_MS, "the client", spawned);
  ctx.client = { code, stdout: spawned.output.stdout, stderr: spawned.output.stderr, drew };
}

/** Leave the open direct client with Ctrl+C and record how it went. */
export async function leaveDirect(ctx: LaunchWorld): Promise<ProcessRun> {
  const direct = ctx.direct;
  if (!direct) throw new Error("no directly started client is open");
  delete ctx.direct;
  const code = await leave(direct.spawned, "ctrl+c");
  const run = {
    code,
    stdout: direct.spawned.output.stdout,
    stderr: direct.spawned.output.stderr,
    drew: true,
  };
  ctx.client = run;
  return run;
}
