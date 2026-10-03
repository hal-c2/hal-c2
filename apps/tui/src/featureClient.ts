// The requests the feature areas (src/host/features) make, next to the
// client's core in connection.ts. Each is one RPC from packages/contracts.
import {
  TrimmedNonEmptyString,
  WS_METHODS,
  type ProviderInstanceMutation,
  type ServerProcessDiagnosticsResult,
  type ServerProvider,
  type ServerProviderUpdateInput,
  type ServerSettings,
  type ServerSettingsPatch,
  type ServerTraceDiagnosticsResult,
} from "@hal-c2/contracts";
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
  };
}
