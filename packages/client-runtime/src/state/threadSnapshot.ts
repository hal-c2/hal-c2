import type { OrchestrationV2ThreadDetailSnapshot, ThreadId } from "@hal-c2/contracts";
import * as Context from "effect/Context";
import type * as Effect from "effect/Effect";

import type { PreparedConnection } from "../connection/model.ts";

/** Progressive history metadata returned by a bounded snapshot loader. */
export type ThreadSnapshotHistoryMeta = {
  readonly historyCursor: string | null;
  readonly hasMoreHistory: boolean;
  /** Max local turn ordinal from the full projection; optional on older servers. */
  readonly latestLocalTurnOrdinal?: number | null;
};

/**
 * Outcome of a thread-detail snapshot load.
 *
 * - `present`: snapshot body is available (seed projection, resume via socket).
 * - `missing`: the environment definitively reported the thread does not exist.
 * - `unavailable`: no snapshot; fall back to the socket path.
 */
export type ThreadSnapshotLoadResult =
  | {
      readonly _tag: "present";
      readonly snapshot: OrchestrationV2ThreadDetailSnapshot;
      readonly history?: ThreadSnapshotHistoryMeta;
    }
  | { readonly _tag: "missing" }
  | { readonly _tag: "unavailable" };

/**
 * Loads a thread's detail snapshot ahead of the socket subscription, so the
 * thread state machine can mark a missing thread deleted without subscribing.
 */
export class ThreadSnapshotLoader extends Context.Service<
  ThreadSnapshotLoader,
  {
    readonly load: (
      prepared: PreparedConnection,
      threadId: ThreadId,
    ) => Effect.Effect<ThreadSnapshotLoadResult>;
  }
>()("@hal-c2/client-runtime/state/threadSnapshot/ThreadSnapshotLoader") {}
