// The requests the feature areas (src/host/features) make, next to the
// client's core in connection.ts. Each is one RPC from packages/contracts.
import { TrimmedNonEmptyString, WS_METHODS } from "@hal-c2/contracts";
import { request } from "@hal-c2/client-runtime/rpc";
import * as Effect from "effect/Effect";

import type { TuiRuntime } from "./connection.ts";

export interface TuiFeatureClient {
  /** Write a workspace file (`projects.writeFile`). */
  readonly writeFile: (cwd: string, relativePath: string, contents: string) => Promise<void>;
}

export function makeFeatureClient(runtime: TuiRuntime): TuiFeatureClient {
  return {
    writeFile: (cwd, relativePath, contents) =>
      runtime.runPromise(
        request(WS_METHODS.projectsWriteFile, {
          cwd: TrimmedNonEmptyString.make(cwd),
          relativePath: TrimmedNonEmptyString.make(relativePath),
          contents,
        }).pipe(Effect.asVoid),
      ),
  };
}
