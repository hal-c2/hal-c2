import {
  HAL_C2_PROJECT_FILE_NAME,
  type EnvironmentId,
  type HalC2ProjectFile,
} from "@hal-c2/contracts";
import { parseHalC2ProjectFile } from "@hal-c2/shared/halC2ProjectFile";
import { executeAtomQuery } from "@hal-c2/client-runtime/state/runtime";

import {
  getProjectFileQueryAtom,
  resolveProjectFileQueryData,
} from "~/components/files/projectFilesQueryState";
import { appAtomRegistry } from "~/rpc/atomRegistry";

/**
 * Read and decode the project's checked-in `hal-c2.json`.
 *
 * Imperative counterpart to `useHalC2ProjectFileState` for the new-thread path,
 * which resolves defaults at call time rather than render time. The file
 * query atom caches per (environment, cwd), so repeat calls don't re-fetch.
 * Optimistic in-app writes overlay the query result, matching what
 * `useProjectFileQuery` renders. Missing, truncated, or invalid files
 * resolve to null.
 */
export async function readHalC2ProjectFile(
  environmentId: EnvironmentId,
  workspaceRoot: string,
): Promise<HalC2ProjectFile | null> {
  const result = await executeAtomQuery(
    appAtomRegistry,
    getProjectFileQueryAtom(environmentId, workspaceRoot, HAL_C2_PROJECT_FILE_NAME),
    { reportDefect: false, reportFailure: false },
  );
  const data = resolveProjectFileQueryData(
    environmentId,
    workspaceRoot,
    HAL_C2_PROJECT_FILE_NAME,
    result._tag === "Success" ? result.value : null,
  );
  if (data === null || data.truncated) return null;
  return parseHalC2ProjectFile(data.contents);
}
