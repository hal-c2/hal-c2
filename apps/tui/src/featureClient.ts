// The requests the feature areas (src/host/features) make, next to the
// client's core in connection.ts. Each is one RPC from packages/contracts.
import {
  TrimmedNonEmptyString,
  WS_METHODS,
  type PreviewSessionSnapshot,
  type ProjectId,
  type ProjectScript,
  type ProviderInstanceMutation,
  type RelayClientInstallProgressStage,
  type RelayClientStatus,
  type ServerProvider,
  type ServerProviderUpdateInput,
  type ServerSettings,
  type ServerSettingsPatch,
  type GitPreparePullRequestThreadResult,
  type GitResolvePullRequestResult,
  type SourceControlPublishRepositoryInput,
  type SourceControlPublishRepositoryResult,
  type ThreadId,
  type VcsCreateWorktreeResult,
  type VcsStatusResult,
} from "@hal-c2/contracts";
import { deleteProject, updateProject } from "@hal-c2/client-runtime/operations";
import { request, runStream } from "@hal-c2/client-runtime/rpc";
import * as Effect from "effect/Effect";
import * as Stream from "effect/Stream";

import type { TuiRuntime } from "./connection.ts";

export interface TuiFeatureClient {
  /** Write a workspace file (`projects.writeFile`). */
  readonly writeFile: (cwd: string, relativePath: string, contents: string) => Promise<void>;
  /** Probe every provider again, models included (`server.refreshProviders`). */
  readonly refreshProviders: () => Promise<ReadonlyArray<ServerProvider>>;
  /** Run a provider's own updater (`server.updateProvider`); resolves when it finished. */
  readonly updateProvider: (
    input: ServerProviderUpdateInput,
  ) => Promise<ReadonlyArray<ServerProvider>>;
  /** Change server settings, optionally one provider instance with them (`server.updateSettings`). */
  readonly updateSettings: (
    patch: ServerSettingsPatch,
    providerInstanceMutation?: ProviderInstanceMutation,
  ) => Promise<ServerSettings>;
  /** Rename a project or replace its scripts (`project.update`). */
  readonly updateProject: (
    projectId: ProjectId,
    change: {
      readonly title?: string;
      readonly scripts?: ReadonlyArray<ProjectScript>;
      /** Where the project's new threads start; null follows the environment. */
      readonly defaultThreadEnvMode?: "local" | "worktree" | null;
    },
  ) => Promise<void>;
  /** Forget a project and its threads; its folder is not touched (`project.delete`). */
  readonly deleteProject: (projectId: ProjectId) => Promise<void>;
  /** The thread's open previews (`preview.list`). */
  readonly listPreviews: (threadId: ThreadId) => Promise<ReadonlyArray<PreviewSessionSnapshot>>;
  readonly openPreview: (threadId: ThreadId, url: string) => Promise<PreviewSessionSnapshot>;
  readonly refreshPreview: (threadId: ThreadId, tabId: string) => Promise<void>;
  readonly closePreview: (threadId: ThreadId, tabId: string) => Promise<void>;
  /** Read a checkout's status again now (`vcs.refreshStatus`). */
  readonly refreshVcsStatus: (cwd: string) => Promise<VcsStatusResult>;
  /** Create a branch and, by default, switch the checkout to it (`vcs.createRef`). */
  readonly createRef: (cwd: string, refName: string) => Promise<string>;
  /** A new worktree on a new branch off `baseRef`; the server picks its path (`vcs.createWorktree`). */
  readonly createWorktree: (
    cwd: string,
    baseRef: string,
    newRef: string,
  ) => Promise<VcsCreateWorktreeResult["worktree"]>;
  /** Remove a worktree's folder; its branch stays (`vcs.removeWorktree`). */
  readonly removeWorktree: (cwd: string, path: string) => Promise<void>;
  readonly initRepository: (cwd: string) => Promise<void>;
  /** A pull request from a URL, a `gh pr checkout` line or `#number` (`git.resolvePullRequest`). */
  readonly resolvePullRequest: (
    cwd: string,
    reference: string,
  ) => Promise<GitResolvePullRequestResult["pullRequest"]>;
  /** Check the pull request out here or in a worktree (`git.preparePullRequestThread`). */
  readonly preparePullRequest: (input: {
    readonly cwd: string;
    readonly reference: string;
    readonly mode: "local" | "worktree";
    readonly threadId?: ThreadId;
  }) => Promise<GitPreparePullRequestThreadResult>;
  /** Create the repository on a provider and make it the remote (`sourceControl.publishRepository`). */
  readonly publishRepository: (
    input: SourceControlPublishRepositoryInput,
  ) => Promise<SourceControlPublishRepositoryResult>;
  /**
   * The checkout's changes since `baseRef` as one unified diff, whitespace-only
   * changes left out on request (`review.getDiffPreview`, its branch-range source).
   */
  readonly reviewDiff: (cwd: string, baseRef: string, ignoreWhitespace: boolean) => Promise<string>;
  /** Whether the server has the relay client HAL-C2 Connect needs (`cloud.getRelayClientStatus`). */
  readonly relayStatus: () => Promise<RelayClientStatus>;
  /** Install it on the server, stage by stage; resolves with the status it ends in. */
  readonly installRelay: (
    onStage: (stage: RelayClientInstallProgressStage) => void,
  ) => Promise<RelayClientStatus | null>;
}

const text = (value: string) => TrimmedNonEmptyString.make(value);

export function makeFeatureClient(runtime: TuiRuntime): TuiFeatureClient {
  return {
    writeFile: (cwd, relativePath, contents) =>
      runtime.runPromise(
        request(WS_METHODS.projectsWriteFile, {
          cwd: TrimmedNonEmptyString.make(cwd),
          relativePath: TrimmedNonEmptyString.make(relativePath),
          contents,
        }).pipe(Effect.asVoid),
      ),
    refreshProviders: () =>
      runtime.runPromise(
        request(WS_METHODS.serverRefreshProviders, { refreshModels: true }).pipe(
          Effect.map((result) => result.providers),
        ),
      ),
    updateProvider: (input) =>
      runtime.runPromise(
        request(WS_METHODS.serverUpdateProvider, input).pipe(
          Effect.map((result) => result.providers),
        ),
      ),
    updateSettings: (patch, providerInstanceMutation) =>
      runtime.runPromise(
        request(WS_METHODS.serverUpdateSettings, {
          patch,
          ...(providerInstanceMutation ? { providerInstanceMutation } : {}),
        }),
      ),
    updateProject: (projectId, change) =>
      runtime.runPromise(updateProject({ projectId, ...change }).pipe(Effect.asVoid)),
    deleteProject: (projectId) =>
      // The MC only removes a project that still has threads when told to take them along.
      runtime.runPromise(deleteProject({ projectId, force: true }).pipe(Effect.asVoid)),
    listPreviews: (threadId) =>
      runtime.runPromise(
        request(WS_METHODS.previewList, { threadId }).pipe(Effect.map((result) => result.sessions)),
      ),
    openPreview: (threadId, url) =>
      runtime.runPromise(request(WS_METHODS.previewOpen, { threadId, url: url as never })),
    refreshPreview: (threadId, tabId) =>
      runtime.runPromise(
        request(WS_METHODS.previewRefresh, { threadId, tabId: tabId as never }).pipe(Effect.asVoid),
      ),
    closePreview: (threadId, tabId) =>
      runtime.runPromise(
        request(WS_METHODS.previewClose, { threadId, tabId: tabId as never }).pipe(Effect.asVoid),
      ),
    refreshVcsStatus: (cwd) =>
      runtime.runPromise(request(WS_METHODS.vcsRefreshStatus, { cwd: text(cwd) })),
    createRef: (cwd, refName) =>
      runtime.runPromise(
        request(WS_METHODS.vcsCreateRef, {
          cwd: text(cwd),
          refName: text(refName),
          switchRef: true,
        }).pipe(Effect.map((result) => result.refName as string)),
      ),
    createWorktree: (cwd, baseRef, newRef) =>
      runtime.runPromise(
        request(WS_METHODS.vcsCreateWorktree, {
          cwd: text(cwd),
          refName: text(baseRef),
          newRefName: text(newRef),
          path: null,
        }).pipe(Effect.map((result) => result.worktree)),
      ),
    removeWorktree: (cwd, path) =>
      runtime.runPromise(
        request(WS_METHODS.vcsRemoveWorktree, { cwd: text(cwd), path: text(path) }).pipe(
          Effect.asVoid,
        ),
      ),
    initRepository: (cwd) =>
      runtime.runPromise(request(WS_METHODS.vcsInit, { cwd: text(cwd) }).pipe(Effect.asVoid)),
    resolvePullRequest: (cwd, reference) =>
      runtime.runPromise(
        request(WS_METHODS.gitResolvePullRequest, {
          cwd: text(cwd),
          reference: text(reference),
        }).pipe(Effect.map((result) => result.pullRequest)),
      ),
    preparePullRequest: (input) =>
      runtime.runPromise(
        request(WS_METHODS.gitPreparePullRequestThread, {
          cwd: text(input.cwd),
          reference: text(input.reference),
          mode: input.mode,
          ...(input.threadId ? { threadId: input.threadId } : {}),
        }),
      ),
    publishRepository: (input) =>
      runtime.runPromise(request(WS_METHODS.sourceControlPublishRepository, input)),
    relayStatus: () => runtime.runPromise(request(WS_METHODS.cloudGetRelayClientStatus, {})),
    installRelay: (onStage) => {
      let status: RelayClientStatus | null = null;
      return runtime.runPromise(
        runStream(WS_METHODS.cloudInstallRelayClient, {}).pipe(
          Stream.runForEach((event) =>
            Effect.sync(() => {
              if (event.type === "progress") onStage(event.stage);
              else status = event.status;
            }),
          ),
          Effect.map(() => status),
        ),
      );
    },
    reviewDiff: (cwd, baseRef, ignoreWhitespace) =>
      runtime.runPromise(
        request(WS_METHODS.reviewGetDiffPreview, {
          cwd: text(cwd),
          baseRef: text(baseRef),
          ignoreWhitespace,
        }).pipe(
          Effect.map(
            (result) =>
              (result.sources.find((source) => source.kind === "branch-range") ?? result.sources[0])
                ?.diff ?? "",
          ),
        ),
      ),
  };
}
