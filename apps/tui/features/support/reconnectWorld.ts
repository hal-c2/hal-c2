// The client's real connection supervisor and socket-ticket channel, with the
// server and the launcher faked: a session factory whose sessions the scenario
// drops, and a launcher that answers ticket requests (or stays silent, or goes
// away). Ticket timeouts run on timers the scenario fires, so nothing waits on
// a clock. The supervisor's phases feed the fake client the host listens to,
// through the same mapping the real client uses.
import type {
  PreparedConnection,
  SupervisorConnectionState,
} from "@t3tools/client-runtime/connection";
import { ConnectionTransientError } from "@t3tools/client-runtime/connection";
import { RpcSessionFactory, type RpcSession } from "@t3tools/client-runtime/rpc";
import * as Deferred from "effect/Deferred";
import * as Effect from "effect/Effect";
import * as Exit from "effect/Exit";
import * as Layer from "effect/Layer";
import * as ManagedRuntime from "effect/ManagedRuntime";
import * as Scope from "effect/Scope";
import * as Stream from "effect/Stream";
import * as SubscriptionRef from "effect/SubscriptionRef";

import {
  connectionPhases,
  makeTuiSupervisor,
  type TuiConnectionPhase,
} from "../../src/connection.ts";
import { makeSocketTicketMinter, type SocketTicketTimers } from "../../src/socketTicket.ts";
import type { World } from "./world.ts";

export interface TicketTimer {
  readonly ms: number;
  readonly fire: () => void;
  cleared: boolean;
}

export interface TicketRequest {
  readonly id: number;
  /** How the client's request settled: the URL, or the error message. */
  outcome?: { readonly url: string } | { readonly error: string };
}

export interface ConnectionHarness {
  /** Requests the client sent to the launcher, in order. */
  readonly requests: TicketRequest[];
  /** Socket URLs the supervisor connected with, in order. */
  readonly connects: string[];
  /** Phases the client reported to the host, in order. */
  readonly phases: TuiConnectionPhase[];
  /** From now on the launcher leaves ticket requests unanswered. */
  readonly silenceLauncher: () => void;
  readonly timers: TicketTimer[];
  /** Resolves once the supervisor has connected `count` times and is connected now. */
  readonly connected: (count: number) => Promise<void>;
  /** Resolves once the launcher has seen `count` requests. */
  readonly requested: (count: number) => Promise<TicketRequest>;
  /** Resolves once the request has settled. */
  readonly settled: (request: TicketRequest) => Promise<NonNullable<TicketRequest["outcome"]>>;
  /** The server side of the socket goes away. */
  readonly drop: () => Promise<void>;
  /** A ticket request the client makes outside the reconnect loop. */
  readonly mint: () => void;
  /** The launcher process exits (the IPC channel closes). */
  readonly launcherGone: () => void;
}

export interface ReconnectWorld extends World {
  connection?: ConnectionHarness;
  /** The page the host showed when the connection dropped. */
  pageBeforeDrop?: { kind: string; key?: string };
}

/** Resolve when `check` passes, re-checking on every notification. */
function waiter() {
  const listeners = new Set<() => void>();
  return {
    notify: () => {
      for (const listener of listeners) listener();
    },
    until: <T>(check: () => T | undefined): Promise<T> =>
      new Promise<T>((resolve) => {
        const run = () => {
          const value = check();
          if (value === undefined) return;
          listeners.delete(run);
          resolve(value);
        };
        listeners.add(run);
        run();
      }),
  };
}

/** Start the supervisor against the fakes; the fake client follows its phases. */
export async function startConnection(ctx: ReconnectWorld): Promise<ConnectionHarness> {
  const changed = waiter();
  const requests: TicketRequest[] = [];
  const connects: string[] = [];
  const phases: TuiConnectionPhase[] = [];
  const timers: TicketTimer[] = [];
  const drops: Array<Deferred.Deferred<never, ConnectionTransientError>> = [];

  const fakeTimers: SocketTicketTimers = {
    set: (run, ms) => {
      const timer: TicketTimer = {
        ms,
        cleared: false,
        fire: () => {
          if (!timer.cleared) run();
        },
      };
      timers.push(timer);
      return timer;
    },
    clear: (handle) => {
      (handle as TicketTimer).cleared = true;
    },
  };

  let launcherAnswers = true;
  const minter = makeSocketTicketMinter({
    timers: fakeTimers,
    send: (message) => {
      const { id } = message as { id: number };
      requests.push({ id });
      changed.notify();
      if (launcherAnswers) {
        queueMicrotask(() =>
          minter.receive({
            type: "socketUrl",
            id,
            url: `ws://127.0.0.1:1/ws?wsTicket=ticket-${id}`,
          }),
        );
      }
      return true;
    },
  });
  const trackedMint = (): Promise<string> => {
    const promise = minter.mint();
    const request = requests.at(-1)!;
    promise.then(
      (url) => {
        request.outcome = { url };
        changed.notify();
      },
      (error: Error) => {
        request.outcome = { error: error.message };
        changed.notify();
      },
    );
    return promise;
  };

  const factory = RpcSessionFactory.of({
    connect: (prepared: PreparedConnection) =>
      Effect.gen(function* () {
        connects.push(prepared.socketUrl);
        const closed = yield* Deferred.make<never, ConnectionTransientError>();
        drops.push(closed);
        changed.notify();
        // The supervisor only waits on `ready` and `closed`.
        return { ready: Effect.void, closed: Deferred.await(closed) } as unknown as RpcSession;
      }),
  });

  const runtime = ManagedRuntime.make(Layer.succeed(RpcSessionFactory, factory));
  const scope = await runtime.runPromise(Scope.make());
  const supervisor = await runtime.runPromise(
    makeTuiSupervisor({
      origin: "http://127.0.0.1:1",
      bearerToken: "reconnect-test",
      mintSocketUrl: trackedMint,
      reconnectDelay: 0,
    }).pipe(Effect.provideService(Scope.Scope, scope)),
  );
  const toPhase = connectionPhases();
  let phase: SupervisorConnectionState["phase"] = "connecting";
  runtime.runFork(
    SubscriptionRef.changes(supervisor.state).pipe(
      Stream.runForEach((state) =>
        Effect.sync(() => {
          phase = state.phase;
          const shown = toPhase(state);
          if (phases.at(-1) !== shown) phases.push(shown);
          ctx.fake?.emitConnection(shown);
          changed.notify();
        }),
      ),
    ),
  );
  ctx.cleanups.push(async () => {
    await runtime.runPromise(Scope.close(scope, Exit.void));
    await runtime.dispose();
  });

  const connection: ConnectionHarness = {
    requests,
    connects,
    phases,
    silenceLauncher: () => {
      launcherAnswers = false;
    },
    timers,
    connected: async (count) => {
      await changed.until(() =>
        connects.length >= count && phase === "connected" ? true : undefined,
      );
    },
    requested: (count) => changed.until(() => requests[count - 1]),
    settled: (request) => changed.until(() => request.outcome),
    drop: async () => {
      const current = drops.at(-1);
      if (!current) throw new Error("no connection to drop");
      await runtime.runPromise(
        Deferred.fail(
          current,
          new ConnectionTransientError({ reason: "network", detail: "socket closed" }),
        ),
      );
    },
    mint: () => {
      trackedMint().catch(() => {});
    },
    launcherGone: () => minter.disconnect(),
  };
  ctx.connection = connection;
  await connection.connected(1);
  return connection;
}
