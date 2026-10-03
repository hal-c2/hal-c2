// The requests the feature areas (src/host/features) make, next to the
// client's core in connection.ts. Each is one RPC from packages/contracts.
import {
  TrimmedNonEmptyString,
  WS_METHODS,
  type PreviewSessionSnapshot,
  type ProjectId,
  type ProjectScript,
  type ProviderInstanceMutation,
  type ServerProcessDiagnosticsResult,
  type ServerProvider,
  type ServerProviderUpdateInput,
  type ServerSettings,
  type ServerSettingsPatch,
  type ServerTraceDiagnosticsResult,
  type GitPreparePullRequestThreadResult,
  type GitResolvePullRequestResult,
  type SourceControlPublishRepositoryInput,
  type SourceControlPublishRepositoryResult,
  type ThreadId,
  type VcsCreateWorktreeResult,
  type VcsStatusResult,
} from "@hal-c2/contracts";
import { deleteProject, updateProject } from "@hal-c2/client-runtime/operations";
import { request } from "@hal-c2/client-runtime/rpc";
import * as Effect from "effect/Effect";

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
  readonly getProcessDiagnostics: () => Promise<ServerProcessDiagnosticsResult>;
  readonly getTraceDiagnostics: () => Promise<ServerTraceDiagnosticsResult>;
  /** Rename a project or replace its scripts (`project.update`). */
  readonly updateProject: (
    projectId: ProjectId,
    change: { readonly title?: string; readonly scripts?: ReadonlyArray<ProjectScript> },
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
    getProcessDiagnostics: () =>
      runtime.runPromise(request(WS_METHODS.serverGetProcessDiagnostics, {})),
    getTraceDiagnostics: () =>
      runtime.runPromise(request(WS_METHODS.serverGetTraceDiagnostics, {})),
    updateProject: (projectId, change) =>
      runtime.runPromise(updateProject({ projectId, ...change }).pipe(Effect.asVoid)),
    deleteProject: (projectId) =>
      runtime.runPromise(deleteProject({ projectId }).pipe(Effect.asVoid)),
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
  };
}
