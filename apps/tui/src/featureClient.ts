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
  type ThreadId,
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
}

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
  };
}
