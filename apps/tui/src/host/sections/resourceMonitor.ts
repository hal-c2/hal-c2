import type { ResourceTelemetryProcess, ResourceTelemetrySnapshot } from "@hal-c2/contracts";

import type { SectionHost, SectionItem, SettingsSection } from "../settingsSections.ts";
import { formatBytes, formatPercent, plural } from "./shared.ts";

export type ProcessGroupId = "server" | "provider" | "terminal";

export interface ProcessGroup {
  readonly id: ProcessGroupId;
  readonly title: string;
  readonly processes: ReadonlyArray<ResourceTelemetryProcess>;
  readonly cpuPercent: number;
  readonly residentBytes: number;
}

const GROUPS: ReadonlyArray<{ readonly id: ProcessGroupId; readonly title: string }> = [
  { id: "server", title: "Server" },
  { id: "provider", title: "Providers" },
  { id: "terminal", title: "Terminals" },
];

/**
 * The monitor's processes by what they are for: a provider or terminal root
 * and everything under it, and the server with the rest.
 */
export function groupProcesses(processes: ReadonlyArray<ResourceTelemetryProcess>): ProcessGroup[] {
  const byPid = new Map(processes.map((process) => [process.identity.pid, process]));
  const groupOf = (process: ResourceTelemetryProcess): ProcessGroupId => {
    const seen = new Set<number>();
    for (
      let current: ResourceTelemetryProcess | undefined = process;
      current && !seen.has(current.identity.pid);
      current = byPid.get(current.ppid)
    ) {
      seen.add(current.identity.pid);
      if (current.category === "provider-root") return "provider";
      if (current.category === "terminal-root") return "terminal";
    }
    return "server";
  };
  return GROUPS.map(({ id, title }) => {
    const members = processes.filter((process) => groupOf(process) === id);
    return {
      id,
      title,
      processes: members,
      cpuPercent: members.reduce((sum, process) => sum + process.cpuPercent, 0),
      residentBytes: members.reduce((sum, process) => sum + process.residentBytes, 0),
    };
  });
}

/**
 * The resource monitor: live CPU and memory of what the MC runs, grouped as
 * server, providers and terminals. Enter on a group folds it away or opens it
 * again. The MC samples faster only while this page is open (the subscription).
 */
export function resourceMonitorSection(host: SectionHost): SettingsSection {
  let snapshot: ResourceTelemetrySnapshot | null = null;
  let collapsed = new Set<ProcessGroupId>();
  let unsubscribe: (() => void) | null = null;

  const toggle = (id: ProcessGroupId) => {
    const next = new Set(collapsed);
    if (!next.delete(id)) next.add(id);
    collapsed = next;
    host.refresh();
  };

  return {
    id: "resourceMonitor",
    commands: () => [
      {
        id: "section.resourceMonitor",
        title: "Resource monitor",
        keywords: "cpu memory processes telemetry diagnostics settings",
        action: "section.open",
        payload: { id: "resourceMonitor" },
      },
    ],
    open: () => {
      unsubscribe?.();
      snapshot = null;
      collapsed = new Set();
      unsubscribe = host.client.subscribeResourceTelemetry((next) => {
        snapshot = next;
        host.refresh();
      });
    },
    close: () => {
      unsubscribe?.();
      unsubscribe = null;
    },
    page: () => {
      const items: SectionItem[] = [];
      if (snapshot === null) {
        items.push({ kind: "note", text: "Waiting for the first sample…" });
        return { title: "resource monitor", items };
      }
      for (const group of groupProcesses(snapshot.processes)) {
        const folded = collapsed.has(group.id);
        items.push({
          kind: "row",
          id: `group-${group.id}`,
          label: `${folded ? "▸" : "▾"} ${group.title}`,
          value: `${plural(group.processes.length, "process", "processes")} · CPU ${formatPercent(group.cpuPercent)} · memory ${formatBytes(group.residentBytes)}`,
          tone: "accent",
          run: () => toggle(group.id),
        });
        if (folded) continue;
        for (const process of group.processes) {
          items.push({
            kind: "note",
            text: `${String(process.identity.pid).padEnd(7)} ${formatPercent(process.cpuPercent).padStart(6)} ${formatBytes(process.residentBytes).padStart(8)}  ${process.command || process.name}`,
            tone: "text",
          });
        }
      }
      return { title: "resource monitor", items };
    },
    dispatch: (action, payload) => {
      if (action !== "resourceMonitor.toggleGroup" || !host.isOpen()) return false;
      const group = (payload as { readonly group?: unknown } | undefined)?.group;
      if (group === "server" || group === "provider" || group === "terminal") toggle(group);
      return true;
    },
  };
}
