import type { ThreadEnvMode, VcsRef } from "@t3tools/contracts";
import { truncate } from "@t3tools/shared/String";
import type { PropertyMap } from "opentui-qml";

import type { TuiClient } from "../connection.ts";
import {
  newThreadValidationMessage,
  resolveInitialBranch,
  resolveNewThreadBranchSelection,
  resolveNewThreadContext,
  validateNewThread,
  type NewThreadWorkspaceMode,
} from "../newThread.logic.ts";
import type { Store } from "../store.ts";
import type { TuiMode } from "./layoutState.ts";
import { idFromKey, projectKey } from "./sidebarState.ts";

/** Published under `newThread` (null when no draft is open): the new-thread form. */
export interface TuiNewThreadState {
  readonly draftId: string;
  readonly projectKey: string;
  readonly projectName: string;
  readonly workspaceMode: NewThreadWorkspaceMode;
  /** "New worktree", "Current worktree" or "Project workspace". */
  readonly workspaceLabel: string;
  /** The base branch (new worktree) or the branch the thread works on. */
  readonly branch: string | null;
  readonly worktreePath: string | null;
  readonly refsStatus: "loading" | "ready" | "empty" | "error";
  readonly refs: ReadonlyArray<{
    readonly name: string;
    readonly current: boolean;
    readonly worktreePath: string | null;
    readonly selected: boolean;
  }>;
  /** A branch switch or the create call is in flight. */
  readonly pending: boolean;
}

export interface NewThreadSettings {
  readonly defaultThreadEnvMode: ThreadEnvMode | null;
  readonly newWorktreesStartFromOrigin: boolean;
}

export interface NewThreadContext {
  readonly client: TuiClient;
  readonly store: Store;
  readonly state: PropertyMap;
  readonly settings: () => NewThreadSettings;
  readonly setMode: (mode: TuiMode) => void;
  /** The draft opened or closed: the sidebar and page follow it. */
  readonly onDraftChange: () => void;
}

interface Draft {
  readonly draftId: string;
  readonly projectId: string;
  readonly workspaceMode: NewThreadWorkspaceMode;
  readonly branch: string | null;
  readonly worktreePath: string | null;
  /** The selected thread's worktree, restored when switching back to "current". */
  readonly contextWorktreePath: string | null;
  readonly refs: ReadonlyArray<VcsRef>;
  readonly refsStatus: TuiNewThreadState["refsStatus"];
  readonly pending: boolean;
}

const field = (payload: unknown, name: string): unknown =>
  typeof payload === "object" && payload !== null
    ? (payload as Record<string, unknown>)[name]
    : undefined;

const envMode = (mode: ThreadEnvMode | null | undefined): "local" | "worktree" | null =>
  mode === "worktree" ? "worktree" : mode === "local" ? "local" : null;

/**
 * The new-thread flow (port of ChatView's `openNewThread` / `submitNewThread`):
 * a draft inherits the selected thread's project and workspace, loads the
 * project's refs, and creates the thread with its first message.
 */
export function createNewThreadFlow(ctx: NewThreadContext) {
  const { client, store, state } = ctx;
  let draft: Draft | null = null;
  let drafts = 0;

  const project = (id: string) =>
    store.getState().shell?.projects.find((candidate) => candidate.id === id) ?? null;

  const publish = () => {
    if (!draft) {
      state.set("newThread", null);
      return;
    }
    const current = draft;
    state.set("newThread", {
      draftId: current.draftId,
      projectKey: projectKey(current.projectId),
      projectName: project(current.projectId)?.title ?? current.projectId,
      workspaceMode: current.workspaceMode,
      workspaceLabel:
        current.workspaceMode === "new-worktree"
          ? "New worktree"
          : current.worktreePath
            ? "Current worktree"
            : "Project workspace",
      branch: current.branch,
      worktreePath: current.worktreePath,
      refsStatus: current.refsStatus,
      refs: current.refs.map((ref) => ({
        name: ref.name,
        current: ref.current,
        worktreePath: ref.worktreePath,
        selected: ref.name === current.branch,
      })),
      pending: current.pending,
    } satisfies TuiNewThreadState);
  };

  const update = (patch: Partial<Draft>) => {
    if (!draft) return;
    draft = { ...draft, ...patch };
    publish();
  };

  const loadRefs = (draftId: string, cwd: string) => {
    void client.listRefs(cwd).then(
      (result) => {
        if (draft?.draftId !== draftId) return;
        update({
          refs: result.refs,
          refsStatus: result.refs.length > 0 ? "ready" : "empty",
          branch: resolveInitialBranch(result.refs, draft.branch),
        });
      },
      () => {
        if (draft?.draftId !== draftId) return;
        update({ refsStatus: "error" });
      },
    );
  };

  const open = (payload: unknown) => {
    if (draft) return;
    const snapshot = store.getState();
    const projects = snapshot.shell?.projects ?? [];
    if (projects.length === 0) {
      store.setStatus(newThreadValidationMessage("missing-project"), "error");
      return;
    }
    const selection = snapshot.selection;
    const thread =
      selection?.kind === "thread"
        ? (snapshot.shell?.threads.find((candidate) => candidate.id === selection.id) ?? null)
        : null;
    const key = field(payload, "projectKey");
    const selectedProjectId =
      typeof key === "string"
        ? idFromKey(key)
        : selection?.kind === "project"
          ? selection.id
          : (thread?.projectId ?? snapshot.projectScopeId);
    const target = projects.find((candidate) => candidate.id === selectedProjectId);
    const context = resolveNewThreadContext({
      projects,
      selectedProjectId,
      thread,
      // Null means inherit: the project's own default, then the server's, then local.
      defaultEnvironmentMode:
        envMode(target?.defaultThreadEnvMode) ??
        envMode(ctx.settings().defaultThreadEnvMode) ??
        "local",
    });
    const chosen = projects[context.projectIndex]!;
    drafts += 1;
    draft = {
      draftId: `draft-${drafts}`,
      projectId: chosen.id,
      workspaceMode: context.workspaceMode,
      branch: context.branch,
      worktreePath: context.worktreePath,
      contextWorktreePath: context.worktreePath,
      refs: [],
      refsStatus: "loading",
      pending: false,
    };
    publish();
    ctx.setMode("newThread");
    ctx.onDraftChange();
    loadRefs(draft.draftId, chosen.workspaceRoot);
  };

  const close = () => {
    if (!draft) return;
    draft = null;
    publish();
    ctx.setMode("compose");
    ctx.onDraftChange();
  };

  const chooseBranch = (name: unknown) => {
    const current = draft;
    if (!current || current.pending || typeof name !== "string") return;
    const ref = current.refs.find((candidate) => candidate.name === name);
    const cwd = project(current.projectId)?.workspaceRoot;
    if (!ref || !cwd) return;
    const selection = resolveNewThreadBranchSelection({
      workspaceMode: current.workspaceMode,
      projectCwd: cwd,
      currentWorktreePath: current.worktreePath,
      ref,
    });
    if (selection.kind === "select-base") {
      update({ branch: selection.branch });
      store.setStatus(`Worktree base → ${selection.branch}`, "success");
      return;
    }
    if (selection.kind === "reuse-worktree") {
      update({ branch: selection.branch, worktreePath: selection.worktreePath });
      store.setStatus(`Workspace → ${selection.branch}`, "success");
      return;
    }
    update({ pending: true });
    store.setStatus(`Switching checkout to ${ref.name}…`, "busy");
    const draftId = current.draftId;
    void client.switchRef(selection.checkoutCwd, ref.name).then(
      (result) => {
        if (draft?.draftId !== draftId) return;
        const branch = result.refName ?? selection.branch;
        update({ branch, worktreePath: selection.worktreePath, pending: false });
        store.setStatus(`Branch → ${branch}`, "success");
      },
      (error: unknown) => {
        if (draft?.draftId !== draftId) return;
        update({ pending: false });
        store.setStatus(`branch switch failed: ${String(error)}`, "error");
      },
    );
  };

  const setWorkspaceMode = (mode: unknown) => {
    if (!draft || draft.pending) return;
    if (mode !== "current" && mode !== "new-worktree") return;
    update({
      workspaceMode: mode,
      worktreePath: mode === "new-worktree" ? null : draft.contextWorktreePath,
    });
  };

  const submit = (payload: unknown) => {
    const current = draft;
    if (!current) return;
    if (current.pending) {
      store.setStatus("Wait for the branch switch to finish.", "info");
      return;
    }
    const target = project(current.projectId);
    const raw = field(payload, "message");
    const message = typeof raw === "string" ? raw.trim() : "";
    const selection = store.getState().selection;
    const thread =
      selection?.kind === "thread"
        ? store.getState().shell?.threads.find((candidate) => candidate.id === selection.id)
        : undefined;
    const modelSelection = target?.defaultModelSelection ?? thread?.modelSelection ?? null;
    const error = validateNewThread({
      hasProject: target !== null,
      message,
      hasModelSelection: modelSelection !== null,
      workspaceMode: current.workspaceMode,
      branch: current.branch,
    });
    if (error) {
      store.setStatus(newThreadValidationMessage(error), "error");
      return;
    }
    if (!target || !modelSelection) return;
    const createWorktree = current.workspaceMode === "new-worktree";
    update({ pending: true });
    store.setStatus("Creating thread and starting its first turn…", "busy");
    void client
      .createThread({
        projectId: target.id,
        projectCwd: target.workspaceRoot,
        title: truncate(message),
        modelSelection,
        firstMessage: message,
        attachments: [],
        runtimeMode: thread?.runtimeMode ?? "full-access",
        interactionMode: "default",
        branch: current.branch,
        worktreePath: createWorktree ? null : current.worktreePath,
        createWorktree,
        startFromOrigin: createWorktree && ctx.settings().newWorktreesStartFromOrigin,
      })
      .then(
        (threadId) => {
          if (draft?.draftId !== current.draftId) return;
          const scope = store.getState().projectScopeId;
          if (scope !== null && scope !== target.id) store.setProjectScope(target.id);
          draft = null;
          publish();
          store.select({ kind: "thread", id: threadId });
          store.setStatus("Thread created.", "success");
          ctx.setMode("compose");
          ctx.onDraftChange();
        },
        (failure: unknown) => {
          update({ pending: false });
          store.setStatus(`create failed: ${String(failure)}`, "error");
        },
      );
  };

  publish();

  return {
    /** The open draft's id and project, for the sidebar row and the page. */
    draft: () => (draft ? { draftId: draft.draftId, projectId: draft.projectId } : null),
    dispatch: (action: string, payload?: unknown): boolean => {
      switch (action) {
        case "thread.new":
          open(payload);
          return true;
        case "newThread.workspaceMode":
          setWorkspaceMode(field(payload, "mode"));
          return true;
        case "newThread.branch":
          chooseBranch(field(payload, "name"));
          return true;
        case "newThread.submit":
          submit(payload);
          return true;
        case "newThread.cancel":
          close();
          return true;
        default:
          return false;
      }
    },
  };
}
