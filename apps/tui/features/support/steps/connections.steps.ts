// Connections from the terminal (features/connections/): linking the MC to
// another environment, who may reach this machine (pairing links and paired
// clients, followed live), the notice for a server behind this app, and a
// cluster member that left. The fake MC answers by the real wire methods.
import { expect } from "bun:test";
import type { AuthAccessStreamEvent } from "@hal-c2/contracts";

import type { TuiClusterState } from "../../../src/host/clusterState.ts";
import { memoryMutedThreads } from "../../../src/host/mutedThreads.ts";
import type { TuiUpdateNotice } from "../../../src/host/sections/updates.ts";
import type { TuiSettingsState } from "../../../src/host/settingsState.ts";
import { step } from "../../steps.ts";
import {
  chooseRow,
  connected,
  fillField,
  fixture,
  linkMachine,
  mc,
  pageText,
  paneWords,
  sectionState,
  type SettingsWorld,
} from "../settingsWorld.ts";
import { runPaletteCommand } from "./controls.steps.ts";
import { advance, pressKey, settle, snapshot, useClient, type World } from "../world.ts";

interface Session {
  sessionId: string;
  label: string;
  current: boolean;
  connected: boolean;
}

interface ConnectionsWorld extends SettingsWorld {
  /** The MC's access list: its unused pairing links and its paired clients. */
  access?: { links: Array<{ id: string; label: string }>; sessions: Session[]; revision: number };
  /** The pairing link the scenario holds for another environment. */
  pairingLink?: string;
  /** The client the scenario is about. */
  subject?: string;
}

const PAIRING_LINK = "http://beast.example:3773/pair#token=one-time";
const statusOf = (ctx: World) => ctx.host!.state.get("status") as { kind: string; text: string };
const words = (text: string) => text.replace(/[│╭╮╰╯─]/g, " ").replace(/\s+/g, " ");

// --- The access list ---------------------------------------------------------------

const wireSession = (session: Session) =>
  ({
    sessionId: session.sessionId,
    subject: "paired-client",
    scopes: ["orchestration:read", "orchestration:operate"],
    method: "bearer-access-token",
    client: { label: session.label, deviceType: "desktop" },
    issuedAt: "2026-09-28T10:00:00Z",
    expiresAt: "2026-10-28T10:00:00Z",
    lastConnectedAt: null,
    connected: session.connected,
    current: session.current,
  }) as never;

const wireLink = (link: { id: string; label: string }) =>
  ({
    id: link.id,
    label: link.label,
    scopes: ["orchestration:read"],
    subject: "pairing-link",
    createdAt: "2026-09-28T10:00:00Z",
    expiresAt: "2026-09-28T10:10:00Z",
  }) as never;

/** The MC's access list, with the terminal's own session in it, served as the MC serves it. */
function access(ctx: ConnectionsWorld) {
  if (ctx.access) return ctx.access;
  const state = {
    links: [{ id: "link-1", label: "For the tablet" }],
    sessions: [{ sessionId: "session-tui", label: "Terminal", current: true, connected: true }],
    revision: 1,
  };
  ctx.access = state;
  const fake = mc(ctx);
  const emit = (type: string, payload: unknown) =>
    fake.emitAuthAccess({
      version: 1,
      revision: ++state.revision,
      type,
      payload,
    } as unknown as AuthAccessStreamEvent);
  fake.onAuthAccessSubscribe = () =>
    emit("snapshot", {
      pairingLinks: state.links.map(wireLink),
      clientSessions: state.sessions.map(wireSession),
    });
  const drop = (sessionId: string) => {
    state.sessions = state.sessions.filter((session) => session.sessionId !== sessionId);
    emit("clientRemoved", { sessionId });
  };
  fake.on("hal-c2.revokeClient", (payload) => {
    const session = state.sessions.find((known) => known.sessionId === payload.sessionId);
    if (session?.current) throw new Error("the current session cannot be revoked");
    if (session) drop(session.sessionId);
    return { revoked: session !== undefined };
  });
  fake.on("hal-c2.revokeOtherClients", () => {
    const others = state.sessions.filter((session) => !session.current);
    for (const session of others) drop(session.sessionId);
    return { revokedCount: others.length };
  });
  return state;
}

/** Another client pairs with the MC: it is in the list and everyone watching is told. */
function pair(ctx: ConnectionsWorld, label: string): Session {
  const state = access(ctx);
  const session = {
    sessionId: `session-${label.toLowerCase().replace(/\s+/g, "-")}`,
    label,
    current: false,
    connected: true,
  };
  state.sessions.push(session);
  mc(ctx).emitAuthAccess({
    version: 1,
    revision: ++state.revision,
    type: "clientUpserted",
    payload: wireSession(session),
  } as unknown as AuthAccessStreamEvent);
  return session;
}

async function openAccess(ctx: ConnectionsWorld): Promise<void> {
  access(ctx);
  await connected(ctx);
  await runPaletteCommand(ctx, "Access management");
  await settle(ctx);
  expect(sectionState(ctx).id).toBe("connections");
}

step("a running MC", (ctx: ConnectionsWorld) => {
  fixture(ctx);
});

step("the user administers the environment", (ctx: ConnectionsWorld) => {
  access(ctx);
});

step("the user opens access management in the terminal client", openAccess);

step("it lists pairing links and paired clients", async (ctx: ConnectionsWorld) => {
  const text = await paneWords(ctx);
  expect(text).toContain("1 pairing link");
  expect(text).toContain("For the tablet pairing link · not used yet");
  expect(text).toContain("1 paired client");
  expect(text).toContain("Terminal this client");
});

step("updates the list when another client pairs", async (ctx: ConnectionsWorld) => {
  const asked = mc(ctx).calls.length;
  pair(ctx, "Sam's phone");
  const text = await paneWords(ctx);
  expect(text).toContain("2 paired clients");
  expect(text).toContain("Sam's phone connected");
  // It was told, not asked: the page made no call to learn of it.
  expect(mc(ctx).calls.length).toBe(asked);
});

step("another paired client", (ctx: ConnectionsWorld) => {
  ctx.subject = pair(ctx, "Sam's phone").label;
});

step("the user revokes it from the terminal client", async (ctx: ConnectionsWorld) => {
  await openAccess(ctx);
  await chooseRow(ctx, ctx.subject!);
  expect(sectionState(ctx).confirm?.lines.join(" ")).toContain(`Revoke ${ctx.subject}?`);
  await pressKey(ctx, "y");
  await settle(ctx);
});

step("that client can no longer connect", async (ctx: ConnectionsWorld) => {
  expect(
    mc(ctx)
      .callsTo("hal-c2.revokeClient")
      .map((call) => call.payload),
  ).toEqual([{ sessionId: "session-sam's-phone" }]);
  // The MC holds no session for it any more, and the list says so.
  expect(access(ctx).sessions.map((session) => session.label)).toEqual(["Terminal"]);
  expect(await paneWords(ctx)).not.toContain(ctx.subject!);
  expect(statusOf(ctx)).toEqual({ kind: "success", text: `Revoked ${ctx.subject}.` });
});

step("three other paired clients", (ctx: ConnectionsWorld) => {
  for (const label of ["Sam's phone", "Office desktop", "Tablet"]) pair(ctx, label);
});

step("the user revokes every other client", async (ctx: ConnectionsWorld) => {
  await openAccess(ctx);
  expect(await paneWords(ctx)).toContain("4 paired clients");
  await chooseRow(ctx, "Revoke every other client");
  expect(sectionState(ctx).confirm?.lines.join(" ")).toContain("Revoke 3 other clients?");
  await pressKey(ctx, "y");
  await settle(ctx);
});

step("only the terminal client's own session remains", async (ctx: ConnectionsWorld) => {
  expect(mc(ctx).callsTo("hal-c2.revokeOtherClients")).toHaveLength(1);
  expect(access(ctx).sessions).toEqual([
    { sessionId: "session-tui", label: "Terminal", current: true, connected: true },
  ]);
  const text = await paneWords(ctx);
  expect(text).toContain("1 paired client");
  expect(text).toContain("Terminal this client");
  expect(text).not.toContain("Revoke every other client");
});

// --- Linked environments ----------------------------------------------------------------

step("another MC {string} outside the MC's cluster", (ctx: ConnectionsWorld, label: string) => {
  const links = fixture(ctx).links;
  // Linking pairs the MC with the environment behind the link and keeps it.
  mc(ctx).on("hal-c2.linkEnvironment", (payload) => {
    if (payload.pairingUrl !== PAIRING_LINK)
      throw new Error("the pairing link is invalid or expired");
    const link = linkMachine(ctx, label);
    return { environmentId: link.id, label: link.label };
  });
  mc(ctx).on("hal-c2.unlinkEnvironment", (payload) => {
    const index = links.findIndex((link) => link.id === payload.environmentId);
    if (index < 0) throw new Error("no such link");
    links.splice(index, 1);
    return null;
  });
});

step("the user has a pairing link from {string}", (ctx: ConnectionsWorld, _label: string) => {
  ctx.pairingLink = PAIRING_LINK;
});

step(
  "the user adds it as a linked environment in the connection settings",
  async (ctx: ConnectionsWorld) => {
    await connected(ctx);
    await runPaletteCommand(ctx, "Connections");
    await settle(ctx);
    expect(pageText(ctx)).toContain("None. A link lets this machine reach an environment");
    await chooseRow(ctx, "+ Link an environment");
    await fillField(ctx, ctx.pairingLink!);
  },
);

step(
  "the connection settings list {string} as linked and online",
  async (ctx: ConnectionsWorld, label: string) => {
    expect(
      mc(ctx)
        .callsTo("hal-c2.linkEnvironment")
        .map((call) => call.payload),
    ).toEqual([{ pairingUrl: PAIRING_LINK }]);
    expect(await paneWords(ctx)).toContain(`${label} linked · online`);
    expect(statusOf(ctx)).toEqual({ kind: "success", text: `Linked ${label}.` });
  },
);

step("the user can remove the link there", async (ctx: ConnectionsWorld) => {
  await chooseRow(ctx, "beast");
  expect(sectionState(ctx).confirm?.lines.join(" ")).toContain("Remove the link to beast?");
  await pressKey(ctx, "y");
  await settle(ctx);
  expect(
    mc(ctx)
      .callsTo("hal-c2.unlinkEnvironment")
      .map((call) => call.payload),
  ).toEqual([{ environmentId: "env-beast" }]);
  expect(fixture(ctx).links).toEqual([]);
  expect(await paneWords(ctx)).not.toContain("beast linked");
  expect(statusOf(ctx)).toEqual({ kind: "success", text: "Unlinked beast." });
});

// --- A server on another HAL-C2 version ---------------------------------------------------

step("a client paired with an environment", (ctx: ConnectionsWorld) => {
  fixture(ctx);
});

step(/^this client runs HAL-C2 (\S+)$/, (ctx: ConnectionsWorld, version: string) => {
  ctx.hostOptions = {
    dismissedUpdates: memoryMutedThreads(),
    ...ctx.hostOptions,
    appVersion: version,
  };
});

step(/^the environment's MC runs HAL-C2 (\S+)$/, (ctx: ConnectionsWorld, version: string) => {
  fixture(ctx).local.serverVersion = version;
});

step("the client connects", async (ctx: ConnectionsWorld) => {
  await connected(ctx);
});

step("the connection is used as normal", async (ctx: ConnectionsWorld) => {
  const screen = await settle(ctx);
  expect(ctx.host!.state.get("connection")).toMatchObject({ state: "connected" });
  // The environment's threads are there to work with.
  expect(screen).toContain("Thread one");
  expect((ctx.host!.state.get("page") as { kind: string }).kind).toBe("thread");
});

step(
  /^the client (warns of a version mismatch|does not warn)$/,
  async (ctx: ConnectionsWorld, outcome: string) => {
    const notice = ctx.host!.state.get("updateNotice") as TuiUpdateNotice | null;
    const { serverVersion } = fixture(ctx).local;
    const appVersion = ctx.hostOptions!.appVersion!;
    const screen = words(await snapshot(ctx));
    if (outcome === "does not warn") {
      expect(notice).toBeNull();
      expect(screen).not.toContain("behind this app");
      return;
    }
    expect(notice).toMatchObject({ serverVersion, targetVersion: appVersion });
    expect(notice!.text).toContain(`is on ${serverVersion}, behind this app (${appVersion}).`);
    // Over the conversation; the notice wraps beside its Update button.
    expect(screen).toContain(`is on ${serverVersion}, behind`);
  },
);

// --- A cluster member that left -------------------------------------------------------------

const clusterRow = (ctx: World, label: string) =>
  (ctx.host!.state.get("settings") as TuiSettingsState).groups
    .find((group) => group.title === "Cluster")
    ?.rows.find((row) => row.label === label);

step("a client lists a machine that has left the cluster", async (ctx: ConnectionsWorld) => {
  // The MC still names it, as a member it no longer reaches.
  (ctx.fake ?? useClient(ctx)).cluster.members = [
    { id: "env-studio", label: "studio", addresses: ["studio:47730"], connected: false },
  ];
  await connected(ctx);
  ctx.host!.dispatch("settings.open");
  await settle(ctx);
  expect(clusterRow(ctx, "studio")?.value).toBe("offline");
});

step("the machine stays listed", async (ctx: ConnectionsWorld) => {
  // Looked at again later, with the cluster read anew.
  ctx.host!.dispatch("settings.close");
  ctx.host!.dispatch("settings.open");
  const screen = await settle(ctx);
  expect(clusterRow(ctx, "studio")?.value).toBe("offline");
  expect(screen).toMatch(/studio\s+offline/);
  expect(ctx.fake!.calls.filter((call) => call.method === "clusterRemove")).toEqual([]);
});

step("the user can remove it like any environment", async (ctx: ConnectionsWorld) => {
  ctx.host!.dispatch("settings.close");
  await runPaletteCommand(ctx, "Remove studio from the cluster");
  await settle(ctx);
  expect(
    ctx.fake!.calls.filter((call) => call.method === "clusterRemove").map((call) => call.args),
  ).toEqual([["env-studio"]]);
  const cluster = (ctx.host!.state.get("cluster") as TuiClusterState).status;
  expect(cluster?.clustered === true ? cluster.members : null).toEqual([]);
  ctx.host!.dispatch("settings.open");
  await settle(ctx);
  expect(clusterRow(ctx, "studio")).toBeUndefined();
});

// --- A member that joins later ---------------------------------------------------------------

const member = (label: string) => ({
  id: `env-${label}`,
  label,
  addresses: [`${label}:47730`],
  connected: true,
});

step("a client paired with a cluster of two machines", async (ctx: ConnectionsWorld) => {
  fixture(ctx);
  (ctx.fake ?? useClient(ctx)).cluster.members = [member("desktop")];
  await connected(ctx);
  ctx.host!.dispatch("settings.open");
  await settle(ctx);
  expect(clusterRow(ctx, "desktop")?.value).toBe("connected");
  expect(clusterRow(ctx, "studio")).toBeUndefined();
});

step("a third machine joins the cluster", (ctx: ConnectionsWorld) => {
  ctx.fake!.cluster.members = [...ctx.fake!.cluster.members, member("studio")];
});

step(
  "the client lists the third machine's environment within a minute",
  async (ctx: ConnectionsWorld) => {
    // Nothing is asked of the user: the open page reads the cluster again on its own.
    await advance(ctx, 30_000);
    const screen = await settle(ctx);
    expect(clusterRow(ctx, "studio")?.value).toBe("connected");
    expect(screen).toMatch(/studio\s+connected/);
  },
);

step("reaches it with the same credential", async (ctx: ConnectionsWorld) => {
  // Its settings are read through the connection the client already has.
  ctx.host!.dispatch("settings.close");
  await runPaletteCommand(ctx, "Storage settings");
  for (let guard = 0; guard < 4 && !/Applies to\s+studio/.test(pageText(ctx)); guard += 1) {
    await chooseRow(ctx, "Applies to");
  }
  expect(pageText(ctx)).toMatch(/Applies to\s+studio/);
  expect(
    mc(ctx)
      .callsTo("hal-c2.readSettings")
      .some((call) => call.environmentId === "env-studio"),
  ).toBe(true);
  expect(pageText(ctx)).toContain("Delete worktrees with deleted threads");
  // No pairing, linking or joining was needed to get there.
  expect(mc(ctx).callsTo("hal-c2.linkEnvironment")).toEqual([]);
  expect(ctx.fake!.calls.filter((call) => call.method === "clusterJoin")).toEqual([]);
});
