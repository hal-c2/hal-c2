// Steps for connections/cluster.feature (@tui): the cluster in settings, and
// invite, join and remove from the command palette, against the fake node's
// cluster (fakeClient.ts `cluster`).
import { expect } from "bun:test";

import { step } from "../../steps.ts";
import { LOCAL_ONLY_HINT } from "../../../src/host/clusterState.ts";
import type { TuiSettingsState } from "../../../src/host/settingsState.ts";
import type { FakeCluster } from "../fakeClient.ts";
import { runPaletteCommand } from "./controls.steps.ts";
import {
  findObject,
  geometry,
  pressKey,
  settle,
  typeText,
  useClient,
  type World,
} from "../world.ts";

/**
 * Set up the fake node's cluster right before boot, so a step that replaces
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

step("the node listens only on loopback", (ctx: World) => {
  configure(ctx, (cluster) => {
    cluster.invite = {
      ...cluster.invite,
      link: "http://127.0.0.1:3773/pair#token=cluster-invite",
      localOnly: true,
    };
  });
});

step("the node refuses joins saying {string}", (ctx: World, reason: string) => {
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

step("the node is asked for a cluster invite", async (ctx: World) => {
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

step("the node is asked to join with {string}", (ctx: World, link: string) => {
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

step("the node was not asked to join", (ctx: World) => {
  expect(callsTo(ctx, "clusterJoin")).toEqual([]);
});

step("the node is asked to remove {string}", async (ctx: World, id: string) => {
  await settle(ctx);
  expect(callsTo(ctx, "clusterRemove").map((call) => call.args[0])).toEqual([id]);
});
