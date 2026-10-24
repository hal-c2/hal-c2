import type { OrchestrationV2ShellSnapshot } from "@hal-c2/contracts";
import * as Context from "effect/Context";
import type * as Effect from "effect/Effect";
import type * as Option from "effect/Option";

import type { PreparedConnection } from "../connection/model.ts";

/**
 * Loads the environment shell snapshot ahead of the socket subscription,
 * returning `Option.none()` when there is none so the shell state machine uses
 * the snapshot the socket sends first.
 */
export class ShellSnapshotLoader extends Context.Service<
  ShellSnapshotLoader,
  {
    readonly load: (
      prepared: PreparedConnection,
    ) => Effect.Effect<Option.Option<OrchestrationV2ShellSnapshot>>;
  }
>()("@hal-c2/client-runtime/state/shellSnapshot/ShellSnapshotLoader") {}
