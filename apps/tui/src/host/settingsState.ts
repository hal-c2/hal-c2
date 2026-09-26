import type { OrchestrationThread, VcsStatusResult } from "@hal-c2/contracts";
import type { ShellSettingsState } from "@hal-c2/contracts/shell";

import { composerControls, interactionModeLabel, runtimeModeLabel } from "../controls.ts";
import { clip } from "../format.ts";
import { KEYBINDING_GROUPS } from "../keymap.ts";
import { THEME } from "../theme.ts";
import { chunk, styled, type StyledText } from "./styledText.ts";

/** One labelled line of the overview; `keys` rows name a key chord. */
export interface TuiSettingsRow {
  readonly label: string;
  readonly value: string;
  readonly keys: boolean;
  /** The row as SettingsView draws it: the label padded to 16, the value clipped to the pane. */
  readonly line: StyledText;
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

// SettingsView's key column.
const KEY_COLUMN = 16;

const row = (label: string, value: string, width: number): TuiSettingsRow => ({
  label,
  value,
  keys: false,
  line: styled(
    chunk(`  ${label.padEnd(KEY_COLUMN)}`, { fg: THEME.dim }),
    chunk(clip(value, Math.max(8, width - 20)), { fg: THEME.text }),
  ),
});

const keyRow = (keys: string, description: string, width: number): TuiSettingsRow => ({
  label: keys,
  value: description,
  keys: true,
  line: styled(
    chunk(`  ${keys.padEnd(KEY_COLUMN)}`, { fg: THEME.accent }),
    chunk(clip(description, Math.max(8, width - KEY_COLUMN - 4)), { fg: THEME.text }),
  ),
});

export function buildTuiSettingsState(input: {
  readonly active: boolean;
  readonly detail: OrchestrationThread | null;
  readonly vcsStatus: VcsStatusResult | null;
  /** The pane's width (the conversation column); values clip to it. */
  readonly width: number;
}): TuiSettingsState {
  const width = input.width;
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
          row("model", controls.model ?? "—", width),
          row("reasoning", controls.reasoning ?? "—", width),
          row("mode", interactionModeLabel(controls.interactionMode), width),
          row("runtime access", runtimeModeLabel(controls.runtimeMode), width),
        ],
      },
      {
        title: "Source control",
        rows: [
          row("branch", status?.refName ?? "—", width),
          row("pull request", pr ? `#${pr.number} ${pr.state}` : "—", width),
          row(
            "working tree",
            status ? (status.hasWorkingTreeChanges ? "uncommitted changes" : "clean") : "—",
            width,
          ),
        ],
      },
      ...KEYBINDING_GROUPS.map((group) => ({
        title: group.title,
        rows: group.bindings.map((binding) => keyRow(binding.keys, binding.description, width)),
      })),
    ],
  };
}
