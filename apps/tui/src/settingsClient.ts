// @effect-diagnostics globalErrorInEffectFailure:off
// @effect-diagnostics anyUnknownInErrorContext:off
// The client calls behind the settings pages (`host/settingsSections.ts`).
//
// Settings reach machines other than the one the terminal is connected to
// (cluster members and linked environments), so their calls go to the MC by
// its wire method names, addressed by environment id, and return the MC's JSON
// as it was sent. The pages read plain objects; nothing here is decoded.
import { type ResourceTelemetrySnapshot, type ScheduledTask, WS_METHODS } from "@hal-c2/contracts";
import { EnvironmentSupervisor } from "@hal-c2/client-runtime/connection";
import { subscribe } from "@hal-c2/client-runtime/rpc";
import * as Effect from "effect/Effect";
import * as Fiber from "effect/Fiber";
import type * as ManagedRuntime from "effect/ManagedRuntime";
import * as Option from "effect/Option";
import * as Stream from "effect/Stream";
import * as SubscriptionRef from "effect/SubscriptionRef";

export interface TuiSettingsClient {
  /**
   * Run an MC method (`scheduledTasks.upsert`, `server.signalProcess`,
   * `hal-c2.readSettings`, …) on the MC serving `environmentId`, this machine's
   * when omitted. Rejects with the MC's message.
   */
  readonly mcCall: <T = unknown>(
    method: string,
    payload: unknown,
    environmentId?: string,
  ) => Promise<T>;
  /** This machine's scheduled tasks: the whole list now and after every change. */
  readonly subscribeScheduledTasks: (
    onTasks: (tasks: ReadonlyArray<ScheduledTask>) => void,
  ) => () => void;
  /** This machine's resource monitor: a snapshot every few seconds while subscribed. */
  readonly subscribeResourceTelemetry: (
    onSnapshot: (snapshot: ResourceTelemetrySnapshot) => void,
  ) => () => void;
}

export function makeTuiSettingsClient(
  runtime: ManagedRuntime.ManagedRuntime<EnvironmentSupervisor, never>,
): TuiSettingsClient {
  const drain = <A>(stream: Stream.Stream<A, unknown, EnvironmentSupervisor>): (() => void) => {
    const fiber = runtime.runFork(Stream.runDrain(stream));
    return () => {
      runtime.runFork(Fiber.interrupt(fiber));
    };
  };
  return {
    mcCall: <T>(method: string, payload: unknown, environmentId?: string) =>
      runtime.runPromise(
        Effect.gen(function* () {
          const supervisor = yield* EnvironmentSupervisor;
          const session = yield* SubscriptionRef.get(supervisor.session);
          if (Option.isNone(session)) {
            return yield* Effect.fail(new Error(`${supervisor.target.label} is not connected.`));
          }
          const call = session.value.callEnvironment;
          if (!call) {
            return yield* Effect.fail(new Error("This server cannot be changed from here."));
          }
          return (yield* call(
            environmentId ?? supervisor.target.environmentId,
            method,
            payload,
          )) as T;
        }),
      ),
    subscribeScheduledTasks: (onTasks) =>
      drain(
        subscribe(WS_METHODS.scheduledTasksSubscribe, {}).pipe(
          Stream.tap((result) => Effect.sync(() => onTasks(result.tasks))),
        ),
      ),
    subscribeResourceTelemetry: (onSnapshot) =>
      drain(
        subscribe(WS_METHODS.subscribeResourceTelemetry, {}).pipe(
          Stream.tap((snapshot) => Effect.sync(() => onSnapshot(snapshot))),
        ),
      ),
  };
}
