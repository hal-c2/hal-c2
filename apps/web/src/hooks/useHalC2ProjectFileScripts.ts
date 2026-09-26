import {
  HAL_C2_PROJECT_FILE_NAME,
  type EnvironmentId,
  type HalC2ProjectFile,
  type HalC2ProjectFileScript,
} from "@hal-c2/contracts";
import { parseHalC2ProjectFile } from "@hal-c2/shared/halC2ProjectFile";
import { useMemo } from "react";

import { useProjectFileQuery } from "~/components/files/projectFilesQueryState";

const NO_SCRIPTS: ReadonlyArray<HalC2ProjectFileScript> = [];

export interface HalC2ProjectFileState {
  /**
   * - `valid`: hal-c2.json exists and decoded.
   * - `invalid`: hal-c2.json exists but fails to decode (the server then ignores
   *   the whole file, including `iconPath` and every script).
   * - `missing`: no readable hal-c2.json at the workspace root.
   * - `loading`: the file query has not settled yet.
   */
  status: "loading" | "missing" | "invalid" | "valid";
  /** The decoded file when status is `valid`, null otherwise. */
  file: HalC2ProjectFile | null;
  scripts: ReadonlyArray<HalC2ProjectFileScript>;
}

/**
 * Decoded state of the project's checked-in `hal-c2.json`, including whether the
 * file exists but is broken — which the runtime otherwise swallows silently.
 */
export function useHalC2ProjectFileState(
  environmentId: EnvironmentId,
  cwd: string | null,
): HalC2ProjectFileState {
  const query = useProjectFileQuery(
    environmentId,
    cwd ?? "",
    HAL_C2_PROJECT_FILE_NAME,
    cwd !== null,
  );
  const contents = query.data && !query.data.truncated ? query.data.contents : null;
  const isPending = query.isPending;
  return useMemo(() => {
    if (contents === null) {
      return {
        status: isPending ? "loading" : "missing",
        file: null,
        scripts: NO_SCRIPTS,
      } as const;
    }
    const file = parseHalC2ProjectFile(contents);
    if (file === null) {
      return { status: "invalid", file: null, scripts: NO_SCRIPTS } as const;
    }
    return { status: "valid", file, scripts: file.scripts ?? NO_SCRIPTS } as const;
  }, [contents, isPending]);
}

/**
 * Scripts declared in the project's checked-in `hal-c2.json`, offered in the
 * scripts menu for import. Missing, truncated, or invalid files resolve to
 * an empty list.
 */
export function useHalC2ProjectFileScripts(
  environmentId: EnvironmentId,
  cwd: string | null,
): ReadonlyArray<HalC2ProjectFileScript> {
  return useHalC2ProjectFileState(environmentId, cwd).scripts;
}
