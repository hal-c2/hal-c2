// Steps for connections/cluster.feature (@tui): the cluster in settings, and
// invite, join and remove from the command palette, against the fake MC's
// cluster (fakeClient.ts `cluster`).
import { expect } from "bun:test";

import { step } from "../../steps.ts";
import { makeClusterClient } from "../../../src/clusterClient.ts";
import type { OrchestrationShellSnapshot, TuiClient } from "../../../src/connection.ts";
import { LOCAL_ONLY_HINT } from "../../../src/host/clusterState.ts";
import type { TuiClusterState } from "../../../src/host/clusterState.ts";
import type { TuiSettingsState } from "../../../src/host/settingsState.ts";
import { fakeClient, project, shell, type FakeCluster } from "../fakeClient.ts";
import { runPaletteCommand } from "./controls.steps.ts";
import {
  boot,
  findObject,
  geometry,
  pressKey,
  settle,
  typeText,
  useClient,
  type World,
} from "../world.ts";

/**
 * Set up the fake MC's cluster right before boot, so a step that replaces
 * the fake client first (settings' checkout) keeps it.
 */
const configure = (ctx: World, apply: (cluster: FakeCluster) => void) => {
  const previous = ctx.prepare;
  ctx.prepare = () => {
    previous?.();
    apply((ctx.fake ?? useClient(ctx)).cluster);
  };
};

const clusterRows = (ctx: World) =>
  (ctx.host!.state.get("settings") as TuiSettingsState).groups.find(
    (group) => group.title === "Cluster",
  )?.rows ?? [];

const callsTo = (ctx: World, method: string) =>
  ctx.fake!.calls.filter((call) => call.method === method);

async function openSettings(ctx: World): Promise<string> {
  ctx.host!.dispatch("settings.open");
  return settle(ctx);
}

const member = (label: string, connected: boolean) => ({
  id: `env-${label}`,
  label,
  addresses: [`${label}:47730`],
  connected,
});

step(
  "this machine is clustered with {string}, which is connected, and {string}, which is offline",
  (ctx: World, online: string, offline: string) => {
    configure(ctx, (cluster) => {
      cluster.members = [member(online, true), member(offline, false)];
    });
  },
);

step("this machine is clustered with {string}, which is connected", (ctx: World, label: string) => {
  configure(ctx, (cluster) => {
    cluster.members = [member(label, true)];
  });
});

step("the MC listens only on loopback", (ctx: World) => {
  configure(ctx, (cluster) => {
    cluster.invite = {
      ...cluster.invite,
      link: "http://127.0.0.1:3773/pair#token=cluster-invite",
      localOnly: true,
    };
  });
});

step("the MC refuses joins saying {string}", (ctx: World, reason: string) => {
  configure(ctx, (cluster) => {
    cluster.joinRefusal = reason;
  });
});

step(
  "the cluster group lists {string} as connected and {string} as offline",
  async (ctx: World, online: string, offline: string) => {
    const screen = await settle(ctx);
    const value = (label: string) => clusterRows(ctx).find((row) => row.label === label)?.value;
    expect(value("this machine")).toBe("This machine");
    expect(value(online)).toBe("connected");
    expect(value(offline)).toBe("offline");
    expect(screen).toContain("Cluster");
    expect(screen).toMatch(new RegExp(`${online}\\s+connected`));
    expect(screen).toMatch(new RegExp(`${offline}\\s+offline`));
  },
);

step("the user picks {string} in the command palette", async (ctx: World, title: string) => {
  await runPaletteCommand(ctx, title);
});

step("the MC is asked for a cluster invite", async (ctx: World) => {
  await settle(ctx);
  expect(callsTo(ctx, "clusterInvite").map((call) => call.args[0])).toEqual([{}]);
});

step("the invite link is copied", (ctx: World) => {
  expect(ctx.clipboard?.at(-1)).toBe(ctx.fake!.cluster.invite.link);
});

step("settings show the invite link", async (ctx: World) => {
  await openSettings(ctx);
  // The link is broken over rows from "invite" up to "expires".
  const rows = clusterRows(ctx);
  const from = rows.findIndex((row) => row.label === "invite");
  const to = rows.findIndex((row) => row.label === "expires");
  expect(from).toBeGreaterThanOrEqual(0);
  const link = rows.slice(from, to).map((row) => row.value);
  expect(link.join("")).toBe(ctx.fake!.cluster.invite.link);
});

step("the user is warned that only this machine can open the invite", async (ctx: World) => {
  await settle(ctx);
  const status = ctx.host!.state.get("status") as { kind: string; text: string };
  expect(status.kind).toBe("error");
  expect(status.text).toContain(LOCAL_ONLY_HINT);
});

step("the user pastes the invite {string} and presses Enter", async (ctx: World, link: string) => {
  expect(ctx.host!.state.get("mode")).toBe("join");
  expect(geometry(findObject(ctx, "clusterJoinLink")).visible).toBe(true);
  await typeText(ctx, link);
  await pressKey(ctx, "Enter");
  await settle(ctx);
});

step("the MC is asked to join with {string}", (ctx: World, link: string) => {
  expect(callsTo(ctx, "clusterJoin").map((call) => call.args[0])).toEqual([link]);
});

step("settings list {string} as connected", async (ctx: World, label: string) => {
  await openSettings(ctx);
  expect(clusterRows(ctx).find((row) => row.label === label)?.value).toBe("connected");
});

step("the prompt has the keys again", async (ctx: World) => {
  await settle(ctx);
  expect(ctx.host!.state.get("mode")).toBe("compose");
  expect(geometry(findObject(ctx, "composerAux")).visible).toBe(false);
});

step("the MC was not asked to join", (ctx: World) => {
  expect(callsTo(ctx, "clusterJoin")).toEqual([]);
});

step("the MC is asked to remove {string}", async (ctx: World, id: string) => {
  await settle(ctx);
  expect(callsTo(ctx, "clusterRemove").map((call) => call.args[0])).toEqual([id]);
});

/** Cluster reads the MC holds back, answered by "the MC answers". */
const heldReads = new WeakMap<World, Array<() => void>>();

step("the terminal has read the cluster", async (ctx: World) => {
  await boot(ctx);
  ctx.host!.dispatch("cluster.refresh");
  await settle(ctx);
});

step("the MC is slow to read its cluster", async (ctx: World) => {
  // Every read from now on answers with the cluster as it is now, once released.
  const earlier = await ctx.fake!.client.clusterStatus();
  const held: Array<() => void> = [];
  heldReads.set(ctx, held);
  ctx.fake!.override(
    "clusterStatus",
    () => new Promise((resolve) => held.push(() => resolve(earlier))),
  );
  ctx.held = (ctx.held ?? 0) + 1;
});

step("the MC answers", async (ctx: World) => {
  for (const release of heldReads.get(ctx)?.splice(0) ?? []) release();
  ctx.held = (ctx.held ?? 1) - 1;
  await settle(ctx);
});

step("{string} joins the cluster", async (ctx: World, label: string) => {
  ctx.fake!.cluster.members = [...ctx.fake!.cluster.members, member(label, true)];
  ctx.fake!.emitCluster();
  await settle(ctx);
});

step("the terminal's cluster lists {string} as connected", async (ctx: World, label: string) => {
  await settle(ctx);
  const cluster = ctx.host!.state.get("cluster") as TuiClusterState;
  const members = cluster.status?.clustered ? cluster.status.members : [];
  expect(members.find((member) => member.label === label)?.connected).toBe(true);
});

step("the terminal's cluster no longer lists {string}", async (ctx: World, label: string) => {
  await settle(ctx);
  const cluster = ctx.host!.state.get("cluster") as TuiClusterState;
  const members = cluster.status?.clustered ? cluster.status.members : [];
  expect(members.map((member) => member.label)).not.toContain(label);
});

/** The terminal's one client over this machine and another (clusterClient.ts), each a fake MC of its own. */
interface MergedWorld extends World {
  merged?: {
    readonly client: TuiClient;
    /** Each machine's fake MC, by the label the cluster gives it. */
    readonly machines: Map<string, ReturnType<typeof fakeClient>>;
    readonly projectId: string;
    shell: OrchestrationShellSnapshot | null;
  };
}

step(
  "this machine and {string} of its cluster each have a project with the id {string}",
  (ctx: MergedWorld, label: string, projectId: string) => {
    const machine = () =>
      fakeClient({ shellSnapshot: shell([], [{ ...project, id: projectId }] as never) });
    const here = machine();
    const there = machine();
    here.cluster.members = [member(label, true)];
    ctx.merged = {
      client: makeClusterClient(here.client, () => there.client),
      machines: new Map([
        ["This machine", here],
        [label, there],
      ]),
      projectId,
      shell: null,
    };
  },
);

step("the terminal follows the cluster's projects", async (ctx: MergedWorld) => {
  const merged = ctx.merged!;
  merged.client.subscribeShell((snapshot) => {
    merged.shell = snapshot;
  });
  for (const machine of merged.machines.values()) machine.connect();
  await merged.client.clusterStatus();
});

step("the project is listed once for each machine", (ctx: MergedWorld) => {
  const { machines, shell: listed } = ctx.merged!;
  expect(listed!.projects.map((listing) => listing.machine)).toEqual([...machines.keys()]);
  expect(new Set(listed!.projects.map((listing) => listing.id)).size).toBe(machines.size);
});

step(
  "a thread started in the project on {string} is started on {string}",
  async (ctx: MergedWorld, of: string, on: string) => {
    const { client, machines, projectId, shell: listed } = ctx.merged!;
    const started = () =>
      [...machines].flatMap(([label, machine]) =>
        machine.calls
          .filter((call) => call.method === "createThread")
          .map((call) => `${label} ${(call.args[0] as { projectId: string }).projectId}`),
      );
    const before = started();
    const listing = listed!.projects.find((candidate) => candidate.machine === of)!;
    await client.createThread({ projectId: listing.id } as Parameters<
      TuiClient["createThread"]
    >[0]);
    // The machine is asked by the id it knows the project by.
    expect(started().toSorted()).toEqual([...before, `${on} ${projectId}`].toSorted());
  },
);
