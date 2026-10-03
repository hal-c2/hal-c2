// The MC behind the settings pages, faked: the methods `TuiSettingsClient`
// reaches by their wire names (`scheduledTasks.upsert`, `server.signalProcess`,
// `hal-c2.readSettings`, …), answered by handlers a step installs with `on`.
// Like the fake MC of launch.feature, a method nobody answers is refused as
// unsupported. Every call is kept in `calls` with the environment it addressed.
import type { ResourceTelemetrySnapshot, ScheduledTask } from "@hal-c2/contracts";

import type { TuiSettingsClient } from "../../src/settingsClient.ts";

export interface FakeMcCall {
  readonly method: string;
  readonly payload: unknown;
  /** The environment addressed; undefined is the MC the terminal is connected to. */
  readonly environmentId: string | undefined;
}

export type FakeMcHandler = (payload: any, environmentId: string | undefined) => unknown;

export interface FakeSettingsMc {
  readonly client: TuiSettingsClient;
  readonly calls: FakeMcCall[];
  /** Answer `method` (a returned promise is awaited; a throw is the MC's refusal). */
  readonly on: (method: string, handler: FakeMcHandler) => void;
  readonly callsTo: (method: string) => FakeMcCall[];
  /** Push this machine's scheduled tasks to whoever watches them. */
  readonly emitScheduledTasks: (tasks: ReadonlyArray<ScheduledTask>) => void;
  /** Called when the client starts watching scheduled tasks. */
  onScheduledTasksSubscribe: (() => void) | null;
  readonly emitTelemetry: (snapshot: ResourceTelemetrySnapshot) => void;
  /** How many clients watch the resource monitor right now. */
  readonly telemetryWatchers: () => number;
  onTelemetrySubscribe: (() => void) | null;
}

export function fakeSettingsMc(): FakeSettingsMc {
  const handlers = new Map<string, FakeMcHandler>([["hal-c2.environmentLinks", () => []]]);
  const calls: FakeMcCall[] = [];
  const taskWatchers = new Set<(tasks: ReadonlyArray<ScheduledTask>) => void>();
  const telemetryWatchers = new Set<(snapshot: ResourceTelemetrySnapshot) => void>();
  const fake: FakeSettingsMc = {
    calls,
    on: (method, handler) => {
      handlers.set(method, handler);
    },
    callsTo: (method) => calls.filter((call) => call.method === method),
    emitScheduledTasks: (tasks) => {
      for (const watcher of taskWatchers) watcher(tasks);
    },
    onScheduledTasksSubscribe: null,
    emitTelemetry: (snapshot) => {
      for (const watcher of telemetryWatchers) watcher(snapshot);
    },
    telemetryWatchers: () => telemetryWatchers.size,
    onTelemetrySubscribe: null,
    client: {
      mcCall: async <T>(method: string, payload: unknown, environmentId?: string) => {
        calls.push({ method, payload, environmentId });
        const handler = handlers.get(method);
        if (!handler) throw new Error("unsupported");
        return (await handler(payload, environmentId)) as T;
      },
      subscribeScheduledTasks: (onTasks) => {
        taskWatchers.add(onTasks);
        fake.onScheduledTasksSubscribe?.();
        return () => {
          taskWatchers.delete(onTasks);
        };
      },
      subscribeResourceTelemetry: (onSnapshot) => {
        telemetryWatchers.add(onSnapshot);
        fake.onTelemetrySubscribe?.();
        return () => {
          telemetryWatchers.delete(onSnapshot);
        };
      },
    },
  };
  return fake;
}
