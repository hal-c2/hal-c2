import type { GitStackedAction } from "@hal-c2/contracts";
import type { PropertyMap } from "opentui-qml";

import type { Store, StoreState } from "../store.ts";
import type { PickRequest } from "./composerState.ts";
import { buildTuiGitState, clampIndex, planGitRun, type TuiGitState } from "./gitState.ts";
import type { TuiMode } from "./layoutState.ts";

/** The `layout.rightPanel.kind` of the source-control panel. */
export const SOURCE_CONTROL_PANEL = "sourceControl";

const payloadField = (payload: unknown, field: string): unknown =>
  typeof payload === "object" && payload !== null
    ? (payload as Record<string, unknown>)[field]
    : undefined;

/**
 * The source-control panel's git state and actions (`git.*`). The host owns
 * the panel slot (`layout.rightPanel`), forwards store changes (`publish`),
 * panel open/close (`panelChanged`) and unhandled actions (`dispatch`) here.
 */
export function createSourceControl(deps: {
  readonly store: Store;
  readonly state: PropertyMap;
  readonly setMode: (mode: TuiMode) => void;
  /** Whether the source-control panel is open and has the keys. */
  readonly panel: () => { readonly open: boolean; readonly focused: boolean };
  /** The panel's width in cells. */
  readonly width: () => number;
  /** Open the source-control panel with the keys on it. */
  readonly focusPanel: () => void;
  /** Ask the user to choose (the picker). */
  readonly menu: (spec: PickRequest) => void;
  /** Put text on the system clipboard; false when the terminal cannot (OSC 52). */
  readonly copyToClipboard?: ((text: string) => boolean) | undefined;
}) {
  const { store, state } = deps;
  let gitIndex = 0;
  let commitPrompt: TuiGitState["commitPrompt"] = null;
  /** The user chose a new branch for the action the commit prompt is asking about. */
  let featureBranch = false;

  const current = () => store.getState();

  const gitState = () =>
    buildTuiGitState({
      status: current().vcsStatus,
      busy: current().gitBusy,
      selectedIndex: gitIndex,
      commitPrompt,
      width: deps.width(),
      log: current().gitLog,
      progress: current().gitProgress,
    });
  const publishGit = () => {
    const next = gitState();
    gitIndex = next.selectedIndex;
    state.set("git", next);
  };

  const runGit = (action: GitStackedAction, label: string) => {
    const status = current().vcsStatus;
    const plan = planGitRun(action, status);
    if (plan.kind === "nothing") {
      store.setStatus(plan.message);
      return;
    }
    const start = (onNewBranch: boolean) => {
      if (plan.kind === "run") {
        store.runGitAction(plan.action, undefined, { featureBranch: onNewBranch });
        return;
      }
      // The message is asked for in the panel, which opens for it if needed.
      featureBranch = onNewBranch;
      commitPrompt = { action: plan.action, label };
      publishGit();
      deps.focusPanel();
    };
    // Nothing reaches the default branch (or a pull request from it) unasked.
    if (!status?.isDefaultRef || plan.action === "commit") {
      start(false);
      return;
    }
    const branch = status.refName ?? "the default branch";
    deps.menu({
      title: `${label} on the default branch ${branch}?`,
      returnMode: deps.panel().focused ? "panel" : "compose",
      options: [
        {
          label: `Continue on ${branch}`,
          description: `${label} lands on ${branch}.`,
          value: "continue",
        },
        {
          label: "Create a feature branch and continue",
          description: `The same action, on a new branch off ${branch}.`,
          value: "branch",
        },
        { label: "Cancel", description: "Nothing is committed or pushed.", value: "cancel" },
      ],
      index: 2,
      onChoose: (choice) => {
        if (choice !== "cancel") start(choice === "branch");
      },
    });
  };

  const copyPrUrl = (url: string) => {
    const copied = deps.copyToClipboard?.(url) ?? false;
    store.setStatus(
      copied ? "PR link copied. Ctrl-click the underlined link to open it." : `Open PR: ${url}`,
      copied ? "success" : "info",
    );
  };

  const activate = (index: number) => {
    const action = gitState().actions[index];
    if (!action) return;
    if (action.disabled) {
      if (action.hint) store.setStatus(action.hint, "info");
      return;
    }
    if (action.kind === "url" && action.url) {
      copyPrUrl(action.url);
      return;
    }
    if (action.kind === "pull") {
      store.pullGit();
      return;
    }
    if (action.kind === "git" && action.action) runGit(action.action, action.label);
  };

  const endCommitPrompt = () => {
    commitPrompt = null;
    featureBranch = false;
    publishGit();
    deps.setMode(deps.panel().focused ? "panel" : "compose");
  };

  const dispatch = (action: string, payload?: unknown): boolean => {
    switch (action) {
      case "git.next":
      case "git.previous": {
        const count = gitState().actions.length;
        if (count === 0) return true;
        gitIndex = (gitIndex + (action === "git.next" ? 1 : count - 1)) % count;
        publishGit();
        return true;
      }
      case "git.select": {
        const index = payloadField(payload, "index");
        if (typeof index === "number") {
          gitIndex = clampIndex(index, gitState().actions.length);
          publishGit();
        }
        return true;
      }
      case "git.activate": {
        const index = payloadField(payload, "index");
        if (typeof index === "number") gitIndex = clampIndex(index, gitState().actions.length);
        activate(gitIndex);
        return true;
      }
      case "git.run": {
        const stacked = payloadField(payload, "action");
        const label = payloadField(payload, "label");
        if (typeof stacked === "string") {
          runGit(stacked as GitStackedAction, typeof label === "string" ? label : stacked);
        }
        return true;
      }
      case "git.pull":
        store.pullGit();
        return true;
      case "git.openPr": {
        const url = current().vcsStatus?.pr?.url;
        if (url) copyPrUrl(url);
        return true;
      }
      case "git.commit": {
        const message = payloadField(payload, "message");
        if (!commitPrompt) return true;
        const text = typeof message === "string" ? message.trim() : "";
        // An empty message keeps the prompt open; the store says why.
        store.runGitAction(commitPrompt.action, text, { featureBranch });
        if (text.length > 0) endCommitPrompt();
        return true;
      }
      // Tab in the commit prompt: the server's writer model writes the message.
      case "git.commit.generate":
        if (!commitPrompt) return false;
        store.runGitAction(commitPrompt.action, undefined, {
          generateMessage: true,
          featureBranch,
        });
        endCommitPrompt();
        return true;
      case "git.commit.cancel":
        endCommitPrompt();
        return true;
      case "git.log.dismiss":
        // Declined with nothing to dismiss, so the key reaches whatever is under it.
        if (current().gitLog.length === 0) return false;
        store.dismissGitLog();
        return true;
      default:
        return false;
    }
  };

  const publish = (prev: StoreState | null, next: StoreState) => {
    if (
      !prev ||
      prev.vcsStatus !== next.vcsStatus ||
      prev.gitBusy !== next.gitBusy ||
      prev.gitProgress !== next.gitProgress ||
      prev.gitLog !== next.gitLog
    ) {
      publishGit();
    }
  };

  let publishedWidth = -1;
  return {
    dispatch,
    publish,
    /** The panel was resized: its rows clip to the new width. */
    resize: () => {
      if (deps.width() === publishedWidth) return;
      publishedWidth = deps.width();
      publishGit();
    },
    /** The panel opened (highlight the first action) or closed (drop a pending commit message). */
    panelChanged: (open: boolean) => {
      if (open) gitIndex = 0;
      else commitPrompt = null;
      publishGit();
    },
    /** The mode a focused panel takes: the commit message while one is asked for. */
    focusMode: (): TuiMode => (commitPrompt ? "commit" : "panel"),
  };
}
