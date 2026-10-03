import type { GitStackedAction, VcsStatusResult } from "@hal-c2/contracts";
import type { ShellGitState } from "@hal-c2/contracts/shell";

import {
  buildGitMenuItems,
  buildGitPanelActions,
  gitActionNeedsCommitMessage,
  resolveGitQuickAction,
  type GitPanelAction,
} from "../gitActions.logic.ts";
import { clip } from "../format.ts";
import type { GitLogLine } from "../store.ts";

/** One row of the source-control panel's action list. */
export interface TuiGitAction {
  readonly id: string;
  readonly label: string;
  readonly primary: boolean;
  readonly disabled: boolean;
  readonly hint: string | null;
  readonly kind: GitPanelAction["kind"];
  /** The stacked action a `git` row runs. */
  readonly action: GitStackedAction | null;
  readonly url: string | null;
  /** The label as the row draws it: " ↗" after a link, clipped to the panel. */
  readonly text: string;
}

/**
 * Published under `git`: the contract's git control model plus what the
 * terminal's source-control panel draws (summary lines, the keyboard-navigable
 * action list, the pending commit message prompt).
 */
export interface TuiGitState extends ShellGitState {
  /** The branch as the "on …" row draws it, clipped to the panel. */
  readonly branchText: string;
  readonly actions: ReadonlyArray<TuiGitAction>;
  readonly selectedIndex: number;
  /** The highlighted action's hint (why it is disabled, or how it opens), indented and clipped. */
  readonly selectedHint: string | null;
  /** "↑2 ↓1 upstream", "up to date with upstream", or "" without an upstream. */
  readonly syncLine: string;
  /** "◰ PR #12 " in the state's colour, then "open ↗" dimmed; "" without a PR. */
  readonly prLabel: string;
  readonly prStateLabel: string;
  readonly prState: string | null;
  readonly prUrl: string | null;
  /** "3 files · +10 -2", or "working tree clean". */
  readonly changesLine: string;
  /** Set while the panel asks for a commit message for this action. */
  readonly commitPrompt: { readonly action: GitStackedAction; readonly label: string } | null;
  /** The running (or last) action's phases, hooks and hook output, clipped to the panel. */
  readonly log: ReadonlyArray<{ readonly kind: GitLogLine["kind"]; readonly text: string }>;
  /** The last action failed: its error stays in `log` until dismissed. */
  readonly failed: boolean;
}

export function buildTuiGitState(input: {
  readonly status: VcsStatusResult | null;
  readonly busy: boolean;
  readonly selectedIndex: number;
  readonly commitPrompt: TuiGitState["commitPrompt"];
  /** The panel's width; RightPanel clips its rows to the room inside border and padding. */
  readonly width: number;
  readonly log?: ReadonlyArray<GitLogLine>;
}): TuiGitState {
  const { status, busy } = input;
  const room = Math.max(6, input.width - 4);
  const quick = resolveGitQuickAction(status, busy);
  const actions = buildGitPanelActions(status, busy).map((action): TuiGitAction => ({
    id: action.id,
    label: action.label,
    primary: action.primary,
    disabled: action.disabled,
    hint: action.hint ?? null,
    kind: action.kind,
    action: action.kind === "git" ? action.action : null,
    url: action.kind === "url" ? action.url : null,
    text: clip(`${action.label}${action.kind === "url" ? " ↗" : ""}`, room - 2),
  }));
  const selectedIndex = clampIndex(input.selectedIndex, actions.length);
  const menuItems = buildGitMenuItems(status, busy);
  const pr = status?.pr ?? null;
  const fileCount = status?.workingTree.files.length ?? 0;
  return {
    available: status !== null,
    isRepo: status?.isRepo ?? false,
    busy,
    initPending: false,
    quickAction: {
      label: quick.label,
      disabledReason: quick.kind === "show_hint" ? quick.hint : null,
      kind: quick.kind,
    },
    menu: menuItems.map((item) => ({
      id: item.id,
      label: item.label,
      disabledReason: item.disabled
        ? (actions.find((action) => action.id === `menu-${item.id}`)?.hint ?? null)
        : null,
    })),
    // Publishing needs the provider flow, which the terminal does not have.
    canPublish: false,
    hints: [],
    branch: status?.refName ?? null,
    isDefaultRef: status?.isDefaultRef ?? false,
    // The contract's commit-dialog list; the panel itself shows only the count.
    files: (status?.workingTree.files ?? []).map(({ path, insertions, deletions }) => ({
      path,
      insertions,
      deletions,
    })),
    branchText: clip(status?.refName ?? "(detached)", room),
    pendingDefaultBranch: null,
    actions,
    selectedIndex,
    selectedHint: actions[selectedIndex]?.hint
      ? clip(`  ${actions[selectedIndex]!.hint}`, room)
      : null,
    syncLine: status ? syncLine(status) : "",
    prLabel: pr ? `◰ PR #${pr.number} ` : "",
    prStateLabel: pr ? `${pr.state} ↗` : "",
    prState: pr?.state ?? null,
    prUrl: pr?.url ?? null,
    changesLine: !status
      ? ""
      : status.hasWorkingTreeChanges
        ? clip(
            `${fileCount} ${fileCount === 1 ? "file" : "files"} · +${status.workingTree.insertions} -${status.workingTree.deletions}`,
            room,
          )
        : "working tree clean",
    commitPrompt: input.commitPrompt,
    // The newest lines that fit a short pane; an error is always the last and stays.
    log: (input.log ?? []).slice(-8).map((line) => ({
      kind: line.kind,
      text: clip(
        `${line.kind === "phase" ? "▸ " : line.kind === "error" ? "✗ " : line.kind === "hook" ? "⚙ " : "  "}${line.text}`,
        room,
      ),
    })),
    failed: (input.log ?? []).some((line) => line.kind === "error"),
  };
}

function syncLine(status: VcsStatusResult): string {
  const { aheadCount: ahead, behindCount: behind } = status;
  if (ahead > 0 || behind > 0) {
    return [ahead > 0 ? `↑${ahead}` : "", behind > 0 ? `↓${behind}` : ""]
      .filter(Boolean)
      .concat("upstream")
      .join(" ");
  }
  return status.hasUpstream ? "up to date with upstream" : "";
}

export function clampIndex(index: number, length: number): number {
  if (length <= 0) return 0;
  return Math.min(Math.max(0, index), length - 1);
}

/** What running a stacked action from the panel does, given the checkout. */
export type GitRunPlan =
  | { readonly kind: "run"; readonly action: GitStackedAction }
  | { readonly kind: "prompt"; readonly action: GitStackedAction }
  | { readonly kind: "nothing"; readonly message: string };

/**
 * A commit-bearing action on a clean tree skips the commit (commit & push just
 * pushes, commit/push/PR just opens the PR); a bare commit has nothing to do.
 * Otherwise a commit asks for its message first.
 */
export function planGitRun(action: GitStackedAction, status: VcsStatusResult | null): GitRunPlan {
  if (!gitActionNeedsCommitMessage(action)) return { kind: "run", action };
  if (status && !status.hasWorkingTreeChanges) {
    if (action === "commit_push") return { kind: "run", action: "push" };
    if (action === "commit_push_pr") return { kind: "run", action: "create_pr" };
    return { kind: "nothing", message: "Nothing to commit." };
  }
  return { kind: "prompt", action };
}
