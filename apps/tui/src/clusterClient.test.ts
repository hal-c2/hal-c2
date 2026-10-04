import { describe, expect, it } from "bun:test";

import type { ClusterStatus } from "@hal-c2/contracts";

import { makeClusterClient } from "./clusterClient.ts";
import type { OrchestrationShellSnapshot, TuiClient, TuiConnectionPhase } from "./connection.ts";

interface Row {
  readonly id: string;
  readonly [field: string]: unknown;
}

const shell = (
  projects: ReadonlyArray<Row>,
  threads: ReadonlyArray<Row>,
): OrchestrationShellSnapshot => ({ projects, threads }) as unknown as OrchestrationShellSnapshot;

/** One machine's client: the test pushes its shell and reads what was asked of it. */
function machine(name: string, status?: () => ClusterStatus) {
  let onShell: ((snapshot: OrchestrationShellSnapshot) => void) | null = null;
  let onPhase: ((phase: TuiConnectionPhase) => void) | null = null;
  const calls: string[] = [];
  const threadSubs = new Set<string>();
  const client = {
    subscribeShell: (callback: typeof onShell) => {
      onShell = callback;
      return () => {
        onShell = null;
      };
    },
    subscribeConnection: (callback: typeof onPhase) => {
      onPhase = callback;
      return () => {};
    },
    subscribeThread: (threadId: string) => {
      threadSubs.add(threadId);
      return () => threadSubs.delete(threadId);
    },
    clusterStatus: () =>
      status ? Promise.resolve(status()) : Promise.reject(new Error("no cluster")),
    interrupt: (threadId: string) => {
      calls.push(`interrupt ${threadId}`);
      return Promise.resolve();
    },
    listRefs: (cwd: string) => {
      calls.push(`listRefs ${cwd}`);
      return Promise.resolve([]);
    },
    dispose: () => {
      calls.push("dispose");
      return Promise.resolve();
    },
  } as unknown as TuiClient;
  return {
    name,
    client,
    calls,
    threadSubs,
    pushShell: (snapshot: OrchestrationShellSnapshot) => onShell?.(snapshot),
    connected: () => onPhase?.("connected" as TuiConnectionPhase),
  };
}

const member = (id: string, label: string, connected: boolean) => ({
  id,
  label,
  addresses: [],
  connected,
});

const cluster = (members: ReadonlyArray<ReturnType<typeof member>>): ClusterStatus => ({
  clustered: true,
  id: "env-laptop",
  label: "laptop",
  mc: "laptop@host",
  addresses: [],
  members,
});

/** A laptop whose cluster also has a connected desktop and an offline server. */
async function clustered() {
  let status = cluster([
    member("env-desktop", "desktop", true),
    member("env-server", "server", false),
  ]);
  const laptop = machine("laptop", () => status);
  const desktop = machine("desktop");
  const connected: string[] = [];
  const client = makeClusterClient(laptop.client, (environmentId) => {
    connected.push(environmentId);
    return desktop.client;
  });
  const shells: OrchestrationShellSnapshot[] = [];
  client.subscribeShell((snapshot) => shells.push(snapshot));
  await client.clusterStatus();
  return {
    laptop,
    desktop,
    client,
    connected,
    last: () => shells.at(-1)!,
    setStatus: (next: ClusterStatus) => {
      status = next;
    },
  };
}

const rows = (snapshot: OrchestrationShellSnapshot) =>
  snapshot.threads.map((thread) => `${thread.id}@${thread.machine}`);

describe("makeClusterClient", () => {
  it("Given a machine on its own, when its shell arrives, then it is passed through untouched", async () => {
    const laptop = machine("laptop", () => ({ clustered: false, reason: "not started" }));
    const client = makeClusterClient(laptop.client, () => {
      throw new Error("no member to connect to");
    });
    const shells: OrchestrationShellSnapshot[] = [];
    client.subscribeShell((snapshot) => shells.push(snapshot));
    laptop.connected();
    await client.clusterStatus();

    const alone = shell([{ id: "p1" }], [{ id: "t1" }]);
    laptop.pushShell(alone);

    expect(shells.at(-1)).toBe(alone);
  });

  it("Given a server without a cluster, when it connects, then the shell still passes through", async () => {
    const laptop = machine("laptop");
    const client = makeClusterClient(laptop.client, () => laptop.client);
    const shells: OrchestrationShellSnapshot[] = [];
    client.subscribeShell((snapshot) => shells.push(snapshot));
    laptop.connected();
    await Promise.resolve();

    const alone = shell([], [{ id: "t1" }]);
    laptop.pushShell(alone);

    expect(shells.at(-1)).toBe(alone);
  });

  it("Given a cluster, when each machine's shell arrives, then the rows name their machine", async () => {
    const { laptop, desktop, last, connected } = await clustered();

    laptop.pushShell(shell([{ id: "p-laptop" }], [{ id: "alpha" }]));
    desktop.pushShell(shell([{ id: "p-desktop" }], [{ id: "beta" }]));

    // The offline server gets no client; it is still a machine of the cluster.
    expect(connected).toEqual(["env-desktop"]);
    expect(rows(last())).toEqual(["alpha@laptop", "beta@desktop"]);
    expect(
      last().projects.map((project) => `${project.id}@${project.machine}@${project.machineId}`),
    ).toEqual(["p-laptop@laptop@env-laptop", "p-desktop@desktop@env-desktop"]);
    expect(last().machines).toEqual([
      { id: "env-laptop", label: "laptop", online: true },
      { id: "env-desktop", label: "desktop", online: true },
      { id: "env-server", label: "server", online: false },
    ]);
  });

  it("Given a thread on its way to another machine, when only the one it is leaving lists it, then it is shown there as moving", async () => {
    const { laptop, desktop, client, last } = await clustered();
    const moving = { label: "laptop", environmentId: "env-laptop" };

    laptop.pushShell(shell([], []));
    desktop.pushShell(shell([], [{ id: "alpha", moving }]));

    expect(rows(last())).toEqual(["alpha@desktop"]);
    expect(last().threads[0]!.moving).toEqual(moving);
    await client.interrupt("alpha" as Parameters<TuiClient["interrupt"]>[0]);
    expect(desktop.calls).toEqual(["interrupt alpha"]);
  });

  it.each([
    ["the one it is going to answers first", true],
    ["the one it is leaving answers first", false],
  ])(
    "Given a thread the machine it is going to already holds, when the one it is leaving has not let go and %s, then it lives where it went",
    async (_order, destinationFirst) => {
      const { laptop, desktop, client, last } = await clustered();
      const moving = { label: "laptop", environmentId: "env-laptop" };
      const arrive = () => laptop.pushShell(shell([], [{ id: "alpha" }]));
      const leave = () => desktop.pushShell(shell([], [{ id: "alpha", moving }]));

      for (const push of destinationFirst ? [arrive, leave] : [leave, arrive]) push();

      expect(rows(last())).toEqual(["alpha@laptop"]);
      expect(last().threads[0]!.moving).toBeUndefined();
      await client.interrupt("alpha" as Parameters<TuiClient["interrupt"]>[0]);
      expect(laptop.calls).toEqual(["interrupt alpha"]);
      expect(desktop.calls).toEqual([]);
    },
  );

  it("Given a thread that moved, when the machine it left keeps a forwarding row, then it is listed on the machine it moved to", async () => {
    const { laptop, desktop, last } = await clustered();
    const movedTo = { label: "desktop", environmentId: "env-desktop" };

    laptop.pushShell(shell([], [{ id: "alpha", movedTo }]));
    desktop.pushShell(shell([], [{ id: "alpha" }]));

    expect(rows(last())).toEqual(["alpha@desktop"]);
  });

  it("Given threads on two machines, when one is acted on, then its own machine is asked", async () => {
    const { laptop, desktop, client } = await clustered();
    laptop.pushShell(shell([], [{ id: "alpha" }]));
    desktop.pushShell(shell([], [{ id: "beta" }]));

    await client.interrupt("beta" as Parameters<TuiClient["interrupt"]>[0]);
    await client.interrupt("alpha" as Parameters<TuiClient["interrupt"]>[0]);

    expect(desktop.calls).toEqual(["interrupt beta"]);
    expect(laptop.calls).toEqual(["interrupt alpha"]);
  });

  it("Given an open thread, when it moves to another machine, then it is followed there", async () => {
    const { laptop, desktop, client } = await clustered();
    laptop.pushShell(shell([], [{ id: "alpha" }]));
    desktop.pushShell(shell([], []));
    const stop = client.subscribeThread(
      "alpha" as Parameters<TuiClient["subscribeThread"]>[0],
      () => {},
    );
    expect([...laptop.threadSubs]).toEqual(["alpha"]);

    desktop.pushShell(shell([], [{ id: "alpha" }]));
    laptop.pushShell(
      shell([], [{ id: "alpha", movedTo: { label: "desktop", environmentId: "env-desktop" } }]),
    );

    expect([...laptop.threadSubs]).toEqual([]);
    expect([...desktop.threadSubs]).toEqual(["alpha"]);

    stop();
    expect([...desktop.threadSubs]).toEqual([]);
  });

  it("Given the same checkout path on two machines, when it is read, then the open thread's machine is asked", async () => {
    const { laptop, desktop, client } = await clustered();
    laptop.pushShell(shell([{ id: "p-laptop", workspaceRoot: "/src/shop" }], [{ id: "alpha" }]));
    desktop.pushShell(
      shell(
        [
          { id: "p-desktop", workspaceRoot: "/src/shop" },
          { id: "p-docs", workspaceRoot: "/src/docs" },
        ],
        [{ id: "beta" }],
      ),
    );

    // A path only one machine has names that machine.
    await client.listRefs("/src/docs");
    expect(desktop.calls).toEqual(["listRefs /src/docs"]);

    client.subscribeThread("beta" as Parameters<TuiClient["subscribeThread"]>[0], () => {});
    await client.listRefs("/src/shop");
    expect(desktop.calls).toEqual(["listRefs /src/docs", "listRefs /src/shop"]);
    expect(laptop.calls).toEqual([]);

    // A draft opened in the laptop's project over that thread means the laptop's checkout.
    client.viewProject("p-laptop");
    await client.listRefs("/src/shop");
    expect(laptop.calls).toEqual(["listRefs /src/shop"]);
    // Closed again, the path is the open thread's machine's once more.
    client.viewProject(null);
    await client.listRefs("/src/shop");
    expect(desktop.calls).toEqual([
      "listRefs /src/docs",
      "listRefs /src/shop",
      "listRefs /src/shop",
    ]);
    expect(laptop.calls).toEqual(["listRefs /src/shop"]);
  });

  it("Given a member that left the cluster, when the cluster is read again, then its rows and its client go", async () => {
    const { laptop, desktop, client, last, setStatus } = await clustered();
    laptop.pushShell(shell([], [{ id: "alpha" }]));
    desktop.pushShell(shell([], [{ id: "beta" }]));

    setStatus(cluster([member("env-server", "server", false)]));
    await client.clusterStatus();

    expect(rows(last())).toEqual(["alpha@laptop"]);
    expect(desktop.calls).toEqual(["dispose"]);
  });
});
