// The MC behind the settings pages, faked: the methods `TuiSettingsClient`
// reaches by their wire names (`scheduledTasks.upsert`, `server.signalProcess`,
// `hal-c2.readSettings`, …), answered by handlers a step installs with `on`.
// Like the fake MC of launch.feature, a method nobody answers is refused as
// unsupported. Every call is kept in `calls` with the environment it addressed.
import type {
  AuthAccessStreamEvent,
  ResourceTelemetrySnapshot,
  ScheduledTask,
} from "@hal-c2/contracts";

import type { TuiSettingsClient, UsageLimitsSnapshot } from "../../src/settingsClient.ts";

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
  /** This machine's providers and hubs, as its config says; set them, then `emitUsageLimits`. */
  usageLimits: UsageLimitsSnapshot;
  /** Tell whoever follows limits what `usageLimits` holds now. */
  readonly emitUsageLimits: () => void;
  /** How many clients follow limits right now. */
  readonly usageLimitWatchers: () => number;
  /** Tell whoever follows the access list (pairing links, paired clients) what changed. */
  readonly emitAuthAccess: (event: AuthAccessStreamEvent) => void;
  /** Called when a client starts following the access list (send it the snapshot). */
  onAuthAccessSubscribe: (() => void) | null;
  readonly authAccessWatchers: () => number;
}

export function fakeSettingsMc(): FakeSettingsMc {
  const handlers = new Map<string, FakeMcHandler>([["hal-c2.environmentLinks", () => []]]);
  const calls: FakeMcCall[] = [];
  const taskWatchers = new Set<(tasks: ReadonlyArray<ScheduledTask>) => void>();
  const telemetryWatchers = new Set<(snapshot: ResourceTelemetrySnapshot) => void>();
  const limitWatchers = new Set<(snapshot: UsageLimitsSnapshot) => void>();
  const accessWatchers = new Set<(event: AuthAccessStreamEvent) => void>();
  const fake: FakeSettingsMc = {
    emitAuthAccess: (event) => {
      for (const watcher of accessWatchers) watcher(event);
    },
    onAuthAccessSubscribe: null,
    authAccessWatchers: () => accessWatchers.size,
    usageLimits: { providers: [], sources: [] },
    emitUsageLimits: () => {
      for (const watcher of limitWatchers) watcher(fake.usageLimits);
    },
    usageLimitWatchers: () => limitWatchers.size,
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
      // Like the config stream, a subscriber gets the current state at once.
      subscribeUsageLimits: (onSnapshot) => {
        limitWatchers.add(onSnapshot);
        onSnapshot(fake.usageLimits);
        return () => {
          limitWatchers.delete(onSnapshot);
        };
      },
      subscribeAuthAccess: (onEvent) => {
        accessWatchers.add(onEvent);
        fake.onAuthAccessSubscribe?.();
        return () => {
          accessWatchers.delete(onEvent);
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
