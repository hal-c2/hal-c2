import type { GitStackedAction, OrchestrationThread } from "@t3tools/contracts";
import type { PropertyMap } from "opentui-qml";

import type { TuiClient } from "../connection.ts";
import { splitUnifiedDiff } from "../diffSplit.ts";
import type { Store, StoreState } from "../store.ts";
import { revertableCheckpoints } from "../timeline.ts";
import { buildTuiGitState, clampIndex, planGitRun, type TuiGitState } from "./gitState.ts";
import type { TuiLayoutState, TuiMode } from "./layoutState.ts";
import { threadKey } from "./sidebarState.ts";

/** Copies text for the user; the entry wires the renderer's OSC 52. */
export interface TuiClipboard {
  /** Write `text` to the system clipboard. */
  readonly copy: (text: string) => void;
  /** Whether the terminal is known to honour the copy. */
  readonly supported: () => boolean;
}

/**
 * Published under `rightPanel`: the contract's panel model. The terminal has
 * one surface, source control; `focused` says whether keys go to it.
 */
export interface TuiRightPanelState {
  readonly threadKey: string;
  readonly isOpen: boolean;
  readonly focused: boolean;
  readonly activeSurfaceId: string | null;
  readonly surfaces: ReadonlyArray<{
    readonly id: string;
    readonly kind: string;
    readonly title: string;
  }>;
  readonly canAdd: {
    readonly diff: boolean;
    readonly files: boolean;
    readonly terminal: boolean;
    readonly pullRequest: boolean;
  };
  readonly embedPath: string;
}

export type TuiDiffStatus = "loading" | "ready" | "empty" | "error";

/** Published under `diff`: the checkpoint diff viewer over the conversation. */
export interface TuiDiffState {
  readonly open: boolean;
  /** "all changes" or "turn 3". */
  readonly scopeLabel: string;
  readonly status: TuiDiffStatus;
  readonly files: ReadonlyArray<{
    readonly path: string;
    readonly filetype: string;
    readonly body: string;
  }>;
  readonly view: "unified" | "split";
  /** 0 is all changes, then each turn newest first. */
  readonly index: number;
  readonly entryCount: number;
}

const SOURCE_CONTROL_SURFACE = { id: "git", kind: "source-control", title: "Source Control" };
const NO_ADD = { diff: false, files: false, terminal: false, pullRequest: false };

const payloadField = (payload: unknown, field: string): unknown =>
  typeof payload === "object" && payload !== null
    ? (payload as Record<string, unknown>)[field]
    : undefined;

interface DiffEntry {
  readonly label: string;
  readonly fetch: () => Promise<string>;
}

function diffEntries(client: TuiClient, detail: OrchestrationThread | null): DiffEntry[] {
  if (!detail) return [];
  const checkpoints = revertableCheckpoints(detail.checkpoints);
  const latest = checkpoints.reduce((max, c) => Math.max(max, c.checkpointTurnCount), 0);
  return [
    { label: "all changes", fetch: () => client.getFullThreadDiff(detail.id, latest) },
    ...checkpoints.map((checkpoint) => ({
      label: `turn ${checkpoint.checkpointTurnCount}`,
      fetch: () => client.getTurnDiff(detail.id, checkpoint.checkpointTurnCount),
    })),
  ];
}

/**
 * The source-control panel, its git actions and the diff viewer. The host
 * forwards store changes (`publish`) and unhandled actions (`dispatch`) here.
 */
export function createSourceControl(deps: {
  readonly store: Store;
  readonly client: TuiClient;
  readonly state: PropertyMap;
  readonly mode: () => TuiMode;
  readonly setMode: (mode: TuiMode) => void;
  readonly layout: () => TuiLayoutState;
  /** The panel opened or closed: the host re-splits the columns. */
  readonly panelChanged: () => void;
  readonly clipboard?: TuiClipboard;
}) {
  const { store, client, state } = deps;
  let panelOpen = false;
  let panelFocused = false;
  let gitIndex = 0;
  let commitPrompt: TuiGitState["commitPrompt"] = null;
  let diffOpen = false;
  let diffIndex = 0;
  let diffView: TuiDiffState["view"] = "unified";
  let diffStatus: TuiDiffStatus = "loading";
  let diffText = "";
  let diffRequest = 0;

  const current = () => store.getState();

  const publishPanel = () => {
    const selection = current().selection;
    state.set("rightPanel", {
      threadKey: selection?.kind === "thread" ? threadKey(selection.id) : "",
      isOpen: panelOpen,
      focused: panelFocused,
      activeSurfaceId: panelOpen ? SOURCE_CONTROL_SURFACE.id : null,
      surfaces: [SOURCE_CONTROL_SURFACE],
      canAdd: NO_ADD,
      embedPath: "",
    } satisfies TuiRightPanelState);
  };

  const gitState = () =>
    buildTuiGitState({
      status: current().vcsStatus,
      busy: current().gitBusy,
      selectedIndex: gitIndex,
      commitPrompt,
    });
  const publishGit = () => {
    const next = gitState();
    gitIndex = next.selectedIndex;
    state.set("git", next);
  };

  const publishDiff = () => {
    const entries = diffEntries(client, current().detail);
    state.set("diff", {
      open: diffOpen,
      scopeLabel: entries[diffIndex]?.label ?? "all changes",
      status: diffStatus,
      files:
        diffStatus === "ready"
          ? splitUnifiedDiff(diffText).map((file) => ({
              path: file.path,
              filetype: file.filetype ?? "",
              body: file.body,
            }))
          : [],
      view: diffView,
      index: diffIndex,
      entryCount: entries.length,
    } satisfies TuiDiffState);
  };

  const loadDiff = () => {
    const entry = diffEntries(client, current().detail)[diffIndex];
    const request = ++diffRequest;
    diffStatus = "loading";
    diffText = "";
    publishDiff();
    if (!entry) return;
    entry.fetch().then(
      (text) => {
        if (request !== diffRequest) return;
        diffText = text;
        diffStatus = text.trim().length > 0 ? "ready" : "empty";
        publishDiff();
      },
      () => {
        if (request !== diffRequest) return;
        diffStatus = "error";
        publishDiff();
      },
    );
  };

  const setPanel = (open: boolean, focused: boolean) => {
    const wasOpen = panelOpen;
    panelOpen = open;
    panelFocused = open && focused;
    if (open && !wasOpen) gitIndex = 0;
    publishPanel();
    publishGit();
    if (open !== wasOpen) deps.panelChanged();
    if (panelFocused) deps.setMode(commitPrompt ? "commit" : "panel");
    else if (deps.mode() === "panel" || deps.mode() === "commit") deps.setMode("compose");
  };

  /** Leave the panel's keys; a panel standing in for the conversation closes. */
  const leavePanel = () => {
    if (deps.layout().rightPanelAsMain) setPanel(false, false);
    else setPanel(panelOpen, false);
  };

  const runGit = (action: GitStackedAction, label: string) => {
    const plan = planGitRun(action, current().vcsStatus);
    if (plan.kind === "nothing") {
      store.setStatus(plan.message);
      return;
    }
    if (plan.kind === "run") {
      store.runGitAction(plan.action);
      return;
    }
    // The message is asked for in the panel, which opens for it if needed.
    commitPrompt = { action: plan.action, label };
    setPanel(true, true);
  };

  const copyPrUrl = (url: string) => {
    deps.clipboard?.copy(url);
    const copied = deps.clipboard?.supported() ?? false;
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
    publishGit();
    deps.setMode(panelFocused ? "panel" : "compose");
  };

  const dispatch = (action: string, payload?: unknown): boolean => {
    switch (action) {
      case "rightPanel.toggle":
        if (panelOpen) setPanel(false, false);
        else setPanel(true, true);
        return true;
      case "rightPanel.open":
        setPanel(true, true);
        return true;
      case "rightPanel.close":
        commitPrompt = null;
        setPanel(false, false);
        return true;
      case "rightPanel.focus":
        setPanel(true, true);
        return true;
      case "rightPanel.blur":
        leavePanel();
        return true;
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
        store.runGitAction(commitPrompt.action, text);
        if (text.length > 0) endCommitPrompt();
        return true;
      }
      case "git.commit.cancel":
        endCommitPrompt();
        return true;
      case "diff.open": {
        diffOpen = true;
        const turn = payloadField(payload, "turnCount");
        const entries = diffEntries(client, current().detail);
        const at =
          typeof turn === "number" ? entries.findIndex((e) => e.label === `turn ${turn}`) : 0;
        diffIndex = Math.max(0, at);
        deps.setMode("diff");
        loadDiff();
        return true;
      }
      case "diff.next":
      case "diff.previous": {
        const count = Math.max(1, diffEntries(client, current().detail).length);
        diffIndex = (diffIndex + (action === "diff.next" ? 1 : count - 1)) % count;
        loadDiff();
        return true;
      }
      case "diff.toggleView":
        diffView = diffView === "unified" ? "split" : "unified";
        publishDiff();
        return true;
      case "diff.close":
        diffOpen = false;
        diffRequest += 1;
        publishDiff();
        if (deps.mode() === "diff") deps.setMode("compose");
        return true;
      default:
        return false;
    }
  };

  const publish = (prev: StoreState | null, next: StoreState) => {
    if (!prev || prev.vcsStatus !== next.vcsStatus || prev.gitBusy !== next.gitBusy) publishGit();
    if (!prev || prev.selection !== next.selection) publishPanel();
    if (!prev || prev.detail !== next.detail) publishDiff();
  };

  return {
    dispatch,
    publish,
    /** Whether the panel takes columns (the host's layout input). */
    panelOpen: () => panelOpen,
  };
}
