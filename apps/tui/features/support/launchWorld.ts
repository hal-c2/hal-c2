// Real processes for launch.feature, all on pipes (never a real terminal).
//
// `hal-c2 tui` runs as the real Node launcher against a temp base dir and a fake
// server (a descriptor endpoint plus the runtime file a running server writes).
// A shim stands in for `bun`: it records what the launcher gave it and then runs
// the real client from source, since the launcher's workspace entry is the built
// `dist/index.js`. A fake `tmux` on PATH records calls, so the user's real tmux
// is never touched. Every process is killed by the pid captured at spawn.
import * as NodeFS from "node:fs";
import * as NodeOS from "node:os";
import * as NodePath from "node:path";
import { Database } from "bun:sqlite";

import type { World } from "./world.ts";

const TUI_DIR = NodePath.resolve(import.meta.dir, "../..");
const REPO_ROOT = NodePath.resolve(TUI_DIR, "../..");
const CLIENT_ENTRY = NodePath.join(TUI_DIR, "src/index.ts");
const LAUNCHER = NodePath.join(REPO_ROOT, "apps/server/src/bin.ts");

/** How long a process gets to draw its first frame, or to exit once asked. */
const DRAW_TIMEOUT_MS = 12_000;
const EXIT_TIMEOUT_MS = 6_000;

export const ENTER_ALT_SCREEN = "\x1b[?1049h";
export const LEAVE_ALT_SCREEN = "\x1b[?1049l";
/** What a restored terminal gets back after the alternate screen: cursor, mouse, paste. */
export const RESTORE_SEQUENCES = ["\x1b[?25h", "\x1b[?1000l", "\x1b[?2004l"] as const;

/** The Givens of a launch: which server the runtime file points at, which bun, which terminal. */
export interface LaunchSetup {
  server: "running" | "none" | "stopped";
  /** `HAL_C2_TUI_BUN`: the recording shim, or a path with nothing there. */
  bun: "shim" | "missing";
  /** The terminal's environment; `undefined` removes a key the test process has. */
  env: Record<string, string | undefined>;
}

/** What the shim saw when the launcher started it. */
export interface ShimRecord {
  readonly argv: ReadonlyArray<string>;
  readonly env: { TERM?: string; COLORTERM?: string; TERM_PROGRAM?: string };
  readonly origin?: string;
  readonly bearer: boolean;
  readonly ipc: boolean;
}

export interface SessionRow {
  readonly client_label: string;
  readonly subject: string;
  readonly issued_at: string;
  readonly expires_at: string;
  readonly revoked_at: string | null;
}

export interface ProcessRun {
  readonly code: number | null;
  readonly stdout: string;
  readonly stderr: string;
  readonly drew: boolean;
}

export interface LaunchRun extends ProcessRun {
  readonly bunPath: string;
  readonly shim?: ShimRecord;
  /** `auth_sessions` while the client was open, and after it left. */
  readonly sessionsOpen: ReadonlyArray<SessionRow>;
  readonly sessionsAfter: ReadonlyArray<SessionRow>;
  /** tmux calls made before the first frame, and in all. */
  readonly tmuxBeforeDraw: ReadonlyArray<string>;
  readonly tmux: ReadonlyArray<string>;
  /** The client's own log (`[color-caps startup] …`). */
  readonly log: string;
}

export interface LaunchWorld extends World {
  launch?: LaunchSetup;
  launchHome?: string;
  /** A launched client still open (`the terminal client is open`). */
  opened?: OpenLaunch;
  launched?: LaunchRun;
  /** A client started directly, without the launcher. */
  client?: ProcessRun;
}

export function launchSetup(ctx: LaunchWorld): LaunchSetup {
  return (ctx.launch ??= {
    server: "running",
    bun: "shim",
    env: { TERM: "xterm-256color", COLORTERM: undefined, TERM_PROGRAM: undefined },
  });
}

function home(ctx: LaunchWorld): string {
  if (!ctx.launchHome) {
    const dir = NodeFS.mkdtempSync(NodePath.join(NodeOS.tmpdir(), "hal-c2-tui-launch-"));
    ctx.cleanups.push(() => NodeFS.rmSync(dir, { recursive: true, force: true }));
    NodeFS.mkdirSync(NodePath.join(dir, "data"), { recursive: true });
    NodeFS.mkdirSync(NodePath.join(dir, "state"), { recursive: true });
    NodeFS.mkdirSync(NodePath.join(dir, "bin"), { recursive: true });
    NodeFS.writeFileSync(
      NodePath.join(dir, "bin/tmux"),
      `#!/bin/sh\nprintf '%s\\n' "$*" >> "$HAL_C2_TEST_TMUX_LOG"\n`,
      { mode: 0o755 },
    );
    ctx.launchHome = dir;
  }
  return ctx.launchHome;
}

/** The path the launcher is told to run as bun. */
export function bunPath(ctx: LaunchWorld): string {
  return NodePath.join(home(ctx), "bun-install/bin/bun");
}

function writeShim(path: string): void {
  NodeFS.mkdirSync(NodePath.dirname(path), { recursive: true });
  const source = `#!${process.execPath}
import * as NodeFS from "node:fs";
const env = process.env;
NodeFS.writeFileSync(env.HAL_C2_TEST_SHIM_RECORD, JSON.stringify({
  argv: process.argv.slice(1),
  env: { TERM: env.TERM, COLORTERM: env.COLORTERM, TERM_PROGRAM: env.TERM_PROGRAM },
  origin: env.HAL_C2_TUI_ORIGIN,
  bearer: Boolean(env.HAL_C2_TUI_BEARER),
  ipc: typeof process.send === "function",
}));
await import(${JSON.stringify(CLIENT_ENTRY)});
`;
  NodeFS.writeFileSync(path, source, { mode: 0o755 });
}

/** The test process's env minus anything that would point at real state or a real tmux. */
function cleanEnv(ctx: LaunchWorld): Record<string, string> {
  const env: Record<string, string> = {};
  for (const [key, value] of Object.entries(process.env)) {
    if (value === undefined) continue;
    if (key.startsWith("HAL_C2_TUI_") || key.startsWith("TMUX") || key.startsWith("SSH_")) continue;
    if (key === "HAL_C2_HOME" || key === "COLORTERM" || key === "TERM_PROGRAM") continue;
    env[key] = value;
  }
  const dir = home(ctx);
  env.HOME = dir;
  env.PATH = `${NodePath.join(dir, "bin")}${NodePath.delimiter}${env.PATH ?? ""}`;
  env.HAL_C2_TEST_TMUX_LOG = NodePath.join(dir, "tmux.log");
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

function spawn(
  ctx: LaunchWorld,
  cmd: string[],
  options: { cwd: string; env: Record<string, string>; onDraw?: () => void },
): Spawned {
  const proc = Bun.spawn(cmd, {
    cwd: options.cwd,
    env: options.env,
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
  let onDraw = options.onDraw;
  const readOut = (async () => {
    for await (const chunk of proc.stdout) {
      output.stdout += decoder.decode(chunk, { stream: true });
      if (output.stdout.includes(ENTER_ALT_SCREEN)) {
        onDraw?.();
        onDraw = undefined;
        markDrawn(true);
      }
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

function readSessions(ctx: LaunchWorld): SessionRow[] {
  const path = NodePath.join(home(ctx), "data/statev2.sqlite");
  if (!NodeFS.existsSync(path)) return [];
  const db = new Database(path, { readonly: true });
  try {
    return db
      .query("SELECT client_label, subject, issued_at, expires_at, revoked_at FROM auth_sessions")
      .all() as SessionRow[];
  } finally {
    db.close();
  }
}

function readText(path: string): string {
  try {
    return NodeFS.readFileSync(path, "utf8");
  } catch {
    return "";
  }
}

function lines(text: string): string[] {
  return text.split("\n").filter((line) => line !== "");
}

/** A fake server: the descriptor endpoint the launcher probes, and nothing else. */
function startFakeServer(ctx: LaunchWorld): string {
  const server = Bun.serve({
    hostname: "127.0.0.1",
    port: 0,
    fetch: (request) =>
      new URL(request.url).pathname === "/.well-known/hal-c2/environment"
        ? Response.json({
            environmentId: "launch-test",
            label: "Launch test",
            platform: { os: "linux", arch: "x64" },
            serverVersion: "0.0.0",
            capabilities: {},
          })
        : new Response("not found", { status: 404 }),
  });
  ctx.cleanups.push(() => server.stop(true));
  return `http://127.0.0.1:${server.port}`;
}

async function exitedPid(): Promise<number> {
  const proc = Bun.spawn(["true"]);
  await proc.exited;
  return proc.pid;
}

async function writeRuntimeFile(ctx: LaunchWorld, server: LaunchSetup["server"]) {
  if (server === "none") return;
  const origin = startFakeServer(ctx);
  const pid = server === "running" ? process.pid : await exitedPid();
  const state = {
    version: 1,
    pid,
    port: Number(new URL(origin).port),
    origin,
    startedAt: new Date().toISOString(),
  };
  NodeFS.writeFileSync(
    NodePath.join(home(ctx), "state/server-runtime.json"),
    JSON.stringify(state),
  );
}

export interface OpenLaunch {
  readonly spawned: Spawned;
  readonly bunPath: string;
  readonly tmuxBeforeDraw: string[];
  readonly drew: boolean;
  readonly sessionsOpen: SessionRow[];
}

/** Run `hal-c2 tui` and wait until the client draws (or the launcher gives up). */
export async function openLaunch(ctx: LaunchWorld): Promise<OpenLaunch> {
  const setup = launchSetup(ctx);
  const dir = home(ctx);
  await writeRuntimeFile(ctx, setup.server);
  const bun = setup.bun === "shim" ? bunPath(ctx) : NodePath.join(dir, "no-bun/bin/bun");
  if (setup.bun === "shim") writeShim(bun);
  const env = withTerminal(cleanEnv(ctx), setup.env);
  env.HAL_C2_TUI_BUN = bun;
  env.HAL_C2_TEST_SHIM_RECORD = NodePath.join(dir, "shim.json");
  const tmuxBeforeDraw: string[] = [];
  const spawned = spawn(ctx, ["node", LAUNCHER, "tui", "--base-dir", dir], {
    cwd: REPO_ROOT,
    env,
    onDraw: () => tmuxBeforeDraw.push(...lines(readText(env.HAL_C2_TEST_TMUX_LOG!))),
  });
  const drew = await within(spawned.drawn, DRAW_TIMEOUT_MS, "hal-c2 tui", spawned);
  return {
    spawned,
    bunPath: bun,
    tmuxBeforeDraw,
    drew,
    sessionsOpen: drew ? readSessions(ctx) : [],
  };
}

/** Leave an opened launch with Ctrl+C and collect everything the scenario checks. */
export async function finishLaunch(ctx: LaunchWorld, open: OpenLaunch): Promise<LaunchRun> {
  const { spawned } = open;
  const code = open.drew
    ? await leave(spawned, "ctrl+c")
    : await within(spawned.exited, EXIT_TIMEOUT_MS, "hal-c2 tui", spawned);
  const dir = home(ctx);
  const shimText = readText(NodePath.join(dir, "shim.json"));
  return {
    code,
    stdout: spawned.output.stdout,
    stderr: spawned.output.stderr,
    drew: open.drew,
    bunPath: open.bunPath,
    ...(shimText ? { shim: JSON.parse(shimText) as ShimRecord } : {}),
    sessionsOpen: open.sessionsOpen,
    sessionsAfter: readSessions(ctx),
    tmuxBeforeDraw: open.tmuxBeforeDraw,
    tmux: lines(readText(NodePath.join(dir, "tmux.log"))),
    log: readText(NodePath.join(dir, "state/server-runtime.json.tui.log")),
  };
}

export async function runLaunch(ctx: LaunchWorld): Promise<LaunchRun> {
  const run = await finishLaunch(ctx, await openLaunch(ctx));
  ctx.launched = run;
  return run;
}

/**
 * Start the client directly (no launcher, so no IPC parent). `credentials: false`
 * leaves out HAL_C2_TUI_ORIGIN and HAL_C2_TUI_BEARER; `preload` runs a file first.
 */
export async function runClient(
  ctx: LaunchWorld,
  options: {
    credentials?: boolean;
    preload?: string;
    leaveWith?: "ctrl+c" | "SIGINT" | "SIGTERM";
  },
): Promise<ProcessRun> {
  const dir = home(ctx);
  const env = withTerminal(cleanEnv(ctx), launchSetup(ctx).env);
  env.HAL_C2_TUI_LOG = NodePath.join(dir, "client.log");
  env.HAL_C2_TUI_SHELL_DIR = NodePath.join(dir, "shell");
  if (options.credentials !== false) {
    // Nothing listens there: the client stays on "Connecting…".
    env.HAL_C2_TUI_ORIGIN = "http://127.0.0.1:9";
    env.HAL_C2_TUI_BEARER = "launch-test";
  }
  const preload = options.preload ? ["--preload", options.preload] : [];
  const spawned = spawn(ctx, [process.execPath, ...preload, CLIENT_ENTRY], {
    cwd: TUI_DIR,
    env,
  });
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
