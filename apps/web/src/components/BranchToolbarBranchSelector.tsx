import { ThreadDetailsControl } from "./chat/ThreadDetailsControl";
import { ComposerContextLabel } from "./ComposerContextLabel";
import { useSupportsMultiplePullRequests } from "~/hooks/useSupportsMultiplePullRequests";
import { resolveThreadCurrentPullRequestLink } from "@t3tools/shared/threadPullRequests";
import { useRightPanelStore } from "../rightPanelStore";
import type { ContextMenuItem, EnvironmentId, VcsRef, ThreadId } from "@t3tools/contracts";
import { ChevronDownIcon, GitBranchIcon } from "lucide-react";
import {
  useCallback,
  useEffect,
  useImperativeHandle,
  useMemo,
  useState,
  type MouseEvent as ReactMouseEvent,
  type Ref,
} from "react";

import { type DraftId } from "../composerDraftStore";
import { useThreadBranchSelection } from "../hooks/useThreadBranchSelection";
import { writeTextToClipboard } from "../hooks/useCopyToClipboard";
import { readLocalApi } from "../localApi";
import { useOpenPrLink } from "../lib/openPullRequestLink";
import { useEnvironmentQuery } from "../state/query";
import { vcsEnvironment } from "../state/vcs";
import { cn } from "../lib/utils";
import {
  THREAD_DETAILS_PANEL_CHEVRON_CLASS,
  THREAD_DETAILS_PANEL_ICON_CLASS,
  THREAD_DETAILS_PANEL_ROW_POPUP_CLASS,
} from "./chat/threadDetailsPanelStyles";
import { ThreadDetailsPrRows } from "./chat/ThreadDetailsPrRows";
import { parsePullRequestReference } from "../pullRequestReference";
import { getSourceControlPresentation } from "../sourceControlPresentation";
import { useComposerMenuProps } from "./chat/composerEventScope";
import {
  resolveBranchTriggerLabel,
  resolveBranchToolbarPrBranch,
  sanitizeNewRefName,
  shouldIncludeBranchPickerItem,
} from "./BranchToolbar.logic";
import {
  ThreadPullRequestBadgeControl,
  prStatusIndicator,
  resolveThreadPullRequestBadge,
  useLinkedThreadPullRequest,
} from "./ThreadStatusIndicators";

import { ComboboxItem, ComboboxTrigger } from "./ui/combobox";
import { ComposerControl } from "./chat/ComposerControl";
import { MiddleTruncate } from "./ui/middle-truncate";
import { BranchPicker, BranchPickerRefItem } from "./BranchPicker";
import { stackedThreadToast, toastManager } from "./ui/toast";

export interface BranchToolbarBranchSelectorHandle {
  open: () => void;
}

interface BranchToolbarBranchSelectorProps {
  forceNewWorktree?: boolean;
  ref?: Ref<BranchToolbarBranchSelectorHandle>;
  className?: string;
  displayMode?: "toolbar" | "panel";
  environmentId: EnvironmentId;
  threadId: ThreadId;
  draftId?: DraftId;
  envLocked: boolean;
  effectiveEnvModeOverride?: "local" | "worktree";
  activeThreadBranchOverride?: string | null;
  onActiveThreadBranchOverrideChange?: (refName: string | null) => void;
  startFromOrigin: boolean;
  onStartFromOriginChange: (startFromOrigin: boolean) => void;
  onCheckoutPullRequestRequest?: (reference: string) => void;
  onComposerFocusRequest?: () => void;
}

function toBranchActionErrorMessage(error: unknown): string {
  return error instanceof Error ? error.message : "An error occurred.";
}

export function BranchToolbarBranchSelector({
  forceNewWorktree = false,
  ref,
  className,
  displayMode = "toolbar",
  environmentId,
  threadId,
  draftId,
  envLocked,
  effectiveEnvModeOverride,
  activeThreadBranchOverride,
  onActiveThreadBranchOverrideChange,
  startFromOrigin,
  onStartFromOriginChange,
  onCheckoutPullRequestRequest,
  onComposerFocusRequest,
}: BranchToolbarBranchSelectorProps) {
  const composerFloatingLayerProps = useComposerMenuProps();
  const [isBranchMenuOpen, setIsBranchMenuOpen] = useState(false);
  const [branchQuery, setBranchQuery] = useState("");
  const {
    threadRef,
    serverThread,
    activeProject,
    activeProjectCwd,
    activeThreadBranch,
    activeWorktreePath,
    branchCwd,
    effectiveEnvMode,
    isSelectingWorktreeBase,
    branchStatusQuery,
    trimmedBranchQuery,
    deferredTrimmedBranchQuery,
    branchRefState,
    refs,
    hasNextPage,
    isFetchingNextPage,
    isInitialBranchesLoadPending,
    resolvedActiveBranch,
    branchByName,
    branchNames,
    isBranchActionPending,
    selectBranch: selectBranchRef,
    createRef: createRefNamed,
  } = useThreadBranchSelection({
    forceNewWorktree,
    environmentId,
    threadId,
    draftId,
    envLocked,
    effectiveEnvModeOverride,
    activeThreadBranchOverride,
    onActiveThreadBranchOverrideChange,
    branchQuery,
  });
  const sourceControlPresentation = useMemo(
    () => getSourceControlPresentation(branchStatusQuery.data?.sourceControlProvider),
    [branchStatusQuery.data?.sourceControlProvider],
  );
  const SourceControlIcon = sourceControlPresentation.Icon;
  const normalizedDeferredBranchQuery = deferredTrimmedBranchQuery.toLowerCase();
  const prReference = parsePullRequestReference(trimmedBranchQuery);
  const checkoutPullRequestItemValue =
    prReference && onCheckoutPullRequestRequest ? `__checkout_pull_request__:${prReference}` : null;
  const canCreateBranch = !isSelectingWorktreeBase && trimmedBranchQuery.length > 0;
  const newRefName = sanitizeNewRefName(trimmedBranchQuery);
  const hasExactBranchMatch = branchByName.has(newRefName);
  const createBranchItemValue = canCreateBranch
    ? `__create_new_branch__:${trimmedBranchQuery}`
    : null;
  const branchPickerItems = useMemo(() => {
    const items = [...branchNames];
    if (createBranchItemValue && !hasExactBranchMatch) {
      items.push(createBranchItemValue);
    }
    if (checkoutPullRequestItemValue) {
      items.unshift(checkoutPullRequestItemValue);
    }
    return items;
  }, [branchNames, checkoutPullRequestItemValue, createBranchItemValue, hasExactBranchMatch]);
  const filteredBranchPickerItems = useMemo(
    () =>
      normalizedDeferredBranchQuery.length === 0
        ? branchPickerItems
        : branchPickerItems.filter((itemValue) =>
            shouldIncludeBranchPickerItem({
              itemValue,
              normalizedQuery: normalizedDeferredBranchQuery,
              createBranchItemValue,
              checkoutPullRequestItemValue,
            }),
          ),
    [
      branchPickerItems,
      checkoutPullRequestItemValue,
      createBranchItemValue,
      normalizedDeferredBranchQuery,
    ],
  );
  const listedActiveBranch =
    resolvedActiveBranch === null ? null : (branchByName.get(resolvedActiveBranch) ?? null);
  const activeBranchRefQuery = useEnvironmentQuery(
    branchCwd !== null && resolvedActiveBranch !== null
      ? vcsEnvironment.listRefs({
          environmentId,
          input: {
            cwd: branchCwd,
            query: resolvedActiveBranch,
            limit: 10,
          },
        })
      : null,
  );
  const queriedActiveBranch = activeBranchRefQuery.data?.refs.find(
    (refName) => refName.name === resolvedActiveBranch,
  );
  const resolvedActiveBranchIsRemote =
    listedActiveBranch !== null
      ? listedActiveBranch.isRemote === true
      : queriedActiveBranch
        ? queriedActiveBranch.isRemote === true
        : null;
  const totalBranchCount = branchRefState.data?.totalCount ?? 0;
  const branchStatusText = isInitialBranchesLoadPending
    ? "Loading refs..."
    : isFetchingNextPage
      ? "Loading more refs..."
      : hasNextPage
        ? `Showing ${refs.length} of ${totalBranchCount} refs`
        : null;

  const copyBranchName = useCallback((branchName: string) => {
    void writeTextToClipboard(branchName, "branch name").then(
      (didCopy) => {
        if (!didCopy) return;
        toastManager.add({
          type: "success",
          title: "Branch name copied",
          description: branchName,
        });
      },
      (error: unknown) => {
        toastManager.add(
          stackedThreadToast({
            type: "error",
            title: "Failed to copy branch name",
            description: toBranchActionErrorMessage(error),
          }),
        );
      },
    );
  }, []);

  const handleBranchContextMenu = useCallback(
    (event: ReactMouseEvent, branchName: string | null) => {
      if (!branchName) return;
      const api = readLocalApi();
      if (!api) return;
      event.preventDefault();
      event.stopPropagation();
      const items: ContextMenuItem<"copy-branch-name">[] = [
        { id: "copy-branch-name", label: "Copy branch name", icon: "copy" },
      ];
      void api.contextMenu.show(items, { x: event.clientX, y: event.clientY }).then((action) => {
        if (action === "copy-branch-name") copyBranchName(branchName);
      });
    },
    [copyBranchName],
  );

  const selectBranch = (refName: VcsRef) => {
    if (!selectBranchRef(refName)) return;
    setIsBranchMenuOpen(false);
    onComposerFocusRequest?.();
  };

  const createRef = (rawName: string) => {
    if (!createRefNamed(rawName)) return;
    setIsBranchMenuOpen(false);
    onComposerFocusRequest?.();
  };

  const handleOpenChange = useCallback((open: boolean) => {
    setIsBranchMenuOpen(open);
    if (!open) {
      setBranchQuery("");
    }
  }, []);

  useImperativeHandle(
    ref,
    () => ({
      open: () => {
        if (isInitialBranchesLoadPending || isBranchActionPending) return;
        handleOpenChange(true);
      },
    }),
    [handleOpenChange, isBranchActionPending, isInitialBranchesLoadPending],
  );

  const triggerLabel = resolveBranchTriggerLabel({
    activeWorktreePath,
    effectiveEnvMode,
    resolvedActiveBranch,
    resolvedActiveBranchIsRemote,
    startFromOrigin,
  });

  // Branch status is the fallback when this thread has no linked pull requests.
  const branchPrBranch = resolveBranchToolbarPrBranch({
    activeThreadBranch,
    resolvedActiveBranch,
  });
  const branchPr =
    branchPrBranch !== null && branchStatusQuery.data?.refName === branchPrBranch
      ? (branchStatusQuery.data.pr ?? null)
      : null;
  const supportsMultiplePullRequests = useSupportsMultiplePullRequests(environmentId);
  const linkedStatus = useLinkedThreadPullRequest(
    environmentId,
    serverThread?.linkedPullRequest,
    true,
    serverThread?.pullRequests,
    serverThread?.branchPullRequest,
  );
  const currentLinkedPr = supportsMultiplePullRequests
    ? resolveThreadCurrentPullRequestLink(serverThread?.pullRequests ?? [])
    : null;
  const prBadge = supportsMultiplePullRequests
    ? resolveThreadPullRequestBadge(serverThread?.pullRequests)
    : null;
  const displayedPr = linkedStatus?.pr ?? (currentLinkedPr === null ? branchPr : null);
  const displayedPrStatus = prStatusIndicator(
    displayedPr,
    linkedStatus?.sourceControlProvider ?? branchStatusQuery.data?.sourceControlProvider,
  );
  const prNumber = currentLinkedPr?.number ?? displayedPr?.number;
  const prUrl = currentLinkedPr?.url ?? displayedPr?.url;
  const openPrLink = useOpenPrLink(threadRef);
  const panelPrLabel =
    prNumber === undefined
      ? ""
      : `#${prNumber}${displayedPr?.title.trim() ? `: ${displayedPr.title}` : ""}`;

  function selectPickerItem(itemValue: string) {
    if (itemValue === checkoutPullRequestItemValue && prReference && onCheckoutPullRequestRequest) {
      handleOpenChange(false);
      onComposerFocusRequest?.();
      onCheckoutPullRequestRequest(prReference);
    } else if (itemValue === createBranchItemValue) {
      createRef(trimmedBranchQuery);
    } else {
      const refName = branchByName.get(itemValue);
      if (refName) selectBranch(refName);
    }
  }

  function renderPickerItem(itemValue: string, index: number) {
    if (checkoutPullRequestItemValue && itemValue === checkoutPullRequestItemValue) {
      return (
        <ComboboxItem
          hideIndicator
          key={itemValue}
          index={index}
          value={itemValue}
          onClick={() => selectPickerItem(itemValue)}
        >
          <div className="flex min-w-0 items-center gap-2 py-1">
            <SourceControlIcon className="size-3.5 shrink-0 text-muted-foreground" />
            <span className="flex min-w-0 flex-col items-start">
              <span className="truncate font-medium">
                Checkout {sourceControlPresentation.terminology.singular}
              </span>
              <span className="truncate text-muted-foreground text-xs">{prReference}</span>
            </span>
          </div>
        </ComboboxItem>
      );
    }
    if (createBranchItemValue && itemValue === createBranchItemValue) {
      return (
        <ComboboxItem
          hideIndicator
          key={itemValue}
          index={index}
          value={itemValue}
          onClick={() => selectPickerItem(itemValue)}
        >
          <span className="truncate">Create new ref &quot;{newRefName}&quot;</span>
        </ComboboxItem>
      );
    }

    const refName = branchByName.get(itemValue);
    if (!refName) return null;

    return (
      <BranchPickerRefItem
        branch={refName}
        projectCwd={activeProjectCwd}
        index={index}
        value={itemValue}
        onClick={() => selectPickerItem(itemValue)}
        onContextMenu={(event) => handleBranchContextMenu(event, itemValue)}
      />
    );
  }

  return (
    <BranchPicker
      items={branchPickerItems}
      filteredItems={filteredBranchPickerItems}
      open={isBranchMenuOpen}
      onOpenChange={handleOpenChange}
      onSelectItem={selectPickerItem}
      value={resolvedActiveBranch}
      query={branchQuery}
      resultsQuery={deferredTrimmedBranchQuery}
      onQueryChange={setBranchQuery}
      hasNextPage={hasNextPage}
      isFetchingNextPage={isFetchingNextPage}
      onLoadNext={branchRefState.loadNext}
      statusText={branchStatusText}
      renderItem={renderPickerItem}
      getItemType={(item) =>
        item === checkoutPullRequestItemValue
          ? "checkout-pull-request"
          : item === createBranchItemValue
            ? "create-branch"
            : "branch"
      }
      originControl={
        isSelectingWorktreeBase
          ? { checked: startFromOrigin, onCheckedChange: onStartFromOriginChange }
          : undefined
      }
      popupProps={{
        align: displayMode === "panel" ? "start" : "end",
        side: displayMode === "panel" ? "bottom" : "top",
        className: cn(
          "flex flex-col",
          displayMode === "panel" ? THREAD_DETAILS_PANEL_ROW_POPUP_CLASS : "w-80",
        ),
        ...(displayMode === "toolbar" ? composerFloatingLayerProps : {}),
      }}
    >
      <div
        className={cn(
          "flex min-w-0",
          displayMode === "panel" ? "w-full flex-col items-stretch" : "items-center gap-1",
          className,
        )}
      >
        {displayMode !== "panel" ? (
          <ThreadPullRequestBadgeControl
            render={<ComposerControl size="xs" />}
            badge={prBadge}
            pullRequests={serverThread?.pullRequests ?? []}
            number={prNumber}
            url={prUrl}
            status={displayedPrStatus}
            onOpenStack={() => useRightPanelStore.getState().open(threadRef, "pull-requests")}
            onOpenPullRequest={(event, targetUrl = prUrl) => {
              if (targetUrl) openPrLink(event, targetUrl);
            }}
          />
        ) : null}
        <span
          className="flex min-w-0"
          onContextMenu={(event) => handleBranchContextMenu(event, resolvedActiveBranch)}
        >
          <ComboboxTrigger
            render={
              displayMode === "panel" ? (
                <ThreadDetailsControl part="select" />
              ) : (
                <ComposerControl size="xs" />
              )
            }
            className="min-w-0 max-w-full active:scale-100"
            disabled={isInitialBranchesLoadPending || isBranchActionPending}
          >
            <GitBranchIcon
              className={cn(
                "size-3 shrink-0 opacity-70",
                displayMode === "panel" && THREAD_DETAILS_PANEL_ICON_CLASS,
              )}
            />
            <ComposerContextLabel displayMode={displayMode}>
              <MiddleTruncate value={triggerLabel} className="w-full" />
            </ComposerContextLabel>
            {displayMode === "panel" ? (
              <span data-slot="select-icon">
                <ChevronDownIcon className={THREAD_DETAILS_PANEL_CHEVRON_CLASS} />
              </span>
            ) : (
              <ChevronDownIcon className="size-3 shrink-0 opacity-50" />
            )}
          </ComboboxTrigger>
        </span>
        {displayMode === "panel" && prNumber !== undefined && prUrl !== undefined ? (
          <ThreadDetailsPrRows
            links={serverThread?.pullRequests ?? []}
            currentLink={currentLinkedPr}
            onOpenLink={openPrLink}
            environmentId={environmentId}
            pr={displayedPr}
            number={prNumber}
            reference={currentLinkedPr}
            status={displayedPrStatus}
            project={activeProject}
            label={panelPrLabel}
            openAriaLabel={prUrl ?? "Open pull request"}
            onOpen={(event) => openPrLink(event, prUrl)}
            onActed={() => branchStatusQuery.refresh()}
          />
        ) : null}
      </div>
    </BranchPicker>
  );
}
