import type { PropertyMap } from "opentui-qml";

import type { TuiClient } from "../../connection.ts";
import type { StatusKind, Store } from "../../store.ts";
import type { AskSpec } from "../askState.ts";
import type { TuiMenuSpec } from "../composerState.ts";
import type { TuiMode } from "../layoutState.ts";
import type { PaletteCommand } from "../paletteState.ts";
import type { TuiSettingsExtraGroup } from "../settingsState.ts";

/** The open thread's workspace: its worktree, else the project root. */
export interface FeatureWorkspace {
  readonly threadId: string;
  readonly projectId: string | null;
  readonly cwd: string;
}

/**
 * What a feature area gets from the host: the client and store, the picker
 * (`menu`) and the one-line question (`ask`) to talk to the user with, and the
 * status line. Features hold no UI of their own.
 */
export interface FeatureKit {
  readonly client: TuiClient;
  readonly store: Store;
  readonly state: PropertyMap;
  readonly mode: () => TuiMode;
  readonly setMode: (mode: TuiMode) => void;
  readonly menu: (spec: TuiMenuSpec) => void;
  readonly closeMenu: (title?: string) => void;
  readonly ask: (spec: AskSpec) => void;
  readonly status: (text: string, kind?: StatusKind) => void;
  /** Put text on the clipboard; false when the terminal cannot. */
  readonly copy: (text: string) => boolean;
  readonly workspace: () => FeatureWorkspace | null;
  /** Run another host action (a palette command, a chord's action). */
  readonly dispatch: (action: string, payload?: unknown) => boolean;
  /** Keep a request in `host.settled()` until it lands. */
  readonly track: <T>(promise: Promise<T>) => Promise<T>;
  /** The palette's entries changed. */
  readonly commandsChanged: () => void;
  /** A settings group this feature lists changed. */
  readonly settingsChanged: () => void;
}

export interface Feature {
  readonly commands?: () => ReadonlyArray<PaletteCommand>;
  /** Groups for the settings page (never an empty one). */
  readonly settingsGroups?: () => ReadonlyArray<TuiSettingsExtraGroup>;
  /** True when the action was this feature's. */
  readonly dispatch: (action: string, payload: unknown) => boolean;
  /** The store changed (shell, selection, detail). */
  readonly sync?: () => void;
  readonly dispose?: () => void;
}

export const payloadField = (payload: unknown, name: string): unknown =>
  typeof payload === "object" && payload !== null
    ? (payload as Record<string, unknown>)[name]
    : undefined;

export const errorText = (error: unknown): string =>
  error instanceof Error ? error.message : String(error);
