import * as Schema from "effect/Schema";
import { TrimmedNonEmptyString } from "./baseSchemas.ts";

const FILESYSTEM_PATH_MAX_LENGTH = 512;

export const FilesystemBrowseInput = Schema.Struct({
  partialPath: TrimmedNonEmptyString.check(Schema.isMaxLength(FILESYSTEM_PATH_MAX_LENGTH)),
  cwd: Schema.optional(TrimmedNonEmptyString.check(Schema.isMaxLength(FILESYSTEM_PATH_MAX_LENGTH))),
});
export type FilesystemBrowseInput = typeof FilesystemBrowseInput.Type;

export const FilesystemBrowseEntry = Schema.Struct({
  name: TrimmedNonEmptyString,
  fullPath: TrimmedNonEmptyString,
});
export type FilesystemBrowseEntry = typeof FilesystemBrowseEntry.Type;

export const FilesystemBrowseResult = Schema.Struct({
  parentPath: TrimmedNonEmptyString,
  entries: Schema.Array(FilesystemBrowseEntry),
});
export type FilesystemBrowseResult = typeof FilesystemBrowseResult.Type;

export const FilesystemBrowseFailure = Schema.Literals([
  "windows_path_unsupported",
  "current_project_required",
  "read_directory_failed",
]);
export type FilesystemBrowseFailure = typeof FilesystemBrowseFailure.Type;

function decodedFilesystemBrowseErrorMessage(props: object): string | undefined {
  if (!("message" in props)) return undefined;
  return typeof props.message === "string" ? props.message : undefined;
}

export class FilesystemBrowseError extends Schema.TaggedError<FilesystemBrowseError>()(
  "FilesystemBrowseError",
  {
    partialPath: Schema.optional(TrimmedNonEmptyString),
    cwd: Schema.optional(TrimmedNonEmptyString),
    failure: Schema.optional(FilesystemBrowseFailure),
    parentPath: Schema.optional(TrimmedNonEmptyString),
    platform: Schema.optional(TrimmedNonEmptyString),
    message: TrimmedNonEmptyString,
    cause: Schema.optional(Schema.Defect()),
  },
) {
  // Structured diagnostics stay optional for rolling compatibility with legacy message-only
  // payloads, while new call sites must provide the request context and failure classification.
  // @effect-diagnostics-next-line overriddenSchemaConstructor:off
  constructor(props: {
    readonly partialPath: string;
    readonly cwd?: string | undefined;
    readonly failure: FilesystemBrowseFailure;
    readonly parentPath?: string;
    readonly platform?: string;
    readonly cause?: unknown;
  }) {
    const cwd = props.cwd === undefined ? "" : ` from '${props.cwd}'`;
    super({
      ...props,
      message:
        decodedFilesystemBrowseErrorMessage(props) ??
        `Failed to browse filesystem path '${props.partialPath}'${cwd}.`,
    } as any);
  }
}

/** A path on the machine of environment `environmentId`, to open on this one. */
export const FilesLocalPathInput = Schema.Struct({
  environmentId: TrimmedNonEmptyString,
  path: TrimmedNonEmptyString,
});
export type FilesLocalPathInput = typeof FilesLocalPathInput.Type;

/**
 * Why a file on another machine has no path on this one: that machine is not in
 * this machine's cluster, this platform cannot show it yet, FUSE or the helper is
 * missing, its folder is still mounting, or the machine is not answering.
 */
export const FilesLocalPathReason = Schema.Literals([
  "not_a_member",
  "unsupported",
  "no_fuse",
  "no_helper",
  "not_ready",
  "unavailable",
]);
export type FilesLocalPathReason = typeof FilesLocalPathReason.Type;

/**
 * The path this machine's apps open (the path itself for this machine's own files,
 * the one under its folder for another member's), or why there is none, with the
 * machine's label and what to tell the user.
 */
export const FilesLocalPathResult = Schema.Union([
  Schema.Struct({ path: TrimmedNonEmptyString }),
  Schema.Struct({
    reason: FilesLocalPathReason,
    machine: Schema.optional(TrimmedNonEmptyString),
    message: TrimmedNonEmptyString,
  }),
]);
export type FilesLocalPathResult = typeof FilesLocalPathResult.Type;

/** The path is not absolute. */
export class FilesLocalPathError extends Schema.TaggedError<FilesLocalPathError>()(
  "FilesLocalPathError",
  { path: Schema.String, message: TrimmedNonEmptyString },
) {}
