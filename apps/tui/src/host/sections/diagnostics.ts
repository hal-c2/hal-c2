import type { SectionHost, SectionItem, SettingsSection } from "../settingsSections.ts";
import { errorText, formatBytes, formatPercent, optionValue, plural } from "./shared.ts";

// `server.getProcessDiagnostics`, `server.getTraceDiagnostics` and
// `server.signalProcess` as the MC answers them.
interface WireProcess {
  readonly pid: number;
  readonly startTimeMs: number;
  readonly cpuPercent: number;
  readonly rssBytes: number;
  readonly command: string;
  /** How long it has run, as `ps` prints it. */
  readonly elapsed?: string;
}
interface WireProcesses {
  /** The MC's own process: its `elapsed` is the server's uptime. */
  readonly serverPid?: number;
  readonly processCount: number;
  readonly totalRssBytes: number;
  readonly totalCpuPercent: number;
  readonly processes: ReadonlyArray<WireProcess>;
  readonly error?: unknown;
}
interface WireFailure {
  readonly name: string;
  readonly cause: string;
}
interface WireTraces {
  readonly failureCount: number;
  readonly slowSpanCount: number;
  readonly latestFailures?: ReadonlyArray<WireFailure>;
  readonly error?: unknown;
}

/** How many processes and failures the page lists before it sums up the rest. */
export const DIAGNOSTICS_PROCESS_LIMIT = 8;
export const DIAGNOSTICS_FAILURE_LIMIT = 5;

export type ProcessSignal = "SIGINT" | "SIGKILL";

/**
 * Diagnostics: what the MC started and what it costs, the latest failures it
 * recorded, and a way to stop a process. Long lists are cut to the busiest
 * processes and the newest failures, with the rest summed up in one line.
 */
export function diagnosticsSection(host: SectionHost): SettingsSection {
  let processes: WireProcesses | null = null;
  let traces: WireTraces | null = null;
  let version: string | null = null;
  let error: string | null = null;
  /** The process whose signals are offered (its own page). */
  let picked: WireProcess | null = null;
  let generation = 0;

  const read = () => {
    const asked = ++generation;
    void host.track(
      Promise.all([
        host.client.mcCall<WireProcesses>("server.getProcessDiagnostics", {}),
        // An MC without traces still lists its processes.
        host.client.mcCall<WireTraces>("server.getTraceDiagnostics", {}).catch(() => null),
        // The version the MC reports for itself.
        host.client.getServerConfig().then(
          (config) => config.environment?.serverVersion ?? null,
          () => null,
        ),
      ]).then(
        ([nextProcesses, nextTraces, nextVersion]) => {
          if (asked !== generation) return;
          version = nextVersion;
          processes = nextProcesses;
          traces = nextTraces;
          error = optionValue<{ message: string }>(nextProcesses.error)?.message ?? null;
          host.refresh();
        },
        (cause: unknown) => {
          if (asked !== generation) return;
          error = errorText(cause);
          host.refresh();
        },
      ),
    );
  };

  const send = (target: WireProcess, signal: ProcessSignal) => {
    void host.track(
      host.client
        .mcCall<{ readonly signaled: boolean; readonly message?: unknown }>(
          "server.signalProcess",
          { pid: target.pid, startTimeMs: target.startTimeMs, signal },
        )
        .then(
          (result) => {
            if (result.signaled) host.status(`Sent ${signal} to process ${target.pid}.`, "success");
            else {
              host.status(
                optionValue<string>(result.message) ?? `Failed to send ${signal}.`,
                "error",
              );
            }
            picked = null;
            read();
          },
          (cause: unknown) => host.status(`Could not send ${signal}: ${errorText(cause)}`, "error"),
        ),
    );
  };

  /** A force kill asks first: the process gets no chance to clean up. */
  const signal = (target: WireProcess, which: ProcessSignal) => {
    if (which !== "SIGKILL") {
      send(target, which);
      return;
    }
    host.confirm(
      `Send SIGKILL to process ${target.pid}? This cannot be handled by the process.`,
      () => send(target, which),
    );
  };

  const processPage = (target: WireProcess): SectionItem[] => [
    { kind: "heading", text: `Process ${target.pid}` },
    { kind: "note", text: target.command },
    {
      kind: "note",
      text: `CPU ${formatPercent(target.cpuPercent)} · memory ${formatBytes(target.rssBytes)}`,
    },
    { kind: "blank" },
    {
      kind: "row",
      id: "signal-SIGINT",
      label: "Interrupt (SIGINT)",
      run: () => signal(target, "SIGINT"),
    },
    {
      kind: "row",
      id: "signal-SIGKILL",
      label: "Force kill (SIGKILL)",
      tone: "error",
      run: () => signal(target, "SIGKILL"),
    },
  ];

  const overview = (): SectionItem[] => {
    const items: SectionItem[] = [];
    if (error !== null) items.push({ kind: "note", text: error, tone: "error" });
    if (processes === null) {
      if (error === null) items.push({ kind: "note", text: "Reading diagnostics…" });
      return items;
    }
    const server = processes.processes.find((process) => process.pid === processes!.serverPid);
    items.push({ kind: "heading", text: "Server" });
    items.push({
      kind: "note",
      text: `version ${version ?? "unknown"} · up ${server?.elapsed ?? "unknown"}`,
    });
    items.push({ kind: "blank" });
    items.push({ kind: "heading", text: "Processes" });
    items.push({
      kind: "note",
      text: `${plural(processes.processCount, "process", "processes")} · CPU ${formatPercent(processes.totalCpuPercent)} · memory ${formatBytes(processes.totalRssBytes)}`,
    });
    const busiest = processes.processes.toSorted((a, b) => b.cpuPercent - a.cpuPercent);
    const shown = busiest.slice(0, DIAGNOSTICS_PROCESS_LIMIT);
    for (const process of shown) {
      items.push({
        kind: "row",
        id: `process-${process.pid}`,
        label: `${String(process.pid).padEnd(7)} ${formatPercent(process.cpuPercent).padStart(6)} ${formatBytes(process.rssBytes).padStart(8)}`,
        value: process.command,
        clip: true,
        run: () => {
          picked = process;
          host.refresh();
        },
      });
    }
    const rest = busiest.slice(DIAGNOSTICS_PROCESS_LIMIT);
    if (rest.length > 0) {
      const cpu = rest.reduce((sum, process) => sum + process.cpuPercent, 0);
      const memory = rest.reduce((sum, process) => sum + process.rssBytes, 0);
      items.push({
        kind: "note",
        text: `… and ${plural(rest.length, "more process", "more processes")} · CPU ${formatPercent(cpu)} · memory ${formatBytes(memory)}`,
      });
    }
    items.push({ kind: "blank" });
    items.push({ kind: "heading", text: "Failures" });
    const traceError = optionValue<{ message: string }>(traces?.error)?.message ?? null;
    if (traces === null || traceError !== null) {
      items.push({ kind: "note", text: traceError ?? "This MC does not record traces." });
    } else {
      const failures = traces.latestFailures ?? [];
      items.push({
        kind: "note",
        text: `${plural(traces.failureCount, "failure")} · ${plural(traces.slowSpanCount, "slow span")}`,
      });
      for (const [index, failure] of failures.slice(0, DIAGNOSTICS_FAILURE_LIMIT).entries()) {
        items.push({
          kind: "row",
          id: `failure-${index}`,
          label: failure.name,
          value: failure.cause,
          clip: true,
          tone: "error",
        });
      }
      const more = Math.max(traces.failureCount, failures.length) - DIAGNOSTICS_FAILURE_LIMIT;
      if (more > 0) items.push({ kind: "note", text: `… and ${plural(more, "more failure")}` });
    }
    items.push({ kind: "blank" });
    items.push({ kind: "row", id: "refresh", label: "Refresh", run: read });
    return items;
  };

  return {
    id: "diagnostics",
    commands: () => [
      {
        id: "section.diagnostics",
        title: "Diagnostics",
        keywords: "processes cpu memory failures traces kill signal settings",
        action: "section.open",
        payload: { id: "diagnostics" },
      },
    ],
    open: () => {
      processes = null;
      traces = null;
      error = null;
      picked = null;
      read();
    },
    close: () => {
      generation += 1;
    },
    back: () => {
      if (picked === null) return false;
      picked = null;
      return true;
    },
    page: () => ({
      title: "diagnostics",
      items: picked ? processPage(picked) : overview(),
    }),
    dispatch: (action, payload) => {
      if (action !== "diagnostics.signal" || !host.isOpen()) return false;
      const input = payload as { readonly pid?: unknown; readonly signal?: unknown } | undefined;
      const target = processes?.processes.find((process) => process.pid === input?.pid);
      if (target && (input?.signal === "SIGINT" || input?.signal === "SIGKILL")) {
        signal(target, input.signal);
      }
      return true;
    },
  };
}
