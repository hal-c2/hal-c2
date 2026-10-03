import type { PaletteCommand } from "../paletteState.ts";
import type { TuiSettingsExtraGroup } from "../settingsState.ts";
import { createKeysFeature } from "./keys.ts";
import type { Feature, FeatureKit } from "./kit.ts";

export interface FeatureOptions {
  readonly saveKeymap?: ((overrides: Record<string, string | null>) => void) | undefined;
}

/**
 * The feature areas that talk to the user through the picker, the one-line
 * question and the status line (see kit.ts). The host routes actions it does
 * not know to `dispatch` and lists `commands` in the palette.
 */
export function createFeatures(
  base: Omit<FeatureKit, "track">,
  options: FeatureOptions,
): {
  readonly dispatch: (action: string, payload: unknown) => boolean;
  readonly commands: () => PaletteCommand[];
  readonly settingsGroups: () => TuiSettingsExtraGroup[];
  readonly sync: () => void;
  readonly settled: () => Promise<void>;
  readonly dispose: () => void;
} {
  const pending = new Set<Promise<unknown>>();
  const kit: FeatureKit = {
    ...base,
    track: (promise) => {
      pending.add(promise);
      const done = () => pending.delete(promise);
      promise.then(done, done);
      return promise;
    },
  };
  const features: Feature[] = [createKeysFeature(kit, options)];
  return {
    dispatch: (action, payload) => features.some((feature) => feature.dispatch(action, payload)),
    commands: () => features.flatMap((feature) => [...(feature.commands?.() ?? [])]),
    settingsGroups: () => features.flatMap((feature) => [...(feature.settingsGroups?.() ?? [])]),
    sync: () => {
      for (const feature of features) feature.sync?.();
    },
    settled: async () => {
      while (pending.size > 0) await Promise.allSettled(pending);
    },
    dispose: () => {
      for (const feature of features) feature.dispose?.();
    },
  };
}
