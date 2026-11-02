import * as Schema from "effect/Schema";

import {
  IsoDateTime,
  NonNegativeInt,
  PositiveInt,
  ProjectId,
  SpaceBlockId,
  SpaceCommentId,
  SpaceDeckId,
  SpaceId,
  SpaceImageId,
  SpacePageId,
  SpaceSlideId,
  ThreadId,
  TrimmedNonEmptyString,
} from "./baseSchemas.ts";
import { ScheduledTaskRunStatus, ScheduledTaskUpsertSchedule } from "./scheduledTask.ts";

/**
 * Spaces hold Pages that people and agents write together, and slide decks. Clients
 * read them from streams, the same subscribe/resume path as projects and threads:
 * `SPACES_STREAM_ID` holds one `space` entity per Space, and `spaceStreamId(id)`
 * holds that Space's `page`, `block`, `comment`, `image`, `site`, `deck`, `slide` and `pageAgent`
 * entities. The RPCs below change them. An image's bytes are never on a stream: fetch them on
 * demand from the address `assets.createUrl` signs for a `space-image`.
 */
export const SPACES_STREAM_ID = "spaces";

export const spaceStreamId = (spaceId: SpaceId) => `space:${spaceId}`;

/**
 * Who wrote something: the user, the agent of a thread, a page's own update, or the
 * project file a page is (what the page took from its file).
 */
export const SpaceAuthor = Schema.Union([
  Schema.Struct({ type: Schema.Literal("user") }),
  Schema.Struct({ type: Schema.Literal("agent"), threadId: ThreadId }),
  Schema.Struct({ type: Schema.Literal("schedule") }),
  Schema.Struct({ type: Schema.Literal("file") }),
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

/**
 * The project file a page is. The MC that has the project writes the page to the file
 * and takes the file's changes onto the page; clients never touch the file.
 */
export const SpacePageFile = Schema.Struct({
  projectId: ProjectId,
  /** The file's path in the project's own folder, never a thread's worktree. */
  path: TrimmedNonEmptyString,
  /** The SHA-256 of what the page last read or wrote there, in lowercase hex. */
  hash: Schema.String,
  size: NonNegativeInt,
  /** True while the file is gone (deleted, or not on the branch checked out). */
  missing: Schema.Boolean,
  /**
   * When the file last won over an edit on the page, the edit being a version in the
   * page's history; null once an edit reaches the file again.
   */
  conflictAt: Schema.NullOr(IsoDateTime),
});
export type SpacePageFile = typeof SpacePageFile.Type;

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
  /** The project file the page is, if it is one. */
  file: Schema.optional(Schema.NullOr(SpacePageFile)),
  createdAt: IsoDateTime,
  updatedAt: IsoDateTime,
});
export type SpacePage = typeof SpacePage.Type;

/**
 * The kinds of block that can be written by hand. A `raw` block is Markdown a page does
 * not model, kept as its source and shown as written, so a page imported from Markdown
 * exports exactly as it was. A `table`'s text is its Markdown, written by the MC; a
 * `code` block's text is the code.
 */
export const SpaceWritableBlockKind = Schema.Literals([
  "paragraph",
  "heading",
  "checklist",
  "callout",
  "subpage_link",
  "image",
  "table",
  "code",
  "raw",
]);
export type SpaceWritableBlockKind = typeof SpaceWritableBlockKind.Type;

/**
 * A `generated` block is the marked part of a page that updates itself: at most one on
 * a page, its text is the Markdown of the last run, and only a run writes it. It can be
 * moved, deleted and commented on. A `chart` is only made by `space.block.visualize`.
 */
export const SpaceBlockKind = Schema.Literals([
  ...SpaceWritableBlockKind.literals,
  "chart",
  "generated",
]);
export type SpaceBlockKind = typeof SpaceBlockKind.Type;

/** The limits of a chart, in UTF-8 bytes for text. `HalC2.Space.Chart` enforces them. */
export const SPACE_CHART_LIMITS = {
  labels: 24,
  series: 4,
  titleBytes: 120,
  labelBytes: 40,
  requestBytes: 200,
  sourceBytes: 160,
  value: 1e15,
} as const;

/** Plain text a client shows as it is, and never interprets. */
const SpaceChartText = (maxLength: number) => Schema.String.check(Schema.isMaxLength(maxLength));

/**
 * A chart our own drawing code draws: data only, with no URL, script, QML or formatting.
 * The MC refuses anything else, and clients still treat every field as untrusted text.
 * Values are from zero up, one per label.
 */
export const SpaceChart = Schema.Struct({
  type: Schema.Literals(["bar", "line"]),
  title: SpaceChartText(SPACE_CHART_LIMITS.titleBytes),
  labels: Schema.Array(SpaceChartText(SPACE_CHART_LIMITS.labelBytes)).check(
    Schema.isMaxLength(SPACE_CHART_LIMITS.labels),
  ),
  series: Schema.Array(
    Schema.Struct({
      name: SpaceChartText(SPACE_CHART_LIMITS.labelBytes),
      values: Schema.Array(Schema.Finite).check(Schema.isMaxLength(SPACE_CHART_LIMITS.labels)),
    }),
  ).check(Schema.isMaxLength(SPACE_CHART_LIMITS.series)),
  /** What was asked for, offered again when the user asks again. */
  request: SpaceChartText(SPACE_CHART_LIMITS.requestBytes),
  /** Where the numbers came from, written by the MC and not the model. */
  source: SpaceChartText(SPACE_CHART_LIMITS.sourceBytes),
});
export type SpaceChart = typeof SpaceChart.Type;

export const SpaceHeadingLevel = Schema.Int.check(Schema.isBetween({ minimum: 1, maximum: 6 }));

/** How a table's column aligns; null is as the reader likes. */
export const SpaceTableAlign = Schema.NullOr(Schema.Literals(["left", "center", "right"]));
export type SpaceTableAlign = typeof SpaceTableAlign.Type;

/**
 * A table: the header row first in `rows`, every row a cell per column, each cell one
 * line of inline Markdown. `widths` (how wide its Markdown pads each column),
 * `ruleWidths` (how wide its rule row's marks are, when not `widths`) and `tight` (its
 * rule row has no spaces) keep the Markdown as it was written; clients do not show them.
 */
export const SpaceTable = Schema.Struct({
  align: Schema.Array(SpaceTableAlign),
  rows: Schema.Array(Schema.Array(Schema.String)),
  widths: Schema.Array(Schema.Int),
  ruleWidths: Schema.optional(Schema.Array(Schema.Int)),
  tight: Schema.optional(Schema.Boolean),
});
export type SpaceTable = typeof SpaceTable.Type;

/** What `space.block.insert` takes for a table: its cells, and how its columns align. */
export const SpaceTableInput = Schema.Struct({
  rows: Schema.Array(Schema.Array(Schema.String)),
  align: Schema.optional(Schema.Array(SpaceTableAlign)),
});
export type SpaceTableInput = typeof SpaceTableInput.Type;

/** A code block's language: one word, such as `elixir` or `mermaid`. */
export const SpaceCodeLanguage = Schema.String.check(Schema.isPattern(/^\S+$/u));

export const SpaceBlock = Schema.Struct({
  id: SpaceBlockId,
  pageId: SpacePageId,
  kind: SpaceBlockKind,
  text: Schema.String,
  /** Ticked; always false for blocks that are not checklist items. */
  checked: Schema.Boolean,
  /** The page a `subpage_link` block points at. */
  linkedPageId: Schema.NullOr(SpacePageId),
  /** A heading's level, 1 to 6 as the number of `#` in Markdown; 2 when left out. */
  level: Schema.optional(SpaceHeadingLevel),
  /**
   * The blank lines above a block imported from Markdown, when they are not the usual
   * one, so its export writes them back. Clients do not show it.
   */
  gap: Schema.optional(Schema.String),
  /** What a `chart` block draws. Its `text` says what it is, for clients that do not draw it. */
  chart: Schema.optional(SpaceChart),
  /** The image an `image` block shows; its `text` is the caption. Only on image blocks. */
  imageId: Schema.optional(SpaceImageId),
  /** A `table` block's cells. Its `text` is the table's Markdown. */
  table: Schema.optional(SpaceTable),
  /** A `code` block's language, when it has one. */
  language: Schema.optional(Schema.String),
  /**
   * The fence a `code` block imported from Markdown was written with, when it is not
   * three backticks, and the rest of its line after the language. Clients do not show them.
   */
  fence: Schema.optional(Schema.String),
  info: Schema.optional(Schema.String),
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

export const SpaceDeck = Schema.Struct({
  id: SpaceDeckId,
  spaceId: SpaceId,
  title: TrimmedNonEmptyString,
  /** Set while the deck is in the trash. */
  trashedAt: Schema.NullOr(IsoDateTime),
  createdAt: IsoDateTime,
  updatedAt: IsoDateTime,
});
export type SpaceDeck = typeof SpaceDeck.Type;

export const SpaceSlide = Schema.Struct({
  id: SpaceSlideId,
  deckId: SpaceDeckId,
  /** May be blank: a new slide starts that way. */
  title: Schema.String,
  /** Plain text, its lines apart by line breaks. */
  body: Schema.String,
  /** Sorts the deck's slides as `SpaceBlock.order` sorts a page's blocks. */
  order: Schema.String,
  createdAt: IsoDateTime,
  updatedAt: IsoDateTime,
});
export type SpaceSlide = typeof SpaceSlide.Type;

/** A provider and model, as chosen for anything else in HAL-C2. */
const SpaceImageSelection = Schema.Struct({
  instanceId: TrimmedNonEmptyString,
  model: Schema.optional(Schema.String),
});

/**
 * What is known about an image a Space keeps, not its bytes. Any number of blocks may
 * show one image; a block whose image has left says so.
 */
export const SpaceImage = Schema.Struct({
  id: SpaceImageId,
  spaceId: SpaceId,
  name: TrimmedNonEmptyString,
  /** Read from the file's content: image/png, image/jpeg, image/gif or image/webp. */
  mimeType: TrimmedNonEmptyString,
  sizeBytes: Schema.Number,
  width: Schema.Number,
  height: Schema.Number,
  /** What it was generated from; null for an image added from a file. */
  prompt: Schema.NullOr(Schema.String),
  /** The provider and model that made it; null for an image added from a file. */
  generatedBy: Schema.NullOr(SpaceImageSelection),
  /** Set while the image is in the trash. */
  trashedAt: Schema.NullOr(IsoDateTime),
  createdBy: SpaceAuthor,
  createdAt: IsoDateTime,
  updatedAt: IsoDateTime,
});
export type SpaceImage = typeof SpaceImage.Type;

// Spaces

/** Lists the Spaces, making the "Personal" Space first if there are none. */
export const SpaceListInput = Schema.Struct({});
export const SpaceListResult = Schema.Struct({ spaces: Schema.Array(Space) });
export type SpaceListResult = typeof SpaceListResult.Type;

export const SpaceCreateInput = Schema.Struct({ name: TrimmedNonEmptyString });
export type SpaceCreateInput = typeof SpaceCreateInput.Type;

export const SpaceRenameInput = Schema.Struct({ spaceId: SpaceId, name: TrimmedNonEmptyString });
export type SpaceRenameInput = typeof SpaceRenameInput.Type;

/** Deletes a Space that has no pages, decks or images, in the trash or out of it. */
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

/** A block as a published site shows it. A link to another page is only that page's title. */
export const SpaceSiteBlock = Schema.Struct({
  kind: SpaceBlockKind,
  text: Schema.String,
  checked: Schema.optional(Schema.Boolean),
  table: Schema.optional(
    Schema.Struct({ align: SpaceTable.fields.align, rows: SpaceTable.fields.rows }),
  ),
  language: Schema.optional(Schema.String),
});
export type SpaceSiteBlock = typeof SpaceSiteBlock.Type;

/**
 * A page published as a site, one per page, in the Space's stream. `id` is the secret in
 * `url`: anyone holding the link reads `snapshot`, the page as it was at `publishedAt`,
 * and nothing else. `behind` says the page has changed since. `localOnly` says only the
 * MC's own machine can open `url`.
 */
export const SpaceSite = Schema.Struct({
  id: TrimmedNonEmptyString,
  spaceId: SpaceId,
  pageId: SpacePageId,
  url: TrimmedNonEmptyString,
  localOnly: Schema.Boolean,
  publishedAt: IsoDateTime,
  behind: Schema.Boolean,
  snapshot: Schema.Struct({
    title: TrimmedNonEmptyString,
    blocks: Schema.Array(SpaceSiteBlock),
  }),
});
export type SpaceSite = typeof SpaceSite.Type;

/**
 * Publishes a live page, or brings its site up to date under the same link. The link is
 * on `baseUrl` when the caller knows an address others reach the MC at, over Tailscale
 * with `tailscale` (which needs `access:write`), else on the address the MC listens on.
 */
export const SpacePagePublishInput = Schema.Struct({
  spaceId: SpaceId,
  pageId: SpacePageId,
  baseUrl: Schema.optional(TrimmedNonEmptyString),
  tailscale: Schema.optional(Schema.Boolean),
});
export type SpacePagePublishInput = typeof SpacePagePublishInput.Type;

export const SpacePagePublishResult = Schema.Struct({ site: SpaceSite });
export type SpacePagePublishResult = typeof SpacePagePublishResult.Type;

/** Takes the page's site down for good: publishing later makes a new link. */
export const SpacePageUnpublishResult = Schema.Struct({ pageId: SpacePageId });
export type SpacePageUnpublishResult = typeof SpacePageUnpublishResult.Type;

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

// Project files as pages

/**
 * The page of a project file, made in `spaceId` when the file has none, or the page it
 * already is wherever it is (brought back from the trash and read again). Only files
 * the project's `spaces` section counts open. `relativePath` is in the project's folder.
 */
export const SpacePageOpenFileInput = Schema.Struct({
  spaceId: SpaceId,
  projectId: ProjectId,
  relativePath: TrimmedNonEmptyString,
});
export type SpacePageOpenFileInput = typeof SpacePageOpenFileInput.Type;

export const SpacePageOpenFileResult = Schema.Struct({
  /** The Space the page is in, which is not `spaceId` when it was opened elsewhere. */
  spaceId: SpaceId,
  page: SpacePage,
  created: Schema.Boolean,
});
export type SpacePageOpenFileResult = typeof SpacePageOpenFileResult.Type;

/** Which of a project's files are Space content: `space.files.list`, `space.files.scan`. */
export const SpaceFilesProjectInput = Schema.Struct({ projectId: ProjectId });
export type SpaceFilesProjectInput = typeof SpaceFilesProjectInput.Type;

/** A Space file kind the `spaces` section of hal-c2.json can name. */
export const SpaceFileKind = Schema.Literals(["page"]);
export type SpaceFileKind = typeof SpaceFileKind.Type;

/** One entry of the `spaces` section: a path glob (`*`, `**`, `?`) and its kind. */
export const SpaceFileEntry = Schema.Struct({ path: Schema.String, kind: SpaceFileKind });
export type SpaceFileEntry = typeof SpaceFileEntry.Type;

export const SpaceFilesListResult = Schema.Struct({
  /**
   * Where the entries come from: the project's `spaces` section, the default (every
   * Markdown file a page) when it has none, or a section that does not match the format,
   * which counts no files.
   */
  config: Schema.Literals(["project", "default", "invalid"]),
  files: Schema.Array(
    Schema.Struct({
      relativePath: Schema.String,
      kind: SpaceFileKind,
      page: Schema.NullOr(
        Schema.Struct({ spaceId: SpaceId, pageId: SpacePageId, title: Schema.String }),
      ),
    }),
  ),
});
export type SpaceFilesListResult = typeof SpaceFilesListResult.Type;

export const SpaceFilesScanInput = Schema.Struct({
  projectId: ProjectId,
  /** Write over a `spaces` section someone already wrote. */
  replace: Schema.optional(Schema.Boolean),
});
export type SpaceFilesScanInput = typeof SpaceFilesScanInput.Type;

/**
 * What the scan proposed (`entries`) and did: `written` to hal-c2.json, `current` when
 * the section already says it, `kept` when someone wrote a different one (re-run with
 * `replace`), `empty` when the project has no Markdown and nothing was written.
 */
export const SpaceFilesScanResult = Schema.Struct({
  status: Schema.Literals(["written", "current", "kept", "empty"]),
  entries: Schema.Array(SpaceFileEntry),
});
export type SpaceFilesScanResult = typeof SpaceFilesScanResult.Type;

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
  /** Required for `image`: an image of this Space not in the trash. */
  imageId: Schema.optional(SpaceImageId),
  /** For `heading`: 1 to 6, 2 when left out. */
  level: Schema.optional(SpaceHeadingLevel),
  /** Required for `table`. Its `text` is written from it. */
  table: Schema.optional(SpaceTableInput),
  /** For `code`. */
  language: Schema.optional(SpaceCodeLanguage),
  afterBlockId: AfterBlockId,
});
export type SpaceBlockInsertInput = typeof SpaceBlockInsertInput.Type;

/**
 * Changes what is given in one step, or nothing. A table's `text` is read as a table,
 * kept as written when it is in the table's own form; `level` is a heading's, and
 * `language` a code block's, null for none.
 */
export const SpaceBlockUpdateInput = Schema.Struct({
  spaceId: SpaceId,
  blockId: SpaceBlockId,
  text: Schema.optional(Schema.String),
  level: Schema.optional(SpaceHeadingLevel),
  language: Schema.optional(Schema.NullOr(SpaceCodeLanguage)),
});
export type SpaceBlockUpdateInput = typeof SpaceBlockUpdateInput.Type;

/**
 * One edit of a table, where it stands. Rows count from the header, row 0, which stays;
 * `insertRow` puts a blank row at `at`, 1 or more. A table keeps one column at least.
 */
export const SpaceTableEdit = Schema.Union([
  Schema.Struct({
    type: Schema.Literal("setCell"),
    row: Schema.Int,
    column: Schema.Int,
    text: Schema.String,
  }),
  Schema.Struct({ type: Schema.Literal("insertRow"), at: Schema.Int }),
  Schema.Struct({ type: Schema.Literal("deleteRow"), row: Schema.Int }),
  Schema.Struct({
    type: Schema.Literal("insertColumn"),
    at: Schema.Int,
    align: Schema.optional(SpaceTableAlign),
  }),
  Schema.Struct({ type: Schema.Literal("deleteColumn"), column: Schema.Int }),
  Schema.Struct({ type: Schema.Literal("setAlign"), column: Schema.Int, align: SpaceTableAlign }),
]);
export type SpaceTableEdit = typeof SpaceTableEdit.Type;

/** Edits a `table` block's cells; its `text` is written again, only the rows it changes. */
export const SpaceBlockEditTableInput = Schema.Struct({
  spaceId: SpaceId,
  blockId: SpaceBlockId,
  edit: SpaceTableEdit,
});
export type SpaceBlockEditTableInput = typeof SpaceBlockEditTableInput.Type;

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

// The agent asked from inside a page

/** An agent's state on its page: `stopping` until the runs it was stopped in have ended. */
export const SpacePageAgentStatus = Schema.Literals([
  "running",
  "stopping",
  "completed",
  "failed",
  "stopped",
]);
export type SpacePageAgentStatus = typeof SpacePageAgentStatus.Type;

/** A `pageAgent` entity, keyed by its page: the agent asked last on that page. */
export const SpacePageAgent = Schema.Struct({
  id: SpacePageId,
  pageId: SpacePageId,
  /** An ordinary thread, which the page links to. */
  threadId: ThreadId,
  request: Schema.String,
  status: SpacePageAgentStatus,
  /** Set when the agent ends: whether page history holds an edit of its thread. */
  edited: Schema.Boolean,
  /** Why it failed, or why it stopped when the user did not stop it. */
  error: Schema.NullOr(Schema.String),
  startedAt: IsoDateTime,
  endedAt: Schema.NullOr(IsoDateTime),
});
export type SpacePageAgent = typeof SpacePageAgent.Type;

export const SpacePageAskAgentInput = Schema.Struct({
  spaceId: SpaceId,
  pageId: SpacePageId,
  /** What the agent should do; a leading `@agent` is not part of it. */
  request: Schema.String,
});
export type SpacePageAskAgentInput = typeof SpacePageAskAgentInput.Type;

/** Names a page for `space.page.stopAgent` and `space.page.dismissAgent`. */
export const SpacePageAgentRef = Schema.Struct({
  spaceId: SpaceId,
  pageId: SpacePageId,
});
export type SpacePageAgentRef = typeof SpacePageAgentRef.Type;

export const SpacePageAgentResult = Schema.Struct({ agent: SpacePageAgent });
export type SpacePageAgentResult = typeof SpacePageAgentResult.Type;

export const SpacePageDismissAgentResult = Schema.Struct({ pageId: SpacePageId });
export type SpacePageDismissAgentResult = typeof SpacePageDismissAgentResult.Type;

// A page's history (read on demand; never on the stream)

/**
 * Names a version: the event-log position of its last edit. Any position reads the
 * page as it stood there, so a name stays good when its run of edits grows.
 */
export const SpacePageVersionId = NonNegativeInt;
export type SpacePageVersionId = typeof SpacePageVersionId.Type;

/** For `space.page.history`: from the newest version, or `before` the one given. */
export const SpacePageHistoryInput = Schema.Struct({
  spaceId: SpaceId,
  pageId: SpacePageId,
  before: Schema.optional(SpacePageVersionId),
  /** How many versions to send; the MC caps it. */
  limit: Schema.optional(PositiveInt),
});
export type SpacePageHistoryInput = typeof SpacePageHistoryInput.Type;

/** One author's run of edits on a page. */
export const SpacePageVersion = Schema.Struct({
  version: SpacePageVersionId,
  /** When its last edit was written. */
  at: IsoDateTime,
  author: SpaceAuthor,
  /** The title of the agent's thread, while it still exists. */
  threadTitle: Schema.NullOr(Schema.String),
  /** When the version this one restored was written, if it is a restore. */
  restoredFromAt: Schema.NullOr(IsoDateTime),
});
export type SpacePageVersion = typeof SpacePageVersion.Type;

export const SpacePageHistoryResult = Schema.Struct({
  /** Newest first. */
  versions: Schema.Array(SpacePageVersion),
  /** What to pass as `before` for the next stretch; null at the oldest. */
  nextBefore: Schema.NullOr(SpacePageVersionId),
});
export type SpacePageHistoryResult = typeof SpacePageHistoryResult.Type;

/** Names one version for `space.page.version` and `space.page.restoreVersion`. */
export const SpacePageVersionRef = Schema.Struct({
  spaceId: SpaceId,
  pageId: SpacePageId,
  version: SpacePageVersionId,
});
export type SpacePageVersionRef = typeof SpacePageVersionRef.Type;

/** A version's title and blocks, without its comments, which are not versioned. */
export const SpacePageVersionContent = Schema.Struct({
  version: SpacePageVersionId,
  at: IsoDateTime,
  title: Schema.String,
  blocks: Schema.Array(SpaceBlock),
});
export type SpacePageVersionContent = typeof SpacePageVersionContent.Type;

// Decks

/** A new deck with one blank slide. */
export const SpaceDeckCreateInput = Schema.Struct({
  spaceId: SpaceId,
  title: TrimmedNonEmptyString,
});
export type SpaceDeckCreateInput = typeof SpaceDeckCreateInput.Type;

/**
 * A new deck copied from a live page, named after it: one slide per heading and what
 * follows it, with anything before the first heading on a slide under the page's title.
 * Later edits of the page do not reach the deck.
 */
export const SpaceDeckCreateFromPageInput = Schema.Struct({
  spaceId: SpaceId,
  pageId: SpacePageId,
});
export type SpaceDeckCreateFromPageInput = typeof SpaceDeckCreateFromPageInput.Type;

export const SpaceDeckRenameInput = Schema.Struct({
  spaceId: SpaceId,
  deckId: SpaceDeckId,
  title: TrimmedNonEmptyString,
});
export type SpaceDeckRenameInput = typeof SpaceDeckRenameInput.Type;

/**
 * Names one deck for `space.deck.trash`, `space.deck.restore` and `space.deck.delete`.
 * Only a deck in the trash can be deleted; its slides go with it.
 */
export const SpaceDeckRef = Schema.Struct({ spaceId: SpaceId, deckId: SpaceDeckId });
export type SpaceDeckRef = typeof SpaceDeckRef.Type;

export const SpaceDeckResult = Schema.Struct({ deck: SpaceDeck });
export type SpaceDeckResult = typeof SpaceDeckResult.Type;

export const SpaceDeckDeleteResult = Schema.Struct({ deckId: SpaceDeckId });
export type SpaceDeckDeleteResult = typeof SpaceDeckDeleteResult.Type;

// Slides

/**
 * Where a slide goes in its deck: after `afterSlideId`, first with null, or last when
 * it is left out.
 */
const AfterSlideId = Schema.optional(Schema.NullOr(SpaceSlideId));

export const SpaceSlideInsertInput = Schema.Struct({
  spaceId: SpaceId,
  deckId: SpaceDeckId,
  title: Schema.optional(Schema.String),
  body: Schema.optional(Schema.String),
  afterSlideId: AfterSlideId,
});
export type SpaceSlideInsertInput = typeof SpaceSlideInsertInput.Type;

/** Changes what is given of a slide's title and body. */
export const SpaceSlideUpdateInput = Schema.Struct({
  spaceId: SpaceId,
  slideId: SpaceSlideId,
  title: Schema.optional(Schema.String),
  body: Schema.optional(Schema.String),
});
export type SpaceSlideUpdateInput = typeof SpaceSlideUpdateInput.Type;

export const SpaceSlideMoveInput = Schema.Struct({
  spaceId: SpaceId,
  slideId: SpaceSlideId,
  afterSlideId: AfterSlideId,
});
export type SpaceSlideMoveInput = typeof SpaceSlideMoveInput.Type;

export const SpaceSlideDeleteInput = Schema.Struct({ spaceId: SpaceId, slideId: SpaceSlideId });
export type SpaceSlideDeleteInput = typeof SpaceSlideDeleteInput.Type;

export const SpaceSlideResult = Schema.Struct({ slide: SpaceSlide });
export type SpaceSlideResult = typeof SpaceSlideResult.Type;

export const SpaceSlideDeleteResult = Schema.Struct({ slideId: SpaceSlideId });
export type SpaceSlideDeleteResult = typeof SpaceSlideDeleteResult.Type;

// Images

/**
 * Keeps an upload as an image, if its content is a PNG, JPEG, GIF or WebP. Upload with
 * `attachments.createUploadUrl` first; the upload is used up whatever the answer.
 */
export const SpaceImageAddInput = Schema.Struct({
  spaceId: SpaceId,
  attachmentId: TrimmedNonEmptyString,
  name: TrimmedNonEmptyString,
});
export type SpaceImageAddInput = typeof SpaceImageAddInput.Type;

/**
 * An image from a prompt, made by the coding agent of `modelSelection`, or of the
 * selection `space.image.providers` names when it is left out. Takes as long as the
 * agent does, up to 5 minutes.
 */
export const SpaceImageGenerateInput = Schema.Struct({
  spaceId: SpaceId,
  prompt: TrimmedNonEmptyString,
  modelSelection: Schema.optional(SpaceImageSelection),
});
export type SpaceImageGenerateInput = typeof SpaceImageGenerateInput.Type;

/**
 * Names one image for `space.image.trash`, `space.image.restore` and
 * `space.image.delete`. Only an image in the trash can be deleted; its file goes with it.
 */
export const SpaceImageRef = Schema.Struct({ spaceId: SpaceId, imageId: SpaceImageId });
export type SpaceImageRef = typeof SpaceImageRef.Type;

export const SpaceImageResult = Schema.Struct({ image: SpaceImage });
export type SpaceImageResult = typeof SpaceImageResult.Type;

export const SpaceImageDeleteResult = Schema.Struct({ imageId: SpaceImageId });
export type SpaceImageDeleteResult = typeof SpaceImageDeleteResult.Type;

export const SpaceImageProvider = Schema.Struct({
  instanceId: TrimmedNonEmptyString,
  driver: TrimmedNonEmptyString,
  status: Schema.Literals(["ready", "unavailable", "unsupported"]),
  /** Why it cannot make an image; null when it can. */
  message: Schema.NullOr(Schema.String),
});
export type SpaceImageProvider = typeof SpaceImageProvider.Type;

/** Which providers can make an image, and which is used when the user does not choose. */
export const SpaceImageProvidersResult = Schema.Struct({
  providers: Schema.Array(SpaceImageProvider),
  selection: Schema.NullOr(SpaceImageSelection),
});
export type SpaceImageProvidersResult = typeof SpaceImageProvidersResult.Type;

// Errors

/** A Space request the MC refused: something missing, a page in the trash, a move into itself. */
export class SpaceError extends Schema.TaggedError<SpaceError>()("SpaceError", {
  message: Schema.String,
  reason: Schema.Literals([
    "invalid",
    "notFound",
    "trashed",
    "notEmpty",
    "cycle",
    "unavailable",
    /** The project's `spaces` section does not count the file. */
    "notSpaceFile",
    /** What a page that is a file cannot have: a chart, an update of its own. */
    "fileBacked",
  ]),
}) {}

/**
 * A chart from `request` ("weekly turns"), drawn from what the MC counts or what the page
 * says, or refused. A new block goes where `afterBlockId` says; with `blockId` the chart
 * in that block is replaced where it is, and stays as it was if this fails.
 */
export const SpaceBlockVisualizeInput = Schema.Struct({
  spaceId: SpaceId,
  pageId: SpacePageId,
  request: Schema.String.check(Schema.isMaxLength(SPACE_CHART_LIMITS.requestBytes)),
  blockId: Schema.optional(SpaceBlockId),
  afterBlockId: AfterBlockId,
});
export type SpaceBlockVisualizeInput = typeof SpaceBlockVisualizeInput.Type;

/**
 * No chart was drawn: no text generation provider (`unavailable`), it failed or its answer
 * was refused (`failed`), or real data cannot answer the request (`unanswerable`).
 */
export class SpaceChartError extends Schema.TaggedError<SpaceChartError>()("SpaceChartError", {
  message: Schema.String,
  reason: Schema.Literals(["unavailable", "failed", "unanswerable"]),
}) {}

/** A page could not be written from a thread: no text generation provider, or it failed. */
export class SpaceTextGenerationError extends Schema.TaggedError<SpaceTextGenerationError>()(
  "SpaceTextGenerationError",
  {
    message: Schema.String,
    reason: Schema.Literals(["unavailable", "failed"]),
  },
) {}

/**
 * An image could not be generated: this provider cannot, none is available, or the
 * agent failed or left no image.
 */
export class SpaceImageGenerationError extends Schema.TaggedError<SpaceImageGenerationError>()(
  "SpaceImageGenerationError",
  {
    message: Schema.String,
    reason: Schema.Literals(["unsupported", "unavailable", "failed"]),
  },
) {}

// Presence

/**
 * Follows who else has a page open (the `spacePresence` shape). Subscribing is what
 * puts this client on the page; it leaves by unsubscribing or by its connection going.
 * Nothing about it is stored, and it sends only when the viewers of this page change.
 */
export const SpacePresenceSubscribeInput = Schema.Struct({
  spaceId: SpaceId,
  pageId: SpacePageId,
});
export type SpacePresenceSubscribeInput = typeof SpacePresenceSubscribeInput.Type;

/**
 * Someone else on the page. HAL-C2 has no accounts, so every paired device is the one
 * user: `devices` names the user's other devices on the page, and there is at most one
 * such viewer. An agent is on the page it last read or wrote while its turn runs.
 */
export const SpacePresenceViewer = Schema.Union([
  Schema.Struct({
    type: Schema.Literal("user"),
    devices: Schema.Array(TrimmedNonEmptyString),
  }),
  Schema.Struct({
    type: Schema.Literal("agent"),
    threadId: ThreadId,
    title: TrimmedNonEmptyString,
  }),
]);
export type SpacePresenceViewer = typeof SpacePresenceViewer.Type;

export const SpacePresenceStreamEvent = Schema.Struct({
  viewers: Schema.Array(SpacePresenceViewer),
});
export type SpacePresenceStreamEvent = typeof SpacePresenceStreamEvent.Type;
