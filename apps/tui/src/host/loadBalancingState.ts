import type { McSettings, TuiClient } from "../connection.ts";
import {
  LOAD_PREFERENCES,
  loadPreferenceForWeight,
  readLoadBalancing,
  withLoadBalancing,
  withLoadPreference,
  type LoadBalancingSettings,
} from "../loadBalancing.ts";
import type { TuiMachine } from "../orchestrationV2Adapter.ts";
import type { Store } from "../store.ts";
import type { Composer } from "./composerState.ts";
import type { PaletteCommand } from "./paletteState.ts";

/**
 * Load balancing as settings list it: null while this machine is alone (one
 * machine has nothing to balance against), else the cluster's machines with
 * what the MC's settings say (`settings` null until read).
 */
export interface TuiLoadBalancingState {
  readonly machines: ReadonlyArray<TuiMachine>;
  readonly settings: LoadBalancingSettings | null;
  /** Why the settings could not be read. */
  readonly error: string | null;
}

const errorText = (error: unknown): string =>
  error instanceof Error ? error.message : String(error);

// Another client writing between this one's read and write sends the edit round again.
const WRITE_ATTEMPTS = 3;

/**
 * Balancing new threads across the cluster's machines, from the terminal:
 * whether it is on and each machine's preference in settings, changed from
 * the palette. Both live in the home MC's settings document, which is read
 * when the cluster first has a second machine and again when settings or the
 * palette open; the MC does the choosing (`placeNewThread`).
 */
export function createLoadBalancingController(ctx: {
  readonly client: TuiClient;
  readonly store: Store;
  readonly pick: Composer["pick"];
  /** What settings and the palette show changed. */
  readonly publish: () => void;
}) {
  const { client, store } = ctx;
  let settings: LoadBalancingSettings | null = null;
  let error: string | null = null;
  const pending = new Set<Promise<unknown>>();
  const track = <T>(promise: Promise<T>): Promise<T> => {
    pending.add(promise);
    const done = () => pending.delete(promise);
    promise.then(done, done);
    return promise;
  };

  const machines = () => store.getState().shell?.machines ?? [];
  const available = () => machines().length > 1;

  // Bumped by every read and edit: a read sent before an edit may land after it,
  // and only the latest request counts.
  let generation = 0;
  const refresh = () => {
    if (!available()) return Promise.resolve();
    const asked = ++generation;
    return track(
      client.readSettings().then(
        (document) => {
          if (asked !== generation) return;
          settings = readLoadBalancing(document.settings);
          error = null;
          ctx.publish();
        },
        (cause: unknown) => {
          if (asked !== generation) return;
          error = errorText(cause);
          ctx.publish();
        },
      ),
    );
  };

  const write = async (
    apply: (document: McSettings["settings"]) => McSettings["settings"],
  ): Promise<LoadBalancingSettings> => {
    for (let attempt = 0; attempt < WRITE_ATTEMPTS; attempt += 1) {
      const { settings: document, version } = await client.readSettings();
      const next = apply(document);
      if (await client.writeSettings(next, version)) return readLoadBalancing(next);
    }
    throw new Error("the settings kept changing");
  };

  const edit = (
    apply: (document: McSettings["settings"]) => McSettings["settings"],
    said: string,
  ) => {
    generation += 1;
    void track(
      write(apply).then(
        (next) => {
          settings = next;
          error = null;
          store.setStatus(said, "success");
          ctx.publish();
        },
        (cause: unknown) => {
          store.setStatus(`Load balancing was not changed: ${errorText(cause)}`, "error");
          // In place of any read this edit overtook.
          void refresh();
        },
      ),
    );
  };

  const choosePreference = (machine: TuiMachine) => {
    const current = loadPreferenceForWeight(settings?.weights[machine.id]);
    ctx.pick({
      title: `How often ${machine.label} gets new threads`,
      status: "ready",
      options: LOAD_PREFERENCES.map((preference) => ({
        label: preference.label,
        description: preference === current ? "current" : "",
        value: String(preference.weight),
      })),
      onChoose: (value) => {
        const chosen = LOAD_PREFERENCES.find((preference) => String(preference.weight) === value);
        if (!chosen) return;
        edit(
          (document) => withLoadPreference(document, machine.id, chosen.weight),
          `${machine.label} → ${chosen.label}`,
        );
      },
    });
  };

  return {
    state: (): TuiLoadBalancingState | null =>
      available() ? { machines: machines(), settings, error } : null,
    refresh,
    /** Follow the shell: read the settings once a second machine makes them matter. */
    sync: () => {
      if (generation === 0) void refresh();
    },
    /** Resolves once every settings call in flight has landed (tests wait on it). */
    settled: async () => {
      while (pending.size > 0) await Promise.allSettled(pending);
    },
    commands: (): PaletteCommand[] => {
      if (!available() || settings === null) return [];
      return [
        settings.enabled
          ? {
              id: "loadBalancing.off",
              title: "Turn off load balancing",
              keywords: "cluster machines automatically balance new threads",
              action: "loadBalancing.set",
              payload: { enabled: false },
            }
          : {
              id: "loadBalancing.on",
              title: "Turn on load balancing",
              keywords: "cluster machines automatically balance new threads",
              action: "loadBalancing.set",
              payload: { enabled: true },
            },
        ...machines().map((machine) => ({
          id: `loadBalancing.preference.${machine.id}`,
          title: `Load balancing preference for ${machine.label}…`,
          keywords: "cluster machine prefer normal less often manual only",
          action: "loadBalancing.preference",
          payload: { id: machine.id },
        })),
      ];
    },
    dispatch: (action: string, payload: unknown): boolean => {
      const field = (name: string) =>
        typeof payload === "object" && payload !== null
          ? (payload as Record<string, unknown>)[name]
          : undefined;
      switch (action) {
        case "loadBalancing.set": {
          const enabled = field("enabled") === true;
          edit(
            (document) => withLoadBalancing(document, enabled),
            enabled
              ? "Load balancing is on: new threads start on the machine with the most room."
              : "Load balancing is off: new threads start on the machine you pick.",
          );
          return true;
        }
        case "loadBalancing.preference": {
          const machine = machines().find((candidate) => candidate.id === field("id"));
          if (machine) choosePreference(machine);
          return true;
        }
        default:
          return false;
      }
    },
  };
}
