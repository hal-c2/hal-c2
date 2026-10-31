import * as Schema from "effect/Schema";

import {
  IsoDateTime,
  SpaceBlockId,
  SpaceCommentId,
  SpaceId,
  SpacePageId,
  ThreadId,
  TrimmedNonEmptyString,
} from "./baseSchemas.ts";
import { ScheduledTaskRunStatus, ScheduledTaskUpsertSchedule } from "./scheduledTask.ts";

/**
 * Spaces hold Pages that people and agents write together. Clients read them
 * from streams, the same subscribe/resume path as projects and threads:
 * `SPACES_STREAM_ID` holds one `space` entity per Space, and `spaceStreamId(id)`
 * holds that Space's `page`, `block` and `comment` entities. The RPCs below
 * change them.
 */
export const SPACES_STREAM_ID = "spaces";

export const spaceStreamId = (spaceId: SpaceId) => `space:${spaceId}`;

/** Who wrote something: the user, the agent of a thread, or a page's own update. */
export const SpaceAuthor = Schema.Union([
  Schema.Struct({ type: Schema.Literal("user") }),
  Schema.Struct({ type: Schema.Literal("agent"), threadId: ThreadId }),
  Schema.Struct({ type: Schema.Literal("schedule") }),
]);
export type SpaceAuthor = typeof SpaceAuthor.Type;

export const Space = Schema.Struct({
  id: SpaceId,
  name: TrimmedNonEmptyString,
  createdAt: IsoDateTime,
  updatedAt: IsoDateTime,
});
export type Space = typeof Space.Type;

/**
 * What a page shows of its update: the MC's scheduler keeps it and mirrors it here, so
 * a client changes it through `space.page.schedule.*` and never writes it.
 */
export const SpacePageSchedule = Schema.Struct({
  instruction: TrimmedNonEmptyString,
  cadence: ScheduledTaskUpsertSchedule,
  /** False while the update is paused. */
  enabled: Schema.Boolean,
  /** Null while paused, or while the page is in the trash. */
  nextRunAt: Schema.NullOr(IsoDateTime),
  lastRunAt: Schema.NullOr(IsoDateTime),
  lastRunStatus: ScheduledTaskRunStatus,
  lastRunError: Schema.NullOr(Schema.String),
});
export type SpacePageSchedule = typeof SpacePageSchedule.Type;

export const SpacePage = Schema.Struct({
  id: SpacePageId,
  spaceId: SpaceId,
  title: TrimmedNonEmptyString,
  parentPageId: Schema.NullOr(SpacePageId),
  /** The thread the page was made from, if any. */
  sourceThreadId: Schema.NullOr(ThreadId),
  /** Set while the page is in the trash. Its subpages are hidden with it. */
  trashedAt: Schema.NullOr(IsoDateTime),
  /** The page's update, if it has one. */
  schedule: Schema.optional(Schema.NullOr(SpacePageSchedule)),
  /** When a run of its update last wrote the page's generated part. */
  writtenAt: Schema.optional(Schema.NullOr(IsoDateTime)),
  createdAt: IsoDateTime,
  updatedAt: IsoDateTime,
});
export type SpacePage = typeof SpacePage.Type;

/** The kinds of block that can be written by hand. */
export const SpaceWritableBlockKind = Schema.Literals([
  "paragraph",
  "heading",
  "checklist",
  "callout",
  "subpage_link",
]);
export type SpaceWritableBlockKind = typeof SpaceWritableBlockKind.Type;

/**
 * A `generated` block is the marked part of a page that updates itself: at most one on
 * a page, its text is the Markdown of the last run, and only a run writes it. It can be
 * moved, deleted and commented on.
 */
export const SpaceBlockKind = Schema.Literals([...SpaceWritableBlockKind.literals, "generated"]);
export type SpaceBlockKind = typeof SpaceBlockKind.Type;

export const SpaceBlock = Schema.Struct({
  id: SpaceBlockId,
  pageId: SpacePageId,
  kind: SpaceBlockKind,
  text: Schema.String,
  /** Ticked; always false for blocks that are not checklist items. */
  checked: Schema.Boolean,
  /** The page a `subpage_link` block points at. */
  linkedPageId: Schema.NullOr(SpacePageId),
  /**
   * Sorts the page's blocks: compare as plain strings. A block inserted or moved
   * gets a key between its neighbours', so no other block changes.
   */
  order: Schema.String,
  createdBy: SpaceAuthor,
  updatedBy: SpaceAuthor,
  createdAt: IsoDateTime,
  updatedAt: IsoDateTime,
});
export type SpaceBlock = typeof SpaceBlock.Type;

export const SpaceComment = Schema.Struct({
  id: SpaceCommentId,
  pageId: SpacePageId,
  /** The block the comment is on, or null for the page as a whole. */
  blockId: Schema.NullOr(SpaceBlockId),
  author: SpaceAuthor,
  body: TrimmedNonEmptyString,
  resolvedAt: Schema.NullOr(IsoDateTime),
  createdAt: IsoDateTime,
  updatedAt: IsoDateTime,
});
export type SpaceComment = typeof SpaceComment.Type;

// Spaces

/** Lists the Spaces, making the "Personal" Space first if there are none. */
export const SpaceListInput = Schema.Struct({});
export const SpaceListResult = Schema.Struct({ spaces: Schema.Array(Space) });
export type SpaceListResult = typeof SpaceListResult.Type;

export const SpaceCreateInput = Schema.Struct({ name: TrimmedNonEmptyString });
export type SpaceCreateInput = typeof SpaceCreateInput.Type;

export const SpaceRenameInput = Schema.Struct({ spaceId: SpaceId, name: TrimmedNonEmptyString });
export type SpaceRenameInput = typeof SpaceRenameInput.Type;

/** Deletes a Space that has no pages, in the trash or out of it. */
export const SpaceDeleteInput = Schema.Struct({ spaceId: SpaceId });
export type SpaceDeleteInput = typeof SpaceDeleteInput.Type;

export const SpaceResult = Schema.Struct({ space: Space });
export type SpaceResult = typeof SpaceResult.Type;

export const SpaceDeleteResult = Schema.Struct({ spaceId: SpaceId });
export type SpaceDeleteResult = typeof SpaceDeleteResult.Type;

// Pages

export const SpacePageCreateInput = Schema.Struct({
  spaceId: SpaceId,
  title: TrimmedNonEmptyString,
  parentPageId: Schema.optional(Schema.NullOr(SpacePageId)),
});
export type SpacePageCreateInput = typeof SpacePageCreateInput.Type;

export const SpacePageRenameInput = Schema.Struct({
  spaceId: SpaceId,
  pageId: SpacePageId,
  title: TrimmedNonEmptyString,
});
export type SpacePageRenameInput = typeof SpacePageRenameInput.Type;

/** Moves a page under another page, or to the top of the Space with null. Never under itself. */
export const SpacePageMoveInput = Schema.Struct({
  spaceId: SpaceId,
  pageId: SpacePageId,
  parentPageId: Schema.NullOr(SpacePageId),
});
export type SpacePageMoveInput = typeof SpacePageMoveInput.Type;

/**
 * Names one page for `space.page.trash`, `space.page.restore`, `space.page.delete`
 * and `space.page.exportMarkdown`. Restoring a page whose parent is still in the
 * trash, or gone, puts it at the top of the Space. Only a page in the trash can be
 * deleted; its subpages, blocks and comments go with it.
 */
export const SpacePageRef = Schema.Struct({ spaceId: SpaceId, pageId: SpacePageId });
export type SpacePageRef = typeof SpacePageRef.Type;

export const SpacePageResult = Schema.Struct({ page: SpacePage });
export type SpacePageResult = typeof SpacePageResult.Type;

export const SpacePageDeleteResult = Schema.Struct({
  deletedPageIds: Schema.Array(SpacePageId),
});
export type SpacePageDeleteResult = typeof SpacePageDeleteResult.Type;

export const SpacePageExportMarkdownResult = Schema.Struct({ markdown: Schema.String });
export type SpacePageExportMarkdownResult = typeof SpacePageExportMarkdownResult.Type;

/** A new page from Markdown. Without a title, a leading `# Title` line names it. */
export const SpacePageImportMarkdownInput = Schema.Struct({
  spaceId: SpaceId,
  markdown: Schema.String,
  title: Schema.optional(TrimmedNonEmptyString),
  parentPageId: Schema.optional(Schema.NullOr(SpacePageId)),
});
export type SpacePageImportMarkdownInput = typeof SpacePageImportMarkdownInput.Type;

/** A new page summarising a thread, written by text generation in the thread's project. */
export const SpacePageCreateFromThreadInput = Schema.Struct({
  spaceId: SpaceId,
  threadId: ThreadId,
  parentPageId: Schema.optional(Schema.NullOr(SpacePageId)),
});
export type SpacePageCreateFromThreadInput = typeof SpacePageCreateFromThreadInput.Type;

// A page's update

/**
 * Gives a live page an instruction and a cadence, or changes them. Each run writes the
 * page's generated part. A paused update stays paused.
 */
export const SpacePageScheduleSetInput = Schema.Struct({
  spaceId: SpaceId,
  pageId: SpacePageId,
  instruction: TrimmedNonEmptyString,
  cadence: ScheduledTaskUpsertSchedule,
});
export type SpacePageScheduleSetInput = typeof SpacePageScheduleSetInput.Type;

/** Pauses or resumes a live page's update. Resuming does not run what was missed. */
export const SpacePageScheduleSetEnabledInput = Schema.Struct({
  spaceId: SpaceId,
  pageId: SpacePageId,
  enabled: Schema.Boolean,
});
export type SpacePageScheduleSetEnabledInput = typeof SpacePageScheduleSetEnabledInput.Type;

// `space.page.schedule.runNow` starts a run and answers at once; the page shows how it
// goes. `space.page.schedule.remove` ends the update and leaves what it last wrote as
// ordinary blocks. Both take a `SpacePageRef`.

// Blocks

/**
 * Where a block goes on its page: after `afterBlockId`, first with null, or last
 * when it is left out.
 */
const AfterBlockId = Schema.optional(Schema.NullOr(SpaceBlockId));

export const SpaceBlockInsertInput = Schema.Struct({
  spaceId: SpaceId,
  pageId: SpacePageId,
  kind: SpaceWritableBlockKind,
  text: Schema.optional(Schema.String),
  checked: Schema.optional(Schema.Boolean),
  /** Required for `subpage_link`, which shows that page's title. */
  linkedPageId: Schema.optional(SpacePageId),
  afterBlockId: AfterBlockId,
});
export type SpaceBlockInsertInput = typeof SpaceBlockInsertInput.Type;

export const SpaceBlockUpdateInput = Schema.Struct({
  spaceId: SpaceId,
  blockId: SpaceBlockId,
  text: Schema.String,
});
export type SpaceBlockUpdateInput = typeof SpaceBlockUpdateInput.Type;

/** Ticks or unticks a checklist item. */
export const SpaceBlockSetCheckedInput = Schema.Struct({
  spaceId: SpaceId,
  blockId: SpaceBlockId,
  checked: Schema.Boolean,
});
export type SpaceBlockSetCheckedInput = typeof SpaceBlockSetCheckedInput.Type;

export const SpaceBlockMoveInput = Schema.Struct({
  spaceId: SpaceId,
  blockId: SpaceBlockId,
  afterBlockId: AfterBlockId,
});
export type SpaceBlockMoveInput = typeof SpaceBlockMoveInput.Type;

/** Deletes a block and the comments on it. */
export const SpaceBlockDeleteInput = Schema.Struct({ spaceId: SpaceId, blockId: SpaceBlockId });
export type SpaceBlockDeleteInput = typeof SpaceBlockDeleteInput.Type;

export const SpaceBlockResult = Schema.Struct({ block: SpaceBlock });
export type SpaceBlockResult = typeof SpaceBlockResult.Type;

export const SpaceBlockDeleteResult = Schema.Struct({ blockId: SpaceBlockId });
export type SpaceBlockDeleteResult = typeof SpaceBlockDeleteResult.Type;

// Comments

export const SpaceCommentAddInput = Schema.Struct({
  spaceId: SpaceId,
  pageId: SpacePageId,
  blockId: Schema.optional(Schema.NullOr(SpaceBlockId)),
  body: TrimmedNonEmptyString,
});
export type SpaceCommentAddInput = typeof SpaceCommentAddInput.Type;

/** Names one comment for `space.comment.resolve` and `space.comment.reopen`. */
export const SpaceCommentRef = Schema.Struct({ spaceId: SpaceId, commentId: SpaceCommentId });
export type SpaceCommentRef = typeof SpaceCommentRef.Type;

export const SpaceCommentResult = Schema.Struct({ comment: SpaceComment });
export type SpaceCommentResult = typeof SpaceCommentResult.Type;

// Errors

/** A Space request the MC refused: something missing, a page in the trash, a move into itself. */
export class SpaceError extends Schema.TaggedError<SpaceError>()("SpaceError", {
  message: Schema.String,
  reason: Schema.Literals(["invalid", "notFound", "trashed", "notEmpty", "cycle"]),
}) {}

/** A page could not be written from a thread: no text generation provider, or it failed. */
export class SpaceTextGenerationError extends Schema.TaggedError<SpaceTextGenerationError>()(
  "SpaceTextGenerationError",
  {
    message: Schema.String,
    reason: Schema.Literals(["unavailable", "failed"]),
  },
) {}
