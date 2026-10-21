// Real processes for launch.feature, all on pipes (never a real terminal).
//
// The client finds a fake protocol-3 MC (fakeMc.ts) through the runtime record
// and access token under a temp `--base-dir`, or pairs with it from `--url`.
// Every process is killed by the pid captured at spawn.
import * as NodeFS from "node:fs";
import * as NodeOS from "node:os";
import * as NodePath from "node:path";

import * as XtermHeadless from "@xterm/headless";

import { startFakeMc, type FakeMc, type FakeMcOptions } from "./fakeMc.ts";
import type { World } from "./world.ts";

const TUI_DIR = NodePath.resolve(import.meta.dir, "../..");
const CLIENT_ENTRY = NodePath.join(TUI_DIR, "src/index.ts");

/**
 * How long a process gets to draw its first frame, or to exit once asked. The
 * draw and the exit are the signals the steps wait on, and both always arrive
 * (a client that fails exits instead of drawing); these only guard a hang and
 * put the client's stderr in the failure. A cold bun start on a loaded machine
 * takes many seconds with the CPU idle, so they sit well above that.
 */
const DRAW_TIMEOUT_MS = 30_000;
const EXIT_TIMEOUT_MS = 15_000;
/** How long a screen gets to show what a step waits for, once the client drew; it only guards a regression. */
const SCREEN_TIMEOUT_MS = 15_000;

export const ENTER_ALT_SCREEN = "\x1b[?1049h";
export const LEAVE_ALT_SCREEN = "\x1b[?1049l";
/** What a restored terminal gets back after the alternate screen: cursor, mouse, paste. */
export const RESTORE_SEQUENCES = ["\x1b[?25h", "\x1b[?1000l", "\x1b[?2004l"] as const;

/** The Givens of a launch: the terminal the client starts in. */
export interface LaunchSetup {
  /** The terminal's environment; `undefined` removes a key the test process has. */
  env: Record<string, string | undefined>;
  /**
   * Note `alt-screen` in the order log (`orderPreload`). Only the scenarios that read the
   * log ask for it, so the other launches do not depend on the renderer's internals.
   */
  recordOrder: boolean;
}

const { Terminal } = XtermHeadless;

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
    recordOrder: false,
  });
}

function home(ctx: LaunchWorld): string {
  if (!ctx.launchHome) {
    const dir = NodeFS.mkdtempSync(NodePath.join(NodeOS.tmpdir(), "hal-c2-tui-launch-"));
    ctx.cleanups.push(() => NodeFS.rmSync(dir, { recursive: true, force: true }));
    ctx.launchHome = dir;
    // A `tmux` that only writes down its call, ahead of any real one, so the
    // client can never reach the tester's tmux (see `orderLog`). Created once
    // with the home, so `cleanEnv` stays a pure env computation.
    const bin = NodePath.join(dir, "bin");
    NodeFS.mkdirSync(bin, { recursive: true });
    NodeFS.writeFileSync(
      NodePath.join(bin, "tmux"),
      '#!/bin/sh\necho "tmux $*" >> "$HAL_C2_TEST_ORDER"\n',
      {
        mode: 0o755,
      },
    );
  }
  return ctx.launchHome;
}

function orderPath(ctx: LaunchWorld): string {
  return NodePath.join(home(ctx), "order.log");
}

/**
 * What the client did to its surroundings, one line per event in the order they
 * happened: each `tmux` call, and `alt-screen` once the renderer has taken the
 * alternate screen (written by `orderPreload`, which every launch adds once `recordOrder` is set).
 * Appends from different processes are ordered by the file, not by clocks.
 */
export function orderLog(ctx: LaunchWorld): string[] {
  if (!launchSetup(ctx).recordOrder) {
    throw new Error("the order log was not asked for: a Given must set recordOrder first");
  }
  return readText(orderPath(ctx)).split("\n").filter(Boolean);
}

/**
 * A preload that notes `alt-screen` in the order log when the renderer's
 * `setupTerminal` (which enters the alternate screen) returns, before
 * `createCliRenderer` hands the renderer back. Every call is noted, even one the renderer
 * ignores because the terminal is already set up, so read the log for "present", not "once".
 * The renderer class is resolved from the client's directory, so it is the module the client
 * loads.
 */
function orderPreload(ctx: LaunchWorld): string {
  const path = NodePath.join(home(ctx), "order.ts");
  NodeFS.writeFileSync(
    path,
    `import { appendFileSync } from "node:fs";
const { CliRenderer } = await import(Bun.resolveSync("@opentui/core", ${JSON.stringify(TUI_DIR)}));
const setupTerminal = CliRenderer.prototype.setupTerminal;
if (typeof setupTerminal !== "function") {
  throw new Error("orderPreload: @opentui/core's CliRenderer no longer has setupTerminal; update the order patch");
}
CliRenderer.prototype.setupTerminal = function (...args: unknown[]) {
  const result = setupTerminal.apply(this, args);
  const note = () => appendFileSync(process.env.HAL_C2_TEST_ORDER!, "alt-screen\\n");
  if (result && typeof result.then === "function") {
    return result.then((value: unknown) => {
      note();
      return value;
    });
  }
  note();
  return result;
};
`,
  );
  return path;
}

/**
 * What else a terminal leaves in its shell's environment for tools to identify it by. The
 * renderer reads these too, so the terminal a scenario claims is the only one present.
 * Families are stripped by prefix, so a marker the renderer learns to read cannot leak
 * the tester's real terminal in just because its exact name is new.
 */
const TERMINAL_MARKER_PREFIXES = [
  "KITTY_",
  "WEZTERM_",
  "GHOSTTY_",
  "ALACRITTY_",
  "KONSOLE_",
  "ITERM_",
  "WT_",
  "VTE_",
  "GNOME_TERMINAL_",
];
const TERMINAL_MARKERS = new Set(["LC_TERMINAL", "TERM_SESSION_ID", "TERMINAL_EMULATOR"]);

/** The test process's env minus anything that would point at real state or a real tmux. */
function cleanEnv(ctx: LaunchWorld): Record<string, string> {
  const env: Record<string, string> = {};
  for (const [key, value] of Object.entries(process.env)) {
    if (value === undefined) continue;
    if (key.startsWith("HAL_C2_TUI_") || key.startsWith("TMUX") || key.startsWith("SSH_")) continue;
    if (key === "HAL_C2_HOME" || key === "HAL_C2_MC_HOME" || key.startsWith("XDG_")) continue;
    // The screen model below assumes the pipe renderer draws 80x24 inside a 100x30
    // screen; an inherited size would break that assumption on shells that export one.
    if (key === "COLUMNS" || key === "LINES") continue;
    if (key === "COLORTERM" || key === "TERM_PROGRAM" || TERMINAL_MARKERS.has(key)) continue;
    if (TERMINAL_MARKER_PREFIXES.some((prefix) => key.startsWith(prefix))) continue;
    env[key] = value;
  }
  const dir = home(ctx);
  env.HOME = dir;
  env.HAL_C2_TUI_LOG = NodePath.join(dir, "client.log");
  env.HAL_C2_TUI_SHELL_DIR = NodePath.join(dir, "shell");
  const bin = NodePath.join(dir, "bin");
  env.PATH = `${bin}${NodePath.delimiter}${env.PATH ?? ""}`;
  env.HAL_C2_TEST_ORDER = orderPath(ctx);
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
  /** The terminal the client's output draws, as the user would see it. */
  readonly screen: {
    /** The screen's last non-blank row: where the client draws its status line. */
    statusLine(): string;
    /** Resolves once the screen, or just its status line, shows `text`. */
    until(text: string, where?: "screen" | "status"): Promise<void>;
  };
}

function spawn(ctx: LaunchWorld, cmd: string[], env: Record<string, string>): Spawned {
  // The renderer on a pipe has no columns or rows of its own and draws 80x24, inside this
  // larger screen. Rows below its last stay blank, which is what makes `statusLine()` (the last
  // non-blank row) the client's status row; anything the client wrote below it would move that.
  const terminal = new Terminal({ cols: 100, rows: 30, allowProposedApi: true });
  // Cleanups run reversed, so registering dispose before the kill below kills the
  // client first and only then disposes the terminal it may still be writing to.
  ctx.cleanups.push(() => terminal.dispose());
  const proc = Bun.spawn(cmd, {
    cwd: TUI_DIR,
    env,
    stdin: "pipe",
    stdout: "pipe",
    stderr: "pipe",
  });
  // The drained promise (process dead and both streams read to the end, so
  // every queued terminal write has fired) is built below; the kill cleanup
  // awaits it through this late-bound variable so dispose cannot race writes.
  let drained: Promise<number> | undefined;
  ctx.cleanups.push(async () => {
    if (proc.exitCode === null && proc.signalCode === null) {
      proc.kill("SIGKILL");
    }
    await (drained ?? proc.exited);
  });
  const output = { stdout: "", stderr: "" };
  let markDrawn: (drew: boolean) => void = () => {};
  const drawn = new Promise<boolean>((resolve) => {
    markDrawn = resolve;
  });
  const decoder = new TextDecoder();
  const screenWaiters = new Set<() => void>();
  const screenText = () => {
    const buffer = terminal.buffer.active;
    const lines: string[] = [];
    for (let y = 0; y < terminal.rows; y++) {
      lines.push(buffer.getLine(buffer.viewportY + y)?.translateToString(true) ?? "");
    }
    return lines.join("\n");
  };
  const statusLine = () =>
    screenText()
      .split("\n")
      .findLast((line) => line.trim() !== "") ?? "";
  const readOut = (async () => {
    for await (const chunk of proc.stdout) {
      output.stdout += decoder.decode(chunk, { stream: true });
      // Parsed asynchronously: the screen is ready, and waiters re-check, when xterm is done.
      terminal.write(chunk, () => {
        for (const waiter of screenWaiters) waiter();
      });
      if (output.stdout.includes(ENTER_ALT_SCREEN)) markDrawn(true);
    }
  })();
  const readErr = (async () => {
    output.stderr += await new Response(proc.stderr).text();
  })();
  const exited = (async () => {
    const code = await proc.exited;
    await Promise.all([readOut, readErr]);
    // Flush the parser: an empty write's callback runs after every queued
    // one, so after this every terminal write has fired and dispose is safe.
    await new Promise<void>((resolve) => terminal.write(new Uint8Array(0), resolve));
    markDrawn(false);
    return code;
  })();
  drained = exited;
  const screen = {
    statusLine,
    until: (text: string, where = "screen") =>
      new Promise<void>((resolve, reject) => {
        let settled = false;
        const settle = () => {
          settled = true;
          clearTimeout(timer);
          screenWaiters.delete(waiter);
        };
        const waiter = () => {
          if (settled) return;
          if (!(where === "status" ? statusLine() : screenText()).includes(text)) return;
          settle();
          resolve();
        };
        // A screen that never shows the text fails the step, so the scenario's cleanup runs.
        const timer = setTimeout(() => {
          settle();
          reject(
            new Error(
              `the ${where === "status" ? "status line" : "screen"} never showed ${JSON.stringify(text)}; the screen shows:\n${screenText()}\nstderr:\n${output.stderr}`,
            ),
          );
        }, SCREEN_TIMEOUT_MS);
        // If the client dies first, fail at once with its complete stderr
        // (`exited` only resolves once both streams are drained).
        void exited.then((code) => {
          if (settled) return;
          // Flush the parser first: the final chunk may be queued but not yet
          // parsed, and an empty write's callback runs after every prior one.
          terminal.write(new Uint8Array(0), () => {
            if (settled) return;
            waiter();
            settle();
            reject(
              new Error(
                `the client exited (${code}) before the screen showed ${JSON.stringify(text)}; the screen shows:\n${screenText()}\nstderr:\n${output.stderr}`,
              ),
            );
          });
        });
        screenWaiters.add(waiter);
        waiter();
      }),
  };
  return { proc, output, drawn, exited, screen };
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
export function runningMc(ctx: LaunchWorld, options: FakeMcOptions = {}): FakeMc {
  if (ctx.mc) {
    // The MC is already up with its own options; a Given asking for others would silently get these.
    if (Object.keys(options).length > 0) {
      throw new Error("an MC is already running in this scenario; ask for its options first");
    }
    return ctx.mc;
  }
  const running = fakeMc(ctx, options);
  writeMcRecord(ctx, {
    pid: process.pid,
    origin: running.origin,
    accessToken: running.accessToken,
  });
  return running;
}

/** The `--preload` args every client launch shares, including the order log's. */
function preloadArgs(ctx: LaunchWorld, preload?: string): string[] {
  return [preload, launchSetup(ctx).recordOrder ? orderPreload(ctx) : undefined].flatMap((path) =>
    path ? ["--preload", path] : [],
  );
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
  const preload = preloadArgs(ctx, options.preload);
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

export function fakeMc(ctx: LaunchWorld, options: FakeMcOptions = {}): FakeMc {
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
  const setup = launchSetup(ctx);
  const env = withTerminal(cleanEnv(ctx), setup.env);
  const preload = preloadArgs(ctx);
  const spawned = spawn(ctx, [process.execPath, ...preload, CLIENT_ENTRY, ...args], env);
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
