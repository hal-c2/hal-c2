import { compareSemverVersions, parseSemver } from "@hal-c2/shared/semver";

import type { TuiClient } from "../../connection.ts";
import type { MutedThreadsStore } from "../mutedThreads.ts";
import type { PaletteCommand } from "../paletteState.ts";
import type { SectionHost, SectionItem, SettingsSection } from "../settingsSections.ts";
import { environmentOf, errorText, type Machine, readMachines } from "./shared.ts";

// Updating servers and their providers. The app and a server can be on
// different versions: a server behind this app is offered its update where the
// user is (the notice over the conversation) and on the Updates page, which
// also updates every machine at once and each machine's providers.

/** Core `major.minor.patch`, dropping any prerelease or build suffix. */
const versionCore = (version: string): string => version.replace(/[-+].*$/, "");

/**
 * True when the server runs an older HAL-C2 than this app, so the server is
 * the side to update. Two nightly builds compare in full; otherwise only the
 * core version counts. Versions that are not semver are behind when they differ.
 */
export function serverIsBehind(appVersion: string | null, serverVersion: string | null): boolean {
  const app = appVersion?.trim() ?? "";
  const server = serverVersion?.trim() ?? "";
  if (app === "" || server === "") return false;
  const nightlies =
    parseSemver(app)?.prerelease[0] === "nightly" &&
    parseSemver(server)?.prerelease[0] === "nightly";
  if (!parseSemver(versionCore(app)) || !parseSemver(versionCore(server))) return app !== server;
  return (
    compareSemverVersions(
      nightlies ? server : versionCore(server),
      nightlies ? app : versionCore(app),
    ) < 0
  );
}

/** The command for a server that cannot update itself. */
export const manualUpdateCommand = (targetVersion: string): string => `npx hal-c2@${targetVersion}`;

/** How a server behind this app can be brought up to it. */
export type UpdatePath = "update" | "desktop" | "desktop-manual" | "command";

export function updatePath(machine: Machine): UpdatePath {
  const selfUpdate = machine.capabilities?.serverSelfUpdate ?? null;
  if (selfUpdate === null) return "command";
  if (selfUpdate !== "desktop-managed") return "update";
  return machine.capabilities?.desktopAppUpdate === true ? "desktop" : "desktop-manual";
}

/** Published under `updateNotice`: the offer over the conversation, or null. */
export interface TuiUpdateNotice {
  readonly machineId: string;
  readonly label: string;
  readonly serverVersion: string;
  readonly targetVersion: string;
  readonly text: string;
}

const dismissalKey = (machineId: string, targetVersion: string) =>
  `${machineId}\u0000${targetVersion}`;

/**
 * The update notice: shown while the server the terminal is connected to is
 * behind this app, until the user dismisses it. A dismissal is for that server
 * and that version, kept on this device: a newer app asks again.
 */
export function createUpdateNotice(ctx: {
  readonly client: Pick<TuiClient, "getServerConfig">;
  readonly appVersion: string | null;
  readonly dismissed: MutedThreadsStore;
  readonly publish: (notice: TuiUpdateNotice | null) => void;
}) {
  let current: TuiUpdateNotice | null = null;
  const pending = new Set<Promise<unknown>>();
  const set = (next: TuiUpdateNotice | null) => {
    current = next;
    ctx.publish(next);
  };
  const check = () => {
    const appVersion = ctx.appVersion;
    if (appVersion === null) return;
    const reading = ctx.client.getServerConfig().then(
      (config) => {
        const environment = config.environment as
          | { environmentId?: string; label?: string; serverVersion?: string }
          | undefined;
        const serverVersion = environment?.serverVersion ?? null;
        const machineId = environment?.environmentId ?? "local";
        if (
          serverVersion === null ||
          !serverIsBehind(appVersion, serverVersion) ||
          ctx.dismissed.load().includes(dismissalKey(machineId, appVersion))
        ) {
          set(null);
          return;
        }
        const label = environment?.label ?? "This server";
        set({
          machineId,
          label,
          serverVersion,
          targetVersion: appVersion,
          text: `${label} is on ${serverVersion}, behind this app (${appVersion}). Update it: ^K, "Updates".`,
        });
      },
      () => {
        // Not connected yet; the next connection checks again.
      },
    );
    pending.add(reading);
    void reading.finally(() => pending.delete(reading));
  };
  return {
    /** Read the server's version again (on every connection, and after an update). */
    check,
    state: () => current,
    dismiss: () => {
      if (!current) return;
      const key = dismissalKey(current.machineId, current.targetVersion);
      ctx.dismissed.save([...ctx.dismissed.load().filter((known) => known !== key), key]);
      set(null);
    },
    commands: (): PaletteCommand[] =>
      current
        ? [
            {
              id: "update.notice.open",
              title: `Update ${current.label}…`,
              keywords: "server version upgrade",
              action: "section.open",
              payload: { id: "updates" },
            },
            {
              id: "update.notice.dismiss",
              title: "Dismiss the update notice",
              keywords: "server version hide",
              action: "update.notice.dismiss",
            },
          ]
        : [],
    settled: async () => {
      while (pending.size > 0) await Promise.allSettled(pending);
    },
  };
}

interface WireProvider {
  readonly instanceId: string;
  readonly driver: string;
  readonly displayName?: string;
  readonly versionAdvisory?: {
    readonly status: string;
    readonly currentVersion: string | null;
    readonly latestVersion: string | null;
    readonly canUpdate?: boolean;
  } | null;
  readonly updateState?: { readonly status: string; readonly message: string | null } | null;
}

/** A provider that is behind its latest release on one machine. */
interface ProviderUpdate {
  readonly machine: Machine;
  readonly provider: WireProvider;
}

type Outcome =
  | { readonly kind: "running" }
  | { readonly kind: "done"; readonly text: string; readonly ok: boolean };

const providerName = (provider: WireProvider) => provider.displayName ?? provider.driver;

/** What a provider update came to on a machine, from the state the MC reports for it. */
export function providerOutcome(provider: WireProvider | undefined): {
  readonly text: string;
  readonly ok: boolean;
} {
  const state = provider?.updateState;
  if (state?.status === "succeeded") return { text: "Updated", ok: true };
  if (state?.status === "unchanged") return { text: "Already up to date", ok: true };
  return { text: `Failed: ${state?.message ?? "the update did not finish."}`, ok: false };
}

export function updatesSection(
  host: SectionHost,
  options: { readonly appVersion: string | null; readonly updated: () => void },
): SettingsSection {
  const { client } = host;
  const appVersion = options.appVersion;
  let machines: Machine[] = [];
  let providers: ProviderUpdate[] = [];
  let loading = true;
  const serverOutcomes = new Map<string, Outcome>();
  /** By machine id and provider instance. */
  const providerOutcomes = new Map<string, Outcome>();
  let generation = 0;

  const behind = (machine: Machine) => serverIsBehind(appVersion, machine.version);
  const providerKey = (update: ProviderUpdate) =>
    `${update.machine.id}\u0000${update.provider.instanceId}`;

  const readProviders = (machine: Machine): Promise<ReadonlyArray<WireProvider>> =>
    machine.local
      ? client.getServerConfig().then((config) => config.providers as never)
      : client
          .mcCall<{
            readonly providers: ReadonlyArray<WireProvider>;
          }>("server.refreshProviders", {}, machine.id)
          .then((result) => result.providers);

  const load = () => {
    const asked = ++generation;
    loading = true;
    void host.track(
      readMachines(client).then(async (next) => {
        if (asked !== generation) return;
        machines = next;
        host.refresh();
        const lists = await Promise.all(
          next
            .filter((machine) => machine.online)
            .map((machine) =>
              readProviders(machine).then(
                (list) => ({ machine, list: list ?? [] }),
                () => ({ machine, list: [] as ReadonlyArray<WireProvider> }),
              ),
            ),
        );
        if (asked !== generation) return;
        providers = lists.flatMap(({ machine, list }) =>
          list
            .filter((provider) => provider.versionAdvisory?.status === "behind_latest")
            .map((provider) => ({ machine, provider })),
        );
        loading = false;
        host.refresh();
      }),
    );
  };

  /** Update one server to this app's version; each machine reports for itself. */
  const updateServer = (machine: Machine): Promise<void> => {
    if (appVersion === null || serverOutcomes.get(machine.id)?.kind === "running") {
      return Promise.resolve();
    }
    serverOutcomes.set(machine.id, { kind: "running" });
    host.refresh();
    return client
      .mcCall<{
        readonly targetVersion?: string;
      }>("server.updateServer", { targetVersion: appVersion }, environmentOf(machine))
      .then(
        async (result) => {
          // The version it answers with now is the one it came back on.
          const now = (await readMachines(client).catch(() => machines)).find(
            (candidate) => candidate.id === machine.id,
          );
          const version = now?.version ?? result.targetVersion ?? appVersion;
          machines = machines.map((known) => (known.id === machine.id && now ? now : known));
          const text = `${machine.label} was updated and reconnected on ${version}.`;
          serverOutcomes.set(machine.id, { kind: "done", ok: true, text });
          host.status(text, "success");
          options.updated();
          host.refresh();
        },
        (cause: unknown) => {
          const text = `${machine.label} update failed: ${errorText(cause)}`;
          serverOutcomes.set(machine.id, { kind: "done", ok: false, text });
          host.status(text, "error");
          host.refresh();
        },
      );
  };

  const updateAll = () => {
    const eligible = machines.filter(
      (machine) =>
        machine.online &&
        behind(machine) &&
        (updatePath(machine) === "update" || updatePath(machine) === "desktop"),
    );
    const run = () => void host.track(Promise.all(eligible.map(updateServer)));
    const desktops = eligible.filter((machine) => updatePath(machine) === "desktop");
    if (desktops.length === 0) run();
    else {
      host.confirm(
        `Update the HAL-C2 desktop apps on ${desktops.map((machine) => machine.label).join(", ")}? They will close and relaunch on those machines.`,
        run,
      );
    }
  };

  const updateProvider = (update: ProviderUpdate): Promise<void> => {
    const key = providerKey(update);
    if (providerOutcomes.get(key)?.kind === "running") return Promise.resolve();
    providerOutcomes.set(key, { kind: "running" });
    host.refresh();
    return client
      .mcCall<{ readonly providers: ReadonlyArray<WireProvider> }>(
        "server.updateProvider",
        { provider: update.provider.driver, instanceId: update.provider.instanceId },
        environmentOf(update.machine),
      )
      .then(
        (result) => {
          const outcome = providerOutcome(
            result.providers?.find(
              (provider) => provider.instanceId === update.provider.instanceId,
            ),
          );
          providerOutcomes.set(key, { kind: "done", ...outcome });
          host.refresh();
        },
        (cause: unknown) => {
          providerOutcomes.set(key, {
            kind: "done",
            ok: false,
            text: `Failed: ${errorText(cause)}`,
          });
          host.refresh();
        },
      );
  };

  const serverRow = (machine: Machine): SectionItem[] => {
    const outcome = serverOutcomes.get(machine.id);
    const version = machine.version ?? "unknown version";
    const items: SectionItem[] = [];
    if (!machine.online) {
      items.push({
        kind: "row",
        id: `server-${machine.id}`,
        label: machine.label,
        value: "offline",
      });
    } else if (!behind(machine)) {
      items.push({
        kind: "row",
        id: `server-${machine.id}`,
        label: machine.label,
        value: `${version} · up to date`,
        tone: "success",
      });
    } else {
      const path = updatePath(machine);
      const target = appVersion ?? "";
      const base = `${version} → ${target}`;
      items.push({
        kind: "row",
        id: `server-${machine.id}`,
        label: machine.label,
        tone: "warning",
        ...(outcome?.kind === "running"
          ? { value: `${base} · Updating…` }
          : path === "command"
            ? {
                value: `${base} · Copy update command`,
                run: () => {
                  const command = manualUpdateCommand(target);
                  if (host.copyToClipboard(command)) {
                    host.status(
                      `Update command copied. Run \`${command}\` on ${machine.label}.`,
                      "success",
                    );
                  } else host.status(`Run \`${command}\` on ${machine.label}.`, "info");
                },
              }
            : path === "desktop-manual"
              ? { value: `${base} · Update the desktop app on that machine to update this server.` }
              : path === "desktop"
                ? {
                    value: `${base} · Update the desktop app`,
                    run: () =>
                      host.confirm(
                        `Update the HAL-C2 desktop app that runs ${machine.label}? It will close and relaunch on that machine.`,
                        () => void host.track(updateServer(machine)),
                      ),
                  }
                : {
                    value: `${base} · Update server`,
                    run: () => void host.track(updateServer(machine)),
                  }),
      });
    }
    if (outcome?.kind === "done") {
      items.push({
        kind: "note",
        indent: 2,
        text: outcome.text,
        tone: outcome.ok ? "success" : "error",
      });
    }
    return items;
  };

  return {
    id: "updates",
    commands: () => [
      {
        id: "section.updates",
        title: "Updates",
        keywords: "update server provider version upgrade settings",
        action: "section.open",
        payload: { id: "updates" },
      },
    ],
    open: () => {
      machines = [];
      providers = [];
      serverOutcomes.clear();
      providerOutcomes.clear();
      load();
    },
    close: () => {
      generation += 1;
    },
    page: () => {
      const items: SectionItem[] = [];
      items.push({
        kind: "note",
        text:
          appVersion === null
            ? "This app does not know its own version, so it cannot tell which servers are behind."
            : `This app is ${appVersion}. A server behind it can be updated to match.`,
      });
      if (machines.length === 0) {
        items.push({ kind: "note", text: "Reading versions…" });
        return { title: "updates", items };
      }
      items.push({ kind: "heading", text: "Servers" });
      for (const machine of machines) items.push(...serverRow(machine));
      const updatable = machines.filter(
        (machine) =>
          machine.online &&
          behind(machine) &&
          (updatePath(machine) === "update" || updatePath(machine) === "desktop"),
      );
      if (updatable.length > 1) {
        items.push({
          kind: "row",
          id: "update-all",
          label: "Update all machines",
          tone: "accent",
          run: updateAll,
        });
      }
      items.push({ kind: "blank" });
      items.push({ kind: "heading", text: "Providers" });
      if (loading) items.push({ kind: "note", text: "Checking provider versions…" });
      else if (providers.length === 0) {
        items.push({ kind: "note", text: "Every provider is on its latest release." });
      }
      for (const update of providers) {
        const outcome = providerOutcomes.get(providerKey(update));
        const advisory = update.provider.versionAdvisory;
        const versions = `${advisory?.currentVersion ?? "?"} → ${advisory?.latestVersion ?? "latest"}`;
        items.push({
          kind: "row",
          id: `provider-${providerKey(update)}`,
          label: `${providerName(update.provider)} on ${update.machine.label}`,
          value:
            outcome?.kind === "running"
              ? `${versions} · Updating…`
              : outcome?.kind === "done"
                ? outcome.text
                : `${versions} · Update`,
          tone: outcome?.kind === "done" ? (outcome.ok ? "success" : "error") : "warning",
          run: () => void host.track(updateProvider(update)),
        });
      }
      // The same provider behind on several machines can be updated on all of them at once.
      const drivers = new Map<string, ProviderUpdate[]>();
      for (const update of providers) {
        drivers.set(update.provider.driver, [
          ...(drivers.get(update.provider.driver) ?? []),
          update,
        ]);
      }
      for (const [driver, updates] of drivers) {
        if (updates.length < 2) continue;
        items.push({
          kind: "row",
          id: `provider-all-${driver}`,
          label: `Update ${providerName(updates[0]!.provider)} on ${updates.length} machines`,
          tone: "accent",
          run: () => void host.track(Promise.all(updates.map(updateProvider))),
        });
      }
      return { title: "updates", items };
    },
  };
}
