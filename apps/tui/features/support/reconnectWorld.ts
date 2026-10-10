// The client's real connection supervisor with the server faked: a session
// factory whose sessions the scenario drops, and a ticket minter that hands out
// a fresh socket URL on every call. The supervisor's phases feed the fake client
// the host listens to, through the same mapping the real client uses.
import type {
  PreparedConnection,
  SupervisorConnectionState,
} from "@hal-c2/client-runtime/connection";
import { ConnectionTransientError } from "@hal-c2/client-runtime/connection";
import { RpcSessionFactory, type RpcSession } from "@hal-c2/client-runtime/rpc";
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
import type { World } from "./world.ts";

export interface ConnectionHarness {
  /** Socket URLs the supervisor connected with, in order. */
  readonly connects: string[];
  /** Phases the client reported to the host, in order. */
  readonly phases: TuiConnectionPhase[];
  /** Resolves once the supervisor has connected `count` times and is connected now. */
  readonly connected: (count: number) => Promise<void>;
  /** The server side of the socket goes away. */
  readonly drop: () => Promise<void>;
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
  const connects: string[] = [];
  const phases: TuiConnectionPhase[] = [];
  const drops: Array<Deferred.Deferred<never, ConnectionTransientError>> = [];
  let tickets = 0;
  const mintSocketUrl = async () => `ws://127.0.0.1:1/ws?wsTicket=ticket-${++tickets}`;

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
      environmentId: "reconnect-test",
      mintSocketUrl,
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
    connects,
    phases,
    connected: async (count) => {
      await changed.until(() =>
        connects.length >= count && phase === "connected" ? true : undefined,
      );
    },
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
  };
  ctx.connection = connection;
  await connection.connected(1);
  return connection;
}
