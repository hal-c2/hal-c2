import type { OrchestrationThread, VcsStatusResult } from "@hal-c2/contracts";
import type { ShellSettingsState } from "@hal-c2/contracts/shell";

import { composerControls, interactionModeLabel, runtimeModeLabel } from "../controls.ts";
import { clip } from "../format.ts";
import { KEYBINDING_GROUPS } from "../keymap.ts";
import { loadPreferenceForWeight } from "../loadBalancing.ts";
import { THEME } from "../theme.ts";
import { LOCAL_ONLY_HINT, type TuiClusterState } from "./clusterState.ts";
import type { TuiLoadBalancingState } from "./loadBalancingState.ts";
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
 * terminal's overview (the selected thread's provider and git state, this
 * machine's cluster and how it balances new threads, then the keybinding
 * reference by context). The cluster and load balancing change through
 * palette commands; other editing stays in the desktop app.
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

/** A value too long to clip (an invite link), broken over as many rows as it needs. */
const wrappedRows = (label: string, value: string, width: number): TuiSettingsRow[] => {
  const size = Math.max(8, width - 20);
  const rows: TuiSettingsRow[] = [];
  for (let at = 0; at < value.length; at += size) {
    rows.push(row(at === 0 ? label : "", value.slice(at, at + size), width));
  }
  return rows;
};

function clusterRows(cluster: TuiClusterState, width: number): TuiSettingsRow[] {
  const status = cluster.status;
  const rows: TuiSettingsRow[] = [];
  if (cluster.error !== null) rows.push(row("status", cluster.error, width));
  else if (status === null) rows.push(row("status", "reading…", width));
  else if (!status.clustered) rows.push(row("status", status.reason, width));
  else {
    rows.push(row("this machine", status.label, width));
    for (const member of status.members) {
      const connection = member.connected ? "connected" : "offline";
      const detail =
        member.compatible === false
          ? `Update to connect (${member.version ?? "unknown version"})`
          : member.updateRecommended
            ? `${connection} (${member.version}). Please update your machines.`
            : connection;
      rows.push(row(member.label, detail, width));
    }
    if (status.members.length === 0) {
      rows.push(row("members", "none yet: invite a machine from the palette (^K)", width));
    }
  }
  const invite = cluster.invite;
  if (invite) {
    rows.push(...wrappedRows("invite", invite.link, width));
    rows.push(row("expires", invite.expiresAt, width));
    if (invite.localOnly) rows.push(...wrappedRows("", LOCAL_ONLY_HINT, width));
  }
  return rows;
}

/** Whether new threads are balanced, then how often each machine gets them. */
function loadBalancingRows(balancing: TuiLoadBalancingState, width: number): TuiSettingsRow[] {
  const { settings } = balancing;
  if (settings === null) return [row("balance load", balancing.error ?? "reading…", width)];
  return [
    row("balance load", settings.enabled ? "On" : "Off", width),
    ...balancing.machines.map((machine) =>
      row(machine.label, loadPreferenceForWeight(settings.weights[machine.id]).label, width),
    ),
    row("", "change these from the palette (^K)", width),
  ];
}

/** A group another controller adds to the overview: its title and labelled values. */
export interface TuiSettingsExtraGroup {
  readonly title: string;
  readonly rows: ReadonlyArray<readonly [label: string, value: string]>;
}

export function buildTuiSettingsState(input: {
  readonly active: boolean;
  readonly detail: OrchestrationThread | null;
  readonly vcsStatus: VcsStatusResult | null;
  readonly cluster: TuiClusterState;
  /** Null while this machine is alone: one machine has nothing to balance against. */
  readonly loadBalancing: TuiLoadBalancingState | null;
  /** The pane's width (the conversation column); values clip to it. */
  readonly width: number;
  /** Groups other areas list after the cluster: label and value per row, wrapped to the pane. */
  readonly extra?: ReadonlyArray<TuiSettingsExtraGroup>;
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
      { title: "Cluster", rows: clusterRows(input.cluster, width) },
      ...(input.loadBalancing
        ? [{ title: "Load balancing", rows: loadBalancingRows(input.loadBalancing, width) }]
        : []),
      ...(input.extra ?? []).map((group) => ({
        title: group.title,
        rows: group.rows.flatMap(([label, value]) => wrappedRows(label, value || "—", width)),
      })),
      ...KEYBINDING_GROUPS.map((group) => ({
        title: group.title,
        rows: group.bindings.map((binding) => keyRow(binding.keys, binding.description, width)),
      })),
    ],
  };
}
