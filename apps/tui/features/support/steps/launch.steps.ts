// tui/launch.feature: `t3 tui` starts the client next to a running server and
// the client gives the terminal back when it leaves. These run real processes on
// pipes (see launchWorld.ts); the Ctrl+C key itself goes through the headless host.
import { expect } from "bun:test";

import { step } from "../../steps.ts";
import { TUI_RENDERER_CONFIG } from "../../../src/terminalStartup.ts";
import {
  bunPath,
  ENTER_ALT_SCREEN,
  faultPreload,
  finishLaunch,
  LEAVE_ALT_SCREEN,
  launchSetup,
  openLaunch,
  RESTORE_SEQUENCES,
  runClient,
  runLaunch,
  type LaunchRun,
  type LaunchWorld,
  type ProcessRun,
} from "../launchWorld.ts";

const TUI_SESSION_LABEL = "T3 Code TUI";
const DAY_MS = 24 * 60 * 60 * 1000;

/** How each named terminal identifies itself (TERM, TERM_PROGRAM). */
const TERMINALS: Record<string, { TERM: string; TERM_PROGRAM?: string; KONSOLE_VERSION?: string }> =
  {
    ghostty: { TERM: "xterm-ghostty", TERM_PROGRAM: "ghostty" },
    kitty: { TERM: "xterm-kitty" },
    wezterm: { TERM: "xterm-256color", TERM_PROGRAM: "WezTerm" },
    alacritty: { TERM: "alacritty" },
    foot: { TERM: "foot" },
    rio: { TERM: "rio", TERM_PROGRAM: "rio" },
    contour: { TERM: "contour", TERM_PROGRAM: "contour" },
    iTerm: { TERM: "xterm-256color", TERM_PROGRAM: "iTerm.app" },
    "VS Code": { TERM: "xterm-256color", TERM_PROGRAM: "vscode" },
    konsole: { TERM: "xterm-256color", KONSOLE_VERSION: "230804" },
  };

function launched(ctx: LaunchWorld): LaunchRun {
  if (!ctx.launched) throw new Error('no launch ran: use "When the user runs "t3 tui""');
  return ctx.launched;
}

function client(ctx: LaunchWorld): ProcessRun {
  if (!ctx.client) throw new Error("the client was not started directly");
  return ctx.client;
}

/** The renderer's own capability report, logged at startup. */
function startupCaps(run: LaunchRun): { rgb: boolean; terminal: { name: string } } {
  const line = run.log.split("\n").find((entry) => entry.startsWith("[color-caps startup]"));
  if (!line) throw new Error(`the client logged no colour capabilities:\n${run.log}`);
  return JSON.parse(line.slice(line.indexOf("caps=") + "caps=".length));
}

function tuiSessions(rows: LaunchRun["sessionsOpen"]) {
  return rows.filter((row) => row.client_label === TUI_SESSION_LABEL);
}

/** The screen after the last frame: the alternate screen left, cursor, mouse and paste restored. */
function expectTerminalRestored(run: ProcessRun): void {
  expect(run.drew).toBe(true);
  const afterDraw = run.stdout.slice(run.stdout.lastIndexOf(ENTER_ALT_SCREEN));
  expect(afterDraw).toContain(LEAVE_ALT_SCREEN);
  for (const sequence of RESTORE_SEQUENCES) expect(afterDraw).toContain(sequence);
}

// --- the server and bun ---

step("a T3 Code server is running on this machine", (ctx: LaunchWorld) => {
  launchSetup(ctx).server = "running";
});

step("no T3 Code server is running on this machine", (ctx: LaunchWorld) => {
  launchSetup(ctx).server = "none";
});

step("the recorded T3 Code server is no longer running", (ctx: LaunchWorld) => {
  launchSetup(ctx).server = "stopped";
});

// The launcher only finds bun through T3_TUI_BUN or PATH; the test's own node
// and bun share PATH, so "not installed" is a T3_TUI_BUN pointing at nothing.
step("Bun is not installed", (ctx: LaunchWorld) => {
  launchSetup(ctx).bun = "missing";
});

step("the environment variable {string} names a Bun binary", (ctx: LaunchWorld, name: string) => {
  expect(name).toBe("T3_TUI_BUN");
  launchSetup(ctx).bun = "shim";
});

step("the terminal client opens in the alternate screen", (ctx: LaunchWorld) => {
  const run = launched(ctx);
  expect(run.drew, run.stderr).toBe(true);
  expect(run.shim?.origin).toMatch(/^http:\/\/127\.0\.0\.1:\d+$/);
  expect(run.shim?.bearer).toBe(true);
  expect(run.shim?.ipc).toBe(true);
  expect(run.code).toBe(0);
});

step("the command fails with {string}", (ctx: LaunchWorld, message: string) => {
  const run = launched(ctx);
  expect(run.drew).toBe(false);
  expect(run.stderr).toContain(message);
  expect(run.code).not.toBe(0);
});

step("the command fails and says the recorded server is no longer running", (ctx: LaunchWorld) => {
  const run = launched(ctx);
  expect(run.drew).toBe(false);
  expect(run.stderr).toContain("The recorded T3 Code server is no longer running.");
  expect(run.code).not.toBe(0);
});

step("the command fails with a hint to install Bun from bun.sh", (ctx: LaunchWorld) => {
  const run = launched(ctx);
  expect(run.drew).toBe(false);
  expect(run.stderr).toContain("needs Bun");
  expect(run.stderr).toContain("https://bun.sh");
  expect(run.code).not.toBe(0);
  // The session issued for the client is not left behind.
  for (const row of tuiSessions(run.sessionsAfter)) expect(row.revoked_at).not.toBeNull();
});

step("the terminal client runs on that Bun binary", (ctx: LaunchWorld) => {
  const run = launched(ctx);
  expect(run.drew, run.stderr).toBe(true);
  expect(run.shim?.argv[0]).toBe(bunPath(ctx));
  expect(run.shim?.argv[1]).toMatch(/tui[\\/](?:dist[\\/])?index\.js$/);
});

// --- the session ---

step("the server lists a client session labelled {string}", (ctx: LaunchWorld, label: string) => {
  expect(label).toBe(TUI_SESSION_LABEL);
  const open = tuiSessions(launched(ctx).sessionsOpen);
  expect(open).toHaveLength(1);
  expect(open[0]).toMatchObject({ subject: "t3-tui", revoked_at: null });
});

step("the session expires after {int} days if never closed", (ctx: LaunchWorld, days: number) => {
  const [session] = tuiSessions(launched(ctx).sessionsOpen);
  const lifetime = Date.parse(session!.expires_at) - Date.parse(session!.issued_at);
  expect(lifetime).toBe(days * DAY_MS);
});

step("the terminal client is open", async (ctx: LaunchWorld) => {
  ctx.opened = await openLaunch(ctx);
  expect(ctx.opened.drew, ctx.opened.spawned.output.stderr).toBe(true);
  expect(tuiSessions(ctx.opened.sessionsOpen)).toMatchObject([{ revoked_at: null }]);
});

step("the user leaves the terminal client", async (ctx: LaunchWorld) => {
  if (!ctx.opened) throw new Error("the terminal client is not open");
  ctx.launched = await finishLaunch(ctx, ctx.opened);
  expect(ctx.launched.code).toBe(0);
});

step("the server no longer lists the {string} session", (ctx: LaunchWorld, label: string) => {
  expect(label).toBe(TUI_SESSION_LABEL);
  const after = tuiSessions(launched(ctx).sessionsAfter);
  expect(after).toHaveLength(1);
  expect(after[0]!.revoked_at).not.toBeNull();
});

// --- starting the client directly ---

step(
  "the terminal client is started directly without an origin or bearer credential",
  async (ctx: LaunchWorld) => {
    await runClient(ctx, { credentials: false });
  },
);

step("it exits with an error naming the missing value", (ctx: LaunchWorld) => {
  const run = client(ctx);
  expect(run.drew).toBe(false);
  expect(run.code).toBe(1);
  expect(run.stderr).toContain("T3_TUI_ORIGIN");
  expect(run.stderr).toContain("T3_TUI_BEARER");
});

// --- colour ---

step("the user's terminal is {word}", (ctx: LaunchWorld, name: string) => {
  const key = Object.keys(TERMINALS).find((each) => each.toLowerCase() === name.toLowerCase());
  const terminal = key === undefined ? undefined : TERMINALS[key];
  if (!terminal) throw new Error(`unknown terminal "${name}"`);
  Object.assign(launchSetup(ctx).env, { TERM_PROGRAM: undefined, ...terminal });
});

step("the user's terminal is VS Code", (ctx: LaunchWorld) => {
  Object.assign(launchSetup(ctx).env, TERMINALS["VS Code"]);
});

step("the user's terminal is not one the client recognises", (ctx: LaunchWorld) => {
  Object.assign(launchSetup(ctx).env, { TERM: "xterm-256color", TERM_PROGRAM: "Apple_Terminal" });
});

step("the terminal does not set COLORTERM", (ctx: LaunchWorld) => {
  launchSetup(ctx).env.COLORTERM = undefined;
});

step("the shell already set COLORTERM", (ctx: LaunchWorld) => {
  launchSetup(ctx).env.COLORTERM = "24bit";
});

step("the terminal client renders in truecolor", (ctx: LaunchWorld) => {
  const run = launched(ctx);
  // The native renderer reads COLORTERM from the environ it was spawned with.
  expect(run.shim?.env.COLORTERM).toBe("truecolor");
  expect(startupCaps(run).rgb).toBe(true);
});

step("the terminal client keeps the shell's COLORTERM", (ctx: LaunchWorld) => {
  expect(launched(ctx).shim?.env.COLORTERM).toBe("24bit");
});

step("the client does not claim truecolor support", (ctx: LaunchWorld) => {
  const run = launched(ctx);
  expect(run.shim?.env.COLORTERM).toBeUndefined();
  expect(startupCaps(run).rgb).toBe(false);
});

// --- tmux ---

step("the user is not inside tmux", (ctx: LaunchWorld) => {
  Object.assign(launchSetup(ctx).env, { TMUX: undefined, TMUX_PANE: undefined });
});

step("the user is inside a tmux pane that is in copy mode", (ctx: LaunchWorld) => {
  Object.assign(launchSetup(ctx).env, { TMUX: "/tmp/tmux-1000/default,4242,0", TMUX_PANE: "%7" });
});

step("the client does not run any tmux command", (ctx: LaunchWorld) => {
  const run = launched(ctx);
  expect(run.drew).toBe(true);
  expect(run.tmux).toEqual([]);
});

step("the pane leaves copy mode before the terminal client draws", (ctx: LaunchWorld) => {
  expect(launched(ctx).tmuxBeforeDraw).toContain("copy-mode -q -t %7");
});

// --- SSH ---

const SSH_TERMINAL = { TERM: "xterm-ghostty", COLORTERM: "truecolor", TERM_PROGRAM: "ghostty" };

step("the user runs the terminal client over SSH", async (ctx: LaunchWorld) => {
  Object.assign(launchSetup(ctx).env, SSH_TERMINAL, {
    SSH_CONNECTION: "10.0.0.2 50022 10.0.0.1 22",
    SSH_CLIENT: "10.0.0.2 50022 22",
    SSH_TTY: "/dev/pts/9",
  });
  await runLaunch(ctx);
});

step(
  "the client keeps the remote terminal's TERM, COLORTERM and TERM_PROGRAM",
  (ctx: LaunchWorld) => {
    const run = launched(ctx);
    expect(run.shim?.env).toEqual(SSH_TERMINAL);
    // A remote renderer reads only what the client forwards to it.
    expect(TUI_RENDERER_CONFIG.forwardEnvKeys).toEqual(
      expect.arrayContaining(["TERM", "COLORTERM", "TERM_PROGRAM"]),
    );
    expect(startupCaps(run)).toMatchObject({ rgb: true, terminal: { name: "ghostty" } });
  },
);

// --- leaving ---

step(
  "the terminal client closes and the terminal returns to its previous screen",
  async (ctx: LaunchWorld) => {
    // The key reached the host's quit (headless), and a real client given the same
    // key on its input gives the screen back.
    expect(ctx.quitRequested).toBe(true);
    const run = await runClient(ctx, { leaveWith: "ctrl+c" });
    expect(run.code).toBe(0);
    expectTerminalRestored(run);
  },
);

step("the terminal client receives {word}", async (ctx: LaunchWorld, signal: string) => {
  if (signal !== "SIGINT" && signal !== "SIGTERM") throw new Error(`unexpected signal ${signal}`);
  await runClient(ctx, { leaveWith: signal });
});

step("the terminal client closes and restores the terminal", (ctx: LaunchWorld) => {
  expectTerminalRestored(client(ctx));
});

/** `it exits with status {int}` after the client was started directly (routed in common.steps.ts). */
export function expectClientStatus(ctx: LaunchWorld, status: number): void {
  expect(client(ctx).code).toBe(status);
}

step("the terminal client hits an unrecoverable error", async (ctx: LaunchWorld) => {
  await runClient(ctx, { preload: faultPreload(ctx) });
});

step(
  "the terminal leaves the alternate screen with the cursor and input restored",
  (ctx: LaunchWorld) => {
    const run = client(ctx);
    expectTerminalRestored(run);
    expect(run.stderr).toContain("t3 tui crashed");
  },
);

step("the client exits with status {int}", (ctx: LaunchWorld, status: number) => {
  expect(client(ctx).code).toBe(status);
});
