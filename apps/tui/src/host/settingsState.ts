import type { OrchestrationThread, VcsStatusResult } from "@t3tools/contracts";
import type { ShellSettingsState } from "@t3tools/contracts/shell";

import { composerControls, interactionModeLabel, runtimeModeLabel } from "../controls.ts";
import { KEYBINDING_GROUPS } from "../keymap.ts";

/** One labelled line of the overview; `keys` rows name a key chord. */
export interface TuiSettingsRow {
  readonly label: string;
  readonly value: string;
  readonly keys: boolean;
}

export interface TuiSettingsGroup {
  readonly title: string;
  readonly rows: ReadonlyArray<TuiSettingsRow>;
}

/**
 * Published under `settings`: the contract's navigation model plus the
 * terminal's read-only overview (the selected thread's provider and git
 * state, then the keybinding reference by context). Editing stays in the
 * web and desktop apps.
 */
export interface TuiSettingsState extends ShellSettingsState {
  readonly groups: ReadonlyArray<TuiSettingsGroup>;
}

const SECTIONS = [
  { to: "providers", label: "Providers" },
  { to: "source-control", label: "Source control" },
  { to: "keybindings", label: "Keybindings" },
];

const row = (label: string, value: string): TuiSettingsRow => ({ label, value, keys: false });

export function buildTuiSettingsState(input: {
  readonly active: boolean;
  readonly detail: OrchestrationThread | null;
  readonly vcsStatus: VcsStatusResult | null;
}): TuiSettingsState {
  const controls = composerControls(input.detail);
  const status = input.vcsStatus;
  const pr = status?.pr ?? null;
  return {
    active: input.active,
    sections: SECTIONS,
    activeSection: input.active ? "providers" : null,
    searchQuery: "",
    searchResults: [],
    groups: [
      {
        title: "Providers",
        rows: [
          row("model", controls.model ?? "—"),
          row("reasoning", controls.reasoning ?? "—"),
          row("mode", interactionModeLabel(controls.interactionMode)),
          row("runtime access", runtimeModeLabel(controls.runtimeMode)),
        ],
      },
      {
        title: "Source control",
        rows: [
          row("branch", status?.refName ?? "—"),
          row("pull request", pr ? `#${pr.number} ${pr.state}` : "—"),
          row(
            "working tree",
            status ? (status.hasWorkingTreeChanges ? "uncommitted changes" : "clean") : "—",
          ),
        ],
      },
      ...KEYBINDING_GROUPS.map((group) => ({
        title: group.title,
        rows: group.bindings.map((binding) => ({
          label: binding.keys,
          value: binding.description,
          keys: true,
        })),
      })),
    ],
  };
}
