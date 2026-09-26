import { useAtomValue } from "@effect/atom-react";
import { type ScopedThreadRef } from "@hal-c2/contracts";
import {
  isAtomCommandInterrupted,
  squashAtomCommandFailure,
} from "@hal-c2/client-runtime/state/runtime";
import type {
  GitRunStackedActionResult,
  GitStackedAction,
  VcsStatusResult,
} from "@hal-c2/contracts";
import {
  type MouseEvent,
  useCallback,
  useEffect,
  useLayoutEffect,
  useMemo,
  useRef,
  useState,
} from "react";

import {
  buildMenuItems,
  GIT_ACTION_SUCCESS_VISIBLE_MS,
  type GitActionMenuItem,
  type DefaultBranchConfirmableAction,
  requiresDefaultBranchConfirmation,
  resolveDefaultBranchActionDialogCopy,
  resolveGitActionProgressPresentation,
  resolveGitActionResultToastTiming,
  resolveLiveThreadBranchUpdate,
  resolveThreadBranchMetadataPatch,
  resolveQuickAction,
  resolveThreadBranchUpdate,
} from "../components/GitActionsControl.logic";
import { stackedThreadToast, toastManager } from "../components/ui/toast";
import { useOpenInPreferredEditor } from "../editorPreferences";
import {
  useGitStackedAction,
  useSourceControlActionRunning,
  useVcsInitAction,
  useVcsPullAction,
} from "../lib/sourceControlActions";
import { useThreadShell } from "../state/entities";
import { useEnvironmentQuery } from "../state/query";
import { serverEnvironment } from "../state/server";
import { threadEnvironment } from "../state/threads";
import { useAtomCommand } from "../state/use-atom-command";
import { vcsActionManager, vcsEnvironment } from "../state/vcs";
import { randomUUID } from "../lib/utils";
import { type DraftId, useComposerDraftStore } from "../composerDraftStore";
import { getSourceControlPresentation } from "../sourceControlPresentation";
import { useOpenPrLink } from "../lib/openPullRequestLink";

export interface PendingDefaultBranchAction {
  action: DefaultBranchConfirmableAction;
  branchName: string;
  includesCommit: boolean;
  commitMessage?: string;
  onConfirmed?: () => void;
  filePaths?: string[];
}

type GitActionToastId = ReturnType<typeof toastManager.add>;

export interface RunGitActionWithToastInput {
  action: GitStackedAction;
  commitMessage?: string;
  onConfirmed?: () => void;
  skipDefaultBranchPrompt?: boolean;
  statusOverride?: VcsStatusResult | null;
  featureBranch?: boolean;
  filePaths?: string[];
}

export interface InlineGitActionSuccess {
  readonly title: string;
  readonly description: string | null;
  readonly scopeKey: string;
}

const GIT_STATUS_WINDOW_REFRESH_DEBOUNCE_MS = 250;

type RefreshVcsStatus = (target: {
  readonly environmentId: ScopedThreadRef["environmentId"];
  readonly input: { readonly cwd: string };
}) => Promise<unknown>;

export function requestVcsStatusRefresh(
  refresh: RefreshVcsStatus,
  environmentId: ScopedThreadRef["environmentId"] | null,
  cwd: string | null,
): void {
  if (environmentId === null || cwd === null) {
    return;
  }
  void refresh({ environmentId, input: { cwd } });
}
const RUNNING_SOURCE_CONTROL_ACTIONS = ["runStackedAction", "pull", "publishRepository"] as const;

export function getMenuActionDisabledReason({
  item,
  gitStatus,
  isBusy,
  hasPrimaryRemote,
}: {
  item: GitActionMenuItem;
  gitStatus: VcsStatusResult | null;
  isBusy: boolean;
  hasPrimaryRemote: boolean;
}): string | null {
  if (!item.disabled) return null;
  if (isBusy) return "Git action in progress.";
  if (!gitStatus) return "Git status is unavailable.";

  const hasBranch = gitStatus.refName !== null;
  const hasChanges = gitStatus.hasWorkingTreeChanges;
  const isAhead = gitStatus.aheadCount > 0;
  const isBehind = gitStatus.behindCount > 0;
  const terminology = getSourceControlPresentation(gitStatus.sourceControlProvider).terminology;

  if (item.id === "commit") {
    if (!hasChanges) {
      return "Worktree is clean. Make changes before committing.";
    }
    return "Commit is currently unavailable.";
  }

  if (item.id === "push") {
    if (!hasBranch) {
      return "Detached HEAD: check out a branch before pushing.";
    }
    if (hasChanges) {
      return "Commit or stash local changes before pushing.";
    }
    if (isBehind) {
      return "Branch is behind upstream. Pull/rebase before pushing.";
    }
    if (!gitStatus.hasUpstream && !hasPrimaryRemote) {
      return 'Add an "origin" remote before pushing.';
    }
    if (!isAhead) {
      return "No local commits to push.";
    }
    return "Push is currently unavailable.";
  }

  if (!hasBranch) {
    return `Detached HEAD: check out a branch before creating a ${terminology.singular}.`;
  }
  if (hasChanges) {
    return `Commit local changes before creating a ${terminology.singular}.`;
  }
  if (!gitStatus.hasUpstream && !hasPrimaryRemote) {
    return `Add an "origin" remote before creating a ${terminology.singular}.`;
  }
  if (!isAhead) {
    return `No local commits to include in a ${terminology.singular}.`;
  }
  if (isBehind) {
    return `Branch is behind upstream. Pull/rebase before creating a ${terminology.singular}.`;
  }
  return `Create ${terminology.singular} is currently unavailable.`;
}

export interface GitActionsInput {
  readonly gitCwd: string | null;
  readonly activeThreadRef: ScopedThreadRef | null;
  readonly draftId?: DraftId | undefined;
  /** The quick action wants the publish-repository flow (a dialog the caller owns). */
  readonly onOpenPublish: () => void;
  /** Report results inline (`visibleInlineSuccess`) instead of as success toasts. */
  readonly inlineSuccess?: boolean | undefined;
}

/**
 * The git control's brain: status for the checkout, the stacked-action
 * runner with its progress and results, the default-branch gate, the
 * thread↔branch sync, and the menu / quick-action model. Shared by the HTML
 * GitActionsControl and the Qt shell's git bridge so both run git the same
 * way; dialog form state stays with whichever view shows the dialog.
 */
export function useGitActions({
  gitCwd,
  activeThreadRef,
  draftId,
  onOpenPublish,
  inlineSuccess: reportSuccessInline = false,
}: GitActionsInput) {
  const updateThreadMetadata = useAtomCommand(
    threadEnvironment.updateMetadata,
    "thread branch metadata update",
  );
  const activeEnvironmentId = activeThreadRef?.environmentId ?? null;
  const successScopeKey = `${activeEnvironmentId ?? ""}\u0000${gitCwd ?? ""}`;
  const serverConfig = useAtomValue(serverEnvironment.configValueAtom(activeEnvironmentId));
  const openInPreferredEditor = useOpenInPreferredEditor(
    activeEnvironmentId,
    serverConfig?.availableEditors ?? [],
  );
  const threadToastData = useMemo(
    () => (activeThreadRef ? { threadRef: activeThreadRef } : undefined),
    [activeThreadRef],
  );
  const openPrLink = useOpenPrLink(activeThreadRef ?? undefined);
  const activeDraftThread = useComposerDraftStore((store) =>
    draftId
      ? store.getDraftSession(draftId)
      : activeThreadRef
        ? store.getDraftThreadByRef(activeThreadRef)
        : null,
  );
  const activeServerThread = useThreadShell(activeThreadRef);
  const setDraftThreadContext = useComposerDraftStore((store) => store.setDraftThreadContext);
  const [inlineSuccess, setInlineSuccess] = useState<InlineGitActionSuccess | null>(null);
  const [pendingDefaultBranchAction, setPendingDefaultBranchAction] =
    useState<PendingDefaultBranchAction | null>(null);
  const sourceControlScope = useMemo(
    () => ({ environmentId: activeEnvironmentId, cwd: gitCwd }),
    [activeEnvironmentId, gitCwd],
  );
  const vcsActionState = useAtomValue(vcsActionManager.stateAtom(sourceControlScope));
  const visibleInlineSuccess = inlineSuccess?.scopeKey === successScopeKey ? inlineSuccess : null;
  const latestGitAction = useRef<((input: RunGitActionWithToastInput) => Promise<void>) | null>(
    null,
  );

  useEffect(() => {
    if (!inlineSuccess) return;
    const timeoutId = window.setTimeout(() => {
      setInlineSuccess(null);
    }, GIT_ACTION_SUCCESS_VISIBLE_MS);
    return () => window.clearTimeout(timeoutId);
  }, [inlineSuccess]);

  const persistThreadBranchSync = useCallback(
    (branch: string | null, manualSelection = false) => {
      if (!activeThreadRef) {
        return;
      }

      if (activeServerThread) {
        if (activeServerThread.branch === branch) {
          return;
        }

        void updateThreadMetadata({
          environmentId: activeThreadRef.environmentId,
          input: {
            threadId: activeThreadRef.threadId,
            ...resolveThreadBranchMetadataPatch(branch, activeServerThread.branch),
          },
        });

        return;
      }

      if (!activeDraftThread || activeDraftThread.branch === branch) {
        return;
      }

      setDraftThreadContext(draftId ?? activeThreadRef, {
        branch,
        worktreePath: activeDraftThread.worktreePath,
        environmentSelection: manualSelection
          ? "manual"
          : (activeDraftThread.environmentSelection ??
            (activeDraftThread.branch ? "manual" : "auto")),
      });
    },
    [
      activeDraftThread,
      activeServerThread,
      activeThreadRef,
      draftId,
      setDraftThreadContext,
      updateThreadMetadata,
    ],
  );

  const syncThreadBranchAfterGitAction = useCallback(
    (result: GitRunStackedActionResult) => {
      const branchUpdate = resolveThreadBranchUpdate(result);
      if (!branchUpdate) {
        return;
      }

      persistThreadBranchSync(branchUpdate.branch, true);
    },
    [persistThreadBranchSync],
  );

  const gitStatusQuery = useEnvironmentQuery(
    activeEnvironmentId !== null && gitCwd !== null
      ? vcsEnvironment.status({
          environmentId: activeEnvironmentId,
          input: { cwd: gitCwd },
        })
      : null,
  );
  const refreshVcsStatus = useAtomCommand(vcsEnvironment.refreshStatus, {
    reportFailure: false,
  });
  const { data: gitStatus, error: gitStatusError } = gitStatusQuery;
  const sourceControlPresentation = useMemo(
    () => getSourceControlPresentation(gitStatus?.sourceControlProvider),
    [gitStatus?.sourceControlProvider],
  );
  const changeRequestTerminology = sourceControlPresentation.terminology;
  const SourceControlIcon = sourceControlPresentation.Icon;
  // Default to true while loading so we don't flash init controls.
  const isRepo = gitStatus?.isRepo ?? true;
  const hasPrimaryRemote = gitStatus?.hasPrimaryRemote ?? false;
  const gitStatusForActions = gitStatus;

  const allFiles = gitStatusForActions?.workingTree.files ?? [];

  const initAction = useVcsInitAction(sourceControlScope);
  const initRepository = useCallback(async () => {
    const result = await initAction.run();
    if (result._tag === "Success" || isAtomCommandInterrupted(result)) return;
    const error = squashAtomCommandFailure(result);
    toastManager.add(
      stackedThreadToast({
        type: "error",
        title: "Git initialization failed",
        description: error instanceof Error ? error.message : "An error occurred.",
        ...(threadToastData !== undefined ? { data: threadToastData } : {}),
      }),
    );
  }, [initAction, threadToastData]);
  const runImmediateGitAction = useGitStackedAction(sourceControlScope);
  const pullAction = useVcsPullAction(sourceControlScope);
  const isGitActionRunning = useSourceControlActionRunning(
    sourceControlScope,
    RUNNING_SOURCE_CONTROL_ACTIONS,
  );
  const isSelectingWorktreeBase =
    !activeServerThread &&
    activeDraftThread?.envMode === "worktree" &&
    activeDraftThread.worktreePath === null;

  useEffect(() => {
    if (isGitActionRunning || isSelectingWorktreeBase || activeServerThread) {
      return;
    }

    const branchUpdate = resolveLiveThreadBranchUpdate({
      threadBranch: activeDraftThread?.branch ?? null,
      gitStatus: gitStatusForActions,
    });
    if (!branchUpdate) {
      return;
    }

    persistThreadBranchSync(branchUpdate.branch);
  }, [
    activeServerThread,
    activeDraftThread?.branch,
    gitStatusForActions,
    isGitActionRunning,
    isSelectingWorktreeBase,
    persistThreadBranchSync,
  ]);

  const isDefaultRef = useMemo(() => {
    return gitStatusForActions?.isDefaultRef ?? false;
  }, [gitStatusForActions?.isDefaultRef]);

  const gitActionMenuItems = useMemo(
    () => buildMenuItems(gitStatusForActions, isGitActionRunning, hasPrimaryRemote),
    [gitStatusForActions, hasPrimaryRemote, isGitActionRunning],
  );
  const quickAction = useMemo(
    () =>
      resolveQuickAction(gitStatusForActions, isGitActionRunning, isDefaultRef, hasPrimaryRemote),
    [gitStatusForActions, hasPrimaryRemote, isDefaultRef, isGitActionRunning],
  );
  const quickActionDisabledReason = quickAction.disabled
    ? (quickAction.hint ?? "This action is currently unavailable.")
    : null;
  const gitActionProgress = resolveGitActionProgressPresentation(vcsActionState);
  const pendingDefaultBranchActionCopy = pendingDefaultBranchAction
    ? resolveDefaultBranchActionDialogCopy({
        action: pendingDefaultBranchAction.action,
        branchName: pendingDefaultBranchAction.branchName,
        includesCommit: pendingDefaultBranchAction.includesCommit,
        terminology: changeRequestTerminology,
      })
    : null;

  useEffect(() => {
    if (gitCwd === null) {
      return;
    }

    let refreshTimeout: number | null = null;
    const scheduleRefreshCurrentGitStatus = () => {
      if (refreshTimeout !== null) {
        window.clearTimeout(refreshTimeout);
      }
      refreshTimeout = window.setTimeout(() => {
        refreshTimeout = null;
        requestVcsStatusRefresh(refreshVcsStatus, activeEnvironmentId, gitCwd);
      }, GIT_STATUS_WINDOW_REFRESH_DEBOUNCE_MS);
    };
    const handleVisibilityChange = () => {
      if (document.visibilityState === "visible") {
        scheduleRefreshCurrentGitStatus();
      }
    };

    window.addEventListener("focus", scheduleRefreshCurrentGitStatus);
    document.addEventListener("visibilitychange", handleVisibilityChange);

    return () => {
      if (refreshTimeout !== null) {
        window.clearTimeout(refreshTimeout);
      }
      window.removeEventListener("focus", scheduleRefreshCurrentGitStatus);
      document.removeEventListener("visibilitychange", handleVisibilityChange);
    };
  }, [activeEnvironmentId, gitCwd, refreshVcsStatus]);

  const runGitActionWithToast = async ({
    action,
    commitMessage,
    onConfirmed,
    skipDefaultBranchPrompt = false,
    statusOverride,
    featureBranch = false,
    filePaths,
  }: RunGitActionWithToastInput) => {
    const actionStatus = statusOverride ?? gitStatusForActions;
    const actionBranch = actionStatus?.refName ?? null;
    const actionIsDefaultBranch = featureBranch ? false : isDefaultRef;
    const actionCanCommit =
      action === "commit" || action === "commit_push" || action === "commit_push_pr";
    const includesCommit =
      actionCanCommit &&
      (action === "commit" || !!actionStatus?.hasWorkingTreeChanges || featureBranch);
    if (
      !skipDefaultBranchPrompt &&
      requiresDefaultBranchConfirmation(action, actionIsDefaultBranch) &&
      actionBranch
    ) {
      if (
        action !== "push" &&
        action !== "create_pr" &&
        action !== "commit_push" &&
        action !== "commit_push_pr"
      ) {
        return;
      }
      setPendingDefaultBranchAction({
        action,
        branchName: actionBranch,
        includesCommit,
        ...(commitMessage ? { commitMessage } : {}),
        ...(onConfirmed ? { onConfirmed } : {}),
        ...(filePaths ? { filePaths } : {}),
      });
      return;
    }
    onConfirmed?.();
    setInlineSuccess(null);

    const scopedToastData = threadToastData ? { ...threadToastData } : undefined;
    const actionId = randomUUID();

    const result = await runImmediateGitAction.run({
      actionId,
      action,
      ...(commitMessage ? { commitMessage } : {}),
      ...(featureBranch ? { featureBranch } : {}),
      ...(filePaths ? { filePaths } : {}),
      // A pull request the action opens is linked to the thread it ran beside. Drafts
      // have no server thread yet, so there is nothing to link to.
      ...(activeServerThread ? { threadId: activeServerThread.id } : {}),
      ...(activeDraftThread ? { projectId: activeDraftThread.projectId } : {}),
    });

    if (result._tag === "Failure") {
      if (isAtomCommandInterrupted(result)) {
        return;
      }

      const error = squashAtomCommandFailure(result);
      const errorToastTiming = resolveGitActionResultToastTiming("error");
      toastManager.add(
        stackedThreadToast({
          type: "error",
          title: "Action failed",
          description: error instanceof Error ? error.message : "An error occurred.",
          timeout: errorToastTiming.timeout,
          ...(scopedToastData !== undefined ? { data: scopedToastData } : {}),
        }),
      );
      return;
    }

    const actionResult = result.value;
    syncThreadBranchAfterGitAction(actionResult);
    if (reportSuccessInline) {
      setInlineSuccess({
        title: actionResult.toast.title,
        description: actionResult.toast.description ?? null,
        scopeKey: successScopeKey,
      });
      return;
    }
    let resultToastId: GitActionToastId | null = null;
    const closeResultToast = () => {
      if (resultToastId !== null) {
        toastManager.close(resultToastId);
      }
    };

    const toastCta = actionResult.toast.cta;
    let toastActionProps: {
      children: string;
      onClick: (event: MouseEvent<HTMLButtonElement>) => void;
    } | null = null;
    if (toastCta.kind === "run_action") {
      toastActionProps = {
        children: toastCta.label,
        onClick: () => {
          closeResultToast();
          void latestGitAction.current?.({
            action: toastCta.action.kind,
          });
        },
      };
    } else if (toastCta.kind === "open_pr") {
      toastActionProps = {
        children: toastCta.label,
        onClick: (event) => {
          closeResultToast();
          openPrLink(event, toastCta.url);
        },
      };
    }

    const successToastTiming = resolveGitActionResultToastTiming("success");
    const successToastData = {
      ...scopedToastData,
      ...(successToastTiming.dismissAfterVisibleMs !== null
        ? { dismissAfterVisibleMs: successToastTiming.dismissAfterVisibleMs }
        : {}),
    };

    if (toastActionProps) {
      resultToastId = toastManager.add(
        stackedThreadToast({
          type: "success",
          title: actionResult.toast.title,
          description: actionResult.toast.description,
          timeout: successToastTiming.timeout,
          actionProps: toastActionProps,
          data: successToastData,
        }),
      );
    } else {
      resultToastId = toastManager.add({
        type: "success",
        title: actionResult.toast.title,
        description: actionResult.toast.description,
        timeout: successToastTiming.timeout,
        data: successToastData,
      });
    }
  };

  useLayoutEffect(() => {
    latestGitAction.current = runGitActionWithToast;
    return () => {
      latestGitAction.current = null;
    };
  });

  const continuePendingDefaultBranchAction = () => {
    if (!pendingDefaultBranchAction) return;
    const { action, commitMessage, onConfirmed, filePaths } = pendingDefaultBranchAction;
    setPendingDefaultBranchAction(null);
    void runGitActionWithToast({
      action,
      ...(commitMessage ? { commitMessage } : {}),
      ...(onConfirmed ? { onConfirmed } : {}),
      ...(filePaths ? { filePaths } : {}),
      skipDefaultBranchPrompt: true,
    });
  };

  const checkoutFeatureBranchAndContinuePendingAction = () => {
    if (!pendingDefaultBranchAction) return;
    const { action, commitMessage, onConfirmed, filePaths } = pendingDefaultBranchAction;
    setPendingDefaultBranchAction(null);
    void runGitActionWithToast({
      action,
      ...(commitMessage ? { commitMessage } : {}),
      ...(onConfirmed ? { onConfirmed } : {}),
      ...(filePaths ? { filePaths } : {}),
      featureBranch: true,
      skipDefaultBranchPrompt: true,
    });
  };

  const runQuickAction = () => {
    if (quickAction.kind === "open_publish") {
      onOpenPublish();
      return;
    }
    if (quickAction.kind === "run_pull") {
      void (async () => {
        setInlineSuccess(null);
        const result = await pullAction.run();
        if (result._tag === "Failure") {
          if (isAtomCommandInterrupted(result)) {
            return;
          }
          const error = squashAtomCommandFailure(result);
          const errorToastTiming = resolveGitActionResultToastTiming("error");
          toastManager.add(
            stackedThreadToast({
              type: "error",
              title: "Pull failed",
              description: error instanceof Error ? error.message : "An error occurred.",
              timeout: errorToastTiming.timeout,
              ...(threadToastData !== undefined ? { data: threadToastData } : {}),
            }),
          );
          return;
        }

        const pullResult = result.value;
        const title = pullResult.status === "pulled" ? "Pulled" : "Already up to date";
        const description =
          pullResult.status === "pulled"
            ? `Updated ${pullResult.refName} from ${pullResult.upstreamRef ?? "upstream"}`
            : `${pullResult.refName} is already synchronized.`;
        if (reportSuccessInline) {
          setInlineSuccess({ title, description, scopeKey: successScopeKey });
          return;
        }
        const successToastTiming = resolveGitActionResultToastTiming("success");
        toastManager.add({
          type: "success",
          title,
          description,
          timeout: successToastTiming.timeout,
          data: {
            ...threadToastData,
            ...(successToastTiming.dismissAfterVisibleMs !== null
              ? { dismissAfterVisibleMs: successToastTiming.dismissAfterVisibleMs }
              : {}),
          },
        });
      })();
      return;
    }
    if (quickAction.kind === "show_hint") {
      toastManager.add({
        type: "info",
        title: quickAction.label,
        description: quickAction.hint,
        data: threadToastData,
      });
      return;
    }
    if (quickAction.action) {
      void runGitActionWithToast({ action: quickAction.action });
    }
  };

  const runMenuItemAction = (item: GitActionMenuItem): "commit" | null => {
    if (item.disabled) return null;
    if (item.dialogAction === "push") {
      void runGitActionWithToast({ action: "push" });
      return null;
    }
    if (item.dialogAction === "create_pr") {
      void runGitActionWithToast({ action: "create_pr" });
      return null;
    }
    return "commit";
  };

  const dismissPendingDefaultBranchAction = useCallback(() => {
    setPendingDefaultBranchAction(null);
  }, []);

  return {
    activeEnvironmentId,
    threadToastData,
    openInPreferredEditor,
    gitStatusForActions,
    gitStatusError,
    refreshVcsStatus,
    sourceControlPresentation,
    changeRequestTerminology,
    SourceControlIcon,
    isRepo,
    hasPrimaryRemote,
    isDefaultRef,
    allFiles,
    initAction,
    initRepository,
    pullAction,
    isGitActionRunning,
    gitActionMenuItems,
    quickAction,
    quickActionDisabledReason,
    gitActionProgress,
    visibleInlineSuccess,
    pendingDefaultBranchAction,
    pendingDefaultBranchActionCopy,
    dismissPendingDefaultBranchAction,
    continuePendingDefaultBranchAction,
    checkoutFeatureBranchAndContinuePendingAction,
    runGitActionWithToast,
    runQuickAction,
    /** Runs the item, or returns "commit" when it needs the caller's commit dialog. */
    runMenuItemAction,
  };
}
