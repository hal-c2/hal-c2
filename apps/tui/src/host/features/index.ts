import type { PaletteCommand } from "../paletteState.ts";
import type { TuiSettingsExtraGroup } from "../settingsState.ts";
import { createArchiveFeature } from "./archive.ts";
import { createConversationFeature } from "./conversation.ts";
import { createEditorFeature, type EditorOptions } from "./editor.ts";
import { createKeysFeature } from "./keys.ts";
import { createPlansFeature } from "./plans.ts";
import { createRepositoryFeature } from "./repository.ts";
import { createServerFeature } from "./server.ts";
import type { Feature, FeatureKit } from "./kit.ts";
import { createWorkspaceFeature } from "./workspace.ts";

export interface FeatureOptions extends Partial<EditorOptions> {
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
  const features: Feature[] = [
    createKeysFeature(kit, options),
    createArchiveFeature(kit),
    createConversationFeature(kit),
    createPlansFeature(kit),
    createServerFeature(kit),
    createWorkspaceFeature(kit),
    createRepositoryFeature(kit),
    createEditorFeature(kit, {
      env: options.env ?? {},
      runEditor: options.runEditor ?? (() => Promise.reject(new Error("no editor runner"))),
    }),
  ];
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
