/**
 * HalC2ProjectFileLoader - Effect service that loads the checked-in `hal-c2.json`
 * project file from a workspace root.
 *
 * A repository that still only has the pre-rename `t3.json` is read from that
 * file instead; `hal-c2.json` wins when both exist.
 *
 * Loading is best-effort: a missing file resolves to `Option.none`, and
 * unreadable or invalid files are logged and treated as absent so callers
 * can fall back to their defaults.
 *
 * @module HalC2ProjectFileLoader
 */
import * as Context from "effect/Context";
import * as Effect from "effect/Effect";
import * as FileSystem from "effect/FileSystem";
import * as Layer from "effect/Layer";
import * as Option from "effect/Option";
import * as Path from "effect/Path";
import * as Schema from "effect/Schema";

import {
  HAL_C2_PROJECT_FILE_NAME,
  HAL_C2_PROJECT_FILE_NAMES,
  type HalC2ProjectFile,
} from "@hal-c2/contracts";
import { HalC2ProjectFileFromJson } from "@hal-c2/shared/halC2ProjectFile";

const decodeHalC2ProjectFileJson = Schema.decodeEffect(HalC2ProjectFileFromJson);

export class HalC2ProjectFileLoadError extends Schema.TaggedError<HalC2ProjectFileLoadError>()(
  "HalC2ProjectFileLoadError",
  {
    operation: Schema.Literals(["read", "decode"]),
    workspaceRoot: Schema.String,
    filePath: Schema.String,
    cause: Schema.Defect(),
  },
) {
  override get message(): string {
    return `Failed to ${this.operation} project file at ${this.filePath}.`;
  }
}

/** Service tag for hal-c2.json project file loading. */
export class HalC2ProjectFileLoader extends Context.Service<
  HalC2ProjectFileLoader,
  {
    /**
     * Load and decode `hal-c2.json` at the workspace root.
     *
     * Never fails: missing, unreadable, or invalid files resolve to
     * `Option.none` (invalid files are logged as warnings).
     */
    readonly load: (workspaceRoot: string) => Effect.Effect<Option.Option<HalC2ProjectFile>>;
  }
>()("hal-c2/project/HalC2ProjectFileLoader") {}

const logHalC2ProjectFileLoadError = (error: HalC2ProjectFileLoadError) =>
  Effect.logWarning(error).pipe(
    Effect.annotateLogs({
      operation: error.operation,
      workspaceRoot: error.workspaceRoot,
      filePath: error.filePath,
      errorTag: error._tag,
    }),
  );

/** @public Service construction is part of the canonical Effect module API. */
export const make = Effect.gen(function* () {
  const fileSystem = yield* FileSystem.FileSystem;
  const path = yield* Path.Path;

  const load: HalC2ProjectFileLoader["Service"]["load"] = Effect.fn("HalC2ProjectFileLoader.load")(
    function* (workspaceRoot) {
      let filePath = path.join(workspaceRoot, HAL_C2_PROJECT_FILE_NAME);
      let raw = Option.none<string>();
      for (const fileName of HAL_C2_PROJECT_FILE_NAMES) {
        filePath = path.join(workspaceRoot, fileName);
        const read = yield* fileSystem.readFileString(filePath).pipe(
          Effect.map((contents) => ({ found: true as const, contents: Option.some(contents) })),
          Effect.catchTags({
            PlatformError: (error) =>
              error.reason._tag === "NotFound"
                ? Effect.succeed({ found: false as const, contents: Option.none<string>() })
                : logHalC2ProjectFileLoadError(
                    new HalC2ProjectFileLoadError({
                      operation: "read",
                      workspaceRoot,
                      filePath,
                      cause: error,
                    }),
                  ).pipe(Effect.as({ found: true as const, contents: Option.none<string>() })),
          }),
        );
        // Only a missing file falls through: an unreadable hal-c2.json must not
        // silently hand the project to a stale t3.json.
        if (read.found) {
          raw = read.contents;
          break;
        }
      }
      if (Option.isNone(raw)) {
        return Option.none<HalC2ProjectFile>();
      }
      return yield* decodeHalC2ProjectFileJson(raw.value).pipe(
        Effect.map(Option.some),
        Effect.catchTags({
          SchemaError: (error) =>
            logHalC2ProjectFileLoadError(
              new HalC2ProjectFileLoadError({
                operation: "decode",
                workspaceRoot,
                filePath,
                cause: error,
              }),
            ).pipe(Effect.as(Option.none<HalC2ProjectFile>())),
        }),
      );
    },
  );

  return HalC2ProjectFileLoader.of({ load });
});

export const layer = Layer.effect(HalC2ProjectFileLoader, make);
