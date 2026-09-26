// TODO(xdg-merge): replaced by the server worker's implementation
import type { HalC2Dirs, HalC2DirsEnvironment, HalC2Profile } from "./xdgDirs.ts";

export interface LegacyHomeMigrationResult {
  readonly source: string | undefined;
  readonly copied: readonly string[];
  readonly outcome: "migrated" | "no-source" | "already-done" | "opted-out" | "failed";
  readonly error?: string;
}

/** Copies a legacy `~/.t3` or `~/.hal-c2` home into the XDG directories once. */
export const migrateLegacyHome = async (_options: {
  readonly dirs: HalC2Dirs;
  readonly env: HalC2DirsEnvironment & { HAL_C2_NO_MIGRATE?: string };
  readonly homeDir: string;
  readonly platform: NodeJS.Platform;
  readonly profile: HalC2Profile;
  readonly log: (line: string) => void;
}): Promise<LegacyHomeMigrationResult> => ({ outcome: "no-source", copied: [], source: undefined });
