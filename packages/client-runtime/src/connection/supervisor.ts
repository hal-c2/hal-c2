import * as Context from "effect/Context";
import type * as Effect from "effect/Effect";
import type * as Option from "effect/Option";
import type * as SubscriptionRef from "effect/SubscriptionRef";

import type { ConnectionTarget, PreparedConnection, SupervisorConnectionState } from "./model.ts";
import type * as RpcSession from "../rpc/session.ts";

/** One environment's connection: its state, live RPC session, and the controls a client drives. */
export class EnvironmentSupervisor extends Context.Service<
  EnvironmentSupervisor,
  {
    readonly target: ConnectionTarget;
    readonly state: SubscriptionRef.SubscriptionRef<SupervisorConnectionState>;
    readonly session: SubscriptionRef.SubscriptionRef<Option.Option<RpcSession.RpcSession>>;
    readonly prepared: SubscriptionRef.SubscriptionRef<Option.Option<PreparedConnection>>;
    readonly connect: Effect.Effect<void>;
    readonly disconnect: Effect.Effect<void>;
    readonly retryNow: Effect.Effect<void>;
  }
>()("@hal-c2/client-runtime/connection/supervisor/EnvironmentSupervisor") {}
