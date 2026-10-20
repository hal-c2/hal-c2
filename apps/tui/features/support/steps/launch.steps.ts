// tui/launch.feature: the client finds (or pairs with) an MC, and it gives the
// terminal back when it leaves. These run real processes on pipes (see
// launchWorld.ts); the Ctrl+C key itself goes through the headless host.
import { expect } from "bun:test";

import { step } from "../../steps.ts";
import { TUI_RENDERER_CONFIG } from "../../../src/terminalStartup.ts";
import { FAKE_MC_ENVIRONMENT_ID, type FakeMc } from "../fakeMc.ts";
import {
  baseDir,
  clientLog,
  closedOrigin,
  deadPid,
  ENTER_ALT_SCREEN,
  fakeMc,
  faultPreload,
  LEAVE_ALT_SCREEN,
  launchSetup,
  leaveDirect,
  orderLog,
  RESTORE_SEQUENCES,
  runClient,
  runningMc,
  savedSessions,
  startDirect,
  writeMcRecord,
  type LaunchWorld,
  type ProcessRun,
} from "../launchWorld.ts";

/** How each named terminal identifies itself (TERM, TERM_PROGRAM). */
const TERMINALS: Record<string, { TERM: string; TERM_PROGRAM?: string; KONSOLE_VERSION?: string }> =
  {
    ghostty: { TERM: "xterm-ghostty", TERM_PROGRAM: "ghostty" },
    kitty: { TERM: "xterm-kitty" },
    wezterm: { TERM: "xterm-256color", TERM_PROGRAM: "WezTerm" },
    konsole: { TERM: "xterm-256color", KONSOLE_VERSION: "230804" },
    alacritty: { TERM: "alacritty" },
    foot: { TERM: "foot" },
    iterm: { TERM: "xterm-256color", TERM_PROGRAM: "iTerm.app" },
    rio: { TERM: "rio", TERM_PROGRAM: "rio" },
    contour: { TERM: "contour", TERM_PROGRAM: "contour" },
    // "VS Code" in the ledger's old outline; the step's {word} needs one word.
    vscode: { TERM: "xterm-256color", TERM_PROGRAM: "vscode" },
    // The matcher's `-direct` branch, e.g. a TERM that names direct colour itself.
    "xterm-direct": { TERM: "xterm-direct" },
  };

function client(ctx: LaunchWorld): ProcessRun {
  if (!ctx.client) throw new Error("the client has not run");
  return ctx.client;
}

/** The renderer's own capability report, logged at startup. */
function startupLine(log: string): string {
  const line = log.split("\n").find((entry) => entry.startsWith("[color-caps startup]"));
  if (!line) throw new Error(`the client logged no colour capabilities:\n${log}`);
  return line;
}

function startupCaps(line: string): { rgb: boolean; terminal: { name: string } } {
  return JSON.parse(line.slice(line.indexOf("caps=") + "caps=".length));
}

/** The screen after the last frame: the alternate screen left, cursor, mouse and paste restored. */
function expectTerminalRestored(run: ProcessRun): void {
  expect(run.drew).toBe(true);
  const afterDraw = run.stdout.slice(run.stdout.lastIndexOf(ENTER_ALT_SCREEN));
  expect(afterDraw).toContain(LEAVE_ALT_SCREEN);
  for (const sequence of RESTORE_SEQUENCES) expect(afterDraw).toContain(sequence);
}

step("the user leaves the terminal client", async (ctx: LaunchWorld) => {
  expect((await leaveDirect(ctx)).code).toBe(0);
});

// --- the MC ---

function mc(ctx: LaunchWorld): FakeMc {
  if (!ctx.mc) throw new Error("no MC is running for this scenario");
  return ctx.mc;
}

/** A socket that subscribed the MC's config for its own environment. */
function sessionSockets(ctx: LaunchWorld) {
  return mc(ctx).sockets.filter((socket) =>
    socket.shapes.some(
      (shape) => shape.type === "config" && shape.environment === FAKE_MC_ENVIRONMENT_ID,
    ),
  );
}

async function connected(ctx: LaunchWorld, sockets = 1): Promise<void> {
  await mc(ctx).until(() => sessionSockets(ctx).length >= sockets, "the client's session");
  expect(ctx.direct, ctx.client?.stderr).toBeDefined();
}

function exited(ctx: LaunchWorld): ProcessRun {
  const run = client(ctx);
  expect(run.drew).toBe(false);
  expect(run.code).toBe(1);
  return run;
}

step("an MC is running on this machine", (ctx: LaunchWorld) => {
  runningMc(ctx);
});

step("no MC is running on this machine", () => {});

step("the recorded MC is no longer running", async (ctx: LaunchWorld) => {
  writeMcRecord(ctx, { pid: await deadPid(), origin: closedOrigin(), accessToken: "stale" });
});

step("the recorded MC does not answer", (ctx: LaunchWorld) => {
  writeMcRecord(ctx, { pid: process.pid, origin: closedOrigin(), accessToken: "silent" });
});

step("the user starts the terminal client", async (ctx: LaunchWorld) => {
  await startDirect(ctx, ["--base-dir", baseDir(ctx)]);
});

step("the terminal client connects to that MC", async (ctx: LaunchWorld) => {
  await connected(ctx);
});

step("it signs in with the MC's access token", (ctx: LaunchWorld) => {
  const running = mc(ctx);
  expect(running.ticketBearers[0]).toBe(running.accessToken);
  // No pairing: the access token is not a session of its own.
  expect(running.tokenExchanges).toBe(0);
});

step("it exits saying {string}", (ctx: LaunchWorld, message: string) => {
  expect(exited(ctx).stderr).toContain(message);
});

step("it exits saying the recorded MC is no longer running", (ctx: LaunchWorld) => {
  expect(exited(ctx).stderr).toMatch(/The recorded HAL-C2 MC \(pid \d+\) is no longer running\./);
});

step("it exits saying the MC at the recorded address could not be reached", (ctx: LaunchWorld) => {
  expect(exited(ctx).stderr).toMatch(
    /The HAL-C2 MC at http:\/\/127\.0\.0\.1:\d+ could not be reached/,
  );
});

step("the client buys a socket ticket from the MC over HTTP", async (ctx: LaunchWorld) => {
  await connected(ctx);
  expect(mc(ctx).ticketBearers.length).toBeGreaterThanOrEqual(1);
});

step("the socket URL carries only that ticket", (ctx: LaunchWorld) => {
  const [socket] = sessionSockets(ctx);
  const url = new URL(socket!.url);
  expect(url.pathname).toBe("/ws");
  expect([...url.searchParams.keys()]).toEqual(["wsTicket"]);
  expect(url.searchParams.get("wsTicket")).toBe(socket!.ticket);
});

step("the terminal client is connected to an MC", async (ctx: LaunchWorld) => {
  runningMc(ctx);
  await startDirect(ctx, ["--base-dir", baseDir(ctx)]);
  await connected(ctx);
});

step("the MC drops the connection", (ctx: LaunchWorld) => {
  ctx.ticketsBeforeDrop = mc(ctx).ticketBearers.length;
  mc(ctx).dropConnections();
});

step("the client buys a new socket ticket over HTTP", async (ctx: LaunchWorld) => {
  const running = mc(ctx);
  await running.until(
    () => running.ticketBearers.length > (ctx.ticketsBeforeDrop ?? 0),
    "a new ticket",
  );
  expect(running.ticketBearers.at(-1)).toBe(running.accessToken);
});

step("it reconnects without the user doing anything", async (ctx: LaunchWorld) => {
  await connected(ctx, 2);
  const [first, second] = sessionSockets(ctx);
  expect(second!.ticket).not.toBe(first!.ticket);
});

// --- pairing from the command line ---

const PAIRING_TOKEN = "pair-once";

function pairingLink(ctx: LaunchWorld): string {
  if (!ctx.pairingLink) throw new Error("no pairing link in this scenario");
  return ctx.pairingLink;
}

step("a pairing link from a remote HAL-C2 environment", (ctx: LaunchWorld) => {
  const remote = fakeMc(ctx, { pairingToken: PAIRING_TOKEN });
  ctx.pairingLink = `${remote.origin}/?token=${PAIRING_TOKEN}`;
});

step("a pairing credential that has expired", (ctx: LaunchWorld) => {
  const remote = fakeMc(ctx, { pairingToken: PAIRING_TOKEN });
  // Only the fresh token is accepted; this one was used or timed out.
  ctx.pairingLink = `${remote.origin}/?token=expired-token`;
});

async function startWithLink(ctx: LaunchWorld): Promise<void> {
  await startDirect(ctx, ["--url", pairingLink(ctx), "--base-dir", baseDir(ctx)]);
}

step("the user starts the terminal client with that pairing link", startWithLink);
step("the user starts the terminal client with it", startWithLink);

step("the client connects to the remote environment", async (ctx: LaunchWorld) => {
  await connected(ctx);
  const remote = mc(ctx);
  expect(remote.sessions).toHaveLength(1);
  expect(remote.ticketBearers[0]).toBe(remote.sessions[0]!.bearerToken);
});

step("later launches reuse the paired credential", async (ctx: LaunchWorld) => {
  expect((await leaveDirect(ctx)).code).toBe(0);
  // The link's token is spent; the origin alone brings the saved session back.
  await startDirect(ctx, ["--url", mc(ctx).origin, "--base-dir", baseDir(ctx)]);
  await connected(ctx, 2);
  const remote = mc(ctx);
  expect(remote.tokenExchanges).toBe(1);
  expect(remote.ticketBearers.at(-1)).toBe(remote.sessions[0]!.bearerToken);
});

step("the client says the credential expired and does not connect", (ctx: LaunchWorld) => {
  expect(exited(ctx).stderr).toContain("was already used or has expired");
  expect(mc(ctx).sockets).toEqual([]);
  expect(savedSessions(ctx)).toEqual({});
});

step("the terminal client paired with a remote environment", async (ctx: LaunchWorld) => {
  const remote = fakeMc(ctx, { pairingToken: PAIRING_TOKEN });
  ctx.pairingLink = `${remote.origin}/?token=${PAIRING_TOKEN}`;
  await startWithLink(ctx);
  await connected(ctx);
});

step("the environment still lists the {string} session", (ctx: LaunchWorld, label: string) => {
  expect(mc(ctx).sessions).toMatchObject([{ label, revoked: false }]);
  expect(Object.keys(savedSessions(ctx))).toEqual([mc(ctx).origin]);
});

step("the environment revoked that session", async (ctx: LaunchWorld) => {
  // The client has to be gone before the revocation: a client still running would
  // reconnect, meet the revoked bearer and forget the credential on its own clock,
  // racing the Ctrl+C that is meant to leave it, and the next start would find
  // either a saved revoked session or none. Revoked while closed, it finds the former.
  if (ctx.direct) expect((await leaveDirect(ctx)).code).toBe(0);
  for (const session of mc(ctx).sessions) session.revoked = true;
});

step("the user starts the terminal client for that environment again", async (ctx: LaunchWorld) => {
  await startDirect(ctx, ["--url", mc(ctx).origin, "--base-dir", baseDir(ctx)]);
});

step(
  "the client says its access was revoked and asks for a new pairing link",
  (ctx: LaunchWorld) => {
    const { stderr } = exited(ctx);
    expect(stderr).toContain("revoked this terminal client's access");
    expect(stderr).toContain("new pairing link");
  },
);

step("it forgets the saved credential", (ctx: LaunchWorld) => {
  expect(savedSessions(ctx)).toEqual({});
});

// --- colour ---

step("the user's terminal is {word}", (ctx: LaunchWorld, name: string) => {
  const key = Object.keys(TERMINALS).find((each) => each.toLowerCase() === name.toLowerCase());
  const terminal = key === undefined ? undefined : TERMINALS[key];
  if (!terminal) throw new Error(`unknown terminal "${name}"`);
  Object.assign(launchSetup(ctx).env, { TERM_PROGRAM: undefined, ...terminal });
});

step("the terminal does not set COLORTERM", (ctx: LaunchWorld) => {
  launchSetup(ctx).env.COLORTERM = undefined;
});

step("the shell set COLORTERM to {string}", (ctx: LaunchWorld, value: string) => {
  launchSetup(ctx).env.COLORTERM = value;
});

// A name no terminal gives itself: nothing in TERM or TERM_PROGRAM the client recognises.
step("the user's terminal is not one the client recognises", (ctx: LaunchWorld) => {
  Object.assign(launchSetup(ctx).env, { TERM: "dumb", TERM_PROGRAM: undefined });
});

/** The client's colour report once it has left, so its startup line is certainly written. */
async function leftWithColourReport(ctx: LaunchWorld): Promise<string> {
  if (ctx.direct) expect((await leaveDirect(ctx)).code).toBe(0);
  return startupLine(clientLog(ctx));
}

step("the client advertises truecolor to its renderer", async (ctx: LaunchWorld) => {
  const line = await leftWithColourReport(ctx);
  expect(line).toContain("COLORTERM=truecolor ");
  expect(startupCaps(line).rgb).toBe(true);
});

step(
  "the client keeps the shell's COLORTERM of {string}",
  async (ctx: LaunchWorld, value: string) => {
    expect(await leftWithColourReport(ctx)).toContain(`COLORTERM=${value} `);
  },
);

step("the client does not claim truecolor support", async (ctx: LaunchWorld) => {
  const line = await leftWithColourReport(ctx);
  expect(line).toContain("COLORTERM= ");
  expect(startupCaps(line).rgb).toBe(false);
});

// --- tmux ---

step("the user is not inside tmux", (ctx: LaunchWorld) => {
  const setup = launchSetup(ctx);
  Object.assign(setup.env, { TMUX: undefined, TMUX_PANE: undefined });
  setup.recordOrder = true;
});

const TMUX_PANE = "%7";

step("the user is inside a tmux pane that is in copy mode", (ctx: LaunchWorld) => {
  const setup = launchSetup(ctx);
  Object.assign(setup.env, {
    TMUX: "/tmp/tmux-1000/default,4242,0",
    TMUX_PANE,
  });
  setup.recordOrder = true;
});

step("the client does not run any tmux command", async (ctx: LaunchWorld) => {
  if (ctx.direct) expect((await leaveDirect(ctx)).code).toBe(0);
  const events = orderLog(ctx);
  // The client did start (it took the alternate screen) and called no tmux.
  expect(events).toContain("alt-screen");
  expect(events.filter((event) => event.startsWith("tmux "))).toEqual([]);
});

step("the pane leaves copy mode before the terminal client draws", async (ctx: LaunchWorld) => {
  if (ctx.direct) expect((await leaveDirect(ctx)).code).toBe(0);
  // The client asks tmux other things too (its environment, for inline images).
  const events = orderLog(ctx);
  expect(events).toContain("alt-screen");
  const leftCopyMode = events.indexOf(`tmux copy-mode -q -t ${TMUX_PANE}`);
  expect(leftCopyMode).toBeGreaterThanOrEqual(0);
  expect(leftCopyMode).toBeLessThan(events.indexOf("alt-screen"));
});

// --- the first screen ---

step(
  "an MC is running on this machine that has not sent its first snapshot",
  (ctx: LaunchWorld) => {
    runningMc(ctx, { holdShell: true });
  },
);

function open(ctx: LaunchWorld) {
  if (!ctx.direct) throw new Error(`the client is not open:\n${ctx.client?.stderr}`);
  return ctx.direct.spawned;
}

step("the terminal client opens in the alternate screen", (ctx: LaunchWorld) => {
  expect(open(ctx).output.stdout).toContain(ENTER_ALT_SCREEN);
});

step("the MC is holding the client's request for its first snapshot", async (ctx: LaunchWorld) => {
  // With the shell held, "Connecting…" is what the client shows while the snapshot is outstanding.
  await mc(ctx).until(
    () => mc(ctx).sockets.some((socket) => socket.shapes.some((shape) => shape.type === "shell")),
    "the client's request for the shell snapshot",
  );
});

step("its status line says {string}", async (ctx: LaunchWorld, text: string) => {
  await open(ctx).screen.until(text, "status");
});

step("the MC sends its first snapshot", (ctx: LaunchWorld) => {
  mc(ctx).releaseShell();
});

step("its status line counts the projects and threads", async (ctx: LaunchWorld) => {
  const screen = open(ctx).screen;
  await screen.until("0 project(s) · 0 thread(s)", "status");
  expect(screen.statusLine()).not.toContain("Connecting…");
});

// --- a socket ticket nobody answers ---

/** Client-runtime's default for an authorization request. */
const TICKET_REQUEST_TIMEOUT_MS = 10_000;

step(
  "an MC is running on this machine that does not answer socket ticket requests",
  (ctx: LaunchWorld) => {
    runningMc(ctx, { silentTickets: true });
  },
);

step("the client asks that MC for another socket ticket", async (ctx: LaunchWorld) => {
  // The 10 s timeout and the 2 s reconnect delay are the behaviour, so the wait is theirs.
  await mc(ctx).until(() => mc(ctx).ticketRequests.length >= 2, "a second ticket request", 40_000);
});

step("the first ticket request was given up on only after 10 seconds", async (ctx: LaunchWorld) => {
  const first = mc(ctx).ticketRequests[0]!;
  // The client hangs up before it asks again, but the abort reaches the MC on its own clock.
  await mc(ctx).until(
    () => first.endedAt !== undefined,
    "the client to hang up on the first ticket request",
  );
  const lived = first.endedAt! - first.startedAt;
  // The client's timer starts before the request reaches the MC, and a loaded runner can
  // stretch that gap and the abort's way back; the lower bound is the load-bearing one
  // ("not at once"), while the upper slack only needs to catch a wholesale change of
  // default (30s/60s), so it is wide — a miss here on a loaded runner means rerun first.
  expect(lived).toBeGreaterThanOrEqual(TICKET_REQUEST_TIMEOUT_MS - 1_500);
  expect(lived).toBeLessThan(TICKET_REQUEST_TIMEOUT_MS + 15_000);
});

// --- SSH ---

const SSH_TERMINAL = { TERM: "xterm-ghostty", COLORTERM: "truecolor", TERM_PROGRAM: "ghostty" };

step("the user runs the terminal client over SSH", async (ctx: LaunchWorld) => {
  Object.assign(launchSetup(ctx).env, SSH_TERMINAL, {
    SSH_CONNECTION: "10.0.0.2 50022 10.0.0.1 22",
    SSH_CLIENT: "10.0.0.2 50022 22",
    SSH_TTY: "/dev/pts/9",
  });
  expect((await runClient(ctx, { leaveWith: "ctrl+c" })).code).toBe(0);
});

step(
  "the client keeps the remote terminal's TERM, COLORTERM and TERM_PROGRAM",
  (ctx: LaunchWorld) => {
    const line = startupLine(clientLog(ctx));
    expect(line).toContain(`TERM=${SSH_TERMINAL.TERM} COLORTERM=${SSH_TERMINAL.COLORTERM} `);
    // A remote renderer reads only what the client forwards to it.
    expect(TUI_RENDERER_CONFIG.forwardEnvKeys).toEqual(
      expect.arrayContaining(["TERM", "COLORTERM", "TERM_PROGRAM"]),
    );
    expect(startupCaps(line)).toMatchObject({ rgb: true, terminal: { name: "ghostty" } });
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
    expect(run.stderr).toContain("hal-c2 tui crashed");
  },
);

step("the client exits with status {int}", (ctx: LaunchWorld, status: number) => {
  expect(client(ctx).code).toBe(status);
});
