import * as Schema from "effect/Schema";

import {
  IsoDateTime,
  NonNegativeInt,
  PositiveInt,
  SpaceBlockId,
  SpaceCommentId,
  SpaceId,
  SpaceImageId,
  SpacePageId,
  ThreadId,
  TrimmedNonEmptyString,
} from "./baseSchemas.ts";

/**
 * Spaces hold Pages that people and agents write together. Clients read them
 * from streams, the same subscribe/resume path as projects and threads:
 * `SPACES_STREAM_ID` holds one `space` entity per Space, and `spaceStreamId(id)`
 * holds that Space's `page`, `block`, `comment`, `image`, `site` and `pageAgent` entities. The RPCs
 * below change them. An image's bytes are never on a stream: fetch them on demand from the
 * address `assets.createUrl` signs for a `space-image`.
 */
export const SPACES_STREAM_ID = "spaces";

export const spaceStreamId = (spaceId: SpaceId) => `space:${spaceId}`;

/** Who wrote something: the user, or the agent of a thread. */
export const SpaceAuthor = Schema.Union([
  Schema.Struct({ type: Schema.Literal("user") }),
  Schema.Struct({ type: Schema.Literal("agent"), threadId: ThreadId }),
]);
export type SpaceAuthor = typeof SpaceAuthor.Type;

export const Space = Schema.Struct({
  id: SpaceId,
  name: TrimmedNonEmptyString,
  createdAt: IsoDateTime,
  updatedAt: IsoDateTime,
});
export type Space = typeof Space.Type;

export const SpacePage = Schema.Struct({
  id: SpacePageId,
  spaceId: SpaceId,
  title: TrimmedNonEmptyString,
  parentPageId: Schema.NullOr(SpacePageId),
  /** The thread the page was made from, if any. */
  sourceThreadId: Schema.NullOr(ThreadId),
  /** Set while the page is in the trash. Its subpages are hidden with it. */
  trashedAt: Schema.NullOr(IsoDateTime),
  createdAt: IsoDateTime,
  updatedAt: IsoDateTime,
});
export type SpacePage = typeof SpacePage.Type;

export const SpaceBlockKind = Schema.Literals([
  "paragraph",
  "heading",
  "checklist",
  "callout",
  "subpage_link",
  "image",
]);
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
  /** The image an `image` block shows; its `text` is the caption. Only on image blocks. */
  imageId: Schema.optional(SpaceImageId),
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

/** Deletes a Space that has no pages or images, in the trash or out of it. */
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

/** A new page summarising a thread, written by text generation in the thread's project. */
export const SpacePageCreateFromThreadInput = Schema.Struct({
  spaceId: SpaceId,
  threadId: ThreadId,
  parentPageId: Schema.optional(Schema.NullOr(SpacePageId)),
});
export type SpacePageCreateFromThreadInput = typeof SpacePageCreateFromThreadInput.Type;

// Blocks

/**
 * Where a block goes on its page: after `afterBlockId`, first with null, or last
 * when it is left out.
 */
const AfterBlockId = Schema.optional(Schema.NullOr(SpaceBlockId));

export const SpaceBlockInsertInput = Schema.Struct({
  spaceId: SpaceId,
  pageId: SpacePageId,
  kind: SpaceBlockKind,
  text: Schema.optional(Schema.String),
  checked: Schema.optional(Schema.Boolean),
  /** Required for `subpage_link`, which shows that page's title. */
  linkedPageId: Schema.optional(SpacePageId),
  /** Required for `image`: an image of this Space not in the trash. */
  imageId: Schema.optional(SpaceImageId),
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
  reason: Schema.Literals(["invalid", "notFound", "trashed", "notEmpty", "cycle", "unavailable"]),
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
