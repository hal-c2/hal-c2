import { migrateLegacyHome } from "@hal-c2/shared/legacyHomeMigration";
import * as Effect from "effect/Effect";
import * as Layer from "effect/Layer";

import * as DesktopEnvironment from "./DesktopEnvironment.ts";
import { makeComponentLogger } from "./DesktopObservability.ts";

const { logInfo, logWarning } = makeComponentLogger("desktop-legacy-home-migration");

/**
 * Copies a legacy `~/.t3` or `~/.hal-c2` home into the XDG directories once,
 * before any desktop service reads its settings. A failed copy is logged and
 * startup continues with whatever the new directories hold.
 */
export const run = Effect.gen(function* () {
  const environment = yield* DesktopEnvironment.DesktopEnvironment;
  const lines: string[] = [];
  const result = yield* Effect.tryPromise(() =>
    migrateLegacyHome({
      dirs: environment.dirs,
      env: process.env,
      homeDir: environment.homeDirectory,
      platform: environment.platform,
      profile: environment.storageProfile,
      log: (line) => lines.push(line),
    }),
  ).pipe(
    Effect.catch((cause) =>
      Effect.succeed({ outcome: "failed" as const, error: String(cause), source: undefined }),
    ),
  );
  for (const line of lines) {
    yield* logInfo(line);
  }
  if (result.outcome === "failed") {
    yield* logWarning("legacy home migration failed", {
      source: result.source ?? null,
      error: result.error ?? null,
    });
  } else if (result.outcome === "migrated") {
    yield* logInfo("legacy home migrated", { source: result.source ?? null });
  }
}).pipe(Effect.withSpan("desktop.legacyHomeMigration"));

export const layer = Layer.effectDiscard(run);
