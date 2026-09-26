import type { GitStackedAction, VcsStatusResult } from "@t3tools/contracts";
import type { ShellGitState } from "@t3tools/contracts/shell";

import {
  buildGitMenuItems,
  buildGitPanelActions,
  gitActionNeedsCommitMessage,
  resolveGitQuickAction,
  type GitPanelAction,
} from "../gitActions.logic.ts";
import { fileTypeColor } from "../icons.ts";

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
}

/** A working-tree file as the panel lists it, tinted by its type (null: dimmed). */
export interface TuiGitFile {
  readonly path: string;
  readonly insertions: number;
  readonly deletions: number;
  readonly color: string | null;
}

/**
 * Published under `git`: the contract's git control model plus what the
 * terminal's source-control panel draws (summary lines, the keyboard-navigable
 * action list, the pending commit message prompt).
 */
export interface TuiGitState extends ShellGitState {
  readonly files: ReadonlyArray<TuiGitFile>;
  readonly actions: ReadonlyArray<TuiGitAction>;
  readonly selectedIndex: number;
  /** The highlighted action's hint (why it is disabled, or how it opens). */
  readonly selectedHint: string | null;
  /** "↑2 ↓1 upstream", "up to date with upstream", or "" without an upstream. */
  readonly syncLine: string;
  /** "◰ PR #12 open ↗", or "". */
  readonly prLine: string;
  readonly prState: string | null;
  readonly prUrl: string | null;
  /** "3 files · +10 -2", or "working tree clean". */
  readonly changesLine: string;
  /** Set while the panel asks for a commit message for this action. */
  readonly commitPrompt: { readonly action: GitStackedAction; readonly label: string } | null;
}

export function buildTuiGitState(input: {
  readonly status: VcsStatusResult | null;
  readonly busy: boolean;
  readonly selectedIndex: number;
  readonly commitPrompt: TuiGitState["commitPrompt"];
}): TuiGitState {
  const { status, busy } = input;
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
    files: (status?.workingTree.files ?? []).map((file) => ({
      path: file.path,
      insertions: file.insertions,
      deletions: file.deletions,
      color: fileTypeColor(file.path),
    })),
    pendingDefaultBranch: null,
    actions,
    selectedIndex,
    selectedHint: actions[selectedIndex]?.hint ?? null,
    syncLine: status ? syncLine(status) : "",
    prLine: pr ? `◰ PR #${pr.number} ${pr.state} ↗` : "",
    prState: pr?.state ?? null,
    prUrl: pr?.url ?? null,
    changesLine: !status
      ? ""
      : status.hasWorkingTreeChanges
        ? `${fileCount} ${fileCount === 1 ? "file" : "files"} · +${status.workingTree.insertions} -${status.workingTree.deletions}`
        : "working tree clean",
    commitPrompt: input.commitPrompt,
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
