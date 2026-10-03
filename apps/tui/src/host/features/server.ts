import {
  ProviderDriverKind,
  ProviderInstanceId,
  type ServerConfig,
  type ServerProcessDiagnosticsResult,
  type ServerProvider,
  type ServerTraceDiagnosticsResult,
} from "@hal-c2/contracts";
import * as Option from "effect/Option";

import type { TuiSettingsExtraGroup } from "../settingsState.ts";
import { errorText, payloadField, type Feature, type FeatureKit } from "./kit.ts";

// The variable each built-in driver reads its API key from; another driver is asked for the name.
const API_KEY_VARIABLE: Record<string, string> = {
  codex: "OPENAI_API_KEY",
  claude: "ANTHROPIC_API_KEY",
  claudeAgent: "ANTHROPIC_API_KEY",
};

const providerName = (provider: ServerProvider) =>
  provider.displayName ?? provider.driver ?? provider.instanceId;

/** "ready · signed in · 1.4.2 (1.5.0 available)" for one provider. */
function providerSummary(provider: ServerProvider): string {
  const parts: string[] = [provider.enabled === false ? "disabled" : provider.status];
  if (provider.auth?.status === "authenticated") parts.push("signed in");
  if (provider.auth?.status === "unauthenticated") parts.push("signed out");
  if (!provider.installed) parts.push("not installed");
  const advisory = provider.versionAdvisory;
  if (provider.version) {
    parts.push(
      advisory?.status === "behind_latest" && advisory.latestVersion
        ? `${provider.version} (${advisory.latestVersion} available)`
        : provider.version,
    );
  }
  parts.push(`${provider.models.length} model${provider.models.length === 1 ? "" : "s"}`);
  return parts.join(" · ");
}

const updatable = (provider: ServerProvider) =>
  provider.versionAdvisory?.status === "behind_latest" &&
  provider.versionAdvisory.canUpdate &&
  provider.versionAdvisory.latestVersion !== null;

/**
 * The server from the terminal: its providers (refresh, update, add an
 * instance with its key), the defaults new threads start with, and its
 * diagnostics. Everything lists in settings; changes run from the palette.
 */
export function createServerFeature(kit: FeatureKit): Feature {
  const { client } = kit;
  let config: ServerConfig | null = null;
  let diagnostics: {
    readonly process: ServerProcessDiagnosticsResult | null;
    readonly trace: ServerTraceDiagnosticsResult | null;
    readonly error: string | null;
  } | null = null;

  const changed = () => {
    kit.settingsChanged();
    kit.commandsChanged();
  };
  /** Read the config again; the composer follows (models, the provider notice, defaults). */
  const load = (reloadComposer = true) =>
    kit.track(
      client.getServerConfig().then(
        (next) => {
          config = next;
          if (reloadComposer) kit.dispatch("composer.providers.reload");
          changed();
        },
        () => {},
      ),
    );
  const providers = () => config?.providers ?? [];

  const refresh = () => {
    kit.status("Refreshing providers…", "busy");
    void kit.track(
      client.refreshProviders().then(
        async (found) => {
          await load();
          const signedOut = found.filter(
            (provider) => provider.auth?.status === "unauthenticated",
          ).length;
          kit.status(
            `${found.length} provider${found.length === 1 ? "" : "s"} refreshed${signedOut > 0 ? ` · ${signedOut} signed out` : ""}.`,
            "success",
          );
        },
        (error: unknown) => kit.status(`Refresh failed: ${errorText(error)}`, "error"),
      ),
    );
  };

  const update = (instanceId: string) => {
    const provider = providers().find((candidate) => candidate.instanceId === instanceId);
    const latest = provider?.versionAdvisory?.latestVersion;
    if (!provider || !latest) return;
    const name = providerName(provider);
    kit.status(`Updating ${name} to ${latest}…`, "busy");
    void kit.track(
      client
        .updateProvider({
          provider: provider.driver,
          instanceId: provider.instanceId,
          targetVersion: latest,
        })
        .then(
          async (after) => {
            await load();
            const updated = after.find((candidate) => candidate.instanceId === instanceId);
            const state = updated?.updateState;
            if (state?.status === "failed") {
              kit.status(
                `${name} update failed: ${state.message ?? "see the server log"}`,
                "error",
              );
            } else {
              kit.status(
                `${name} updated to ${updated?.version ?? latest}${state?.message ? `: ${state.message}` : "."}`,
                "success",
              );
            }
          },
          (error: unknown) => kit.status(`${name} update failed: ${errorText(error)}`, "error"),
        ),
    );
  };

  const chooseDefaultWorkspace = () => {
    const current = config?.settings.defaultThreadEnvMode === "worktree" ? "worktree" : "local";
    kit.menu({
      title: "new threads start in",
      options: [
        {
          label: "Current checkout",
          description: "Work in the project's checkout.",
          value: "local",
        },
        {
          label: "New worktree",
          description: "Give each thread its own worktree.",
          value: "worktree",
        },
      ],
      index: current === "worktree" ? 1 : 0,
      onChoose: (mode) => {
        void kit.track(
          client.updateSettings({ defaultThreadEnvMode: mode as "local" | "worktree" }).then(
            async () => {
              await load();
              kit.status(
                `New threads start in ${mode === "worktree" ? "a new worktree" : "the current checkout"}.`,
                "success",
              );
            },
            (error: unknown) => kit.status(`Could not save: ${errorText(error)}`, "error"),
          ),
        );
      },
    });
  };

  /** Driver, then a name, then the key: three short questions, one request. */
  const addInstance = () => {
    const drivers = [...new Set(providers().map((provider) => provider.driver as string))];
    if (drivers.length === 0) {
      kit.status("The server reports no provider drivers.", "error");
      return;
    }
    kit.menu({
      title: "provider",
      options: drivers.map((driver) => ({
        label: driver,
        description: `Add another ${driver} instance.`,
        value: driver,
      })),
      onChoose: (driver) =>
        kit.ask({
          label: "instance name",
          placeholder: `Like "${driver} work"`,
          onSubmit: (name) => {
            if (name === "") {
              kit.status("An instance needs a name.", "error");
              return;
            }
            const variable = API_KEY_VARIABLE[driver] ?? `${driver.toUpperCase()}_API_KEY`;
            kit.ask({
              label: variable,
              placeholder: "The API key (stored as a secret on the server)",
              onSubmit: (key) => createInstance(driver, name, variable, key),
            });
          },
        }),
    });
  };
  const createInstance = (driver: string, name: string, variable: string, key: string) => {
    if (key === "") {
      kit.status("No key given; nothing was added.", "error");
      return;
    }
    const slug = name
      .toLowerCase()
      .replace(/[^a-z0-9]+/g, "-")
      .replace(/^-|-$/g, "");
    void kit.track(
      client
        .updateSettings(
          {},
          {
            operation: "create",
            instanceId: ProviderInstanceId.make(`${driver}-${slug || "instance"}`),
            instance: {
              driver: ProviderDriverKind.make(driver),
              displayName: name as never,
              environment: [{ name: variable as never, value: key, sensitive: true }],
              enabled: true,
            },
          },
        )
        .then(
          async () => {
            await load();
            kit.status(`Added ${name}; its key is stored as a secret.`, "success");
          },
          (error: unknown) => kit.status(`Could not add ${name}: ${errorText(error)}`, "error"),
        ),
    );
  };

  const openDiagnostics = () => {
    kit.status("Reading diagnostics…", "busy");
    void kit.track(
      Promise.allSettled([
        client.getProcessDiagnostics(),
        client.getTraceDiagnostics(),
        load(),
      ]).then(([process, trace]) => {
        diagnostics = {
          process: process.status === "fulfilled" ? process.value : null,
          trace: trace.status === "fulfilled" ? trace.value : null,
          error:
            process.status === "rejected" && trace.status === "rejected"
              ? errorText(process.reason)
              : null,
        };
        changed();
        kit.status(
          diagnostics.error ? `Diagnostics failed: ${diagnostics.error}` : "Diagnostics read.",
          diagnostics.error ? "error" : "success",
        );
        kit.dispatch("settings.open");
      }),
    );
  };

  const diagnosticsGroup = (): TuiSettingsExtraGroup[] => {
    if (!diagnostics) return [];
    const { process, trace } = diagnostics;
    const server = process?.processes.find((entry) => entry.pid === process.serverPid);
    const failures = trace?.latestFailures ?? [];
    const logs = trace?.latestWarningAndErrorLogs ?? [];
    const processError = process ? Option.getOrNull(process.error) : null;
    return [
      {
        title: "Diagnostics",
        rows: [
          ["version", config?.environment?.serverVersion ?? "—"],
          ["uptime", server?.elapsed ?? "—"],
          [
            "processes",
            process
              ? `${process.processCount} · ${Math.round(process.totalRssBytes / (1024 * 1024))} MB`
              : "—",
          ],
          ...(processError ? [["process error", processError.message] as const] : []),
          [
            "recent errors",
            failures.length + logs.length === 0 ? "none" : `${failures.length + logs.length}`,
          ],
          ...failures.map((failure) => [failure.name as string, failure.cause as string] as const),
          ...logs.map((log) => [`${log.level} ${log.spanName}`, log.message as string] as const),
        ],
      },
    ];
  };

  const settingsGroups = (): TuiSettingsExtraGroup[] => {
    if (!config) return diagnosticsGroup();
    const instances = config.settings.providerInstances ?? {};
    const rows: Array<readonly [string, string]> = providers().map(
      (provider) => [providerName(provider), providerSummary(provider)] as const,
    );
    for (const [id, instance] of Object.entries(instances)) {
      if (!providers().some((provider) => provider.instanceId === id)) {
        rows.push([instance.displayName ?? id, `${instance.driver} · not started yet`]);
      }
      for (const variable of instance.environment ?? []) {
        // A secret never comes back from the server and is never shown.
        rows.push([
          `  ${variable.name}`,
          variable.sensitive ? "•••••••• (secret)" : variable.value,
        ]);
      }
    }
    return [
      ...(rows.length > 0 ? [{ title: "Provider instances", rows }] : []),
      {
        title: "Defaults",
        rows: [
          [
            "new threads",
            config.settings.defaultThreadEnvMode === "worktree"
              ? "New worktree"
              : "Current checkout",
          ],
        ],
      },
      ...diagnosticsGroup(),
    ];
  };

  // The composer reads the config itself at start.
  void load(false);
  return {
    settingsGroups,
    commands: () => [
      {
        id: "providers.refresh",
        title: "Refresh providers",
        keywords: "models sign in status reload",
        action: "providers.refresh",
      },
      ...providers()
        .filter(updatable)
        .map((provider) => ({
          id: `providers.update.${provider.instanceId}`,
          title: `Update ${providerName(provider)} to ${provider.versionAdvisory!.latestVersion}`,
          keywords: "upgrade provider version",
          action: "providers.update",
          payload: { instanceId: provider.instanceId },
        })),
      {
        id: "providers.add",
        title: "Add a provider instance…",
        keywords: "api key secret account",
        action: "providers.add",
      },
      {
        id: "settings.defaultWorkspace",
        title: "Default workspace for new threads…",
        keywords: "settings worktree checkout defaults",
        action: "settings.defaultWorkspace",
      },
      {
        id: "diagnostics.open",
        title: "Diagnostics",
        keywords: "server version uptime errors processes health",
        action: "diagnostics.open",
      },
    ],
    dispatch: (action, payload) => {
      switch (action) {
        case "providers.refresh":
          refresh();
          return true;
        case "providers.update": {
          const instanceId = payloadField(payload, "instanceId");
          if (typeof instanceId === "string") update(instanceId);
          return true;
        }
        case "providers.add":
          addInstance();
          return true;
        case "settings.defaultWorkspace":
          chooseDefaultWorkspace();
          return true;
        case "diagnostics.open":
          openDiagnostics();
          return true;
        default:
          return false;
      }
    },
  };
}
