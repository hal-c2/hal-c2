// Steps for settings/diagnostics.feature and settings/resource-telemetry.feature
// (@tui, @shared): the diagnostics page with its bounded lists and the force
// kill that asks first, and the resource monitor's groups.
import { expect } from "bun:test";
import type { ResourceTelemetrySnapshot } from "@hal-c2/contracts";

import { step } from "../../steps.ts";
import {
  DIAGNOSTICS_FAILURE_LIMIT,
  DIAGNOSTICS_PROCESS_LIMIT,
} from "../../../src/host/sections/diagnostics.ts";
import { groupProcesses } from "../../../src/host/sections/resourceMonitor.ts";
import { runPaletteCommand } from "./controls.steps.ts";
import {
  chooseRow,
  connected,
  mc,
  pageText,
  paneWords,
  sectionState,
  selectRow,
} from "../settingsWorld.ts";
import { pressKey, settle, type World } from "../world.ts";

const AGENT_PID = 4102;

const process = (pid: number, command: string, cpuPercent = 2.5) => ({
  pid,
  ppid: 4000,
  pgid: pid,
  status: "S",
  cpuPercent,
  rssBytes: 52_428_800,
  elapsed: "00:42",
  startTimeMs: 1_767_225_600_000 + pid,
  command,
  depth: 0,
  childPids: [],
});

const processList = (processes: ReturnType<typeof process>[]) => ({
  serverPid: 4000,
  readAt: "2026-01-01T00:00:00.000Z",
  processCount: processes.length,
  totalRssBytes: processes.reduce((sum, entry) => sum + entry.rssBytes, 0),
  totalCpuPercent: processes.reduce((sum, entry) => sum + entry.cpuPercent, 0),
  processes,
  error: { _id: "Option", _tag: "None" },
});

const traces = (failures: number) => ({
  recordCount: failures * 4,
  failureCount: failures,
  slowSpanCount: 2,
  parseErrorCount: 0,
  latestFailures: Array.from({ length: failures }, (_, index) => ({
    name: `provider.turn.${index + 1}`,
    cause: `The provider stopped answering (${index + 1}).`,
    durationMs: 1200,
    endedAt: "2026-01-01T00:00:00.000Z",
    traceId: `trace-${index}`,
    spanId: `span-${index}`,
  })),
  error: { _id: "Option", _tag: "None" },
});

const signals = (ctx: World) => mc(ctx).callsTo("server.signalProcess");

async function openDiagnostics(ctx: World): Promise<void> {
  await connected(ctx);
  await runPaletteCommand(ctx, "Diagnostics");
  expect(sectionState(ctx).id).toBe("diagnostics");
}

// A provider session and a terminal under the MC.
step("an MC running a provider session and a terminal", (ctx: World) => {
  const fake = mc(ctx);
  fake.on("server.getProcessDiagnostics", () =>
    processList([process(AGENT_PID, "codex app-server"), process(4210, "/bin/zsh -l", 0.5)]),
  );
  fake.on("server.getTraceDiagnostics", () => traces(0));
  fake.on("server.signalProcess", (payload) => ({
    pid: payload.pid,
    signal: payload.signal,
    signaled: true,
    message: { _id: "Option", _tag: "None" },
  }));
});

step("the user force kills a process", async (ctx: World) => {
  await openDiagnostics(ctx);
  await chooseRow(ctx, "codex app-server");
  expect(pageText(ctx)).toContain(`Process ${AGENT_PID}`);
  await chooseRow(ctx, "Force kill (SIGKILL)");
});

step("the user is asked to confirm because the process cannot handle it", async (ctx: World) => {
  const question = `Send SIGKILL to process ${AGENT_PID}? This cannot be handled by the process.`;
  expect(sectionState(ctx).confirm?.lines.join(" ")).toBe(question);
  expect(ctx.host!.state.get("mode")).toBe("sectionConfirm");
  expect(await paneWords(ctx)).toContain(question);
  // Nothing is sent before the user answers.
  expect(signals(ctx)).toEqual([]);
});

step("cancelling leaves the process running", async (ctx: World) => {
  await pressKey(ctx, "n");
  await settle(ctx);
  expect(signals(ctx)).toEqual([]);
  expect(sectionState(ctx).confirm).toBeNull();
  expect(ctx.host!.state.get("mode")).toBe("section");
});

const MANY_PROCESSES = 30;
const MANY_FAILURES = 12;

step("the user opens diagnostics in the terminal client", async (ctx: World) => {
  const fake = mc(ctx);
  fake.on("server.getProcessDiagnostics", () =>
    processList(
      Array.from({ length: MANY_PROCESSES }, (_, index) =>
        process(5000 + index, `worker --shard ${index + 1}`, index + 1),
      ),
    ),
  );
  fake.on("server.getTraceDiagnostics", () => traces(MANY_FAILURES));
  await openDiagnostics(ctx);
});

step("long process lists and failures are summarised", async (ctx: World) => {
  const lines = sectionState(ctx).lines;
  const listed = lines.filter((line) => line.includes("worker --shard"));
  expect(listed).toHaveLength(DIAGNOSTICS_PROCESS_LIMIT);
  // The busiest come first; the rest are one line.
  expect(listed[0]).toContain(`worker --shard ${MANY_PROCESSES}`);
  expect(pageText(ctx)).toContain(
    `… and ${MANY_PROCESSES - DIAGNOSTICS_PROCESS_LIMIT} more processes`,
  );
  expect(pageText(ctx)).toContain(`${MANY_PROCESSES} processes`);
  expect(lines.filter((line) => line.includes("provider.turn."))).toHaveLength(
    DIAGNOSTICS_FAILURE_LIMIT,
  );
  expect(pageText(ctx)).toContain(
    `… and ${MANY_FAILURES - DIAGNOSTICS_FAILURE_LIMIT} more failures`,
  );
  // The whole page fits the pane: nothing is scrolled off.
  expect(sectionState(ctx).rows).toHaveLength(lines.length);
  const screen = await paneWords(ctx);
  expect(screen).toContain(`… and ${MANY_PROCESSES - DIAGNOSTICS_PROCESS_LIMIT} more processes`);
  expect(screen).toContain(`… and ${MANY_FAILURES - DIAGNOSTICS_FAILURE_LIMIT} more failures`);
});

// --- The resource monitor --------------------------------------------------------------

const monitored = (
  pid: number,
  ppid: number,
  category: string,
  command: string,
  depth: number,
) => ({
  identity: { pid, startTimeMs: 1_767_225_600_000 + pid },
  ppid,
  childPids: [],
  depth,
  name: command.split(" ")[0],
  command,
  status: "S",
  category,
  cpuPercent: 1.5,
  cpuTimeMs: 1000,
  residentBytes: 10_485_760,
  peakResidentBytes: 10_485_760,
  virtualBytes: 0,
  ioReadBytes: 0,
  ioWriteBytes: 0,
  ioReadBytesPerSecond: 0,
  ioWriteBytesPerSecond: 0,
  ioSemantics: "unavailable",
  runTimeMs: 60_000,
});

/** The MC, a provider with a tool it started, and a shell running a build. */
const SNAPSHOT = {
  sampleIntervalMs: 2000,
  processes: [
    monitored(4000, 1, "server", "beam.smp hal-c2-mc", 0),
    monitored(4050, 4000, "server-child", "epmd -daemon", 1),
    monitored(4102, 4000, "provider-root", "codex app-server", 1),
    monitored(4103, 4102, "server-child", "rg --files", 2),
    monitored(4210, 4000, "terminal-root", "zsh -l", 1),
    monitored(4211, 4210, "server-child", "bun run build", 2),
  ],
} as unknown as ResourceTelemetrySnapshot;

step("the user watches the resource monitor", async (ctx: World) => {
  await connected(ctx);
  await runPaletteCommand(ctx, "Resource monitor");
  expect(sectionState(ctx).id).toBe("resourceMonitor");
  expect(mc(ctx).telemetryWatchers()).toBe(1);
  mc(ctx).emitTelemetry(SNAPSHOT);
  await settle(ctx);
});

step("processes are grouped as server, provider and terminal", async (ctx: World) => {
  const groups = groupProcesses(SNAPSHOT.processes);
  expect(
    groups.map((group) => [group.id, group.processes.map((entry) => entry.identity.pid)]),
  ).toEqual([
    ["server", [4000, 4050]],
    ["provider", [4102, 4103]],
    ["terminal", [4210, 4211]],
  ]);
  // On the page each group's processes follow its heading.
  const lines = sectionState(ctx).lines;
  const at = (text: string) => lines.findIndex((line) => line.includes(text));
  const order = [
    "Server",
    "beam.smp hal-c2-mc",
    "epmd -daemon",
    "Providers",
    "codex app-server",
    "rg --files",
    "Terminals",
    "zsh -l",
    "bun run build",
  ].map(at);
  expect(order.every((index) => index >= 0)).toBe(true);
  expect(order).toEqual(order.toSorted((a, b) => a - b));
  const screen = await paneWords(ctx);
  expect(screen).toContain("▾ Providers 2 processes · CPU 3.0% · memory 20 MB");
});

step("each group can be collapsed and expanded again", async (ctx: World) => {
  await chooseRow(ctx, "Providers");
  expect(pageText(ctx)).not.toContain("codex app-server");
  expect(pageText(ctx)).toContain("▸ Providers");
  // The other groups stay open.
  expect(pageText(ctx)).toContain("beam.smp hal-c2-mc");
  expect(await paneWords(ctx)).not.toContain("rg --files");
  await selectRow(ctx, "Providers");
  await pressKey(ctx, "Enter");
  expect(await paneWords(ctx)).toContain("codex app-server");
  expect(pageText(ctx)).toContain("▾ Providers");
});
