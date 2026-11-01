// @effect-diagnostics globalErrorInEffectFailure:off
// @effect-diagnostics anyUnknownInErrorContext:off
// @effect-diagnostics globalFetch:off
// The client calls behind the settings pages (`host/settingsSections.ts`).
//
// Settings reach machines other than the one the terminal is connected to
// (cluster members and linked environments), so their calls go to the MC by
// its wire method names, addressed by environment id, and return the MC's JSON
// as it was sent. The pages read plain objects; nothing here is decoded.
import {
  type AuthAccessStreamEvent,
  type ResourceTelemetrySnapshot,
  type ScheduledTask,
  type ServerProvider,
  type ServerSettings,
  type SpaceId,
  type SpacePageId,
  type SpacePresenceViewer,
  type UsageLimitSourceSnapshots,
  WS_METHODS,
} from "@hal-c2/contracts";
import { EnvironmentSupervisor } from "@hal-c2/client-runtime/connection";
import { mcStream, subscribe } from "@hal-c2/client-runtime/rpc";
import type { EntityStreamFrame } from "@hal-c2/client-runtime/state/stream-entities";
import * as Cause from "effect/Cause";
import * as Effect from "effect/Effect";
import * as Fiber from "effect/Fiber";
import type * as ManagedRuntime from "effect/ManagedRuntime";
import * as Option from "effect/Option";
import * as Stream from "effect/Stream";
import * as SubscriptionRef from "effect/SubscriptionRef";

/** What the limits page pools: this machine's providers and the hubs it reads. */
export interface UsageLimitsSnapshot {
  readonly providers: ReadonlyArray<ServerProvider>;
  readonly sources: UsageLimitSourceSnapshots;
}

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
  /** Send a file to an upload address the MC signed (`attachments.createUploadUrl`). */
  readonly uploadToMc: (relativeUrl: string, bytes: Uint8Array, mimeType: string) => Promise<void>;
  /** This machine's scheduled tasks: the whole list now and after every change. */
  readonly subscribeScheduledTasks: (
    onTasks: (tasks: ReadonlyArray<ScheduledTask>) => void,
  ) => () => void;
  /**
   * This machine's server settings: as they are on each (re)connection, then
   * whenever any client changes them.
   */
  readonly subscribeServerSettings: (onSettings: (settings: ServerSettings) => void) => () => void;
  /**
   * This machine's providers and usage hubs, now and whenever either changes.
   * The MC reads its hubs only for clients that follow them, so unsubscribe on leaving.
   */
  readonly subscribeUsageLimits: (
    onSnapshot: (snapshot: UsageLimitsSnapshot) => void,
  ) => () => void;
  /**
   * This machine's pairing links and paired clients: a snapshot, then each
   * change. `onError` gets the MC's refusal (a session that may not read access).
   */
  readonly subscribeAuthAccess: (
    onEvent: (event: AuthAccessStreamEvent) => void,
    onError?: (message: string) => void,
  ) => () => void;
  /** This machine's resource monitor: a snapshot every few seconds while subscribed. */
  readonly subscribeResourceTelemetry: (
    onSnapshot: (snapshot: ResourceTelemetrySnapshot) => void,
  ) => () => void;
  /**
   * One of this machine's MC entity streams (`spaces`, `space:<id>`): a snapshot,
   * then each event, and a fresh snapshot after a reconnection. `onError` gets the
   * MC's refusal, after which nothing more arrives.
   */
  readonly subscribeMcStream: (
    stream: string,
    onFrame: (frame: EntityStreamFrame) => void,
    onError?: (message: string) => void,
  ) => () => void;
  /**
   * Puts this client on a page of a Space until the returned function is called, and
   * says who else is on it: at once, on every change, and anew after a reconnection.
   */
  readonly subscribeSpacePresence: (
    spaceId: SpaceId,
    pageId: SpacePageId,
    onViewers: (viewers: ReadonlyArray<SpacePresenceViewer>) => void,
  ) => () => void;
}

export function makeTuiSettingsClient(
  runtime: ManagedRuntime.ManagedRuntime<EnvironmentSupervisor, never>,
  origin = "",
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
    // The signed address is its own authorization, like the MC's other upload clients use it.
    uploadToMc: async (relativeUrl, bytes, mimeType) => {
      const response = await fetch(new URL(relativeUrl, origin || undefined), {
        method: "POST",
        headers: { "content-type": mimeType },
        body: bytes as Uint8Array<ArrayBuffer>,
      });
      if (!response.ok) throw new Error(`The MC refused the upload (${response.status}).`);
    },
    subscribeScheduledTasks: (onTasks) =>
      drain(
        subscribe(WS_METHODS.scheduledTasksSubscribe, {}).pipe(
          Stream.tap((result) => Effect.sync(() => onTasks(result.tasks))),
        ),
      ),
    subscribeServerSettings: (onSettings) =>
      drain(
        // `subscribe` follows the supervisor's session, so a new connection starts on its snapshot.
        subscribe(WS_METHODS.subscribeServerConfig, {}).pipe(
          Stream.tap((event) =>
            Effect.sync(() => {
              if (event.type === "snapshot") onSettings(event.config.settings);
              if (event.type === "settingsUpdated") onSettings(event.payload.settings);
            }),
          ),
        ),
      ),
    subscribeUsageLimits: (onSnapshot) => {
      let snapshot: UsageLimitsSnapshot = { providers: [], sources: [] };
      const emit = (next: Partial<UsageLimitsSnapshot>) =>
        Effect.sync(() => {
          snapshot = { ...snapshot, ...next };
          onSnapshot(snapshot);
        });
      return drain(
        Stream.unwrap(
          Effect.gen(function* () {
            const supervisor = yield* EnvironmentSupervisor;
            return SubscriptionRef.changes(supervisor.session);
          }),
        ).pipe(
          // A new connection has a new session: follow its config in place of the old one's.
          Stream.switchMap((session) =>
            Option.isNone(session)
              ? Stream.empty
              : session.value
                  .subscribeServerConfig({ usageLimitSources: true })
                  .pipe(Stream.catchCause(() => Stream.empty)),
          ),
          Stream.tap((event) => {
            if (event.type === "snapshot") return emit({ providers: event.config.providers });
            if (event.type === "providerStatuses") {
              return emit({ providers: event.payload.providers });
            }
            if (event.type === "usageLimitSourcesUpdated") {
              return emit({ sources: event.payload.sources });
            }
            return Effect.void;
          }),
        ),
      );
    },
    subscribeAuthAccess: (onEvent, onError) =>
      drain(
        subscribe(WS_METHODS.subscribeAuthAccess, {}).pipe(
          Stream.tap((event) => Effect.sync(() => onEvent(event))),
          Stream.catchCause((cause) =>
            Stream.fromEffect(Effect.sync(() => onError?.(String(Cause.squash(cause))))),
          ),
        ),
      ),
    subscribeResourceTelemetry: (onSnapshot) =>
      drain(
        subscribe(WS_METHODS.subscribeResourceTelemetry, {}).pipe(
          Stream.tap((snapshot) => Effect.sync(() => onSnapshot(snapshot))),
        ),
      ),
    subscribeSpacePresence: (spaceId, pageId, onViewers) =>
      drain(
        subscribe(WS_METHODS.subscribeSpacePresence, { spaceId, pageId }).pipe(
          Stream.tap((event) => Effect.sync(() => onViewers(event.viewers))),
        ),
      ),
    subscribeMcStream: (stream, onFrame, onError) =>
      drain(
        mcStream(stream).pipe(
          Stream.tap((frame) => Effect.sync(() => onFrame(frame))),
          Stream.catchCause((cause) =>
            Stream.fromEffect(
              Effect.sync(() => {
                const error = Cause.squash(cause);
                onError?.(error instanceof Error ? error.message : String(error));
              }),
            ),
          ),
        ),
      ),
  };
}
