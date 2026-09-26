// tui/reconnect.feature: the client's supervisor re-mints a socket ticket from
// its launcher on every reconnect, and a silent or vanished launcher fails the
// request instead of hanging the loop (see reconnectWorld.ts).
import { expect } from "bun:test";

import { step } from "../../steps.ts";
import { SOCKET_TICKET_TIMEOUT_MS } from "../../../src/socketTicket.ts";
import { threadKey } from "../../../src/host/sidebarState.ts";
import { shell } from "../fakeClient.ts";
import { startConnection, type ConnectionHarness, type ReconnectWorld } from "../reconnectWorld.ts";
import { boot, snapshot, useClient } from "../world.ts";

function connection(ctx: ReconnectWorld): ConnectionHarness {
  if (!ctx.connection) throw new Error("the client is not connected");
  return ctx.connection;
}

const shownPage = (ctx: ReconnectWorld) =>
  ctx.host!.state.get("page") as { kind: string; key?: string };

const connectionState = (ctx: ReconnectWorld) =>
  (ctx.host!.state.get("connection") as { state: string }).state;

step("the terminal client is connected and showing a thread", async (ctx: ReconnectWorld) => {
  const snapshotWithThreads = shell();
  const fake = useClient(ctx, { shellSnapshot: snapshotWithThreads });
  await boot(ctx);
  await startConnection(ctx);
  fake.connect();
  const key = threadKey(snapshotWithThreads.threads[0]!.id);
  ctx.host!.dispatch("thread.open", { key });
  await snapshot(ctx);
  expect(shownPage(ctx)).toMatchObject({ kind: "thread", key });
  expect(connectionState(ctx)).toBe("connected");
});

step("the connection to the server drops", async (ctx: ReconnectWorld) => {
  ctx.pageBeforeDrop = shownPage(ctx);
  await connection(ctx).drop();
});

step("the client asks its launcher for a new socket ticket", async (ctx: ReconnectWorld) => {
  const conn = connection(ctx);
  const outcome = await conn.settled(await conn.requested(2));
  expect(outcome).toEqual({ url: expect.stringContaining("wsTicket=") });
  await conn.connected(2);
  expect(conn.connects[1]).toBe((outcome as { url: string }).url);
  expect(conn.connects[1]).not.toBe(conn.connects[0]);
});

step("it reconnects without the user doing anything", async (ctx: ReconnectWorld) => {
  const conn = connection(ctx);
  await conn.connected(2);
  expect(conn.phases).toEqual(["connecting", "connected", "reconnecting", "connected"]);
  await snapshot(ctx);
  expect(connectionState(ctx)).toBe("connected");
  expect(shownPage(ctx)).toEqual(ctx.pageBeforeDrop!);
});

step("the launcher does not answer a socket ticket request", async (ctx: ReconnectWorld) => {
  const conn = connection(ctx);
  conn.silenceLauncher();
  await conn.drop();
  expect((await conn.requested(2)).outcome).toBeUndefined();
});

step("the request fails after {int} seconds", async (ctx: ReconnectWorld, seconds: number) => {
  const conn = connection(ctx);
  const request = conn.requests[1]!;
  const timer = conn.timers[1]!;
  expect(timer.ms).toBe(seconds * 1000);
  expect(SOCKET_TICKET_TIMEOUT_MS).toBe(seconds * 1000);
  expect(request.outcome).toBeUndefined();
  timer.fire();
  expect(await conn.settled(request)).toEqual({ error: "timed out minting a websocket url" });
});

step("the client keeps trying to reconnect", async (ctx: ReconnectWorld) => {
  const conn = connection(ctx);
  await conn.requested(3);
  expect(connectionState(ctx)).toBe("reconnecting");
});

step("ticket requests are waiting on the launcher", async (ctx: ReconnectWorld) => {
  const conn = connection(ctx);
  conn.silenceLauncher();
  await conn.drop();
  await conn.requested(2);
  conn.mint();
  await conn.requested(3);
  expect(conn.requests.slice(1).map((request) => request.outcome)).toEqual([undefined, undefined]);
});

step("the launcher process goes away", (ctx: ReconnectWorld) => {
  connection(ctx).launcherGone();
});

step("every waiting ticket request fails at once", async (ctx: ReconnectWorld) => {
  const conn = connection(ctx);
  const waiting = conn.requests.slice(1, 3);
  const outcomes = await Promise.all(waiting.map((request) => conn.settled(request)));
  expect(outcomes).toEqual([
    { error: "t3 parent IPC channel closed" },
    { error: "t3 parent IPC channel closed" },
  ]);
  // Their timeouts are cancelled, not what failed them.
  expect(conn.timers.slice(1, 3).every((timer) => timer.cleared)).toBe(true);
});
