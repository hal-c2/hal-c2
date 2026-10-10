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

step("the environment revoked that session", (ctx: LaunchWorld) => {
  const remote = mc(ctx);
  for (const session of remote.sessions) session.revoked = true;
  remote.dropConnections();
});

step("the user starts the terminal client for that environment again", async (ctx: LaunchWorld) => {
  if (ctx.direct) await leaveDirect(ctx);
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
