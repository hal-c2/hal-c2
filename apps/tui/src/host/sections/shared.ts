import type { TuiClient } from "../../connection.ts";

// Helpers the settings sections share: reading the MC's JSON (settings calls
// are not decoded, see `settingsClient.ts`) and the machines a page can reach.

/** An `Option` as the MC sends it (`{_tag: "Some", value}`), a decoded one, or a bare value. */
export function optionValue<T>(option: unknown): T | null {
  if (option === null || option === undefined) return null;
  if (typeof option === "object" && "_tag" in option) {
    const tagged = option as { readonly _tag: string; readonly value?: T };
    return tagged._tag === "Some" ? (tagged.value ?? null) : null;
  }
  return option as T;
}

export const errorText = (error: unknown): string =>
  error instanceof Error ? error.message : String(error);

export function formatBytes(bytes: number): string {
  if (bytes >= 1024 ** 3) return `${(bytes / 1024 ** 3).toFixed(1)} GB`;
  if (bytes >= 1024 ** 2) return `${Math.round(bytes / 1024 ** 2)} MB`;
  if (bytes >= 1024) return `${Math.round(bytes / 1024)} KB`;
  return `${bytes} B`;
}

export const formatPercent = (value: number): string => `${value.toFixed(1)}%`;

export const plural = (count: number, one: string, many = `${one}s`): string =>
  `${count} ${count === 1 ? one : many}`;

/** A machine settings can reach through this MC: itself, a cluster member or a linked environment. */
export interface Machine {
  readonly id: string;
  readonly label: string;
  /** The MC the terminal is connected to. */
  readonly local: boolean;
  readonly online: boolean;
  readonly version: string | null;
  readonly capabilities: Readonly<Record<string, unknown>>;
  /** How the desktop app or a service hosts it, when the MC says. */
  readonly host: string | null;
}

interface WireDescriptor {
  readonly environmentId?: string;
  readonly label?: string;
  readonly serverVersion?: string;
  readonly capabilities?: Readonly<Record<string, unknown>>;
  readonly host?: string;
}

const machineOf = (
  descriptor: WireDescriptor,
  fallback: { readonly id: string; readonly label: string },
  local: boolean,
  online: boolean,
): Machine => ({
  id: descriptor.environmentId ?? fallback.id,
  label: descriptor.label ?? fallback.label,
  local,
  online,
  version: descriptor.serverVersion ?? null,
  capabilities: descriptor.capabilities ?? {},
  host: descriptor.host ?? null,
});

/**
 * This machine first, then the environments its MC is linked to and the other
 * members of its cluster. A server that knows neither (an older one) has just itself.
 */
export async function readMachines(client: TuiClient): Promise<Machine[]> {
  const config = await client.getServerConfig().catch(() => null);
  const local = machineOf(
    (config?.environment ?? {}) as WireDescriptor,
    { id: "local", label: "This machine" },
    true,
    true,
  );
  const machines = [local];
  const add = (machine: Machine) => {
    if (!machines.some((known) => known.id === machine.id)) machines.push(machine);
  };
  type WireLink = { readonly environment?: WireDescriptor; readonly online?: boolean };
  const links = await client
    .mcCall<ReadonlyArray<WireLink>>("hal-c2.environmentLinks", {})
    .catch((): ReadonlyArray<WireLink> => []);
  for (const link of Array.isArray(links) ? links : []) {
    const descriptor = link.environment ?? {};
    if (!descriptor.environmentId) continue;
    add(
      machineOf(
        descriptor,
        { id: descriptor.environmentId, label: descriptor.environmentId },
        false,
        link.online === true,
      ),
    );
  }
  const cluster = await client.clusterStatus().catch(() => null);
  if (cluster?.clustered) {
    for (const member of cluster.members) {
      add(machineOf({}, { id: member.id, label: member.label }, false, member.connected));
    }
  }
  return machines;
}
