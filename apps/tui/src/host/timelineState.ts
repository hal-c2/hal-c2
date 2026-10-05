import type { OrchestrationCheckpointSummary, OrchestrationThread } from "@hal-c2/contracts";

import type { TuiQueuedMessage, TuiThreadExtras } from "../orchestrationV2Adapter.ts";
import { shouldCollapseUserMessage } from "@hal-c2/shared/chatMessages";

import { CHAT_CONTENT_MAX_WIDTH } from "../components/ChatView.layout.ts";
import { deriveContextWindow, formatContextWindow } from "../contextWindow.ts";
import { buildFileTree, collectDirPaths, flattenFileTree } from "../fileTree.ts";
import { clip } from "../format.ts";
import { fileGlyph, fileTypeColor, STATUS_ICONS, TOOL_ICONS } from "../icons.ts";
import { latestActionableProposedPlan } from "../proposedPlan.ts";
import { ansi, type Palette, relativeTime, sessionStatusColor } from "../theme.ts";
import {
  changedFilesByMessage,
  deriveTimelineEntries,
  diffStat,
  type FoldableRow,
  isWorking,
  MAX_VISIBLE_WORK_LOG_ENTRIES,
  type TimelineRow,
  workingElapsedSeconds,
  workingStartedAt,
} from "../timeline.ts";
import { linkifyTimelineUrls } from "../timelineLinks.ts";
import {
  workLogIcon,
  workLogLabel,
  workLogPreview,
  workLogStatusKind,
  workLogStatusLabel,
  type WorkLogEntry,
} from "../worklog.ts";
import type { AttachmentPreview } from "./attachmentPreviews.ts";
import { tableToCsv, tableToMarkdown } from "../markdownTable.ts";
import { threadKey } from "./sidebarState.ts";
import { chunk, markdownBlockLines, markdownLines, styled, type StyledText } from "./styledText.ts";

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
}

export const EMPTY_TIMELINE_VIEW: TimelineView = {
  collapsedTables: new Set(),
  expandedGroups: new Set(),
  expandedFolds: new Set(),
  expandedMessages: new Set(),
  collapsedDirs: new Map(),
  windowEnd: null,
};

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
  readonly kind: "pager" | "lineage" | "message" | "work" | "fold" | "files" | "background";
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
  readonly working: { readonly text: StyledText; readonly elapsedSeconds: number | null } | null;
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
  /** Image attachments' links and previews; without it every link reads unavailable. */
  readonly attachments?: (attachmentId: string) => AttachmentPreview;
  /** Sizes inline previews (default: `FALLBACK_CELL_PIXELS`). */
  readonly cellPixels?: CellPixels | null;
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
  };

  const items: TimelineItem[] = [];
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

  const plan = showingLatest ? latestActionableProposedPlan(detail) : null;
  const working = showingLatest && isWorking(detail);
  const elapsed = working ? workingElapsedSeconds(workingStartedAt(detail), input.nowMs) : null;
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
          text: styled(
            chunk("● ", { fg: palette.accent }),
            chunk("Working…", { fg: palette.dim }),
            elapsed !== null && chunk(` ${elapsed}s`, { fg: palette.faint }),
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
  readonly attachments: (attachmentId: string) => AttachmentPreview;
  readonly cellPixels: CellPixels;
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

type ImageAttachment = { readonly id: string; readonly name: string; readonly sizeBytes: number };

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
  attachment: ImageAttachment,
  lineWidth: number,
  ctx: RowContext,
): TimelineLine[] {
  const { link, image } = ctx.attachments(attachment.id);
  const label = attachmentLabel(attachment);
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
  if (expanded) for (const hidden of row.hiddenRows) pushFoldable(items, hidden, ctx);
}

function pushFoldable(items: TimelineItem[], row: FoldableRow, ctx: RowContext): void {
  const { palette, width } = ctx;
  if (row.kind === "work") {
    items.push(
      item(row.id, "work", width, workGroupLines(row.id, row.groupedEntries, ctx), {
        marginBottom: 1,
      }),
    );
    return;
  }
  const message = row.message;
  const rawBody = message.text.trim().length > 0 ? message.text : "…";
  const body = linkifyTimelineUrls(rawBody);
  const images = (message.attachments ?? []).filter((attachment) => attachment.type === "image");

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
                (max, attachment) => Math.max(max, Bun.stringWidth(attachmentLabel(attachment))),
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
    const bubbleWidth = Math.max(
      attachmentMinWidth,
      Math.min(
        width,
        maxBubble,
        Math.max(
          longest,
          sender ? Bun.stringWidth(sender) : 0,
          waiting ? Bun.stringWidth(waiting) : 0,
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
      ...(sender && senderThreadId
        ? [
            line(styled(chunk(sender, { fg: palette.dim })), "thread.open", {
              key: threadKey(senderThreadId),
            }),
          ]
        : []),
      ...(imageLines.length > 0 ? [...imageLines, line(styled(chunk("")))] : []),
    ];
    const canCollapse = shouldCollapseUserMessage(rawBody);
    const expanded = ctx.view.expandedMessages.has(message.id);
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
                line(
                  styled(
                    chunk(expanded ? "⌃ Show less" : "⌄ Show full message", { fg: palette.dim }),
                  ),
                  "timeline.message.toggle",
                  { id: message.id },
                ),
              ]
            : []),
        ],
        {
          align: "right",
          boxed: true,
          marginTop: 1,
          marginBottom: 1,
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
    return;
  }

  const imageLines = images.flatMap((attachment) => attachmentLines(attachment, width, ctx));
  const checkpoint = ctx.checkpointByMessage.get(message.id);
  items.push(
    item(
      row.id,
      "message",
      width,
      [
        ...replyLines(message.id, body, ctx),
        ...(imageLines.length > 0 ? [line(styled(chunk(""))), ...imageLines] : []),
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
 * A reply's Markdown as lines. A click on a code block copies its source; a
 * table is followed by a row that copies it as Markdown or CSV and cuts its
 * cells to one line or wraps them again. What was just copied shows it.
 */
function replyLines(messageId: string, body: string, ctx: RowContext): TimelineLine[] {
  const { palette, width } = ctx;
  const tableKey = (index: number) => `${messageId}:table:${index}`;
  const blocks = markdownBlockLines(body, palette, width, (index) =>
    ctx.view.collapsedTables.has(tableKey(index)),
  );
  const lines: TimelineLine[] = [];
  blocks.forEach((block, position) => {
    if (block.code) {
      const key = `${messageId}:code:${block.code.index}`;
      const text =
        ctx.copied === key
          ? { chunks: block.text.chunks.map((part) => ({ ...part, fg: palette.success })) }
          : block.text;
      lines.push(
        line(text, "timeline.copy", { key, text: block.code.source, label: "Code block" }),
      );
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
  // A subagent's row opens the thread it works in.
  // A file change's row opens its diff.
  const lines = visible.map((entry) =>
    entry.childThreadId
      ? line(toolRow(entry, ctx), "thread.open", { key: threadKey(entry.childThreadId) })
      : entry.diff
        ? line(toolRow(entry, ctx), "diff.item", { id: entry.id })
        : line(toolRow(entry, ctx)),
  );
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

/** icon · label · status glyph · muted preview (port of ToolRow). */
function toolRow(entry: WorkLogEntry, ctx: RowContext): StyledText {
  const { palette, width } = ctx;
  const label = workLogLabel(entry);
  const preview = workLogPreview(entry);
  const status = workLogStatusKind(entry);
  const word = workLogStatusLabel(entry);
  // A call that neither succeeded nor failed (declined, stopped) is the neutral dash.
  const glyph = status !== "neutral" || word !== null ? STATUS_ICONS[status].glyph : null;
  const mark = [glyph, word].filter((part) => part !== null).join(" ");
  return styled(
    chunk(`${workLogIcon(entry)} `, {
      fg: entry.tone === "error" ? palette.error : palette.accent,
    }),
    chunk(label, { fg: palette.text }),
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
