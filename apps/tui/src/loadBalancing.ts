import type { ThreadPlacement, ThreadPlacementInput } from "@hal-c2/contracts";

import type { TuiMachine, TuiProjectShell } from "./orchestrationV2Adapter.ts";

/** How often a machine gets new threads, as the MC's weight for it, most often first. */
export const LOAD_PREFERENCES = [
  { weight: 100, label: "Prefer" },
  { weight: 50, label: "Normal" },
  { weight: 25, label: "Less often" },
  { weight: 0, label: "Manual only" },
] as const;

export type LoadPreference = (typeof LOAD_PREFERENCES)[number];

/**
 * The preference a saved weight shows as. A machine with no weight is at
 * Normal; one from an older build that stored a slider value snaps to the
 * choice on its side of Normal, and only 0 is Manual only: any other weight
 * still gets threads.
 */
export function loadPreferenceForWeight(weight: number | undefined): LoadPreference {
  const at = (value: LoadPreference["weight"]) =>
    LOAD_PREFERENCES.find((preference) => preference.weight === value)!;
  if (weight === undefined || weight === 50) return at(50);
  if (weight === 0) return at(0);
  return at(weight < 50 ? 25 : 100);
}

/** What the MC's settings document (`hal-c2.readSettings`) says about balancing. */
export interface LoadBalancingSettings {
  readonly enabled: boolean;
  /** Each machine's weight by environment id; a machine without one is at Normal. */
  readonly weights: Readonly<Record<string, number>>;
}

type SettingsDocument = Readonly<Record<string, unknown>>;

export function readLoadBalancing(settings: SettingsDocument): LoadBalancingSettings {
  const saved = settings.loadBalancingWeights;
  return {
    enabled: settings.loadBalancingEnabled === true,
    weights: Object.fromEntries(
      Object.entries(typeof saved === "object" && saved !== null ? saved : {}).filter(
        (entry): entry is [string, number] => typeof entry[1] === "number",
      ),
    ),
  };
}

/** The document with balancing on or off; the preferences stay as they are. */
export const withLoadBalancing = (settings: SettingsDocument, enabled: boolean) => ({
  ...settings,
  loadBalancingEnabled: enabled,
});

/** The document with one machine's preference changed. */
export const withLoadPreference = (
  settings: SettingsDocument,
  environmentId: string,
  weight: LoadPreference["weight"],
) => ({
  ...settings,
  loadBalancingWeights: { ...readLoadBalancing(settings).weights, [environmentId]: weight },
});

// The MC waits up to a second for the picked machine and a second for the others.
const PLACEMENT_WAIT_MS = 3_000;

type PlacedProject = Pick<TuiProjectShell, "id" | "machineId">;

/**
 * The project a new thread starts in: the one the home MC answers
 * (`hal-c2.placeThread`), which is another machine's checkout of the same
 * repository when that machine has more room. It is the user's own `project`
 * when this machine is alone, and whenever the MC cannot be followed: it
 * refuses, takes longer than `waitMs`, or names a project this client does not
 * list. The first message is never held up by balancing.
 */
export async function placeNewThread<Project extends PlacedProject>(input: {
  /** The merged shell: every machine's projects, and the machines themselves. */
  readonly projects: ReadonlyArray<Project>;
  readonly machines: ReadonlyArray<TuiMachine> | undefined;
  readonly project: Project;
  /** The agent the thread will run on. */
  readonly instanceId: string;
  readonly place: (input: ThreadPlacementInput) => Promise<ThreadPlacement>;
  readonly waitMs?: number;
}): Promise<Project> {
  const { project } = input;
  const machines = input.machines ?? [];
  // By environment id: two machines may carry the same label.
  const picked = machines.find((machine) => machine.id === project.machineId);
  if (machines.length < 2 || !picked) return project;
  let timer: ReturnType<typeof setTimeout> | undefined;
  const late = new Promise<null>((resolve) => {
    timer = setTimeout(() => resolve(null), input.waitMs ?? PLACEMENT_WAIT_MS);
  });
  try {
    const placement = await Promise.race([
      input.place({
        environmentId: picked.id,
        projectId: project.id,
        instanceId: input.instanceId,
      }),
      late,
    ]);
    if (placement === null) return project;
    return (
      input.projects.find(
        (candidate) =>
          candidate.id === placement.projectId && candidate.machineId === placement.environmentId,
      ) ?? project
    );
  } catch {
    return project;
  } finally {
    clearTimeout(timer);
  }
}
