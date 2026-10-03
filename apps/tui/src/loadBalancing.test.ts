import { describe, expect, it } from "bun:test";

import { ProjectId, type ThreadPlacement, type ThreadPlacementInput } from "@hal-c2/contracts";

import {
  loadPreferenceForWeight,
  placeNewThread,
  readLoadBalancing,
  withLoadBalancing,
  withLoadPreference,
} from "./loadBalancing.ts";

describe("loadPreferenceForWeight", () => {
  it.each([
    [undefined, "Normal"],
    [50, "Normal"],
    [100, "Prefer"],
    [25, "Less often"],
    [0, "Manual only"],
  ] as const)("shows %p as %s", (weight, label) => {
    expect(loadPreferenceForWeight(weight).label).toBe(label);
  });

  it.each([
    [1, "Less often"],
    [49, "Less often"],
    [51, "Prefer"],
    [80, "Prefer"],
  ] as const)("snaps an older build's %p to %s", (weight, label) => {
    expect(loadPreferenceForWeight(weight).label).toBe(label);
  });
});

describe("the MC's settings document", () => {
  it("is off with every machine at Normal until something is saved", () => {
    expect(readLoadBalancing({})).toEqual({ enabled: false, weights: {} });
  });

  it("ignores weights that are not numbers", () => {
    const settings = { loadBalancingEnabled: true, loadBalancingWeights: { a: 25, b: "100" } };
    expect(readLoadBalancing(settings)).toEqual({ enabled: true, weights: { a: 25 } });
  });

  it("keeps the preferences and every other setting when balancing is turned off", () => {
    const settings = {
      loadBalancingEnabled: true,
      loadBalancingWeights: { a: 100, b: 0 },
      defaultThreadEnvMode: "worktree",
    };
    expect(withLoadBalancing(settings, false)).toEqual({
      ...settings,
      loadBalancingEnabled: false,
    });
  });

  it("changes one machine's preference and leaves the others", () => {
    const settings = { loadBalancingWeights: { a: 100, b: 0 }, defaultThreadEnvMode: "worktree" };
    expect(withLoadPreference(settings, "b", 25)).toEqual<Record<string, unknown>>({
      loadBalancingWeights: { a: 100, b: 25 },
      defaultThreadEnvMode: "worktree",
    });
  });
});

describe("placeNewThread", () => {
  const machines = [
    { id: "env-laptop", label: "laptop", online: true },
    { id: "env-server", label: "server", online: true },
  ];
  const picked = { id: ProjectId.make("p-laptop"), machine: "laptop" };
  const projects = [picked, { id: ProjectId.make("p-server"), machine: "server" }];
  const start = (
    place: (input: ThreadPlacementInput) => Promise<ThreadPlacement>,
    overrides: { machines?: typeof machines; waitMs?: number } = {},
  ) =>
    placeNewThread({
      projects,
      machines,
      project: picked,
      instanceId: "codex",
      place,
      ...overrides,
    });

  it("asks the MC about the user's pick and starts in the checkout it answers", async () => {
    const asked: ThreadPlacementInput[] = [];
    const placed = await start(async (input) => {
      asked.push(input);
      return { environmentId: "env-server", projectId: "p-server" };
    });
    expect(asked).toEqual([
      { environmentId: "env-laptop", projectId: "p-laptop", instanceId: "codex" },
    ]);
    expect(placed).toBe(projects[1]!);
  });

  it("does not ask while this machine is alone", async () => {
    let asked = 0;
    const place = async () => {
      asked += 1;
      return { environmentId: "env-server", projectId: "p-server" };
    };
    expect(
      await placeNewThread({
        projects,
        machines: undefined,
        project: picked,
        instanceId: "codex",
        place,
      }),
    ).toBe(picked);
    expect(await start(place, { machines: machines.slice(0, 1) })).toBe(picked);
    expect(asked).toBe(0);
  });

  it("starts where the user picked when the MC refuses", async () => {
    expect(await start(() => Promise.reject(new Error("not a HAL-C2 MC")))).toBe(picked);
  });

  it("starts where the user picked when the MC takes too long", async () => {
    expect(await start(() => new Promise<never>(() => {}), { waitMs: 1 })).toBe(picked);
  });

  it("starts where the user picked when the answer is not a project of that machine", async () => {
    expect(await start(async () => ({ environmentId: "env-server", projectId: "p-gone" }))).toBe(
      picked,
    );
    expect(await start(async () => ({ environmentId: "env-other", projectId: "p-server" }))).toBe(
      picked,
    );
  });
});
