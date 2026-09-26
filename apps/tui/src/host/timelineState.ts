import type { OrchestrationCheckpointSummary, OrchestrationThread } from "@t3tools/contracts";
import { shouldCollapseUserMessage } from "@t3tools/shared/chatMessages";

import { CHAT_CONTENT_MAX_WIDTH } from "../components/ChatView.layout.ts";
import { deriveContextWindow, formatContextWindow } from "../contextWindow.ts";
import { buildFileTree, collectDirPaths, flattenFileTree } from "../fileTree.ts";
import { clip } from "../format.ts";
import { fileTypeColor, STATUS_ICONS, TOOL_ICONS } from "../icons.ts";
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
  type WorkLogEntry,
} from "../worklog.ts";
import { chunk, markdownLines, styled, type StyledText } from "./styledText.ts";

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
  readonly expandedFolds: ReadonlySet<string>;
  readonly expandedMessages: ReadonlySet<string>;
  /** Collapsed changed-files folders, keyed by checkpoint turn count. */
  readonly collapsedDirs: ReadonlyMap<number, ReadonlySet<string>>;
  /** End of the mounted window; null follows the latest row. */
  readonly windowEnd: number | null;
}

export const EMPTY_TIMELINE_VIEW: TimelineView = {
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
}

export interface TimelineItem {
  readonly key: string;
  readonly kind: "pager" | "message" | "work" | "fold" | "files";
  readonly align: "left" | "right";
  readonly boxed: boolean;
  /** Width of the item's box (the column width unless boxed). */
  readonly width: number;
  readonly marginTop: number;
  readonly lines: ReadonlyArray<TimelineLine>;
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
  /** Width of the conversation pane (border and padding included). */
  readonly paneWidth: number;
  readonly nowMs: number;
  readonly palette: Palette;
  readonly emptyHint: string;
}

const line = (
  text: StyledText,
  action: string | null = null,
  payload: unknown = null,
  right: TimelineLine["right"] = null,
): TimelineLine => ({ text, action, payload, right });

const item = (
  key: string,
  kind: TimelineItem["kind"],
  width: number,
  lines: ReadonlyArray<TimelineLine>,
  extra: Partial<Pick<TimelineItem, "align" | "boxed" | "marginTop">> = {},
): TimelineItem => ({
  key,
  kind,
  align: extra.align ?? "left",
  boxed: extra.boxed ?? false,
  width,
  marginTop: extra.marginTop ?? 0,
  lines,
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
  const ctx: RowContext = { palette, width, view, checkpointByMessage };

  const items: TimelineItem[] = [];
  if (window.start > 0 || input.hasOlderTurns) {
    const label =
      window.start > 0
        ? `▴ ${window.start} earlier entries`
        : input.loadingOlderTurns
          ? "▴ Loading earlier turns…"
          : "▴ Load earlier turns";
    items.push(
      item("pager:older", "pager", width, [
        line(styled(chunk(label, { fg: palette.dim })), "timeline.showOlder"),
      ]),
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
          lines: markdownLines(linkifyTimelineUrls(plan.body), palette),
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
    styled(chunk(clip(detail.title, Math.max(1, contentWidth - reserved)), { bold: true })),
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
  readonly checkpointByMessage: Map<string, OrchestrationCheckpointSummary>;
}

function pushRow(items: TimelineItem[], row: TimelineRow, ctx: RowContext): void {
  if (row.kind !== "turn-fold") {
    pushFoldable(items, row, ctx);
    return;
  }
  const expanded = ctx.view.expandedFolds.has(row.id);
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
    items.push(item(row.id, "work", width, workGroupLines(row.id, row.groupedEntries, ctx)));
    return;
  }
  const message = row.message;
  const rawBody = message.text.trim().length > 0 ? message.text : "…";
  const body = markdownLines(linkifyTimelineUrls(rawBody), palette);
  const images = (message.attachments ?? []).filter((attachment) => attachment.type === "image");
  const imageLines = images.map((attachment) =>
    line(
      styled(
        chunk(
          `${TOOL_ICONS.imageView.glyph} ${attachment.name} · ${Math.max(1, Math.round(attachment.sizeBytes / 1024))} KB`,
          { fg: palette.accent },
        ),
      ),
    ),
  );

  if (message.role === "user") {
    const maxBubble = Math.max(8, Math.floor(width * 0.8));
    const canCollapse = shouldCollapseUserMessage(rawBody);
    const toggleWidth = canCollapse ? Bun.stringWidth("⌄ Show full message") : 1;
    const longest = rawBody
      .split("\n")
      .reduce((max, text) => Math.max(max, Bun.stringWidth(text)), toggleWidth);
    const bubbleWidth = Math.max(1, Math.min(width, maxBubble, longest + 4));
    const expanded = ctx.view.expandedMessages.has(message.id);
    const shown = canCollapse && !expanded ? clipRows(body, bubbleWidth - 4) : body;
    items.push(
      item(
        row.id,
        "message",
        bubbleWidth,
        [
          ...imageLines,
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
        { align: "right", boxed: true, marginTop: 1 },
      ),
    );
    return;
  }

  items.push(
    item(row.id, "message", width, [...body.map((text) => line(text)), ...imageLines], {
      marginTop: 1,
    }),
  );
  const checkpoint = ctx.checkpointByMessage.get(message.id);
  if (checkpoint) {
    items.push(
      item(`files:${message.id}`, "files", width, changedFilesLines(checkpoint, ctx), {
        marginTop: 1,
      }),
    );
  }
}

/** Keep the first rows of a collapsed message, counting soft-wrapped rows. */
function clipRows(lines: ReadonlyArray<StyledText>, innerWidth: number): StyledText[] {
  const kept: StyledText[] = [];
  let rows = 0;
  for (const text of lines) {
    const plain = text.chunks.map((part) => part.text).join("");
    const height = Math.max(1, Math.ceil(Bun.stringWidth(plain) / Math.max(1, innerWidth)));
    if (rows + height > COLLAPSED_USER_MESSAGE_ROWS) break;
    kept.push(text);
    rows += height;
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
  const lines = visible.map((entry) => line(toolRow(entry, ctx)));
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
  const glyph = status === "neutral" ? null : STATUS_ICONS[status].glyph;
  return styled(
    chunk(`${workLogIcon(entry)} `, {
      fg: entry.tone === "error" ? palette.error : palette.accent,
    }),
    chunk(label),
    glyph !== null &&
      chunk(` ${glyph}`, {
        fg:
          status === "success"
            ? palette.success
            : status === "failure"
              ? palette.error
              : palette.faint,
      }),
    preview !== null &&
      chunk(`  ${clip(preview, Math.max(8, width - label.length - 8))}`, { fg: palette.dim }),
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
            chunk(clip(`${row.name}/`, nameRoom)),
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
          chunk(`${indent}◦ `, { fg: typeColor ? ansi(typeColor) : palette.faint }),
          chunk(clip(row.name, nameRoom)),
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
