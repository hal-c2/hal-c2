import type {
  MermaidRenderResult,
  OrchestrationCheckpointSummary,
  OrchestrationThread,
  TimestampFormat,
} from "@hal-c2/contracts";

import type {
  TuiMessageIntent,
  TuiQueuedMessage,
  TuiThreadExtras,
} from "../orchestrationV2Adapter.ts";
import { shouldCollapseUserMessage } from "@hal-c2/shared/chatMessages";

import { CHAT_CONTENT_MAX_WIDTH } from "../layout.ts";
import { deriveContextWindow, formatContextWindow } from "../contextWindow.ts";
import { buildFileTree, collectDirPaths, flattenFileTree } from "../fileTree.ts";
import { clip } from "../format.ts";
import { runnableShellCommand } from "../shellRun.ts";
import { formatChatTimestampTooltip, formatDayAwareTimestamp } from "../timestampFormat.ts";
import { fileGlyph, fileTypeColor, STATUS_ICONS, TOOL_ICONS } from "../icons.ts";
import { latestActionableProposedPlan } from "../proposedPlan.ts";
import { ansi, type Palette, relativeTime, sessionStatusColor } from "../theme.ts";
import {
  changedFilesByMessage,
  deriveTimelineEntries,
  diffStat,
  type FoldableRow,
  formatWorkingTimer,
  isWorking,
  MAX_VISIBLE_WORK_LOG_ENTRIES,
  type TimelineRow,
  workingElapsedSeconds,
  workingStartedAt,
} from "../timeline.ts";
import { linkifyTimelineUrls } from "../timelineLinks.ts";
import { commandDisplayText, summarizeToolCalls, workspaceRelative } from "../toolSummary.ts";
import {
  workLogIcon,
  workLogLabel,
  workLogPreview,
  workLogStatusKind,
  workLogStatusLabel,
  type WorkLogEntry,
} from "../worklog.ts";
import type { AttachmentPreview, AttachmentPreviews } from "./attachmentPreviews.ts";
import { tableToCsv, tableToMarkdown } from "../markdownTable.ts";
import { threadKey } from "./sidebarState.ts";
import {
  chunk,
  markdownBlockLines,
  type CodeColouring,
  markdownLines,
  plainText,
  styled,
  type StyledText,
} from "./styledText.ts";

// The conversation as published under `timeline` (port of MessagesTimeline):
// every row pre-styled, with the action a click dispatches, so the Timeline
// brick is a Repeater over items and lines.

/** Rows mounted at once; older rows sit behind "▴ N earlier entries". */
export const TIMELINE_WINDOW_SIZE = 80;
/** Rows a collapsed long user message keeps. */
export const COLLAPSED_USER_MESSAGE_ROWS = 8;
const CHANGED_FILES_ROW_CAP = 40;

export function resolveTimelineWindow(
  rowCount: number,
  requestedEnd: number | null,
): { readonly start: number; readonly end: number } {
  const end = Math.min(rowCount, Math.max(0, requestedEnd ?? rowCount));
  return { start: Math.max(0, end - TIMELINE_WINDOW_SIZE), end };
}

/** View state the host keeps per thread for the timeline. */
export interface TimelineView {
  /** Work groups the user flipped from how they start (a stopped turn's start open). */
  readonly expandedGroups: ReadonlySet<string>;
  /** Turn folds the user flipped from how they start (folded, or open for `openTurns`). */
  readonly expandedFolds: ReadonlySet<string>;
  readonly expandedMessages: ReadonlySet<string>;
  /** Collapsed changed-files folders, keyed by checkpoint turn count. */
  readonly collapsedDirs: ReadonlyMap<number, ReadonlySet<string>>;
  /** End of the mounted window; null follows the latest row. */
  readonly windowEnd: number | null;
  /** Tables whose cells are cut to one line, as `<message id>:table:<n>`. */
  readonly collapsedTables: ReadonlySet<string>;
  /** Mermaid diagrams shown as their source, as `<message id>:diagram:<n>`. */
  readonly diagramSources: ReadonlySet<string>;
}

export const EMPTY_TIMELINE_VIEW: TimelineView = {
  collapsedTables: new Set(),
  diagramSources: new Set(),
  expandedGroups: new Set(),
  expandedFolds: new Set(),
  expandedMessages: new Set(),
  collapsedDirs: new Map(),
  windowEnd: null,
};

/** Why the latest run failed. A usage limit reads as a warning that names when to retry. */
export interface TimelineError {
  readonly message: string;
  readonly usageLimit: { readonly resetAt: string | null } | null;
  /** The user dismissed this failure (its run and message); another one shows again. */
  readonly dismissed: boolean;
}

/** One painted line; a click dispatches `action` with `payload`. */
export interface TimelineLine {
  readonly text: StyledText;
  readonly action: string | null;
  readonly payload: unknown;
  /** A second, right-aligned part with its own action. */
  readonly right: {
    readonly text: StyledText;
    readonly action: string;
    readonly payload: unknown;
  } | null;
  /** An inline image drawn in place of the text (only when the terminal draws images). */
  readonly image: TimelineImage | null;
  /** Further parts after the text, each with its own action (a table's copy and cell controls). */
  readonly parts: ReadonlyArray<{
    readonly text: StyledText;
    readonly action: string;
    readonly payload: unknown;
  }> | null;
}

/** An image attachment's inline preview, `columns` × `rows` cells, aspect kept. */
export interface TimelineImage {
  readonly id: string;
  /** Encoded image bytes the Image brick draws. */
  readonly source: Uint8Array;
  readonly columns: number;
  readonly rows: number;
}

/** Pixel size of one terminal cell. */
export interface CellPixels {
  readonly width: number;
  readonly height: number;
}

/** Used until the terminal reports its pixel size (the old TUI's fallback). */
export const FALLBACK_CELL_PIXELS: CellPixels = { width: 18, height: 35 };

export interface TimelineItem {
  readonly key: string;
  readonly kind:
    | "notice"
    | "pager"
    | "lineage"
    | "message"
    | "work"
    | "fold"
    | "files"
    | "stamp"
    | "background";
  readonly align: "left" | "right";
  readonly boxed: boolean;
  /** Width of the item's box (the column width unless boxed). */
  readonly width: number;
  readonly marginTop: number;
  readonly marginBottom: number;
  readonly lines: ReadonlyArray<TimelineLine>;
  /**
   * A collapsed message: `lines[from, to)` sit in a box `rows` tall that
   * clips them, soft-wrapped rows included.
   */
  readonly clip: { readonly from: number; readonly to: number; readonly rows: number } | null;
}

export interface TimelineState {
  readonly kind: "none" | "thread";
  readonly emptyHint: string;
  readonly width: number;
  readonly header: TimelineLine | null;
  readonly context: StyledText | null;
  readonly items: ReadonlyArray<TimelineItem>;
  /** The newest row is mounted, so the view sticks to the bottom. */
  readonly showingLatest: boolean;
  readonly rowCount: number;
  readonly windowStart: number;
  readonly windowEnd: number;
  /** The working row; `refreshInMs` is when its time next changes (`timeline.tick`). */
  readonly working: {
    readonly text: StyledText;
    readonly elapsedSeconds: number | null;
    readonly refreshInMs: number;
  } | null;
  readonly plan: {
    readonly id: string;
    readonly title: StyledText;
    readonly lines: ReadonlyArray<StyledText>;
    readonly hint: string;
  } | null;
}

export interface TimelineInput {
  readonly detail: OrchestrationThread | null;
  readonly hasOlderTurns: boolean;
  readonly loadingOlderTurns: boolean;
  /** Why the thread's MC cannot be reached (it left the cluster); null while it can. */
  readonly unreachable?: string | null;
  readonly approvalCount: number;
  readonly view: TimelineView;
  /** Turns whose fold starts open: the ones the user stopped in this session. */
  readonly openTurns?: ReadonlySet<string>;
  /** The code block or table just copied (`<message id>:code:<n>`), which shows it. */
  readonly copied?: string | null;
  /** The title of another thread of this environment (a message's sender), when it is known. */
  readonly threadTitle?: (threadId: string) => string | null;
  /** The thread this one is a subagent of. */
  readonly parent?: { readonly threadId: string; readonly title: string } | null;
  /** Width of the conversation pane (border and padding included). */
  readonly paneWidth: number;
  readonly nowMs: number;
  readonly palette: Palette;
  readonly emptyHint: string;
  /** The thread's error, as the banner shows it; null when there is none. */
  readonly error?: TimelineError | null;
  /** Image attachments' links and previews; without it every link reads unavailable. */
  readonly attachments?: AttachmentPreviews["get"];
  /** Sizes inline previews (default: `FALLBACK_CELL_PIXELS`). */
  readonly cellPixels?: CellPixels | null;
  /** What the MC drew of a reply's Mermaid diagram (`mermaidDiagrams.ts`); without it they are code. */
  readonly diagrams?: (source: string) => MermaidRenderResult | undefined;
  /** Colours a reply's code by its language (`codeColours.ts`); without it code is one colour. */
  readonly codeColours?: CodeColouring;
  /** Where the thread works; a file change in it is named relative to it. */
  readonly workspaceRoot?: string | null;
  /** How this device writes times (default: the locale's). */
  readonly timestampFormat?: TimestampFormat;
}

const line = (
  text: StyledText,
  action: string | null = null,
  payload: unknown = null,
  right: TimelineLine["right"] = null,
): TimelineLine => ({ text, action, payload, right, image: null, parts: null });

const item = (
  key: string,
  kind: TimelineItem["kind"],
  width: number,
  lines: ReadonlyArray<TimelineLine>,
  extra: Partial<
    Pick<TimelineItem, "align" | "boxed" | "marginTop" | "marginBottom" | "clip">
  > = {},
): TimelineItem => ({
  key,
  kind,
  align: extra.align ?? "left",
  boxed: extra.boxed ?? false,
  width,
  marginTop: extra.marginTop ?? 0,
  marginBottom: extra.marginBottom ?? 0,
  lines,
  clip: extra.clip ?? null,
});

/** Timeline column width inside a pane of `paneWidth` (border + padding = 4). */
export const timelineColumnWidth = (paneWidth: number): number =>
  Math.min(CHAT_CONTENT_MAX_WIDTH, Math.max(1, paneWidth - 4));

export function buildTimelineState(input: TimelineInput): TimelineState {
  const { detail, palette, view } = input;
  const contentWidth = Math.max(1, input.paneWidth - 4);
  const width = timelineColumnWidth(input.paneWidth);
  if (!detail) {
    return {
      kind: "none",
      emptyHint: input.emptyHint,
      width,
      header: null,
      context: null,
      items: [],
      showingLatest: true,
      rowCount: 0,
      windowStart: 0,
      windowEnd: 0,
      working: null,
      plan: null,
    };
  }

  const rows = deriveTimelineEntries(detail.messages, detail.activities, detail.latestTurn ?? null);
  const window = resolveTimelineWindow(rows.length, view.windowEnd);
  const showingLatest = window.end === rows.length;
  const checkpointByMessage = changedFilesByMessage(detail.checkpoints);
  const ctx: RowContext = {
    palette,
    width,
    view,
    // A turn that failed starts open too: where it stopped and why is what the user needs.
    openTurns:
      detail.latestTurn?.state === "error"
        ? new Set([...(input.openTurns ?? []), detail.latestTurn.turnId as string])
        : (input.openTurns ?? new Set()),
    copied: input.copied ?? null,
    threadTitle: input.threadTitle ?? (() => null),
    checkpointByMessage,
    attachments: input.attachments ?? (() => UNAVAILABLE_ATTACHMENT),
    cellPixels: input.cellPixels ?? FALLBACK_CELL_PIXELS,
    diagrams: input.diagrams ?? null,
    codeColours: input.codeColours,
    workspaceRoot: input.workspaceRoot ?? null,
    nowMs: input.nowMs,
    timestampFormat: input.timestampFormat ?? "locale",
    withMeta: repliesWithMeta(detail),
  };

  const items: TimelineItem[] = [];
  if (input.unreachable) {
    items.push(
      item(
        "notice:unreachable",
        "notice",
        width,
        [line(styled(chunk(input.unreachable, { fg: palette.warning })))],
        { marginBottom: 1 },
      ),
    );
  }
  if (input.parent) {
    items.push(
      item(
        "lineage",
        "lineage",
        width,
        [
          line(
            styled(
              chunk("↳ Subagent of ", { fg: palette.dim }),
              chunk(input.parent.title, { fg: palette.accent }),
            ),
            "thread.open",
            { key: threadKey(input.parent.threadId) },
          ),
        ],
        { marginBottom: 1 },
      ),
    );
  }
  if (window.start > 0 || input.hasOlderTurns) {
    const label =
      window.start > 0
        ? `▴ ${window.start} earlier entries`
        : input.loadingOlderTurns
          ? "▴ Loading earlier turns…"
          : "▴ Load earlier turns";
    items.push(
      item(
        "pager:older",
        "pager",
        width,
        [line(styled(chunk(label, { fg: palette.dim })), "timeline.showOlder")],
        { marginBottom: 1 },
      ),
    );
  }
  for (const row of rows.slice(window.start, window.end)) pushRow(items, row, ctx);
  if (!showingLatest) {
    items.push(
      item(
        "pager:newer",
        "pager",
        width,
        [
          line(
            styled(chunk(`▾ ${rows.length - window.end} newer entries`, { fg: palette.dim })),
            "timeline.showNewer",
          ),
        ],
        { marginTop: 1, marginBottom: 1 },
      ),
    );
  }

  // Work the provider still runs once the turn settled: named, and never a command row.
  const background = (detail as OrchestrationThread & TuiThreadExtras).pendingBackgroundTasks ?? [];
  if (showingLatest && background.length > 0) {
    items.push(
      item(
        "background",
        "background",
        width,
        [
          line(
            styled(
              chunk("◌ ", { fg: palette.accent }),
              chunk(`Background work · ${background.length} running`, { fg: palette.dim }),
            ),
          ),
          ...background.map((task) =>
            line(
              styled(
                chunk(`  ${task.taskType ?? "task"}`, { fg: palette.text }),
                task.description !== undefined &&
                  chunk(` · ${task.description}`, { fg: palette.dim }),
              ),
            ),
          ),
        ],
        { marginTop: 1 },
      ),
    );
  }

  const error = showingLatest ? input.error : null;
  if (error) {
    const reset = error.usageLimit?.resetAt;
    items.push(
      item(
        "error",
        "notice",
        width,
        [
          error.dismissed
            ? line(
                styled(chunk("✕ error hidden · show", { fg: palette.dim })),
                "timeline.error.show",
              )
            : line(
                styled(
                  error.usageLimit
                    ? chunk(
                        `⚠ Usage limit reached${
                          reset
                            ? ` · retry at ${formatDayAwareTimestamp(reset, ctx.timestampFormat, input.nowMs)}`
                            : ""
                        }`,
                        { fg: palette.warning },
                      )
                    : chunk(`✖ ${error.message}`, { fg: palette.error }),
                ),
                null,
                null,
                {
                  action: "timeline.error.dismiss",
                  payload: null,
                  text: styled(chunk("✕ dismiss", { fg: palette.dim })),
                },
              ),
        ],
        { marginTop: 1 },
      ),
    );
  }

  const plan = showingLatest ? latestActionableProposedPlan(detail) : null;
  const working = showingLatest && isWorking(detail);
  const workingFrom = working ? workingStartedAt(detail) : null;
  const elapsed = working ? workingElapsedSeconds(workingFrom, input.nowMs) : null;
  const contextWindow = deriveContextWindow(detail.activities);

  return {
    kind: "thread",
    emptyHint: input.emptyHint,
    width,
    header: headerLine(detail, input.approvalCount, contentWidth, palette),
    context: contextWindow
      ? styled(
          chunk("context  ", { fg: palette.dim }),
          chunk(formatContextWindow(contextWindow), {
            fg:
              contextWindow.usedPercentage === null
                ? palette.dim
                : contextWindow.usedPercentage >= 90
                  ? palette.error
                  : contextWindow.usedPercentage >= 70
                    ? palette.warning
                    : palette.success,
          }),
        )
      : null,
    items,
    showingLatest,
    rowCount: rows.length,
    windowStart: window.start,
    windowEnd: window.end,
    working: working
      ? {
          elapsedSeconds: elapsed,
          // The time moves once a second, not on every frame.
          refreshInMs:
            elapsed === null
              ? 0
              : 1000 - ((((input.nowMs - Date.parse(workingFrom!)) % 1000) + 1000) % 1000),
          text: styled(
            chunk("● ", { fg: palette.accent }),
            elapsed === null
              ? chunk("Working…", { fg: palette.dim })
              : chunk(`Working for ${formatWorkingTimer(elapsed)}`, { fg: palette.dim }),
          ),
        }
      : null,
    plan: plan
      ? {
          id: plan.id,
          title: styled(chunk("◆ ", { fg: palette.accent }), chunk(plan.title, { bold: true })),
          lines: markdownLines(linkifyTimelineUrls(plan.body), palette, Math.max(1, width - 4)),
          hint: "proposed plan · ^Y implement · ^B build mode to refine",
        }
      : null,
  };
}

function headerLine(
  detail: OrchestrationThread,
  approvalCount: number,
  contentWidth: number,
  palette: Palette,
): TimelineLine {
  const status = detail.session?.status ?? "idle";
  const reserved =
    contentWidth >= 64 ? 32 : contentWidth >= 40 ? status.length + 10 : status.length + 2;
  const plan = detail.interactionMode === "plan";
  return line(
    styled(
      chunk(clip(detail.title, Math.max(1, contentWidth - reserved)), {
        fg: palette.text,
        bold: true,
      }),
    ),
    null,
    null,
    {
      action: "",
      payload: null,
      text: styled(
        chunk(approvalCount > 0 ? "pending approval" : status, {
          fg: approvalCount > 0 ? palette.error : ansi(sessionStatusColor(detail.session?.status)),
        }),
        contentWidth >= 40 &&
          chunk(` · ${plan ? "plan" : "build"}`, { fg: plan ? palette.accent : palette.dim }),
        contentWidth >= 64 &&
          chunk(` · ${detail.runtimeMode} · ${relativeTime(detail.updatedAt)}`, {
            fg: palette.dim,
          }),
      ),
    },
  );
}

interface RowContext {
  readonly palette: Palette;
  readonly width: number;
  readonly view: TimelineView;
  readonly openTurns: ReadonlySet<string>;
  readonly copied: string | null;
  readonly threadTitle: (threadId: string) => string | null;
  readonly checkpointByMessage: Map<string, OrchestrationCheckpointSummary>;
  readonly attachments: AttachmentPreviews["get"];
  readonly cellPixels: CellPixels;
  readonly diagrams: ((source: string) => MermaidRenderResult | undefined) | null;
  readonly codeColours: CodeColouring | undefined;
  readonly workspaceRoot: string | null;
  readonly nowMs: number;
  readonly timestampFormat: TimestampFormat;
  /** The replies that end a settled turn, which carry its time and actions. */
  readonly withMeta: ReadonlySet<string>;
}

const UNAVAILABLE_ATTACHMENT: AttachmentPreview = {
  link: { state: "unavailable" },
  image: null,
};

// The web bounds conversation previews to a ~206x220px grid cell; terminal
// cells are chunky, so the TUI gets twice that pixel box and scales down into
// it (never up).
const PREVIEW_MAX_WIDTH_PX = 420;
const PREVIEW_MAX_HEIGHT_PX = 440;
/** The least room the link part of an attachment line keeps before it is clipped. */
const ATTACHMENT_TAIL_MIN = 8;
/** Room a user bubble keeps for an attachment line's link/state tail. */
const ATTACHMENT_TAIL_WIDTH = 28;

type ImageAttachment = {
  readonly type?: string;
  readonly id: string;
  readonly name: string;
  readonly sizeBytes: number;
};
type FileAttachment = ImageAttachment & { readonly type: "file"; readonly mimeType: string };

/** `2 MB`, `12 KB`, `300 B`: a file's size at the unit it reads best in. */
function fileSize(bytes: number): string {
  if (bytes >= 1024 * 1024) return `${Math.round(bytes / (1024 * 1024))} MB`;
  if (bytes >= 1024) return `${Math.round(bytes / 1024)} KB`;
  return `${bytes} B`;
}

/** A file's kind as people say it: its extension (`PDF`), else its mime subtype. */
function fileKind(file: Pick<FileAttachment, "name" | "mimeType">): string {
  const extension = /\.([a-z0-9]{1,8})$/i.exec(file.name)?.[1];
  const subtype = file.mimeType.split("/")[1]?.split(/[+;]/)[0];
  return (extension ?? subtype ?? file.mimeType).toUpperCase();
}

const FILE_GLYPH = "▤";

/** `▤ name · PDF · 2 MB`: what a sent file is called. */
export function fileLabel(file: FileAttachment): string {
  return `${FILE_GLYPH} ${file.name} · ${fileKind(file)} · ${fileSize(file.sizeBytes)}`;
}

/** What a message's input intent reads as; a plain turn start says nothing. */
function intentMarker(intent: TuiMessageIntent | undefined): string | null {
  if (intent === "queued_turn") return "Queued behind the active turn";
  if (intent === "steer") return "Steered the active turn";
  if (intent === "promoted_queued_to_steer") {
    return "Originally queued, then promoted to steer the active turn";
  }
  return null;
}

/** `▣ name · 12 KB`: what an image attachment is called everywhere. */
export function attachmentLabel(attachment: Pick<ImageAttachment, "name" | "sizeBytes">): string {
  const sizeKb = Math.max(1, Math.round(attachment.sizeBytes / 1024));
  return `${TOOL_ICONS.imageView.glyph} ${attachment.name} · ${sizeKb} KB`;
}

/** The attachment's link part: its URL, or why there is none yet. */
function attachmentLinkText(link: AttachmentPreview["link"]): string {
  if (link.state === "ready") return link.url;
  return link.state === "pending" ? "resolving link…" : "link unavailable";
}

/** Cells a preview takes: scaled into the preview box, never up, then into `maxColumns`. */
export function previewCells(
  image: { readonly imageWidth: number; readonly imageHeight: number },
  maxColumns: number,
  cell: CellPixels,
): { readonly columns: number; readonly rows: number } {
  const scale = Math.min(
    1,
    PREVIEW_MAX_WIDTH_PX / image.imageWidth,
    PREVIEW_MAX_HEIGHT_PX / image.imageHeight,
  );
  const columns = Math.min(
    Math.max(1, Math.round((image.imageWidth * scale) / cell.width)),
    Math.max(1, maxColumns),
  );
  const rows = Math.max(
    1,
    Math.round((image.imageHeight / image.imageWidth) * columns * (cell.width / cell.height)),
  );
  return { columns, rows };
}

/**
 * An image attachment: its label and link line (a click opens the link), and
 * the inline preview under it once loaded (a click opens it full size).
 */
function attachmentLines(
  attachment: ImageAttachment | FileAttachment,
  lineWidth: number,
  ctx: RowContext,
): TimelineLine[] {
  const file = attachment.type === "file";
  const { link, image } = ctx.attachments(attachment.id, file ? "file" : "image");
  const label = file ? fileLabel(attachment as FileAttachment) : attachmentLabel(attachment);
  const linkText = attachmentLinkText(link);
  const tail = image ? `click image to expand · ${linkText}` : linkText;
  const tailWidth = Math.max(ATTACHMENT_TAIL_MIN, lineWidth - Bun.stringWidth(label) - 2);
  const lines = [
    line(
      styled(
        chunk(label, { fg: ctx.palette.accent }),
        chunk(`  ${clip(tail, tailWidth)}`, { fg: ctx.palette.dim }),
      ),
      link.state === "ready" ? "link.open" : null,
      link.state === "ready" ? { url: link.url } : null,
    ),
  ];
  if (image) {
    const cells = previewCells(image, lineWidth - 2, ctx.cellPixels);
    lines.push({
      ...line(styled(), "image.open", { id: attachment.id }),
      image: { id: attachment.id, source: image.source, ...cells },
    });
  }
  return lines;
}

function pushRow(items: TimelineItem[], row: TimelineRow, ctx: RowContext): void {
  if (row.kind !== "turn-fold") {
    pushFoldable(items, row, ctx);
    return;
  }
  const expanded = ctx.view.expandedFolds.has(row.id) !== ctx.openTurns.has(row.turnId);
  items.push(
    item(
      row.id,
      "fold",
      ctx.width,
      [
        line(
          styled(chunk(`${expanded ? "▾" : "▸"} ${row.label}`, { fg: ctx.palette.dim })),
          "timeline.fold.toggle",
          { id: row.id },
        ),
      ],
      { marginTop: 1 },
    ),
  );
  // The work of a turn that starts open starts open too: it shows where the turn stopped.
  const settled = { startsOpen: ctx.openTurns.has(row.turnId) };
  if (expanded) for (const hidden of row.hiddenRows) pushFoldable(items, hidden, ctx, settled);
}

/**
 * A row of the conversation; a `settled` turn's work reads as a summary, unless
 * it is one call, which reads as itself.
 */
function pushFoldable(
  items: TimelineItem[],
  row: FoldableRow,
  ctx: RowContext,
  settled: { readonly startsOpen: boolean } | null = null,
): void {
  const { palette, width } = ctx;
  if (row.kind === "work") {
    const lines =
      settled && row.groupedEntries.length > 1
        ? summarizedGroupLines(row.id, row.groupedEntries, ctx, settled.startsOpen)
        : workGroupLines(row.id, row.groupedEntries, ctx);
    items.push(item(row.id, "work", width, lines, { marginBottom: 1 }));
    return;
  }
  const message = row.message;
  const rawBody = message.text.trim().length > 0 ? message.text : "…";
  const body = linkifyTimelineUrls(rawBody);
  // Images draw (when the terminal can) and files list; a kind this build does not know has nothing to show.
  const images: Array<ImageAttachment | FileAttachment> = [
    ...(message.attachments ?? []).filter((attachment) => attachment.type === "image"),
    ...(message.attachments ?? []).filter((attachment) => attachment.type === "file"),
  ] as never;

  if (message.role === "user") {
    // MessagesTimeline's bubble: its longest line plus chrome, at most 80% of
    // the column, and wide enough for an attachment's label, link and preview.
    const maxBubble = Math.max(8, Math.floor(width * 0.8));
    const longest = rawBody
      .split("\n")
      .reduce((max, text) => Math.max(max, Bun.stringWidth(text)), 1);
    const attachmentMinWidth =
      images.length > 0
        ? Math.min(
            maxBubble,
            Math.max(
              images.reduce(
                (max, attachment) =>
                  Math.max(
                    max,
                    Bun.stringWidth(
                      attachment.type === "file"
                        ? fileLabel(attachment as FileAttachment)
                        : attachmentLabel(attachment),
                    ),
                  ),
                0,
              ) +
                2 +
                ATTACHMENT_TAIL_WIDTH,
              Math.round(PREVIEW_MAX_WIDTH_PX / ctx.cellPixels.width),
            ) + 4,
          )
        : 1;
    // A message another agent sent says which thread it came from, and opens it.
    const senderThreadId = (message as { senderThreadId?: string }).senderThreadId;
    const sender = senderThreadId
      ? `↩ from ${ctx.threadTitle(senderThreadId) ?? "another agent"}`
      : null;
    // A message waiting for its turn says so, and where it stands in line.
    const queued = (message as { queued?: TuiQueuedMessage }).queued;
    const waiting = queued
      ? `⏸ queued${queued.position === null ? "" : ` · ${queued.position}`}${queued.held ? " · held" : ""}`
      : null;
    // A message that has gone out says how it reached the agent.
    const marker = intentMarker((message as { intent?: TuiMessageIntent }).intent);
    const canCollapse = shouldCollapseUserMessage(rawBody);
    const expanded = ctx.view.expandedMessages.has(message.id);
    const toggle = expanded ? "⌃ Show less" : "⌄ Show full message";
    const bubbleWidth = Math.max(
      attachmentMinWidth,
      Math.min(
        width,
        maxBubble,
        Math.max(
          longest,
          sender ? Bun.stringWidth(sender) : 0,
          waiting ? Bun.stringWidth(waiting) : 0,
          marker && !waiting ? Bun.stringWidth(marker) : 0,
        ) + 4,
      ),
    );
    const innerWidth = Math.max(1, bubbleWidth - 4);
    const bodyLines = markdownLines(body, palette, innerWidth);
    const imageLines = images.flatMap((attachment) =>
      attachmentLines(attachment, Math.max(8, innerWidth), ctx),
    );
    const head = [
      ...(waiting ? [line(styled(chunk(waiting, { fg: palette.warning })))] : []),
      ...(marker && !waiting ? [line(styled(chunk(marker, { fg: palette.dim })))] : []),
      ...(sender && senderThreadId
        ? [
            line(styled(chunk(sender, { fg: palette.dim })), "thread.open", {
              key: threadKey(senderThreadId),
            }),
          ]
        : []),
      ...(imageLines.length > 0 ? [...imageLines, line(styled(chunk("")))] : []),
    ];
    const collapsed = canCollapse && !expanded;
    const shown = collapsed ? clipRows(bodyLines, innerWidth) : bodyLines;
    items.push(
      item(
        row.id,
        "message",
        bubbleWidth,
        [
          ...head,
          ...shown.map((text) => line(text)),
          ...(canCollapse
            ? [
                line(styled(chunk(toggle, { fg: palette.dim })), "timeline.message.toggle", {
                  id: message.id,
                }),
              ]
            : []),
        ],
        {
          align: "right",
          boxed: true,
          marginTop: 1,
          clip: collapsed
            ? {
                from: head.length,
                to: head.length + shown.length,
                rows: COLLAPSED_USER_MESSAGE_ROWS,
              }
            : null,
        },
      ),
    );
    const stamp = stampLine(message.createdAt, ctx);
    items.push(
      item(`stamp:${message.id}`, "stamp", Bun.stringWidth(plainText(stamp.text)), [stamp], {
        align: "right",
        marginBottom: 1,
      }),
    );
    return;
  }

  const imageLines = images.flatMap((attachment) => attachmentLines(attachment, width, ctx));
  const meta = ctx.withMeta.has(message.id) && !message.streaming;
  const checkpoint = ctx.checkpointByMessage.get(message.id);
  items.push(
    item(
      row.id,
      "message",
      width,
      [
        ...replyLines(message.id, body, message.streaming, ctx),
        ...(imageLines.length > 0 ? [line(styled(chunk(""))), ...imageLines] : []),
        ...(meta ? [replyMetaLine(message, ctx)] : []),
      ],
      { marginTop: 1, marginBottom: checkpoint ? 0 : 1 },
    ),
  );
  if (checkpoint) {
    items.push(
      item(`files:${message.id}`, "files", width, changedFilesLines(checkpoint, ctx), {
        marginTop: 1,
        marginBottom: 1,
      }),
    );
  }
}

/**
 * The replies that carry their turn's time and actions: each turn's last one, once
 * the turn is no longer running (commentary would otherwise flash a time mid-work).
 * Replies outside any turn count as one turn until the user's next message.
 */
function repliesWithMeta(detail: OrchestrationThread): Set<string> {
  const last = new Map<string, string>();
  let asked = 0;
  for (const message of detail.messages) {
    if (message.role === "user") asked += 1;
    if (message.role === "assistant") last.set(message.turnId ?? `asked:${asked}`, message.id);
  }
  const running = isWorking(detail) ? (detail.latestTurn?.turnId ?? null) : null;
  return new Set([...last].filter(([turn]) => turn !== running).map(([, id]) => id));
}

/** When a message was sent; a click shows its full time. */
function stampLine(sentAt: string, ctx: RowContext): TimelineLine {
  return line(
    styled(
      chunk(formatDayAwareTimestamp(sentAt, ctx.timestampFormat, ctx.nowMs), {
        fg: ctx.palette.dim,
      }),
    ),
    "timeline.stamp",
    { full: formatChatTimestampTooltip(sentAt, ctx.timestampFormat) },
  );
}

/** Under a turn's last reply: copy it, and when it was written. */
function replyMetaLine(
  message: OrchestrationThread["messages"][number],
  ctx: RowContext,
): TimelineLine {
  const key = `${message.id}:reply`;
  const copied = ctx.copied === key;
  return {
    ...line(styled(chunk(""))),
    parts: [
      {
        text: styled(
          chunk(copied ? "✓ Copied" : "⧉ Copy", {
            fg: copied ? ctx.palette.success : ctx.palette.dim,
          }),
        ),
        action: "timeline.copy",
        payload: { key, text: message.text, label: "Reply" },
      },
      { text: styled(chunk(" · ", { fg: ctx.palette.dim })), action: "", payload: null },
      {
        text: styled(
          chunk(formatDayAwareTimestamp(message.updatedAt, ctx.timestampFormat, ctx.nowMs), {
            fg: ctx.palette.dim,
          }),
        ),
        action: "timeline.stamp",
        payload: { full: formatChatTimestampTooltip(message.updatedAt, ctx.timestampFormat) },
      },
    ],
  };
}

/**
 * A reply's Markdown as lines. A click on a code block copies its source; a
 * table is followed by a row that copies it as Markdown or CSV and cuts its
 * cells to one line or wraps them again. A Mermaid diagram is drawn in
 * characters when the MC can, its title switching to its source and back; a
 * click on it copies its source. What was just copied shows it. A finished one-line
 * shell block offers to run its command in the thread's terminal (shellRun.ts).
 */
function replyLines(
  messageId: string,
  body: string,
  streaming: boolean,
  ctx: RowContext,
): TimelineLine[] {
  const { palette, width } = ctx;
  const tableKey = (index: number) => `${messageId}:table:${index}`;
  const diagramKey = (index: number) => `${messageId}:diagram:${index}`;
  const blocks = markdownBlockLines(
    body,
    palette,
    width,
    (index) => ctx.view.collapsedTables.has(tableKey(index)),
    ctx.diagrams
      ? {
          get: ctx.diagrams,
          showSource: (index) => ctx.view.diagramSources.has(diagramKey(index)),
        }
      : undefined,
    ctx.codeColours,
  );
  const lines: TimelineLine[] = [];
  blocks.forEach((block, position) => {
    if (block.code) {
      const key = `${messageId}:code:${block.code.index}`;
      const text =
        ctx.copied === key
          ? { chunks: block.text.chunks.map((part) => ({ ...part, fg: palette.success })) }
          : block.text;
      const label = block.diagram ? "Diagram source" : "Code block";
      const command = runnableShellCommand(block.code, streaming);
      const toggle = command
        ? {
            text: styled(chunk("▶ Run", { fg: palette.dim })),
            action: "timeline.code.run",
            payload: { command },
          }
        : block.diagram?.title && block.diagram.drawable
          ? {
              text: styled(
                chunk(
                  ctx.view.diagramSources.has(diagramKey(block.diagram.index))
                    ? "⇄ Drawing"
                    : "⇄ Source",
                  { fg: palette.dim },
                ),
              ),
              action: "timeline.diagram.toggle",
              payload: { key: diagramKey(block.diagram.index) },
            }
          : null;
      lines.push(line(text, "timeline.copy", { key, text: block.code.source, label }, toggle));
      return;
    }
    lines.push(line(block.text));
    const table = block.table;
    if (!table || blocks[position + 1]?.table?.index === table.index) return;
    const key = tableKey(table.index);
    const collapsed = ctx.view.collapsedTables.has(key);
    const part = (label: string, action: string, payload: unknown) => ({
      text: styled(chunk(label, { fg: palette.dim })),
      action,
      payload,
    });
    const copyPart = (format: "Markdown" | "CSV", text: string) => {
      const copyKey = `${key}:${format}`;
      return ctx.copied === copyKey
        ? {
            text: styled(chunk(`✓ Copied ${format}`, { fg: palette.success })),
            action: "timeline.copy",
            payload: { key: copyKey, text, label: "Table" },
          }
        : part(`⧉ ${format}`, "timeline.copy", { key: copyKey, text, label: "Table" });
    };
    lines.push({
      ...line(styled(chunk(""))),
      parts: [
        copyPart("Markdown", tableToMarkdown(table.table)),
        part(" · ", "", null),
        copyPart("CSV", tableToCsv(table.table)),
        part(" · ", "", null),
        part(collapsed ? "⇲ Expand cells" : "⇱ Collapse cells", "timeline.table.toggle", { key }),
      ],
    });
  });
  return lines;
}

/**
 * The lines a collapsed message mounts: enough to fill its clipped rows
 * (counting soft-wrapped rows), the last one possibly cut by the clip.
 */
function clipRows(lines: ReadonlyArray<StyledText>, innerWidth: number): StyledText[] {
  const kept: StyledText[] = [];
  let rows = 0;
  for (const text of lines) {
    if (rows >= COLLAPSED_USER_MESSAGE_ROWS) break;
    const plain = text.chunks.map((part) => part.text).join("");
    kept.push(text);
    rows += Math.max(1, Math.ceil(Bun.stringWidth(plain) / Math.max(1, innerWidth)));
  }
  return kept;
}

function workGroupLines(
  id: string,
  entries: ReadonlyArray<WorkLogEntry>,
  ctx: RowContext,
): TimelineLine[] {
  const { palette } = ctx;
  const hasOverflow = entries.length > MAX_VISIBLE_WORK_LOG_ENTRIES;
  const expanded = ctx.view.expandedGroups.has(id);
  const visible = hasOverflow && !expanded ? entries.slice(-MAX_VISIBLE_WORK_LOG_ENTRIES) : entries;
  const hidden = entries.length - visible.length;
  const lines = visible.map((entry) => callLine(entry, toolRow(entry, ctx)));
  if (hasOverflow) {
    lines.push(
      line(
        styled(
          chunk(
            expanded
              ? "  ⌃ Show fewer tool calls"
              : `  ⌄ +${hidden} previous tool call${hidden === 1 ? "" : "s"}`,
            { fg: palette.dim },
          ),
        ),
        "timeline.workGroup.toggle",
        { id },
      ),
    );
  }
  return lines;
}

// A subagent's row opens the thread it works in.
// A file change's row opens its diff.
const callLine = (entry: WorkLogEntry, text: StyledText): TimelineLine =>
  entry.childThreadId
    ? line(text, "thread.open", { key: threadKey(entry.childThreadId) })
    : entry.diff
      ? line(text, "diff.item", { id: entry.id })
      : line(text);

/**
 * A finished turn's group of calls: what they did in one sentence, marked when
 * one failed, which opens into every call, labelled by what it did.
 */
function summarizedGroupLines(
  id: string,
  entries: ReadonlyArray<WorkLogEntry>,
  ctx: RowContext,
  startsOpen: boolean,
): TimelineLine[] {
  const { palette } = ctx;
  const summary = summarizeToolCalls(entries.map((entry) => entry.item ?? {}));
  const expanded = ctx.view.expandedGroups.has(id) !== startsOpen;
  const head = line(
    styled(
      chunk(`${expanded ? "▾" : "▸"} ${summary.text}`, { fg: palette.dim }),
      summary.failed && chunk(` ${STATUS_ICONS.failure.glyph}`, { fg: palette.error }),
    ),
    "timeline.workGroup.toggle",
    { id },
  );
  if (!expanded) return [head];
  return [
    head,
    ...entries.map((entry) => callLine(entry, toolRow(entry, ctx, callShown(entry, ctx)))),
  ];
}

/** How an opened group shows a call: a command as it was typed with its exit code, a file in the workspace relative to it. */
function callShown(
  entry: WorkLogEntry,
  ctx: RowContext,
): { label: string; preview: string | null } | undefined {
  const item = entry.item;
  if (item?.type === "command_execution" && typeof item.input === "string") {
    return {
      label: commandDisplayText(item.input),
      preview: typeof item.exitCode === "number" ? `exit ${item.exitCode}` : null,
    };
  }
  if (item?.type === "file_change" && typeof item.fileName === "string") {
    return {
      label: workspaceRelative(item.fileName, ctx.workspaceRoot),
      preview: entry.detail ?? null,
    };
  }
  if (item?.type === "dynamic_tool" && item.input != null) {
    return { label: workLogLabel(entry), preview: JSON.stringify(item.input) };
  }
  return undefined;
}

/** icon · label · status glyph · muted preview (port of ToolRow). */
function toolRow(
  entry: WorkLogEntry,
  ctx: RowContext,
  shown: { label: string; preview: string | null } = {
    label: workLogLabel(entry),
    preview: workLogPreview(entry),
  },
): StyledText {
  const { palette, width } = ctx;
  const { label, preview } = shown;
  const status = workLogStatusKind(entry);
  const word = workLogStatusLabel(entry);
  // A call that neither succeeded nor failed (declined, stopped) is the neutral dash.
  const glyph = status !== "neutral" || word !== null ? STATUS_ICONS[status].glyph : null;
  const mark = [glyph, word].filter((part) => part !== null).join(" ");
  return styled(
    chunk(`${workLogIcon(entry)} `, {
      fg: entry.tone === "error" ? palette.error : palette.accent,
    }),
    chunk(clip(label, Math.max(8, width - mark.length - 4)), { fg: palette.text }),
    mark.length > 0 &&
      chunk(` ${mark}`, {
        fg:
          status === "success"
            ? palette.success
            : status === "failure"
              ? palette.error
              : palette.faint,
      }),
    preview !== null &&
      chunk(`  ${clip(preview, Math.max(8, width - label.length - mark.length - 8))}`, {
        fg: palette.dim,
      }),
  );
}

/** The changed-files tree under the message that produced a checkpoint. */
function changedFilesLines(
  checkpoint: OrchestrationCheckpointSummary,
  ctx: RowContext,
): TimelineLine[] {
  const { palette, width } = ctx;
  const turnCount = checkpoint.checkpointTurnCount;
  const tree = buildFileTree(checkpoint.files);
  const allDirs = collectDirPaths(tree);
  const collapsed = ctx.view.collapsedDirs.get(turnCount) ?? new Set<string>();
  const rows = flattenFileTree(tree, collapsed);
  const { additions, deletions } = diffStat(checkpoint.files);
  const allCollapsed = allDirs.length > 0 && allDirs.every((path) => collapsed.has(path));
  const nameRoom = Math.max(8, width - 20);
  const stats = (add: number, del: number) => [
    chunk(`  +${add}`, { fg: palette.success }),
    chunk(` -${del}`, { fg: palette.error }),
  ];
  const lines: TimelineLine[] = [
    line(
      styled(
        chunk(`changed files (${checkpoint.files.length})`, { fg: palette.dim }),
        ...stats(additions, deletions),
        chunk("   ▸ diff", { fg: palette.dim }),
      ),
      "diff.open",
      { turnCount },
      allDirs.length > 0
        ? {
            text: styled(chunk(allCollapsed ? "expand all" : "collapse all", { fg: palette.dim })),
            action: "timeline.files.toggleAll",
            payload: { turnCount },
          }
        : null,
    ),
  ];
  for (const row of rows.slice(0, CHANGED_FILES_ROW_CAP)) {
    const indent = "  ".repeat(row.depth + 1);
    if (row.kind === "dir") {
      lines.push(
        line(
          styled(
            chunk(`${indent}${row.collapsed ? "▸" : "▾"} `, { fg: palette.dim }),
            chunk(clip(`${row.name}/`, nameRoom), { fg: palette.text }),
            ...stats(row.additions, row.deletions),
          ),
          "timeline.files.toggleDir",
          { turnCount, path: row.path },
        ),
      );
      continue;
    }
    const typeColor = fileTypeColor(row.path);
    lines.push(
      line(
        styled(
          chunk(`${indent}${fileGlyph(row.path)} `, {
            fg: typeColor ? ansi(typeColor) : palette.faint,
          }),
          chunk(clip(row.name, nameRoom), { fg: palette.text }),
          ...stats(row.additions, row.deletions),
        ),
        "diff.open",
        { turnCount, path: row.path },
      ),
    );
  }
  if (rows.length > CHANGED_FILES_ROW_CAP) {
    lines.push(
      line(styled(chunk(`  +${rows.length - CHANGED_FILES_ROW_CAP} more`, { fg: palette.dim }))),
    );
  }
  return lines;
}

/** Every folder path of a checkpoint's tree, for "collapse all". */
export function checkpointDirPaths(
  detail: OrchestrationThread | null,
  turnCount: number,
): string[] {
  const checkpoint = detail?.checkpoints.find((entry) => entry.checkpointTurnCount === turnCount);
  return checkpoint ? collectDirPaths(buildFileTree(checkpoint.files)) : [];
}
