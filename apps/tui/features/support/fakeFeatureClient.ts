// The fake's side of src/featureClient.ts: an in-memory answer for each
// request the feature areas make. Scenarios shape it through `ctx.fake.server`
// (or swap one method with `ctx.fake.override`).
import {
  DEFAULT_SERVER_SETTINGS,
  type ProviderInstanceMutation,
  type ServerProcessDiagnosticsResult,
  type ServerProvider,
  type ServerSettings,
  type ServerTraceDiagnosticsResult,
} from "@hal-c2/contracts";

import type { TuiFeatureClient } from "../../src/featureClient.ts";

/** What the fake MC holds for the feature areas. */
export interface FakeServer {
  /** Files written through `writeFile`, by `cwd:relativePath`. */
  readonly written: Map<string, string>;
  /** Every configured provider, as `refreshProviders` and the config report them. */
  providers: ServerProvider[];
  /** What a refresh finds: replaces `providers` when the next refresh runs. */
  afterRefresh: ServerProvider[] | null;
  /** How an update ends: the providers it leaves, or the reason it fails. */
  update: { providers: ServerProvider[] } | { error: string } | null;
  settings: ServerSettings;
  /** The instance mutations `updateSettings` carried, in order. */
  readonly instanceMutations: ProviderInstanceMutation[];
  processDiagnostics: ServerProcessDiagnosticsResult | null;
  traceDiagnostics: ServerTraceDiagnosticsResult | null;
}

export function fakeFeatureClient(): { client: TuiFeatureClient; server: FakeServer } {
  const server: FakeServer = {
    written: new Map(),
    providers: [],
    afterRefresh: null,
    update: null,
    settings: DEFAULT_SERVER_SETTINGS,
    instanceMutations: [],
    processDiagnostics: null,
    traceDiagnostics: null,
  };
  const client: TuiFeatureClient = {
    writeFile: async (cwd, relativePath, contents) => {
      server.written.set(`${cwd}:${relativePath}`, contents);
    },
    refreshProviders: async () => {
      if (server.afterRefresh) server.providers = server.afterRefresh;
      server.afterRefresh = null;
      return server.providers;
    },
    updateProvider: async () => {
      if (!server.update) throw new Error("nothing to update");
      if ("error" in server.update) throw new Error(server.update.error);
      server.providers = server.update.providers;
      return server.providers;
    },
    updateSettings: async (patch, mutation) => {
      let providerInstances = server.settings.providerInstances;
      if (mutation) {
        server.instanceMutations.push(mutation);
        const { [mutation.instanceId]: _removed, ...rest } = providerInstances;
        providerInstances =
          mutation.operation === "remove"
            ? (rest as typeof providerInstances)
            : { ...providerInstances, [mutation.instanceId]: mutation.instance };
      }
      server.settings = { ...server.settings, ...patch, providerInstances } as ServerSettings;
      return server.settings;
    },
    getProcessDiagnostics: async () => {
      if (!server.processDiagnostics) throw new Error("no process diagnostics");
      return server.processDiagnostics;
    },
    getTraceDiagnostics: async () => {
      if (!server.traceDiagnostics) throw new Error("no trace diagnostics");
      return server.traceDiagnostics;
    },
  };
  return { client, server };
}
